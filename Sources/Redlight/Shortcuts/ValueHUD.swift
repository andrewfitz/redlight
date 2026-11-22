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
    private var host: NSHostingView<ValueHUDView>?
    private var size = CGSize.zero
    private var hideTask: Task<Void, Never>?
    private var isFading = false

    func show(_ text: String, level: Double?) {
        let panel = panel ?? makePanel()
        self.panel = panel
        // Reuse the hosting view and avoid resizing or ordering the panel on each key repeat.
        let view = ValueHUDView(text: text, level: level)
        let shouldAnnounce = host?.rootView.text != text || !panel.isVisible
        if let host {
            if host.rootView != view {
                host.rootView = view
                updateSize(from: host)
            }
        } else {
            let host = NSHostingView(rootView: view)
            self.host = host
            panel.contentView = host
            updateSize(from: host)
        }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let frame = CGRect(x: (visible.midX - size.width / 2).rounded(),
                               y: (visible.minY + visible.height * 0.16).rounded(),
                               width: size.width, height: size.height)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
        }

        hideTask?.cancel()
        if isFading {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = 1
            }
            isFading = false
        }
        if !panel.isVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        if shouldAnnounce, let application = NSApp {
            NSAccessibility.post(element: application, notification: .announcementRequested, userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let panel = self?.panel else { return }
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                self?.isFading = true
                await NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    panel.animator().alphaValue = 0
                }
            }
            guard !Task.isCancelled else { return }
            self?.isFading = false
            panel.orderOut(nil)
        }
    }

    private func updateSize(from host: NSHostingView<ValueHUDView>) {
        let fitting = host.fittingSize
        size = CGSize(width: fitting.width.rounded(.up), height: fitting.height.rounded(.up))
    }

    isolated deinit {
        hideTask?.cancel()
        panel?.orderOut(nil)
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

private struct ValueHUDView: View, Equatable {
    let text: String
    let level: Double?

    var body: some View {
        VStack(spacing: 8) {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
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
