import AppKit
import SwiftUI

/// A volume-style overlay showing the boost level, shown when the volume keys change it.
final class BoostHUD {
    private var panel: NSPanel?
    private var host: NSHostingView<HUDView>?
    private var hideWork: DispatchWorkItem?

    func show(percent: Int) {
        let panel = self.panel ?? makePanel()
        host?.rootView = HUDView(percent: percent)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 140))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                panel?.animator().alphaValue = 0
            }, completionHandler: { panel?.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 200, height: 200)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: HUDView(percent: 100))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        self.panel = panel
        self.host = host
        return panel
    }
}

struct HUDView: View {
    let percent: Int
    private let segments = 20

    private var lit: Int {
        let range = AppModel.percentRange
        let fraction = Double(percent - range.lowerBound) / Double(range.upperBound - range.lowerBound)
        return Int((fraction * Double(segments)).rounded())
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 54, weight: .regular))
                .symbolRenderingMode(.hierarchical)
            Text("Boost \(percent)%")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
            HStack(spacing: 2) {
                ForEach(0..<segments, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i < lit ? Color.primary : Color.primary.opacity(0.2))
                        .frame(width: 6, height: 8)
                }
            }
        }
        .frame(width: 200, height: 200)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
