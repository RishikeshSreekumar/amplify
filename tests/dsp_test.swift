// Offline tests of the audio processor: feeds synthetic signals through
// AudioProcessor and checks the output. No audio hardware involved.
// Run: tests/run.sh dsp
import CoreAudio
import Foundation

let rate = 48_000.0
var failures = 0

// MARK: - Harness

func sine(_ freq: Double, _ amp: Float, _ frames: Int) -> [Float] {
    (0..<frames).map { amp * Float(sin(2 * Double.pi * freq * Double($0) / rate)) }
}

/// Runs stereo signals through the processor, one (left, right) pair per tap, in
/// 512-frame blocks like the real device. Returns the output (left, right).
func run(_ params: DSPParams, taps: [(l: [Float], r: [Float])], interleavedOut: Bool = false,
         monoOut: Bool = false) -> (l: [Float], r: [Float]) {
    let p = AudioProcessor()
    p.update(params)
    p.reset(sampleRate: rate, tapChannels: taps.map { _ in 2 })
    let frames = taps[0].l.count
    // Interleaved stereo per tap, in memory we own for the whole run.
    let inputs = taps.map { tap -> UnsafeMutablePointer<Float> in
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        for i in 0..<frames { buffer[2 * i] = tap.l[i]; buffer[2 * i + 1] = tap.r[i] }
        return buffer
    }
    defer { inputs.forEach { $0.deallocate() } }
    var outL = [Float](repeating: 0, count: frames * (interleavedOut ? 2 : 1))
    var outR = [Float](repeating: 0, count: frames)
    let block = 512

    let inList = AudioBufferList.allocate(maximumBuffers: taps.count)
    let outList = AudioBufferList.allocate(maximumBuffers: interleavedOut || monoOut ? 1 : 2)
    defer { free(inList.unsafeMutablePointer); free(outList.unsafeMutablePointer) }

    var start = 0
    while start < frames {
        let n = min(block, frames - start)
        for t in 0..<taps.count {
            inList[t] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(n * 8), mData: inputs[t] + start * 2)
        }
        outL.withUnsafeMutableBufferPointer { l in
            outR.withUnsafeMutableBufferPointer { r in
                if interleavedOut {
                    outList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(n * 8), mData: l.baseAddress! + start * 2)
                } else if monoOut {
                    outList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: l.baseAddress! + start)
                } else {
                    outList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: l.baseAddress! + start)
                    outList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: r.baseAddress! + start)
                }
                p.process(inList.unsafePointer, outList.unsafeMutablePointer)
            }
        }
        start += n
    }
    if interleavedOut {
        return (stride(from: 0, to: outL.count, by: 2).map { outL[$0] }, stride(from: 1, to: outL.count, by: 2).map { outL[$0] })
    }
    return (outL, monoOut ? outL : outR)
}

/// Peak of the last 10% of a signal (after gain glides and filters have settled).
func settled(_ x: [Float]) -> Float { x.suffix(x.count / 10).map(abs).max() ?? 0 }

/// Amplitude of one frequency over the last 20% of a signal (Hann-windowed DFT bin,
/// so neighbouring frequencies don't leak in).
func amplitude(_ x: [Float], at freq: Double) -> Double {
    let tail = Array(x.suffix(x.count / 5))
    let n = Double(tail.count)
    let w = 2 * Double.pi * freq / rate
    var re = 0.0, im = 0.0
    for (i, s) in tail.enumerated() {
        let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / n)
        re += Double(s) * hann * cos(w * Double(i))
        im -= Double(s) * hann * sin(w * Double(i))
    }
    return 4 * (re * re + im * im).squareRoot() / n  // ×2 for one-sided, ×2 for the window's gain
}

func square(_ freq: Double, _ amp: Float, _ frames: Int) -> [Float] {
    (0..<frames).map { sin(2 * Double.pi * freq * Double($0) / rate) >= 0 ? amp : -amp }
}

func db(_ x: Double) -> Double { 20 * log10(max(x, 1e-12)) }

func check(_ name: String, _ got: Double, _ expected: Double, tolerance: Double, _ unit: String = "") {
    let ok = abs(got - expected) <= tolerance
    if !ok { failures += 1 }
    print(String(format: "%@  %@: %.4f%@ (expected %.4f ± %.3g)", ok ? "PASS" : "FAIL", name, got, unit, expected, tolerance))
}

func checkAtLeast(_ name: String, _ got: Double, _ minimum: Double, _ unit: String = "") {
    let ok = got >= minimum
    if !ok { failures += 1 }
    print(String(format: "%@  %@: %.4f%@ (expected ≥ %.4f)", ok ? "PASS" : "FAIL", name, got, unit, minimum))
}

