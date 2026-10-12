import AppKit
import Combine
import ServiceManagement

/// All app state: settings (persisted in UserDefaults), engine control and meters.
final class AppModel: ObservableObject {
    static let percentRange = 100...300
    static let presets = [125, 150, 200, 250, 300]
    static let appPercentRange = 0...300

    struct Meter: Equatable {
        var input: Float = 0
        var output: Float = 0
        var reduction: Float = 1
    }

    /// Meters change 20 times a second, so they live apart from the rest of the
    /// state: only the meter view redraws, not the whole panel or the menu bar icon.
    final class Meters: ObservableObject {
        @Published var value = Meter()
    }

    struct MixerRow: Identifiable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let icon: NSImage
        let isPlaying: Bool
        let isRunning: Bool
    }

    let engine = AudioEngine()
    let volumeKeyMonitor = VolumeKeys()
    private let defaults = UserDefaults.standard
    private var meterTimer: Timer?
    private var meterTicks = 0

    @Published private(set) var isOn = false
    @Published private(set) var output: OutputDevice?
    @Published private(set) var error: String?
    @Published private(set) var permissionDenied = AudioCapturePermission.status == .denied
    let meters = Meters()
    @Published private(set) var mixer: [MixerRow] = []
    /// On-screen level display for the volume keys.
    let hud = BoostHUD()

    @Published var percent: Int {
        didSet {
            let clamped = min(max(percent, Self.percentRange.lowerBound), Self.percentRange.upperBound)
            guard clamped == percent else { percent = clamped; return }
            defaults.set(percent, forKey: "boostPercent")
            if rememberPerDevice, let key = output?.key { devicePercents[key] = percent }
            pushParams()
        }
    }

    @Published var loudness: Bool { didSet { save(loudness, "loudness") } }
    @Published var clarity: Bool { didSet { save(clarity, "clarity") } }
    @Published var autoLevel: Bool { didSet { save(autoLevel, "autoLevel") } }
    @Published var bassEnabled: Bool { didSet { save(bassEnabled, "bassEnabled") } }
    @Published var bassAmount: Double { didSet { save(bassAmount, "bassAmount") } }
    @Published var mono: Bool { didSet { save(mono, "mono") } }
    @Published var width: Double { didSet { save(width, "stereoWidth") } }
    @Published var balance: Double { didSet { save(balance, "balance") } }

    @Published var eqPreset: EQPreset {
        didSet {
            defaults.set(eqPreset.rawValue, forKey: "eqPreset")
            eqGains = eqPreset.gains ?? Self.doubles(defaults.array(forKey: "eqCustom"), count: EQ.bandCount)
        }
    }
    @Published private(set) var eqGains: [Double] { didSet { pushParams() } }

    /// Per-app level by bundle ID, 1 = 100%. Apps at 100% aren't stored.
    @Published private(set) var appGains: [String: Double] {
        didSet {
            defaults.set(appGains, forKey: "appGains")
            engine.appGains = appGains.mapValues(Float.init)
            refreshMixer()
        }
    }

    @Published var rememberPerDevice: Bool {
        didSet {
            defaults.set(rememberPerDevice, forKey: "rememberPerDevice")
            if rememberPerDevice, let key = output?.key { devicePercents[key] = percent }
        }
    }
    private var devicePercents: [String: Int] {
        get { (defaults.dictionary(forKey: "devicePercents") as? [String: Int]) ?? [:] }
        set { defaults.set(newValue, forKey: "devicePercents") }
    }

    @Published var volumeKeys: Bool {
        didSet {
            defaults.set(volumeKeys, forKey: "volumeKeys")
            volumeKeyMonitor.isEnabled = volumeKeys
        }
    }

    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }

    /// Whether the user wants Amplify on; restored at launch.
    private var wantsOn: Bool {
        get { defaults.bool(forKey: "boostEnabled") }
        set { defaults.set(newValue, forKey: "boostEnabled") }
    }

    init() {
        let d = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) == nil ? fallback : d.bool(forKey: key) }
        func double(_ key: String, _ fallback: Double) -> Double { (d.object(forKey: key) as? NSNumber)?.doubleValue ?? fallback }

        percent = min(max((d.object(forKey: "boostPercent") as? Int) ?? 150, Self.percentRange.lowerBound), Self.percentRange.upperBound)
        loudness = bool("loudness", false)
        clarity = bool("clarity", false)
        autoLevel = bool("autoLevel", false)
        bassEnabled = bool("bassEnabled", false)
        bassAmount = double("bassAmount", 0.5)
        mono = bool("mono", false)
        width = double("stereoWidth", 1)
        balance = double("balance", 0)
        let preset = EQPreset(rawValue: d.string(forKey: "eqPreset") ?? "") ?? .flat
        eqPreset = preset
        eqGains = preset.gains ?? Self.doubles(d.array(forKey: "eqCustom"), count: EQ.bandCount)
        appGains = (d.dictionary(forKey: "appGains") ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue ?? Double("\($0)") }
        rememberPerDevice = bool("rememberPerDevice", true)
        volumeKeys = bool("volumeKeys", false)
        output = engine.output

        engine.appGains = appGains.mapValues(Float.init)
        engine.onOutputChange = { [weak self] in self?.outputChanged() }
        engine.onProcessesChange = { [weak self] in self?.refreshMixer() }
        engine.onFailure = { [weak self] error in
            guard let self else { return }
            self.wantsOn = false
            self.error = error.localizedDescription
            self.syncState()
        }
        volumeKeyMonitor.handler = { [weak self] key in self?.volumeKey(key) ?? false }
        volumeKeyMonitor.isEnabled = volumeKeys

        applyDeviceMemory()
        pushParams()
        refreshMixer()
        if wantsOn { turnOn() }
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        pushParams()
    }

    /// Reads a number array from defaults, accepting numbers or numeric strings.
    private static func doubles(_ array: [Any]?, count: Int) -> [Double] {
        var values = (array ?? []).map { ($0 as? NSNumber)?.doubleValue ?? Double("\($0)") ?? 0 }
        values += Array(repeating: 0, count: max(0, count - values.count))
        return Array(values.prefix(count))
    }

    private func pushParams() {
        var p = DSPParams()
        p.boost = Float(percent) / 100
        p.loudness = loudness
        p.clarity = clarity
        p.autoLevel = autoLevel
        p.bass = bassEnabled ? Float(bassAmount) : 0
        p.width = mono ? 0 : Float(width)
        p.balance = Float(balance)
        for (i, g) in eqGains.prefix(EQ.bandCount).enumerated() { p.eq[i] = Float(g) }
        if engine.params != p { engine.params = p }
    }

    // MARK: - On / off

    func setOn(_ on: Bool) {
        if on { turnOn() } else { turnOff() }
    }

    func turnOff() {
        engine.stop()
        wantsOn = false
        syncState()
    }

    func turnOn() {
        switch AudioCapturePermission.status {
        case .granted:
            start()
        case .unknown:
            AudioCapturePermission.request { [weak self] granted in
                guard let self else { return }
                if granted { self.start() } else { self.showPermissionAlert() }
            }
        case .denied:
            showPermissionAlert()
        }
    }

    private func start() {
        do {
            try engine.start()
            wantsOn = true
            error = nil
        } catch {
            wantsOn = false
            self.error = error.localizedDescription
        }
        syncState()
    }

    private func syncState() {
        if isOn != engine.isRunning { isOn = engine.isRunning }
        if output != engine.output { output = engine.output }
        let denied = AudioCapturePermission.status == .denied
        if permissionDenied != denied { permissionDenied = denied }
    }

    private func showPermissionAlert() {
        wantsOn = false
        syncState()
        let alert = NSAlert()
        alert.messageText = "Amplify needs System Audio Recording permission"
        alert.informativeText = "To boost what your Mac is playing, Amplify has to capture it first. Turn on Amplify under System Settings → Privacy & Security → Screen & System Audio Recording (System Audio Recording Only), then try again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(AudioCapturePermission.settingsURL) }
    }

    // MARK: - Boost level

    func nudge(by delta: Int) {
        percent = ((percent + delta) / 5) * 5
    }

    func pickPreset(_ value: Int) {
        percent = value
        if !isOn { turnOn() }
    }

    /// Volume keys: past 100% system volume, Volume Up raises the boost; Volume Down
    /// lowers the boost before the system volume. Returns true to swallow the key.
    private func volumeKey(_ key: VolumeKeys.Key) -> Bool {
        let volume = engine.output?.volume
        if volume?.muted == true { return false }
        switch key {
        case .up:
            guard (volume?.level ?? 1) >= 0.999 else { return false }
            if !isOn {
                if percent == Self.percentRange.lowerBound { percent += 10 }
                turnOn()
            } else {
                percent += 10
            }
        case .down:
            guard isOn, percent > Self.percentRange.lowerBound else { return false }
            percent -= 10
        }
        hud.show(percent: percent)
        return true
    }

    // MARK: - Output devices

    private func outputChanged() {
        syncState()
        applyDeviceMemory()
    }

    /// With per-device memory on, switches to the level last used on this output.
    /// Headphones Amplify hasn't seen before start at 100%, to protect your ears.
    private func applyDeviceMemory() {
        guard rememberPerDevice, let output else { return }
        if let saved = devicePercents[output.key] {
            if saved != percent { percent = saved }
        } else if output.isHeadphones {
            percent = Self.percentRange.lowerBound
        } else {
            devicePercents[output.key] = percent
        }
    }

    // MARK: - EQ

    func setBand(_ index: Int, _ value: Double) {
        var gains = eqGains
        gains[index] = min(max(value, -Double(EQ.maxGain)), Double(EQ.maxGain))
        defaults.set(gains, forKey: "eqCustom")
        if eqPreset != .custom { eqPreset = .custom } else { eqGains = gains }
    }

    func resetEQ() { eqPreset = .flat }

    // MARK: - Per-app levels

    func appPercent(_ bundleID: String) -> Int {
        Int(((appGains[bundleID] ?? 1) * 100).rounded())
    }

    func setAppPercent(_ bundleID: String, _ value: Int) {
        let snapped = min(max((value / 5) * 5, Self.appPercentRange.lowerBound), Self.appPercentRange.upperBound)
        if snapped == 100 { appGains[bundleID] = nil } else { appGains[bundleID] = Double(snapped) / 100 }
    }

    func refreshMixer() {
        let running = AppAudio.apps()
        var rows = running
            .filter { $0.isUserApp || $0.isPlaying || appGains[$0.bundleID] != nil }
            .map { MixerRow(bundleID: $0.bundleID, name: $0.name, icon: $0.icon, isPlaying: $0.isPlaying, isRunning: true) }
        let shown = Set(rows.map(\.bundleID))
        for bundleID in appGains.keys where !shown.contains(bundleID) {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
                ?? bundleID.components(separatedBy: ".").last ?? bundleID
            let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
            rows.append(MixerRow(bundleID: bundleID, name: name, icon: icon, isPlaying: false, isRunning: false))
        }
        // Playing apps first, then alphabetical.
        rows.sort { ($0.isPlaying ? 0 : 1, $0.name.lowercased()) < ($1.isPlaying ? 0 : 1, $1.name.lowercased()) }
        if rows.map(\.bundleID) != mixer.map(\.bundleID) || rows.map(\.isPlaying) != mixer.map(\.isPlaying) {
            mixer = rows
        }
    }

    // MARK: - Meters (only while the panel is open)

    func startMeters() {
        syncState()
        refreshMixer()
        meterTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.tickMeters() }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    func stopMeters() {
        meterTimer?.invalidate()
        meterTimer = nil
        meters.value = Meter()
    }

    private func tickMeters() {
        let m = engine.isRunning ? engine.readMeters() : (input: Float(0), output: Float(0), reduction: Float(1))
        // Peak meters with a smooth fall.
        let last = meters.value
        var next = last
        next.input = max(m.input, last.input * 0.85)
        next.output = max(m.output, last.output * 0.85)
        next.reduction = min(1, m.reduction < last.reduction ? m.reduction : last.reduction + (1 - last.reduction) * 0.15)
        if next != last { meters.value = next }
        meterTicks += 1
        if meterTicks % 20 == 0 { refreshMixer() }
    }
}
