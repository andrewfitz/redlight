import Foundation

/// What Auto has learned from the user's own adjustments: an offset at each anchor of the sun
/// curve, per channel, and the two limit flags.
///
/// Pure and deterministic. Values are slider fractions, 0…1, for both channels: colour temp is
/// stored as it is, white point as `WhitepointScale.shown`. The rules' thresholds are in
/// those units. The caller supplies the sun curve and the anchors' own values; the model only
/// adds to the first and compares against the second.
///
/// The rules, and why each exists, are in the design spec
/// (`docs/superpowers/specs/2026-11-25-learned-auto-design.md`). This is a port of the
/// reference they were simulated with; `HabitParityTests` replays that reference's runs.
struct HabitModel: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = HabitModel.currentVersion
    var color: Channel
    var whitepoint: Channel
    /// The 04:00 that opened the learning day the channels are recording.
    var dayStart: Date?
    /// Auto's offsets as they were left when learning was switched off, in slider fractions.
    /// If they are still the same when it is switched on again, nothing was changed
    /// meanwhile and each channel's own flat offset comes back.
    var heldColor: Double?
    var heldWhitepoint: Double?

    init(color: Channel, whitepoint: Channel, dayStart: Date? = nil) {
        self.color = color
        self.whitepoint = whitepoint
        self.dayStart = dayStart
    }

    enum Rules {
        /// Votes kept per anchor.
        static let ringSize = 7
        /// Weight of a change made by hand as lead, and of any other vote.
        static let correctionWeight = 3.0
        static let acceptanceWeight = 1.0
        /// A vote this close to the anchor's value that morning is acceptance of it.
        static let deadBand = 0.02
        /// After a nudge, dwell at its lead anchor counts again from this many seconds on.
        static let settle: TimeInterval = 120
        /// Attended seconds for a vote, or half of what the anchor's stretch offered that day.
        static let dwell: TimeInterval = 600
        /// Seconds before a nudge that are not acceptance, at anchors not nudged today.
        static let lookback: TimeInterval = 1800
        /// Writes no further apart than this are one nudge.
        static let gestureWindow: TimeInterval = 120
        /// A correction no larger than this, at an anchor with history, is taken at once.
        static let smallCorrection = 0.08
        /// Votes an end anchor needs before its flag follows it.
        static let promoteVotes = 4
        /// A flag moves only by more than this.
        static let promoteMargin = 0.005
        /// A learned flag may clip a known anchor by no more than this.
        static let clipTolerance = 0.01
        /// The least distance a learned flag keeps from the other: `SliderCore.limitGap`.
        static let gap = 0.05
        static let epsilon = 1e-10
    }

    enum End: Sendable { case lower, upper
        /// The anchor that sits on this end of the band: Late below, Day above.
        var anchor: Int {
            self == .upper ? SolarCurve.Anchor.day.rawValue : SolarCurve.Anchor.late.rawValue
        }
    }

    struct Vote: Codable, Equatable, Sendable {
        var value: Double
        var weight: Double
    }

    /// One anchor's evidence for the day that is open.
    struct Bucket: Codable, Equatable, Sendable {
        struct Dwell: Codable, Equatable, Sendable {
            var value: Double
            var seconds: Double
        }
        struct Sample: Equatable, Sendable {
            var time: TimeInterval
            var value: Double
            var seconds: Double
        }

        /// Attended seconds under each offset, in the order the offsets first stood.
        var dwell: [Dwell] = []
        /// Nudged as the lead anchor today.
        var hand = false
        /// Dwell counts from this time on.
        var resume: TimeInterval = 0
        /// The last half hour of `dwell`, newest last, so that a nudge can take it back.
        /// Not saved: after a relaunch the half hour before a nudge stands as acceptance.
        var recent: [Sample] = []

        private enum CodingKeys: String, CodingKey { case dwell, hand, resume }

        var total: Double { dwell.reduce(0) { $0 + $1.seconds } }

        mutating func add(_ value: Double, seconds: Double, at time: TimeInterval) {
            if let index = dwell.firstIndex(where: { $0.value == value }) {
                dwell[index].seconds += seconds
            } else {
                dwell.append(Dwell(value: value, seconds: seconds))
            }
            recent.append(Sample(time: time, value: value, seconds: seconds))
            // Older samples can never be taken back: a nudge only reaches `lookback` behind it.
            if let first = recent.first, time - first.time > 2 * Rules.lookback {
                recent.removeAll { time - $0.time > Rules.lookback }
            }
        }

        /// The anchor's offset moved by `amount` with no change on screen: the time sat
        /// through moves with it, rounded as it was recorded.
        mutating func shift(by amount: Double) {
            var shifted: [Dwell] = []
            for entry in dwell {
                let value = Channel.rounded(entry.value + amount)
                if let index = shifted.firstIndex(where: { $0.value == value }) {
                    shifted[index].seconds += entry.seconds
                } else {
                    shifted.append(Dwell(value: value, seconds: entry.seconds))
                }
            }
            dwell = shifted
            for index in recent.indices { recent[index].value = Channel.rounded(recent[index].value + amount) }
        }

        /// Takes back the dwell recorded at or after `time`.
        mutating func forget(since time: TimeInterval) {
            while let last = recent.last, last.time >= time {
                recent.removeLast()
                guard let index = dwell.firstIndex(where: { $0.value == last.value }) else { continue }
                dwell[index].seconds -= last.seconds
                if dwell[index].seconds <= 1e-9 { dwell.remove(at: index) }
            }
        }
    }

    /// One slider's learning.
    struct Channel: Codable, Equatable, Sendable {
        /// Everything a gesture's later writes start again from.
        struct State: Codable, Equatable, Sendable {
            /// An anchor's own offset, once it has evidence. Nil is open: it shows `flat`.
            var own: [Double?]
            /// The offset every open anchor shows: today's Auto nudge.
            var flat: Double
            /// Each anchor's last votes, newest last.
            var rings: [[Vote]]
            /// The limits as last set by hand. The sun curve is scaled into this band.
            var handLower: Double
            var handUpper: Double
            /// The flags: what clamps the output. Never wider than the hand band.
            var lower: Double
            var upper: Double
            /// The sun curve's value at each anchor, in the hand band.
            var base: [Double]
            var buckets: [Bucket]
            /// Each anchor's offset when the day opened.
            var start: [Double]
            /// Anchors a nudge moved today.
            var written: Set<Int>
        }

        private(set) var state: State
        /// The state before the first write of the nudge in progress, and when its last
        /// write was. Not saved: a relaunch ends the gesture.
        private var gesture: State?
        private var lastWrite: TimeInterval?

        private enum CodingKeys: String, CodingKey { case state }

        static let anchorCount = SolarCurve.Anchor.allCases.count

        /// Nothing learned: every anchor open, the flags on the hand band.
        /// `base` is the sun curve's value at each anchor in that band.
        init(band: ClosedRange<Double>, flat: Double = 0, base: [Double]) {
            precondition(base.count == Channel.anchorCount)
            let count = Channel.anchorCount
            state = State(
                own: Array(repeating: nil, count: count), flat: flat,
                rings: Array(repeating: [], count: count),
                handLower: band.lowerBound, handUpper: band.upperBound,
                lower: band.lowerBound, upper: band.upperBound, base: base,
                buckets: Array(repeating: Bucket(), count: count),
                start: Array(repeating: flat, count: count), written: [])
        }

        // MARK: Reading

        var flat: Double { state.flat }
        var flags: ClosedRange<Double> { state.lower...state.upper }
        var handBand: ClosedRange<Double> { state.handLower...state.handUpper }
        /// True when the flags are not where the hand left them.
        var hasLearnedFlags: Bool { state.lower != state.handLower || state.upper != state.handUpper }
        var knownAnchors: Int { state.own.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }
        var isFixed: Bool { state.lower == state.upper }

        /// An anchor's offset now: its own, or the shared one while it is open.
        func offset(of anchor: Int) -> Double { state.own[anchor] ?? state.flat }
        func isKnown(_ anchor: Int) -> Bool { state.own[anchor] != nil }

        /// Known from what the user kept, not only from a limit they set: an end anchor that
        /// stands on its hand-set limit and has nothing else is not something learned.
        func isLearnedAnchor(_ anchor: Int) -> Bool {
            guard let own = state.own[anchor] else { return false }
            return !(own == 0 && state.rings[anchor] == Channel.standing)
        }

        /// Parts of the day learned from what the user kept.
        var learnedAnchors: Int { (0..<Channel.anchorCount).filter(isLearnedAnchor).count }
        func votes(at anchor: Int) -> [Vote] { state.rings[anchor] }
        /// What an anchor shows when the sun is exactly on it: the curve there, its offset,
        /// and the flags.
        func shown(at anchor: Int) -> Double { clamp(state.base[anchor] + offset(of: anchor)) }

        /// The offset the anchors around the sun add to the curve.
        func offset(at phase: SolarCurve.Phase) -> Double {
            var sum = 0.0
            for (anchor, weight) in phase.weights { sum += weight * offset(of: anchor.rawValue) }
            return sum
        }

        /// True where a known anchor's own offset is part of what shows.
        func isLearned(at phase: SolarCurve.Phase) -> Bool {
            phase.weights.contains { state.own[$0.anchor.rawValue].map { $0 != 0 } ?? false }
        }

        /// The curve plus the offsets, before the flags clamp it.
        func unclamped(curve: Double, phase: SolarCurve.Phase) -> Double {
            var value = curve
            for (anchor, weight) in phase.weights { value += weight * offset(of: anchor.rawValue) }
            return value
        }

        /// What reaches the screen. `curve` is the sun curve now, in the hand band.
        func output(curve: Double, phase: SolarCurve.Phase) -> Double {
            clamp(unclamped(curve: curve, phase: phase))
        }

        private func clamp(_ value: Double) -> Double {
            min(state.upper, max(state.lower, value))
        }

        // MARK: A nudge

        /// A value set by hand in Auto. `slider` is true for the popover's slider, which may
        /// push a flag; other writes stay inside the flags.
        ///
        /// `curve` gives the sun curve now for a hand band, and `anchors` the curve's value
        /// at each anchor for one: a push past the hand band changes the band inside this call.
        mutating func write(
            _ value: Double, slider: Bool, phase: SolarCurve.Phase, at time: TimeInterval,
            curve: (ClosedRange<Double>) -> Double, anchors: (ClosedRange<Double>) -> [Double]
        ) {
            // Inputs normally come from validated command/UI paths, but this model is also
            // restored and exercised directly. A non-finite sample must never poison the
            // offsets that are persisted for future sessions.
            guard value.isFinite, time.isFinite else { return }
            // One gesture is one nudge: a later write of it starts from the state before the
            // first, so a drag leaves what its last value alone would have.
            if let gesture, let lastWrite, time >= lastWrite, time - lastWrite <= Rules.gestureWindow {
                state = gesture
            } else {
                gesture = state
            }
            lastWrite = time

            var value = min(1, max(0, value))
            if slider {
                if value > state.upper + Rules.epsilon { push(.upper, to: value, anchors: anchors) }
                if value < state.lower - Rules.epsilon { push(.lower, to: value, anchors: anchors) }
            }
            value = clamp(value)
            let weights = phase.weights
            let inner = unclamped(curve: curve(handBand), phase: phase)
            if abs(value - clamp(inner)) < 1e-12 { return }
            let error = value - inner

            // The half hour before a nudge is what was being corrected, not acceptance, at
            // every anchor not itself nudged today.
            for index in state.buckets.indices where !state.buckets[index].hand {
                state.buckets[index].forget(since: time - Rules.lookback)
            }

            let lead = phase.lead.rawValue
            var openShare = 0.0, knownNorm = 0.0
            for (anchor, weight) in weights {
                if state.own[anchor.rawValue] == nil { openShare += weight } else { knownNorm += weight * weight }
            }
            // Open anchors follow the whole nudge, as the flat offset does. Known ones share
            // what is left by weight, so the screen lands exactly on the value.
            let rest = error * (1 - openShare)
            let leadIsOpen = state.own[lead] == nil
            var moved: [(anchor: Int, value: Double)] = []
            for (anchor, weight) in weights {
                let index = anchor.rawValue
                if state.own[index] == nil {
                    // An open lead becomes known. An open minor neighbour stays open.
                    if index == lead { moved.append((index, offset(of: index) + error)) }
                } else if leadIsOpen || knownNorm > 0 {
                    moved.append((index, offset(of: index) + rest * weight / knownNorm))
                }
            }
            state.flat += error
            for (index, value) in moved {
                state.own[index] = value
                state.written.insert(index)
                if index == lead {
                    // Dwell restarts at the lead anchor only, once the nudge has settled.
                    var bucket = Bucket()
                    bucket.resume = time + Rules.settle
                    bucket.hand = true
                    state.buckets[index] = bucket
                }
            }
        }

        /// A slider pushed past a flag. Inside the hand band the flag is only lifted to the
        /// value: the curve is not rescaled, and the flag is back at the next close unless
        /// the nudge is kept. Past the hand band it is a hand move.
        private mutating func push(_ end: End, to value: Double, anchors: (ClosedRange<Double>) -> [Double]) {
            if state.handLower - Rules.epsilon <= value, value <= state.handUpper + Rules.epsilon {
                if end == .upper { state.upper = value } else { state.lower = value }
            } else {
                moveByHand(end, to: value, gap: Rules.gap, anchors: anchors)
            }
        }

        // MARK: Evidence

        /// Attended time under the offsets in force. `curve` is the sun curve now, in the
        /// hand band.
        mutating func record(
            phase: SolarCurve.Phase, seconds: Double, at time: TimeInterval, curve: Double
        ) {
            // Sampling is driven by elapsed wall time. A clock adjustment or a malformed
            // caller must not inject negative, non-finite, or zero-duration evidence into the
            // accumulators, since that would distort the weighted median at day close.
            guard seconds.isFinite, seconds > 0, time.isFinite, curve.isFinite else { return }
            let inner = unclamped(curve: curve, phase: phase)
            // Pinned at a limit, any offset beyond it looks the same, so an open anchor
            // learns nothing there.
            let pinned = !(state.lower + Rules.epsilon < inner && inner < state.upper - Rules.epsilon)
            for (anchor, weight) in phase.weights {
                let index = anchor.rawValue
                if pinned, state.own[index] == nil { continue }
                guard time >= state.buckets[index].resume else { continue }
                state.buckets[index].add(
                    Channel.rounded(offset(of: index)), seconds: weight * seconds, at: time)
            }
        }

        /// To four places, as the reference rounds: on the decimal expansion of the value
        /// itself, which multiplying by 10⁴ first does not always give.
        static func rounded(_ value: Double) -> Double {
            // Values recorded during normal operation already have four decimal places
            // (nudges and estimates are rounded before they enter the model). Avoid the
            // relatively expensive String formatting/parsing path for those samples. The
            // exact-integral check keeps the decimal-expansion behavior below for values
            // close to, but not exactly on, a four-place boundary.
            let scaled = value * 10_000
            if scaled.isFinite, scaled.rounded() == scaled { return value }
            return Double(String(format: "%.4f", value)) ?? value
        }

        // MARK: Day close

        /// Ends the learning day: each anchor casts at most one vote, the flat offset follows
        /// the known anchors, and the flags follow Day and Late. `offer` is the seconds each
        /// anchor's stretch of the curve lasted that day.
        mutating func close(offer: [Double]) {
            precondition(offer.count == Channel.anchorCount)
            for index in 0..<Channel.anchorCount {
                let bucket = state.buckets[index]
                let total = bucket.total
                let enough = total > 0 && total + Rules.epsilon >= min(Rules.dwell, offer[index] / 2)
                var vote: Double?
                var hand = false
                if enough {
                    // The offset that stood for most of the attended time.
                    let now = offset(of: index)
                    vote = HabitModel.weightedMedian(
                        bucket.dwell.map { Vote(value: $0.value, weight: $0.seconds) },
                        current: now, newest: now, tieGoesToNewest: false)
                    hand = bucket.hand
                } else if state.written.contains(index), bucket.hand {
                    // A nudge always counts, however briefly it stood.
                    vote = state.own[index]
                    hand = true
                }
                guard var value = vote else {
                    // Shifted as a minor neighbour and not sat through: it goes back.
                    if state.written.contains(index), !state.rings[index].isEmpty {
                        state.own[index] = estimate(index, current: state.start[index], newest: state.start[index])
                    }
                    continue
                }
                let start = state.start[index]
                let ring = state.rings[index]
                var weight = hand ? Rules.correctionWeight : Rules.acceptanceWeight
                if abs(value - start) <= Rules.deadBand {
                    value = start
                    hand = false
                    weight = Rules.acceptanceWeight
                }
                if hand, !ring.isEmpty, abs(value - start) <= Rules.smallCorrection {
                    // A small correction where the anchor has history is taken at once: its
                    // history is restated at the new value.
                    var restated = ring.map { Vote(value: value, weight: $0.weight) }
                    restated.append(Vote(value: value, weight: Rules.correctionWeight))
                    state.rings[index] = Array(restated.suffix(Rules.ringSize))
                    state.own[index] = value
                    continue
                }
                state.rings[index] = Array((ring + [Vote(value: value, weight: weight)]).suffix(Rules.ringSize))
                state.own[index] = estimate(index, current: start, newest: value)
            }
            followKnownAnchors()
            gesture = nil
            lastWrite = nil
            openDay()
            promote()
            openDay()
        }

        private func estimate(_ index: Int, current: Double, newest: Double) -> Double {
            HabitModel.weightedMedian(state.rings[index], current: current, newest: newest, tieGoesToNewest: true)
        }

        /// Parts of the day never attended show the typical offset of those that were.
        private mutating func followKnownAnchors() {
            let known = state.own.compactMap { $0 }.sorted()
            guard !known.isEmpty else { return }
            let middle = known.count / 2
            state.flat = known.count % 2 == 1 ? known[middle] : (known[middle - 1] + known[middle]) / 2
        }

        private mutating func openDay() {
            state.buckets = Array(repeating: Bucket(), count: Channel.anchorCount)
            state.start = (0..<Channel.anchorCount).map { offset(of: $0) }
            state.written = []
        }

        /// The flags follow the end anchors once those have their votes. Only the clamp
        /// moves; the curve is not rescaled, so a known anchor keeps its picture.
        private mutating func promote() {
            var lower = state.lower, upper = state.upper
            for end in [End.upper, .lower] {
                let index = end.anchor
                guard state.own[index] != nil, state.rings[index].count >= Rules.promoteVotes else { continue }
                let value = shown(at: index)
                if end == .upper, value < upper - Rules.promoteMargin { upper = value }
                if end == .lower, value > lower + Rules.promoteMargin { lower = value }
            }
            if (lower == state.lower && upper == state.upper) || upper - lower < Rules.gap { return }
            let shown = (0..<Channel.anchorCount).filter { state.own[$0] != nil }.map { self.shown(at: $0) }
            guard let lowest = shown.min(), let highest = shown.max() else { return }
            let clip = max(max(0, lower - lowest), max(0, highest - upper))
            if clip > Rules.clipTolerance { return }
            state.lower = lower
            state.upper = upper
        }

        // MARK: Limits set by hand

        /// A flag dragged, `redlight limits`, or a slider pushed past the hand band. The
        /// learned flags are folded into the hand band first, so known anchors keep their
        /// picture; then the band changes and the curve scales with it, as it does without
        /// learning. That end anchor's history is replaced by the limit, standing like four
        /// accepted days, so learning does not pull the flag back at the next close.
        ///
        /// `gap` keeps the band from closing; pass 0 where the caller has its own rule.
        mutating func moveByHand(
            _ end: End, to value: Double, gap: Double, anchors: (ClosedRange<Double>) -> [Double]
        ) {
            fold(anchors: anchors)
            // Inside the slider's range even where the other limit is closer to the end
            // than the gap: `redlight limits` can set a band narrower than the flags allow.
            if end == .upper {
                state.handUpper = min(1, max(value, state.handLower + gap))
            } else {
                state.handLower = max(0, min(value, state.handUpper - gap))
            }
            state.lower = state.handLower
            state.upper = state.handUpper
            state.base = anchors(handBand)
            standOnLimit(end)
            state.start = (0..<Channel.anchorCount).map { offset(of: $0) }
        }

        /// Both limits at once, as the app sets them: a flag dragged, `redlight limits`, a
        /// Fixed value. An end that does not move keeps its anchor's history, unless it is
        /// `setAt`, an end set by hand where its learned flag was: that one stands too.
        ///
        /// A limit set by hand wins over the day's evidence: an end that stands loses its
        /// anchor's evidence for the day, so the close cannot restate a nudge past it. The
        /// rest of the day's evidence moves with the anchors when learned flags fold, so it is
        /// not scored against the old curve. Not in the reference: `moveByHand` is its rule.
        mutating func setHandBand(
            _ band: ClosedRange<Double>, setAt end: End? = nil, anchors: (ClosedRange<Double>) -> [Double]
        ) {
            let unfolded = state.base
            fold(anchors: anchors)
            for index in 0..<Channel.anchorCount where isKnown(index) {
                let moved = state.base[index] - unfolded[index]
                guard moved != 0 else { continue }
                state.start[index] -= moved
                state.buckets[index].shift(by: -moved)
            }
            let lowerMoved = band.lowerBound != state.handLower || end == .lower
            let upperMoved = band.upperBound != state.handUpper || end == .upper
            state.handLower = band.lowerBound
            state.handUpper = band.upperBound
            state.lower = state.handLower
            state.upper = state.handUpper
            state.base = anchors(handBand)
            for (end, moved) in [(End.lower, lowerMoved), (.upper, upperMoved)] where moved {
                standOnLimit(end)
                state.buckets[end.anchor] = Bucket()
                state.written.remove(end.anchor)
                state.start[end.anchor] = 0
            }
            dropGesture()
        }

        /// True when this end's flag is not where the hand left it.
        func hasLearnedFlag(_ end: End) -> Bool {
            end == .upper ? state.upper != state.handUpper : state.lower != state.handLower
        }

        /// The votes of an end anchor that stands on a limit set by hand.
        static let standing = Array(
            repeating: Vote(value: 0, weight: Rules.acceptanceWeight), count: Rules.promoteVotes)

        private mutating func standOnLimit(_ end: End) {
            state.own[end.anchor] = 0
            state.rings[end.anchor] = Channel.standing
        }

        /// Makes the learned flags the hand band. The curve then scales into them, so each
        /// known anchor's offset and votes give up what its curve value moved by.
        mutating func fold(anchors: (ClosedRange<Double>) -> [Double]) {
            guard hasLearnedFlags else { return }
            state.handLower = state.lower
            state.handUpper = state.upper
            rebase(to: anchors(handBand))
        }

        /// The curve under the anchors changed (a band folded, a preset saved): known anchors
        /// keep the picture they had.
        mutating func rebase(to base: [Double]) {
            precondition(base.count == Channel.anchorCount)
            let old = state.base
            state.base = base
            for index in 0..<Channel.anchorCount {
                guard let own = state.own[index] else { continue }
                let moved = base[index] - old[index]
                state.own[index] = own - moved
                state.rings[index] = state.rings[index].map { Vote(value: $0.value - moved, weight: $0.weight) }
            }
            followKnownAnchors()
        }

        // MARK: The app's own changes

        /// The curve under the anchors was reshaped from outside: a preset saved, or one that
        /// changed while learning was off. Known anchors keep their picture, as in `rebase`;
        /// open ones keep the flat offset, so only what the preset changes moves. The time sat
        /// through was recorded against the old curve and is dropped, so that it cannot vote
        /// the old picture back in. The day's nudges stand: each is still voted at the close,
        /// against the morning's picture on the new curve. Nothing happens when no anchor moved.
        mutating func reshape(to base: [Double]) {
            precondition(base.count == Channel.anchorCount)
            guard zip(base, state.base).contains(where: { abs($0 - $1) > 1e-12 }) else { return }
            let old = state.base, flat = state.flat
            rebase(to: base)
            state.flat = flat
            for index in 0..<Channel.anchorCount {
                // An open anchor's morning value is a flat offset, which the curve does not move.
                if isKnown(index) { state.start[index] -= base[index] - old[index] }
                state.buckets[index].dwell = []
                state.buckets[index].recent = []
            }
            dropGesture()
        }

        /// Any change that is not a nudge ends the gesture: its later writes must not undo it.
        mutating func dropGesture() {
            gesture = nil
            lastWrite = nil
        }

        /// The system clock was set, maybe back. Recent dwell may be stamped in the future,
        /// where a nudge would take it all back, so none of it can be taken back now. A wait
        /// for a nudge to settle is cut to one settle from now, as the time it was waiting
        /// for may be hours off.
        mutating func clockWasSet(at time: TimeInterval) {
            for index in state.buckets.indices {
                // Samples stamped after the new time can no longer be told apart from what comes
                // next: they stay counted, but a nudge cannot take them back. The rest can.
                state.buckets[index].recent.removeAll { $0.time > time }
                state.buckets[index].resume = min(state.buckets[index].resume, time + Rules.settle)
            }
            dropGesture()
        }

        /// After a write the app makes for its own reasons (holding the screen on a preset just
        /// saved): the open anchors around the sun keep the offset that write gave them, and
        /// every other open part of the day goes back to `flat`. The screen stays where the
        /// write put it.
        mutating func keepOpenAnchors(at phase: SolarCurve.Phase, flat: Double) {
            for (anchor, _) in phase.weights where state.own[anchor.rawValue] == nil {
                state.own[anchor.rawValue] = state.flat
            }
            state.flat = flat
        }

        /// Reset learning: every anchor open again and the flags back on the hand band. The
        /// flat offset is the user's Auto nudge and is kept.
        mutating func openAll() {
            let count = Channel.anchorCount
            state.own = Array(repeating: nil, count: count)
            state.rings = Array(repeating: [], count: count)
            state.lower = state.handLower
            state.upper = state.handUpper
            dropGesture()
            openDay()
        }

        /// The offset of the open anchors, set from outside: the nudge Auto had before
        /// learning was switched on, or zero for a channel that is Fixed.
        mutating func setFlat(_ value: Double) {
            guard value.isFinite else { return }
            state.flat = value
            for index in 0..<Channel.anchorCount where state.own[index] == nil {
                state.start[index] = value
            }
            dropGesture()
        }

        /// The day's evidence is dropped without a vote: learning was off for part of it.
        mutating func discardDay() {
            dropGesture()
            openDay()
        }

        /// False for a state a hand-edited or damaged file could hold and the rules could not.
        var isSane: Bool {
            let count = Channel.anchorCount
            guard state.own.count == count, state.rings.count == count, state.base.count == count,
                  state.buckets.count == count, state.start.count == count else { return false }
            let numbers = state.own.compactMap { $0 } + state.base + state.start
                + [state.flat, state.handLower, state.handUpper, state.lower, state.upper]
                + state.rings.flatMap { $0.flatMap { [$0.value, $0.weight] } }
                + state.buckets.flatMap { $0.dwell.flatMap { [$0.value, $0.seconds] } + [$0.resume] }
            guard numbers.allSatisfy(\.isFinite) else { return false }
            guard state.rings.allSatisfy({ $0.count <= Rules.ringSize }) else { return false }
            // Votes and dwell are accumulated durations. Negative values cannot be produced
            // by the learning rules, and accepting them from a damaged defaults payload would
            // let weightedMedian select an arbitrary value or make an anchor appear learned
            // without any attended time.
            guard state.rings.allSatisfy({ ring in
                ring.allSatisfy { $0.weight >= 0 }
            }) else { return false }
            guard state.buckets.allSatisfy({ bucket in
                bucket.dwell.allSatisfy { $0.seconds >= 0 }
            }) else { return false }
            let slack = 1e-6
            guard state.base.allSatisfy({ $0 >= -slack && $0 <= 1 + slack }),
                  state.rings.flatMap({ $0 }).allSatisfy({ abs($0.value) <= 4 }),
                  state.buckets.flatMap({ $0.dwell }).allSatisfy({ abs($0.value) <= 4 }) else {
                return false
            }
            guard state.written.allSatisfy({ (0..<count).contains($0) }) else { return false }
            // A lifted flag may sit a rounding error outside the hand band, and an offset can
            // pass the slider's own range where a known anchor stands far from the open ones.
            return state.handLower <= state.handUpper
                && state.handLower - slack <= state.lower && state.lower <= state.upper
                && state.upper <= state.handUpper + slack
                && state.handLower >= -slack && state.handUpper <= 1 + slack
                && abs(state.flat) <= 4 && state.own.allSatisfy { abs($0 ?? 0) <= 4 }
        }
    }

    /// The value at which the weights on either side balance. An exact balance goes to
    /// `newest` or stays at `current`. Votes with no weight do not count.
    static func weightedMedian(
        _ votes: [Vote], current: Double, newest: Double, tieGoesToNewest: Bool
    ) -> Double {
        var groups: [Double: Double] = [:]
        for vote in votes where vote.value.isFinite && vote.weight.isFinite && vote.weight > 0 {
            groups[vote.value, default: 0] += vote.weight
        }
        guard !groups.isEmpty else { return current }
        let sorted = groups.sorted { $0.key < $1.key }
        let half = sorted.reduce(0) { $0 + $1.value } / 2
        var sum = 0.0
        for (value, weight) in sorted {
            sum += weight
            if sum > half + Rules.epsilon { return value }
            if abs(sum - half) <= Rules.epsilon { return tieGoesToNewest ? newest : current }
        }
        return current
    }

    /// Nil for data that is not a model this version can use: damaged, from a newer
    /// version, or holding values the rules could not have produced.
    static func decode(_ data: Data) -> HabitModel? {
        struct Probe: Decodable { let version: Int }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data),
              probe.version == currentVersion,
              let model = try? JSONDecoder().decode(HabitModel.self, from: data),
              model.color.isSane, model.whitepoint.isSane else { return nil }
        return model
    }

    /// The version a save says it is, readable or not. Nil when it does not say.
    static func storedVersion(_ data: Data) -> Int? {
        struct Probe: Decodable { let version: Int }
        return (try? JSONDecoder().decode(Probe.self, from: data))?.version
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        // The same model is the same bytes, so an unchanged one is not written again.
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(self)
    }
}