let second = Int(rate)
let tone = sine(1000, 0.1, second)
let ceiling = Double(AudioProcessor.ceiling)

// MARK: - Boost and limiter

print("== Boost and limiter")
for (amp, boost) in [(Float(0.1), Float(1)), (0.1, 1.5), (0.1, 2), (0.1, 3), (0.5, 2), (0.5, 3), (1.0, 3)] {
    var p = DSPParams()
    p.boost = boost
    let x = sine(1000, amp, second)
    let expected = min(Double(amp * boost), ceiling)
    for (label, interleaved) in [("interleaved", true), ("planar", false)] {
        let out = run(p, taps: [(x, x)], interleavedOut: interleaved)
        check("in \(amp) × \(Int(boost * 100))% (\(label))", Double(max(settled(out.l), settled(out.r))), expected, tolerance: 0.001)
    }
}
do {
    var p = DSPParams()
    p.boost = 2
    let out = run(p, taps: [(tone, sine(1000, 0.3, second))], monoOut: true)
    check("mono output device gets (L+R)/2", Double(settled(out.l)), 0.4, tolerance: 0.001)
}

// MARK: - Per-app (per-tap) gains

print("== Per-app levels")
for (gain, expected) in [(Float(1), 0.2), (0.5, 0.15), (0, 0.1), (3, 0.4)] {
    var p = DSPParams()
    p.tapGains[1] = gain
    let out = run(p, taps: [(tone, tone), (tone, tone)])
    check("tap 1 at \(Int(gain * 100))% + tap 0 at 100%", Double(settled(out.l)), expected, tolerance: 0.001)
}

// MARK: - Equalizer

print("== Equalizer")
do {
    var p = DSPParams()
    p.eq[5] = 6  // 1 kHz band
    check("1 kHz band +6 dB at 1 kHz", db(amplitude(run(p, taps: [(tone, tone)]).l, at: 1000) / 0.1), 6, tolerance: 0.1, " dB")
    let low = sine(100, 0.1, second)
    check("1 kHz band +6 dB leaves 100 Hz alone", db(amplitude(run(p, taps: [(low, low)]).l, at: 100) / 0.1), 0, tolerance: 0.3, " dB")
    p.eq = SIMD16()
    p.eq[1] = -12  // 64 Hz band
    let bass = sine(64, 0.1, second)
    check("64 Hz band -12 dB at 64 Hz", db(amplitude(run(p, taps: [(bass, bass)]).l, at: 64) / 0.1), -12, tolerance: 0.2, " dB")
    for preset in EQPreset.allCases where preset != .custom {
        var q = DSPParams()
        for (i, g) in preset.gains!.enumerated() { q.eq[i] = Float(g) }
        let out = run(q, taps: [(tone, tone)])
        let ok = out.l.allSatisfy(\.isFinite) && settled(out.l) > 0
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  preset \(preset.rawValue) is stable")
    }
}

// MARK: - Voice clarity

print("== Voice clarity")
do {
    var p = DSPParams()
    p.clarity = true
    let rumble = sine(40, 0.1, second), presence = sine(3000, 0.1, second)
    let cut = db(amplitude(run(p, taps: [(rumble, rumble)]).l, at: 40) / 0.1)
    let lift = db(amplitude(run(p, taps: [(presence, presence)]).l, at: 3000) / 0.1)
    print(String(format: "%@  40 Hz rumble cut: %.1f dB (expected ≤ -10)", cut <= -10 ? "PASS" : "FAIL", cut)); if cut > -10 { failures += 1 }
    check("3 kHz presence lift", lift, 5, tolerance: 0.6, " dB")
}

// MARK: - Virtual bass

print("== Virtual bass")
do {
    let low = sine(55, 0.2, second)
    var p = DSPParams()
    let off = db(amplitude(run(p, taps: [(low, low)]).l, at: 110) / 0.2)
    print(String(format: "%@  off: no 110 Hz harmonic: %.1f dB (expected ≤ -60)", off <= -60 ? "PASS" : "FAIL", off)); if off > -60 { failures += 1 }
    p.bass = 1
    let on = run(p, taps: [(low, low)]).l
    checkAtLeast("on: 110 Hz harmonic relative to the 55 Hz input", db(amplitude(on, at: 110) / 0.2), -10, " dB")
    check("55 Hz fundamental kept", db(amplitude(on, at: 55) / 0.2), 0, tolerance: 1, " dB")
    let mid = run(p, taps: [(tone, tone)]).l
    check("1 kHz untouched", db(amplitude(mid, at: 1000) / 0.1), 0, tolerance: 0.1, " dB")
}

// MARK: - Stereo

