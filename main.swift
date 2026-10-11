import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let defaults = UserDefaults.standard
    private let booster = AudioBooster()
    private var lastError: String?

    private let presets = [125, 150, 200, 250, 300]
    private let minPercent = 100
    private let maxPercent = 300

    private lazy var sliderItem = makeSliderItem()
    private let slider = NSSlider()
    private let valueLabel = NSTextField(labelWithString: "")

    private var percent: Int {
        get { (defaults.object(forKey: "boostPercent") as? Int).map { min(max($0, minPercent), maxPercent) } ?? 150 }
        set { defaults.set(newValue, forKey: "boostPercent") }
    }

    /// Whether the user wants boosting on; restored at launch.
    private var wantsBoost: Bool {
        get { defaults.bool(forKey: "boostEnabled") }
        set { defaults.set(newValue, forKey: "boostEnabled") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        menu.delegate = self
        statusItem.menu = menu

        booster.gain = Float(percent) / 100
        booster.onChange = { [weak self] error in
            guard let self else { return }
            if let error {
                self.wantsBoost = false
                self.lastError = error.localizedDescription
            }
            self.refresh()
        }

        // Register as a login item on first launch; user can turn it off from the menu.
        if !defaults.bool(forKey: "didSetUpLoginItem") {
            try? SMAppService.mainApp.register()
            defaults.set(true, forKey: "didSetUpLoginItem")
        }

        if wantsBoost { turnOn() }
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        booster.stop()
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let toggle = item(booster.isRunning ? "Turn Boost Off" : "Turn Boost On", #selector(toggleBoost))
        menu.addItem(toggle)
        menu.addItem(.separator())

        syncSlider()
        menu.addItem(sliderItem)

        let header = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for p in presets {
            let mi = item("\(p)%", #selector(pickPreset(_:)))
            mi.representedObject = p
            mi.indentationLevel = 1
            mi.state = booster.isRunning && percent == p ? .on : .off
            menu.addItem(mi)
        }

        menu.addItem(.separator())
        if AudioCapturePermission.status == .denied {
            menu.addItem(item("Allow System Audio Recording…", #selector(openPrivacySettings)))
        }
        let login = item("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Amplify", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        return mi
    }

    private func makeSliderItem() -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))

        let title = NSTextField(labelWithString: "Volume Boost")
        title.font = .menuFont(ofSize: 0)
        title.frame = NSRect(x: 20, y: 30, width: 150, height: 18)
        view.addSubview(title)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: 170, y: 30, width: 72, height: 18)
        view.addSubview(valueLabel)

        slider.minValue = Double(minPercent)
        slider.maxValue = Double(maxPercent)
        slider.numberOfTickMarks = (maxPercent - minPercent) / 50 + 1
        slider.allowsTickMarkValuesOnly = false
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved(_:))
        slider.frame = NSRect(x: 18, y: 4, width: 226, height: 24)
        view.addSubview(slider)

        let mi = NSMenuItem()
        mi.view = view
        return mi
    }

    private func syncSlider() {
        slider.integerValue = percent
        valueLabel.stringValue = "\(percent)%"
    }

    // MARK: - Actions

    @objc private func sliderMoved(_ sender: NSSlider) {
        // Snap to 5% steps.
        let value = Int((sender.doubleValue / 5).rounded()) * 5
        guard value != percent else { return }
        setPercent(value)
        valueLabel.stringValue = "\(value)%"
    }

    @objc private func pickPreset(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? Int else { return }
        setPercent(p)
        if !booster.isRunning { turnOn() }
    }

    @objc private func toggleBoost() {
        if booster.isRunning {
            booster.stop()
            wantsBoost = false
            refresh()
        } else {
            turnOn()
        }
    }

    @objc private func openPrivacySettings() {
        NSWorkspace.shared.open(AudioCapturePermission.settingsURL)
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        if service.status == .enabled {
            try? service.unregister()
        } else {
            try? service.register()
        }
    }

    // MARK: - Boost

    private func setPercent(_ value: Int) {
        percent = min(max(value, minPercent), maxPercent)
        booster.gain = Float(percent) / 100
        refresh()
    }

    private func turnOn() {
        switch AudioCapturePermission.status {
        case .granted:
            start()
        case .unknown:
            AudioCapturePermission.request { [weak self] granted in
                guard let self else { return }
                if granted { self.start() } else { self.permissionDenied() }
            }
        case .denied:
            permissionDenied()
        }
    }

    private func start() {
        do {
            try booster.start()
            wantsBoost = true
            lastError = nil
        } catch {
            wantsBoost = false
            lastError = error.localizedDescription
        }
        refresh()
    }

    private func permissionDenied() {
        wantsBoost = false
        refresh()
        let alert = NSAlert()
        alert.messageText = "Amplify needs System Audio Recording permission"
        alert.informativeText = "To boost what your Mac is playing, Amplify has to capture it first. Turn on Amplify under System Settings → Privacy & Security → Screen & System Audio Recording (System Audio Recording Only), then try again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { openPrivacySettings() }
    }

    // MARK: - UI

    private func refresh() {
        let on = booster.isRunning
        let symbol = on ? "speaker.wave.3.fill" : "speaker.wave.2"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: on ? "Amplify boosting" : "Amplify off")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !on
        statusItem.button?.title = on ? " \(percent)%" : ""
        statusItem.button?.toolTip = "Amplify: " + statusText()
    }

    private func statusText() -> String {
        if booster.isRunning {
            return "Boosting to \(percent)%" + (booster.outputName.map { " — \($0)" } ?? "")
        }
        if let lastError { return "Off — \(lastError)" }
        return "Off — normal volume"
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