// MARK: - In words

extension HabitModel {
    /// A learned offset smaller than this is not worth a sentence.
    static let worthSaying = 0.03

    /// What has been learned, one sentence per slider: where its flags were moved to, and the
    /// part of the day that differs most from the sun curve. A Fixed slider shows neither.
    func sentences() -> [String] {
        func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
        func describe(_ channel: Channel, name: String, lower: String, higher: String) -> String? {
            guard !channel.isFixed else { return nil }
            var parts: [String] = []
            if channel.hasLearnedFlags {
                parts.append("runs from \(percent(channel.flags.lowerBound)) to \(percent(channel.flags.upperBound))")
            }
            // Day and Late sit on the band's ends: once a flag has followed one, the flag says it.
            let candidates = SolarCurve.Anchor.allCases.filter { anchor in
                let index = anchor.rawValue
                guard channel.isLearnedAnchor(index) else { return false }
                switch anchor {
                case .day: return channel.shown(at: index) < channel.flags.upperBound - Rules.promoteMargin
                case .late: return channel.shown(at: index) > channel.flags.lowerBound + Rules.promoteMargin
                default: return true
                }
            }
            if let anchor = candidates.max(by: {
                abs(channel.offset(of: $0.rawValue)) < abs(channel.offset(of: $1.rawValue))
            }) {
                let offset = channel.offset(of: anchor.rawValue)
                if abs(offset) >= HabitModel.worthSaying {
                    parts.append("is about \(percent(abs(offset))) \(offset < 0 ? lower : higher) \(anchor.spoken)")
                }
            }
            return parts.isEmpty ? nil : "\(name) \(parts.joined(separator: " and "))."
        }
        return [
            describe(color, name: "Color temp", lower: "redder", higher: "clearer"),
            describe(whitepoint, name: "White point", lower: "dimmer", higher: "brighter"),
        ].compactMap { $0 }
    }
}

extension SolarCurve.Anchor {
    /// The part of the day an anchor stands for, as the end of a sentence.
    var spoken: String {
        switch self {
        case .day: "in the day"
        case .eveningWarm: "in the late afternoon"
        case .eveningSunset: "around sunset"
        case .eveningCivil, .eveningNautical: "at dusk"
        case .eveningNight: "after dark"
        case .late: "late at night"
        case .morningNight: "before dawn"
        case .morningCivil, .morningNautical: "at dawn"
        case .morningSunset: "around sunrise"
        case .morningWarm: "in the early morning"
        }
    }
}
