#!/bin/sh
# Deterministic boost tests.
#   tests/run.sh dsp   offline DSP test, no audio hardware
#   tests/run.sh e2e   end-to-end: relaunches Amplify at several boost levels and
#                      measures its real output with Core Audio taps
#   tests/run.sh       both
# e2e plays a short 1 kHz tone per case; turn your volume down (taps measure
# before the device volume, so results don't change). The first run asks you to
# allow System Audio Recording for "Amplify Test". Your Amplify settings are
# restored when it finishes.
set -e
cd "$(dirname "$0")/.."

BUILD="$(mktemp -d)"
APP="${APP:-/Applications/Amplify.app}"
DOMAIN=work.mando.amplify

compile() { # <test file> <output> <app sources…>
    test="$1"; output="$2"; shift 2
    cp "tests/$test" "$BUILD/main.swift"
    swiftc -O -target "$(uname -m)-apple-macos14.2" "$@" "$BUILD/main.swift" -o "$BUILD/$output"
}

run_dsp() {
    echo "== DSP (offline)"
    compile dsp_test.swift dsp_test Sources/DSP.swift Sources/CoreAudio+Helpers.swift
    "$BUILD/dsp_test"
}

quit_amplify() {
    pkill -x Amplify 2>/dev/null || true
    while pgrep -qx Amplify; do sleep 0.2; done
}

relaunch() { # <enabled> <percent> <extra defaults commands>
    quit_amplify
    # Start every case from clean settings so effects from one case can't leak into another.
    defaults delete $DOMAIN 2>/dev/null || true
    defaults write $DOMAIN didSetUpLoginItem -bool true
    defaults write $DOMAIN rememberPerDevice -bool false
    defaults write $DOMAIN boostEnabled -bool "$1"
    defaults write $DOMAIN boostPercent -int "$2"
    [ -z "$3" ] || eval "$3"
    open -g "$APP"
    sleep 2
}

# The measuring tool runs as its own small app so macOS can ask it for System
# Audio Recording permission. It's rebuilt only when its sources change, so the
# permission survives between runs.
TESTER=tests/.build/AmplifyTest.app
build_tester() {
    BIN="$TESTER/Contents/MacOS/AmplifyTest"
    if [ -f "$BIN" ] && [ "$BIN" -nt tests/measure.swift ] && [ "$BIN" -nt Sources/CoreAudio+Helpers.swift ]; then return; fi
    rm -rf "$TESTER"
    mkdir -p "$TESTER/Contents/MacOS"
    compile measure.swift measure Sources/CoreAudio+Helpers.swift
    cp "$BUILD/measure" "$BIN"
    cat > "$TESTER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Amplify Test</string>
    <key>CFBundleIdentifier</key><string>work.mando.amplify.test</string>
    <key>CFBundleExecutable</key><string>AmplifyTest</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
    <key>NSAudioCaptureUsageDescription</key><string>Amplify Test measures Amplify's output to check the volume boost.</string>
</dict>
</plist>
PLIST
    codesign --force --sign - "$TESTER"
}

measure() { # <args…>
    out="$BUILD/out.txt"; err="$BUILD/err.txt"
    : > "$out"; : > "$err"
    open -W -n --stdout "$out" --stderr "$err" "$TESTER" --args "$@" || true
    cat "$err" >&2
    cat "$out"
}

run_e2e() {
    echo "== End to end ($APP)"
    [ -d "$APP" ] || { echo "No app at $APP (build it, or set APP=…)"; exit 1; }
    build_tester

    # Snapshot all Amplify settings and restore them (and relaunch it) when done.
    SAVED="$BUILD/settings.plist"
    defaults export $DOMAIN "$SAVED" 2>/dev/null || true
    trap 'quit_amplify; defaults delete $DOMAIN 2>/dev/null; [ -f "$SAVED" ] && defaults import $DOMAIN "$SAVED"; open -g "$APP"; echo "Restored Amplify settings"' EXIT

    # Make sure Amplify itself can run (its permission prompt may be showing).
    relaunch true 100 ""
    echo "Waiting for Amplify to start (allow its System Audio Recording prompt if shown)…"
    measure --wait 180 | grep -q "Amplify is running" || { echo "Amplify did not start"; exit 1; }

    T=work.mando.amplify.test  # the measuring tool's bundle ID, for per-app levels
    fails=0
    # enabled | percent | amplitude | expected gain | extra settings
    # Expected gain = min(amplitude × boost × effects, 0.891 limiter ceiling) / amplitude.
    while IFS='|' read -r enabled percent amp expected extra; do
        relaunch "$enabled" "$percent" "$extra"
        line=$(measure --amplitude "$amp" --seconds 2)
        gain=$(echo "$line" | sed -n 's/.*gain=\([0-9.]*\).*/\1/p')
        # Pass within ±0.25 dB of expected (or silent output when boost is off).
        verdict=$(awk -v g="$gain" -v e="$expected" 'BEGIN {
            if (g == "") { print "FAIL"; exit }
            if (e == 0) { print (g < 0.001) ? "PASS" : "FAIL"; exit }
            d = 20 * log(g / e) / log(10); if (d < 0) d = -d
            print (d <= 0.25) ? "PASS" : "FAIL" }')
        [ "$verdict" = PASS ] || fails=$((fails + 1))
        label="boost $percent%"; [ "$enabled" = true ] || label="off"
        [ -z "$extra" ] || label="$label, $(echo "$extra" | sed -e "s/defaults write \$DOMAIN //g" -e "s/\$T/test app/g")"
        printf '%s  %-58s amp %-4s expected ×%-6s  %s\n' "$verdict" "$label" "$amp" "$expected" "$line"
    done <<EOF
false|150|0.1|0|
true|100|0.1|1.0|
true|150|0.1|1.5|
true|200|0.1|2.0|
true|300|0.1|3.0|
true|300|0.5|1.782|
true|200|0.1|1.0|defaults write \$DOMAIN appGains -dict \$T -float 0.5
true|100|0.1|0|defaults write \$DOMAIN appGains -dict \$T -float 0
true|100|0.1|1.9953|defaults write \$DOMAIN eqPreset Custom; defaults write \$DOMAIN eqCustom -array 0 0 0 0 0 6 0 0 0 0
true|100|0.1|0.7071|defaults write \$DOMAIN balance -float -1
EOF
    if [ $fails -eq 0 ]; then echo "All end-to-end tests passed"; else echo "$fails end-to-end test(s) failed"; return 1; fi
}

case "${1:-all}" in
    dsp) run_dsp ;;
    e2e) run_e2e ;;
    all) run_dsp && run_e2e ;;
    *) echo "Usage: $0 [dsp|e2e|all]"; exit 1 ;;
esac
