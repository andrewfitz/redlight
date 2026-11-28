import Foundation
import Testing
@testable import Redlight

/// Replays the reference's runs through `HabitModel.Channel`: every call the scripted users
/// made, in order, checking the screen after each write and at sampled ticks, and the whole
/// learned state after each day close.
///
/// A failure here means the port differs from the reference. Fix the port; do not loosen the
/// tolerance or edit a fixture.
@Suite struct HabitParityTests {
    private static let tolerance = 1e-9
    private let n = LearnedAutoFixtures.number

    private struct Replay {
        var channel: HabitModel.Channel
        let presets: [Double]
        let grid: [String: Any]

        func anchors(_ band: ClosedRange<Double>) -> [Double] { LearnedAutoFixtures.baseline(presets, band) }
        func phase(_ time: Double) throws -> SolarCurve.Phase {
            try #require(LearnedAutoFixtures.phase(grid[String(Int(time))]), "no tick at \(time)")
        }
        func curve(_ band: ClosedRange<Double>, _ phase: SolarCurve.Phase) -> Double {
            LearnedAutoFixtures.mix(anchors(band), phase)
        }
        func shown(at time: Double) throws -> Double {
            let phase = try phase(time)
            return channel.output(curve: curve(channel.handBand, phase), phase: phase)
        }
    }

