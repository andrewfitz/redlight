import AppKit
import SwiftUI

/// Panes that take each other's place by sliding sideways: Auto and Manual under the mode
/// control, and the popover's pages (controls, Settings, About).
///
/// Only the shown pane is laid out. A pane is built the first time it is selected and then
/// kept for as long as the popover is open: one that is not shown has no height and is not
/// drawn, takes no input, and keeps its state, so going back to it builds nothing.
///
/// The slide itself is not SwiftUI's. Animating the panes in SwiftUI had it lay out and draw
/// the popover again on every frame, which a fast display could not keep up with. Here a
/// change is handed to the popover's `PopoverSlideHost`: it takes a picture of what is on
/// screen, has the pager show the new pane at once, takes a picture of that, and slides the
/// two pictures past each other with Core Animation while the popover's height follows. The
/// display moves them at its own rate, and SwiftUI does nothing until the next change. With
/// no host (outside the popover), with Reduce Motion, or with animations off, the panes are
/// swapped in place.
///
/// Every pane but the selected one takes no input from the pointer or (through
/// `emberIsLeaving`, which each control reads) the keyboard. A pane not shown is transparent,
/// which takes it out of what assistive apps see; it is not hidden from them explicitly,
/// because hiding at this level, even with `false`, would uncover what a pane hides itself.
/// A platform control in the pane that is leaving (a text field, a time picker) gives the
/// keyboard back to the popover.
///
/// A pane is given the popover's width, padded as the popover's content is, so it runs to the
/// popover's edges and leaves by them. The pager is to be placed inside that padding.
struct EmberPager<ID: Hashable, Pane: View>: View {
    /// Left to right.
    let ids: [ID]
    let selection: ID
    @ViewBuilder let pane: (ID) -> Pane

    /// The pane on screen: the selection, once a change has swapped it in.
    @State private var shown: ID
    /// Every pane that has been built.
    @State private var built: Set<ID>
    /// How many times each pane has come into play, for `onPaneShown`.
    @State private var visits: [ID: Int] = [:]
    @State private var place = Place()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.emberAnimationsEnabled) private var animates
    @Environment(\.popoverSlideHost) private var slideHost

    /// Where the pager is in the popover's content, and the latest selection. Not observed:
    /// writing it draws nothing.
    private final class Place {
        var frame: CGRect = .zero
        var selection: ID?
    }

    init(ids: [ID], selection: ID, @ViewBuilder pane: @escaping (ID) -> Pane) {
        self.ids = ids
        self.selection = selection
        self.pane = pane
        _shown = State(initialValue: selection)
        _built = State(initialValue: [selection])
    }

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(ids, id: \.self) { id in slot(id) }
        }
        .frame(width: EmberMetrics.width, alignment: .top)
        .padding(.horizontal, -EmberMetrics.padding)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(PopoverSlideHost.space)) }) {
            place.frame = $0
        }
        .onChange(of: selection) { old, new in
            place.selection = new
            // Built now, out of sight, so it is ready to swap in.
            built.insert(new)
            visits[new, default: 0] += 1
            Self.releaseKeyboardFromPlatformControl()
            guard animates, !reduceMotion, let slideHost else {
                shown = new
                return
            }
            let from = ids.firstIndex(of: old) ?? 0, to = ids.firstIndex(of: new) ?? 0
            let place = place
            slideHost.slide(forward: to >= from, region: { place.frame }) {
                var swap = Transaction()
                swap.disablesAnimations = true
                withTransaction(swap) { shown = place.selection ?? new }
            }
        }
    }

    /// A text field or time picker of the pane that is leaving would keep the keyboard, out of
    /// sight. The popover's own root takes it, as when the popover opens. SwiftUI's own focus
    /// is left alone: it lets go of a control that stops being focusable by itself, and a
    /// control outside the panes (the mode switch, pressed from the keyboard) keeps it.
    private static func releaseKeyboardFromPlatformControl() {
        guard let window = NSApp.keyWindow, let responder = window.firstResponder as? NSView,
              !(responder is PopoverScrollView),
              // SwiftUI's own view: its focus is SwiftUI's business.
              !String(describing: type(of: responder)).hasPrefix("NSHostingView") else { return }
        var view: NSView? = responder
        while let current = view, !(current is PopoverScrollView) { view = current.superview }
        guard let root = view else { return }
        window.makeFirstResponder(root)
    }

    /// One pane: laid out and drawn while shown, and otherwise, once built, kept out of sight.
    @ViewBuilder
    private func slot(_ id: ID) -> some View {
        let isShown = id == shown
        if built.contains(id) || isShown {
            pane(id)
                .padding(.horizontal, EmberMetrics.padding)
                .fixedSize(horizontal: false, vertical: true)
                .allowsHitTesting(isShown && id == selection)
                .environment(\.emberIsLeaving, id != selection)
                .environment(\.emberPaneVisit, visits[id] ?? 0)
                .frame(width: EmberMetrics.width, alignment: .top)
                // Out of sight: no height of its own, not drawn, and well outside the popover,
                // so its platform views (a time picker) are nowhere near a click.
                .frame(height: isShown ? nil : 0, alignment: .top)
                .opacity(isShown ? 1 : 0)
                .offset(x: isShown ? 0 : -4 * EmberMetrics.width)
        }
    }
}

extension EnvironmentValues {
    /// How many times the pane this is in has come into play again in its `EmberPager`.
    @Entry var emberPaneVisit = 0
    /// What slides an `EmberPager`'s panes, in the popover.
    @Entry var popoverSlideHost: PopoverSlideHost? = nil
}

extension View {
    /// Runs when the view appears, and again each time the pager pane it is in comes back
    /// into play: a pane is kept while out of sight, so it does not appear again.
    func onPaneShown(perform action: @escaping () -> Void) -> some View {
        modifier(OnPaneShown(action: action))
    }
}

private struct OnPaneShown: ViewModifier {
    let action: () -> Void
    @Environment(\.emberPaneVisit) private var visit

    func body(content: Content) -> some View {
        content
            .onAppear(perform: action)
            .onChange(of: visit) { action() }
    }
}
