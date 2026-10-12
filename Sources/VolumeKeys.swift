import AppKit
import ApplicationServices

/// Watches the keyboard's volume keys. When `handler` returns true for a key press,
/// the press (and its release) is swallowed so macOS doesn't act on it too.
/// Needs Accessibility permission; asks for it when enabled.
final class VolumeKeys {
    enum Key { case up, down }

    var handler: ((Key) -> Bool)?
    var isEnabled = false {
        didSet { isEnabled ? install() : uninstall() }
    }
    var isTrusted: Bool { AXIsProcessTrusted() }

    fileprivate var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retry: Timer?
    private var swallowed: Set<Int> = []

    private func install() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            // Prompt once, then keep checking until the user flips the switch.
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
            retry?.invalidate()
            retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard let self, self.isEnabled else { return timer.invalidate() }
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    self.retry = nil
                    self.install()
                }
            }
            return
        }
        let systemDefined = CGEventMask(1 << 14)  // NX_SYSDEFINED: media and volume keys
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: systemDefined, callback: volumeKeyCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func uninstall() {
        retry?.invalidate()
        retry = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        source = nil
        tap = nil
        swallowed = []
    }

    fileprivate func handle(_ event: CGEvent) -> Bool {
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else { return false }
        let code = (ns.data1 & 0xFFFF_0000) >> 16
        guard code == 0 || code == 1 else { return false }  // NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_SOUND_DOWN
        let isDown = (ns.data1 & 0xFF00) >> 8 == 0x0A
        guard isDown else { return swallowed.remove(code) != nil }
        if handler?(code == 0 ? .up : .down) == true {
            swallowed.insert(code)
            return true
        }
        return false
    }
}

private func volumeKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let info else { return .passUnretained(event) }
    let keys = Unmanaged<VolumeKeys>.fromOpaque(info).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = keys.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return .passUnretained(event)
    }
    return keys.handle(event) ? nil : .passUnretained(event)
}
