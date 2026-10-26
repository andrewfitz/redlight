import AppKit
import SwiftUI

@MainActor
protocol ValueReadout: AnyObject {
    /// Briefly shows `text`, with a bar when `level` (0…1) is given.
    func show(_ text: String, level: Double?)
}

/// A brief readout like the system volume overlay. It never takes focus or clicks, joins
/// every Space, and sits below Sidecar's filter window so it is tinted on the iPad too.
@MainActor
final class ValueHUD: ValueReadout {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String, level: Double?) {
        let panel = panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: ValueHUDView(text: text, level: level))
        let size = host.fittingSize
        panel.contentView = host
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrame(CGRect(x: visible.midX - size.width / 2, y: visible.minY + visible.height * 0.16,
                                  width: size.width, height: size.height), display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let panel = self?.panel else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                panel.orderOut(nil)
            } else {
                await NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 0 }
                if !Task.isCancelled { panel.orderOut(nil) }
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        return panel
    }
}

private struct ValueHUDView: View {
    let text: String
    let level: Double?

    var body: some View {
        VStack(spacing: 8) {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let level {
                Capsule()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 180, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.75))
                            .frame(width: 180 * min(1, max(0, level)), height: 4)
                    }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(minWidth: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