print("== Stereo")
do {
    let silent = [Float](repeating: 0, count: second)
    var p = DSPParams()
    p.width = 0
    var out = run(p, taps: [(tone, silent)])
    check("mono: left", Double(settled(out.l)), 0.05, tolerance: 0.0005)
    check("mono: right", Double(settled(out.r)), 0.05, tolerance: 0.0005)
    p.width = 2
    out = run(p, taps: [(tone, silent)])
    check("width 2: left", Double(settled(out.l)), 0.15, tolerance: 0.0005)
    check("width 2: right", Double(settled(out.r)), 0.05, tolerance: 0.0005)
    p = DSPParams()
    p.balance = -1
    out = run(p, taps: [(tone, tone)])
    check("balance full left: left", Double(settled(out.l)), 0.1, tolerance: 0.0005)
    check("balance full left: right", Double(settled(out.r)), 0, tolerance: 0.0005)
    p.balance = 0.5
    out = run(p, taps: [(tone, tone)])
    check("balance 50% right: left", Double(settled(out.l)), 0.05, tolerance: 0.0005)
    check("balance 50% right: right", Double(settled(out.r)), 0.1, tolerance: 0.0005)
}

// MARK: - Auto-level

print("== Auto-level")
do {
    var p = DSPParams()
    p.autoLevel = true
    let long = 20 * second  // the slow release needs time to settle
    let quiet = sine(1000, 0.01, long), loud = sine(1000, 0.5, long), silence = [Float](repeating: 0, count: long)
    check("quiet (-43 dB RMS) raised by max +12 dB", db(Double(settled(run(p, taps: [(quiet, quiet)]).l)) / 0.01), 12, tolerance: 0.2, " dB")
    check("loud (-9 dB RMS) lowered by max -6 dB", db(Double(settled(run(p, taps: [(loud, loud)]).l)) / 0.5), -6, tolerance: 0.2, " dB")
    let target = sine(1000, Float(Double(AudioProcessor.agcTarget) * 2.0.squareRoot() * 2), long)  // 6 dB above target
    check("moderate (+6 dB over target) brought to target", db(Double(settled(run(p, taps: [(target, target)]).l)) / (Double(AudioProcessor.agcTarget) * 2.0.squareRoot())), 0, tolerance: 0.3, " dB")
    check("silence stays silent", Double(settled(run(p, taps: [(silence, silence)]).l)), 0, tolerance: 1e-9)
}

// MARK: - Loudness compressor

print("== Loudness compressor")
do {
    var p = DSPParams()
    p.loudness = true
    // A square wave has constant magnitude, so the level detector sees exactly its amplitude.
    for amp in [Float(0.01), 0.05, 0.1, 0.3] {
        let x = square(100, amp, second)
        let expected = db(Double(amp * AudioProcessor.compressorGain(envelope: amp)))
        check("in \(String(format: "%.0f", db(Double(amp)))) dBFS", db(Double(settled(run(p, taps: [(x, x)]).l))), expected, tolerance: 0.1, " dB")
    }
    // Static curve sanity: quiet gets makeup gain, loud is compressed 3:1.
    check("curve: -40 dBFS → +8 dB makeup", db(Double(AudioProcessor.compressorGain(envelope: 0.01))), 8, tolerance: 0.01, " dB")
    check("curve: -6 dBFS → 18 dB over threshold, -12 + 8 = -4 dB", db(Double(AudioProcessor.compressorGain(envelope: 0.5012))), -4, tolerance: 0.01, " dB")
}

// MARK: - Full chain stays safe

print("== Full chain")
do {
    var p = DSPParams()
    p.boost = 3; p.loudness = true; p.clarity = true; p.autoLevel = true; p.bass = 1; p.width = 2
    for i in 0..<EQ.bandCount { p.eq[i] = 12 }
    var noise = [Float](repeating: 0, count: 5 * second)
    var seed: UInt64 = 42
    for i in noise.indices { seed = seed &* 6364136223846793005 &+ 1; noise[i] = Float(Int64(bitPattern: seed >> 11) % 1000) / 1000 }
    let out = run(p, taps: [(noise, noise.reversed())])
    let peak = (out.l + out.r).map(abs).max() ?? 0
    let ok = (out.l + out.r).allSatisfy(\.isFinite) && peak <= Float(ceiling) + 1e-6
    if !ok { failures += 1 }
    print(String(format: "%@  everything maxed on loud noise: peak %.4f ≤ ceiling %.4f, no NaN/Inf", ok ? "PASS" : "FAIL", peak, ceiling))
}

print(failures == 0 ? "\nAll DSP tests passed" : "\n\(failures) DSP test(s) failed")
exit(failures == 0 ? 0 : 1)