    @Test func everyReferenceRunReplaysExactly() throws {
        let traces = try #require(try LearnedAutoFixtures.json("traces") as? [[String: Any]])
        let grid = try #require((try LearnedAutoFixtures.json("grid") as? [String: Any])?["ticks"] as? [String: Any])
        #expect(traces.count >= 30)
        var writes = 0, closes = 0, records = 0
        for trace in traces {
            let name = trace["name"] as? String ?? "?"
            let presets = try #require(trace["presets"] as? [NSNumber]).map(\.doubleValue)
            let band = try #require(trace["band"] as? [NSNumber]).map(\.doubleValue)
            let events = try #require(trace["events"] as? [[Any]])
            var replay = Replay(
                channel: HabitModel.Channel(
                    band: band[0]...band[1], base: LearnedAutoFixtures.baseline(presets, band[0]...band[1])),
                presets: presets, grid: grid)
            var day = 0
            for event in events {
                switch event[0] as? String {
                case "r":
                    let start = n(event[1]), seconds = n(event[2])
                    for index in 0..<Int(n(event[3])) {
                        let time = start + Double(index) * seconds
                        let phase = try replay.phase(time)
                        replay.channel.record(
                            phase: phase, seconds: seconds, at: time,
                            curve: replay.curve(replay.channel.handBand, phase))
                        records += 1
                    }
                case "o":
                    let shown = try replay.shown(at: n(event[1]))
                    #expect(abs(shown - n(event[2])) < Self.tolerance, "\(name) day \(day): shown at \(event[1])")
                case "w":
                    let time = n(event[1])
                    let phase = try replay.phase(time)
                    let frozen = replay
                    replay.channel.write(
                        n(event[2]), slider: n(event[3]) == 1, phase: phase, at: time,
                        curve: { frozen.curve($0, phase) }, anchors: { frozen.anchors($0) })
                    let shown = try replay.shown(at: time)
                    #expect(abs(shown - n(event[4])) < Self.tolerance, "\(name) day \(day): write at \(event[1])")
                    writes += 1
                case "h":
                    let frozen = replay
                    replay.channel.moveByHand(
                        event[1] as? String == "hi" ? .upper : .lower, to: n(event[2]),
                        gap: HabitModel.Rules.gap, anchors: { frozen.anchors($0) })
                case "c":
                    let offer = try #require(event[1] as? [NSNumber]).map(\.doubleValue)
                    replay.channel.close(offer: offer)
                    try expectState(replay.channel, try #require(event[2] as? [String: Any]), "\(name) close \(day)")
                    day += 1
                    closes += 1
                default:
                    Issue.record("unknown event \(event)")
                }
            }
        }
        #expect(writes > 300 && closes > 900 && records > 100_000)
    }

    private func expectState(_ channel: HabitModel.Channel, _ state: [String: Any], _ label: String) throws {
        let own = try #require(state["own"] as? [Any])
        for (index, value) in own.enumerated() {
            if value is NSNull {
                #expect(!channel.isKnown(index), "\(label): anchor \(index) should be open")
            } else {
                #expect(channel.isKnown(index), "\(label): anchor \(index) should be known")
                #expect(abs(channel.offset(of: index) - n(value)) < Self.tolerance, "\(label): anchor \(index)")
            }
        }
        #expect(abs(channel.flat - n(state["flat"])) < Self.tolerance, "\(label): flat")
        #expect(abs(channel.flags.lowerBound - n(state["lo"])) < Self.tolerance, "\(label): min flag")
        #expect(abs(channel.flags.upperBound - n(state["hi"])) < Self.tolerance, "\(label): max flag")
        let hand = try #require(state["ref"] as? [NSNumber]).map(\.doubleValue)
        #expect(abs(channel.handBand.lowerBound - hand[0]) < Self.tolerance, "\(label): hand band")
        #expect(abs(channel.handBand.upperBound - hand[1]) < Self.tolerance, "\(label): hand band")
        let counts = try #require(state["n"] as? [NSNumber]).map(\.intValue)
        #expect((0..<12).map { channel.votes(at: $0).count } == counts, "\(label): vote counts")
        // Rings are written at every seventh close and at the last; where they are, all of them.
        guard state["rings"] != nil else { return }
        let rings = try #require(state["rings"] as? [[[NSNumber]]], "\(label): rings unreadable")
        #expect(rings.count == HabitModel.Channel.anchorCount, "\(label): rings")
        for (index, ring) in rings.enumerated() {
            let votes = channel.votes(at: index)
            // A different count is reported above.
            guard votes.count == ring.count else { continue }
            for (vote, want) in zip(votes, ring) {
                #expect(abs(vote.value - want[0].doubleValue) < Self.tolerance, "\(label): vote at \(index)")
                #expect(vote.weight == want[1].doubleValue, "\(label): vote weight at \(index)")
            }
        }
    }

    @Test func aModelSurvivesEncodingExceptItsGesture() throws {
        let base = LearnedAutoFixtures.baseline([1, 0.7, 0.5, 0.25, 0], 0...1)
        var channel = HabitModel.Channel(band: 0...1, base: base)
        let noon = SolarCurve.Phase(from: .day, to: .day, fraction: 0)
        channel.write(0.9, slider: true, phase: noon, at: 1000, curve: { _ in 1 }, anchors: { _ in base })
        channel.record(phase: noon, seconds: 5, at: 1200, curve: 1)
        let model = HabitModel(color: channel, whitepoint: HabitModel.Channel(band: 0.5...1, base: base),
                               dayStart: Date(timeIntervalSince1970: 86_400))
        let data = try #require(model.encoded())
        let back = try #require(HabitModel.decode(data))
        #expect(back.color.state == model.color.state.withoutRecent)
        #expect(back.dayStart == model.dayStart)

        // The gesture is not saved. In one session a write within two minutes of the last
        // starts again from before the first; after a relaunch it is a nudge of its own. Here
        // the first write pushed the max past the hand band.
        let anchors = { (band: ClosedRange<Double>) in LearnedAutoFixtures.baseline([1, 0.7, 0.5, 0.25, 0], band) }
        var session = HabitModel.Channel(band: 0...0.9, base: anchors(0...0.9))
        session.write(1, slider: true, phase: noon, at: 2000, curve: { $0.upperBound }, anchors: anchors)
        #expect(session.handBand == 0...1)
        let saved = try #require(HabitModel(color: session, whitepoint: session).encoded())
        var relaunched = try #require(HabitModel.decode(saved)).color
        session.write(0.95, slider: true, phase: noon, at: 2060, curve: { $0.upperBound }, anchors: anchors)
        relaunched.write(0.95, slider: true, phase: noon, at: 2060, curve: { $0.upperBound }, anchors: anchors)
        #expect(session.handBand == 0...0.95, "one gesture: the push to 100 % is replaced")
        #expect(relaunched.handBand == 0...1, "after a relaunch the push stands")
        #expect(HabitModel.decode(Data("{\"version\":99}".utf8)) == nil)
        #expect(HabitModel.decode(Data("nonsense".utf8)) == nil)
    }
}

private extension HabitModel.Channel.State {
    /// The half hour of recent dwell is not saved.
    var withoutRecent: Self {
        var copy = self
        for index in copy.buckets.indices { copy.buckets[index].recent = [] }
        return copy
    }
}
