import Cocoa
import Combine
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let defaults = UserDefaults.standard
    private var model: AppModel!
    private var observers: Set<AnyCancellable> = []
    private var scrollMonitor: Any?
    private var scrollAccumulator: CGFloat = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register as a login item on first launch; user can turn it off from the panel.
        if !defaults.bool(forKey: "didSetUpLoginItem") {
            try? SMAppService.mainApp.register()
            defaults.set(true, forKey: "didSetUpLoginItem")
        }

        model = AppModel()

        let host = NSHostingController(rootView: PanelView(model: model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self

        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Scroll over the icon to change the boost.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let button = self.statusItem.button, event.window === button.window else { return event }
            self.scrolled(event)
            return nil
        }

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &observers)
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.engine.stop()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        // Right-click (or Control-click) toggles Amplify without opening the panel.
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            model.setOn(!model.isOn)
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func scrolled(_ event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 12 : event.scrollingDeltaY
        scrollAccumulator += event.isDirectionInvertedFromDevice ? -delta : delta
        let steps = Int(scrollAccumulator.rounded(.towardZero))
        guard steps != 0 else { return }
        scrollAccumulator -= CGFloat(steps)
        model.nudge(by: steps * 5)
    }

    func popoverWillShow(_ notification: Notification) { model.startMeters() }
    func popoverDidClose(_ notification: Notification) { model.stopMeters() }

    private func refresh() {
        let on = model.isOn
        let image = NSImage(systemSymbolName: on ? "speaker.wave.3.fill" : "speaker.wave.2",
                            accessibilityDescription: on ? "Amplify on" : "Amplify off")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !on
        statusItem.button?.title = on ? " \(model.percent)%" : ""
        statusItem.button?.toolTip = on
            ? "Amplify: boosting to \(model.percent)%. Scroll to adjust, right-click to turn off."
            : "Amplify: off. Right-click to turn on."
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
