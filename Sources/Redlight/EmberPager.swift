import SwiftUI

/// Panes that take each other's place by sliding sideways: Auto and Manual under the mode
/// control, and the popover's pages (controls, Settings, About).
///
/// The panes sit side by side, in the order of `ids`, in a strip as many popovers wide, and
/// a change of `selection` moves the strip on `EmberMotion.modeSwitch`. At rest only the
/// selected pane exists. A change brings the new one into its place in the strip, out of
/// sight, then slides the strip, and then takes away the pane that has left. The strip moves
/// one update after the pane is in: a view that arrives in the same update as a move is
/// drawn where the move ends. Meanwhile the height goes from the old pane's to the new
/// one's, laid out anew on every frame, so whatever is under the pager and the popover
/// around it follow.
///
/// Each pane is a view of its own: for the length of the slide two exist, and the one that
/// is leaving takes no input, from the pointer or (through `emberIsLeaving`, which each
/// control reads) the keyboard, and looks as it did. It is not hidden from assistive apps
/// for that third of a second: hiding at this level, even with `false`, would uncover what
/// a pane hides itself.
///
/// A pane is given the popover's width, padded as the popover's content is, so it runs to the
/// popover's edges and leaves by them. The pager is to be placed inside that padding.
///
/// With Reduce Motion, or with animations off, the panes are swapped in place.
struct EmberPager<ID: Hashable, Pane: View>: View {
    /// Left to right.
    let ids: [ID]
    let selection: ID
    @ViewBuilder let pane: (ID) -> Pane

    /// The pane that has arrived and stands alone. Nil during a change, and another pane than
    /// the selection in the one update before that.
    @State private var settled: ID?
    /// The pane the strip is at, or on its way to.
    @State private var position: ID
    /// The panes a change is leaving behind, until it ends.
    @State private var leaving: Set<ID> = []
    /// The selected pane's own height, kept up to date at rest so that a change has somewhere
    /// to start from, and during one the height on its way to the new pane's.
    @State private var paneHeight: CGFloat = 0
    @State private var measured: Measure
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.emberAnimationsEnabled) private var animates

    /// Each pane's own height as last laid out, the latest selection and the latest change.
    /// Not observed: writing it draws nothing.
    private final class Measure {
        var heights: [ID: CGFloat] = [:]
        var selection: ID
        var change = 0

        init(selection: ID) { self.selection = selection }
    }

    /// Room above and below the panes that the clip leaves alone, for a focus band on the
    /// first or last control of a pane.
    private static var bleed: CGFloat { 6 }

    init(ids: [ID], selection: ID, @ViewBuilder pane: @escaping (ID) -> Pane) {
        self.ids = ids
        self.selection = selection
        self.pane = pane
        _settled = State(initialValue: selection)
        _position = State(initialValue: selection)
        _measured = State(initialValue: Measure(selection: selection))
    }

    private var slides: Bool { animates && !reduceMotion }

    var body: some View {
        // During a change the height is held; at rest the pane has its own, and anything
        // unfolding in it resizes the popover at once.
        let inTransit = settled != selection
        let place = CGFloat(ids.firstIndex(of: position) ?? 0)
        HStack(alignment: .top, spacing: 0) {
            ForEach(ids, id: \.self) { id in slot(id) }
        }
        .offset(x: -place * EmberMetrics.width)
        // For the strip alone. The height is outside it: taking hold of it is not a move,
        // and where it then goes is animated in `move`.
        .animation(slides ? EmberMotion.modeSwitch : nil, value: position)
        .frame(width: EmberMetrics.width, alignment: .leading)
        .modifier(HeldHeight(height: paneHeight, isHeld: inTransit && slides))
        .padding(.vertical, Self.bleed)
        .clipped()
        .padding(.vertical, -Self.bleed)
        .padding(.horizontal, -EmberMetrics.padding)
        .onChange(of: selection) { old, new in
            measured.selection = new
            guard slides else {
                position = new
                settled = new
                leaving = []
                return
            }
            settled = nil
            leaving.insert(old)
            MainRunLoop.perform { position = measured.selection }
            // A pane seen before has a height to go to at once, and one turned back to
            // midway never reports another; a new one says its own in `took`.
            if let known = measured.heights[new] { move(to: known) }
            settleLater()
        }
    }

    /// One pane's place in the strip: the pane while it is selected or on its way out, and
    /// otherwise nothing, the width of the popover.
    @ViewBuilder
    private func slot(_ id: ID) -> some View {
        Group {
            if id == selection || id == settled || leaving.contains(id) {
                pane(id)
                    .padding(.horizontal, EmberMetrics.padding)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                        took(height, of: id)
                    }
                    .allowsHitTesting(id == selection)
                    .environment(\.emberIsLeaving, id != selection)
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .frame(width: EmberMetrics.width, alignment: .top)
    }

    /// A pane's own height, as laid out. The selected pane's is where the height is, at rest,
    /// and where it goes during a change.
    private func took(_ height: CGFloat, of id: ID) {
        measured.heights[id] = height
        guard id == measured.selection, height != paneHeight else { return }
        guard settled != id, slides else {
            paneHeight = height
            return
        }
        // On its way already: the height sets off again from where it is, and the change
        // ends when this move does.
        move(to: height)
        settleLater()
    }

    /// Sends the held height to a pane's own.
    private func move(to height: CGFloat) {
        withAnimation(EmberMotion.modeSwitch) { paneHeight = height }
    }

    /// Ends the change when the strip and the height have arrived, with a frame to spare.
    /// Asked again, by a further change or a height that set off anew, the earlier ask
    /// leaves it to the later one.
    private func settleLater() {
        measured.change += 1
        let change = measured.change
        MainRunLoop.perform(after: EmberMotion.modeSwitchDuration + 0.05) {
            guard measured.change == change else { return }
            settled = measured.selection
            leaving = []
        }
    }
}

/// Holds its content to a height that animates as a layout: every frame lays the content
/// out at that frame's height, so what is under it moves with it and the popover can follow.
/// Not held, the content has its own height.
private struct HeldHeight: ViewModifier, Animatable {
    var height: CGFloat
    var isHeld: Bool

    nonisolated var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func body(content: Content) -> some View {
        content.frame(height: isHeld ? max(0, height) : nil, alignment: .top)
    }
}
