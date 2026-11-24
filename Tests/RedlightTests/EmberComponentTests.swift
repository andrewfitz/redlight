import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Redlight

/// Placement of the sun arc's clock times.
@Suite struct AnchoredLabelsTests {
    @Test func oneLabelIsCentredOnItsAnchorUntilAnEndOfTheRow() {
        #expect(AnchoredLabels.origin(anchor: 100, width: 30, row: 268) == 85)
        #expect(AnchoredLabels.origin(anchor: 4, width: 30, row: 268) == 0)
        #expect(AnchoredLabels.origin(anchor: 0, width: 30, row: 268) == 0)
        #expect(AnchoredLabels.origin(anchor: 268, width: 30, row: 268) == 238)
        #expect(AnchoredLabels.origin(anchor: 260, width: 30, row: 268) == 238)
        // Wider than the row: it starts at the row's start rather than hanging off it.
        #expect(AnchoredLabels.origin(anchor: 10, width: 40, row: 20) == 0)
    }

    @Test func twoLabelsWithRoomStayCentred() {
        let xs = AnchoredLabels.origins(first: (70, 40), second: (200, 40), row: 268, gap: 6)
        #expect(xs.first == 50)
        #expect(xs.second == 180)
    }

    @Test func collidingLabelsMoveApartEvenly() {
        let xs = AnchoredLabels.origins(first: (130, 40), second: (140, 40), row: 268, gap: 6)
        #expect(xs.second - (xs.first + 40) == 6)
        // Their shared centre has not moved.
        #expect((xs.first + xs.second + 40) / 2 == 135)
        // Coincident anchors behave the same way.
        let same = AnchoredLabels.origins(first: (135, 40), second: (135, 40), row: 268, gap: 6)
        #expect(same.first == xs.first && same.second == xs.second)
    }

    @Test func collidingLabelsAtAnEndSlideBackOntoTheRow() {
        let left = AnchoredLabels.origins(first: (2, 40), second: (10, 40), row: 268, gap: 6)
        #expect(left.first == 0)
        #expect(left.second == 46)
        let right = AnchoredLabels.origins(first: (258, 40), second: (266, 40), row: 268, gap: 6)
        #expect(right.second == 228)
        #expect(right.first == 182)
    }

    @Test func labelsTooWideForTheRowStartFromItsTwoEnds() {
        let xs = AnchoredLabels.origins(first: (10, 40), second: (20, 40), row: 60, gap: 6)
        #expect(xs.first == 0)
        #expect(xs.second == 20)
    }
}

/// Pure logic behind the sun arc's horizon labels and bedtime mark.
@MainActor @Suite struct EmberSunArcTests {
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// Minutes after midnight of a 24-hour clock text, whether or not its hour is padded.
    private func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        return hour * 60 + minute
    }

    /// Evenly spaced samples one hour apart from a fixed midnight.
    private func samples(_ elevations: [Double]) -> [SunCycle.Sample] {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        return elevations.enumerated().map { index, elevation in
            SunCycle.Sample(t: Double(index) / Double(max(1, elevations.count - 1)), elevation: elevation,
                            rising: false, date: start.addingTimeInterval(Double(index) * 3_600))
        }
    }

    @Test func ordinaryDayHasOneSunriseThenOneSunset() throws {
        let chicago = calendar("America/Chicago")
        let now = date(2026, 3, 20, in: chicago)
        let cycle = SunCycle(now: now, latitude: 41.88, longitude: -87.63, calendar: chicago)
        let crossings = SunArcView.horizonCrossings(in: cycle.samples)
        #expect(crossings.map(\.rising) == [true, false])
        let (sunrise, sunset) = SunArcView.sunriseAndSunset(in: cycle.samples)
        let rise = try #require(sunrise), set = try #require(sunset)
        #expect(rise == crossings[0] && set == crossings[1])
        // Near the equinox: sunrise a little before 7, sunset a little after 7, daylight time.
        #expect((6.5...7.25).contains(rise.t * 24))
        #expect((18.75...19.5).contains(set.t * 24))
        // The same fractions the cycle's own interpolation finds.
        let fractions = cycle.crossingFractions(at: 0)
        #expect(fractions.count == 2)
        #expect(abs(fractions[0] - rise.t) < 1e-12 && abs(fractions[1] - set.t) < 1e-12)
        // The interpolated instant really is on the horizon, and matches its fraction.
        for crossing in [rise, set] {
            let elevation = SolarCalculator.elevation(at: crossing.date, latitude: 41.88, longitude: -87.63)
            #expect(abs(elevation) < 0.05)
            let dayStart = try #require(cycle.samples.first?.date)
            #expect(abs(crossing.date.timeIntervalSince(dayStart) - crossing.t * 86_400) < 1e-6)
        }
        let labels = SunArcView.clockLabels(for: cycle.samples, calendar: chicago,
                                            locale: Locale(identifier: "en_GB"))
        #expect(labels.count == 2)
        #expect(labels[0].t == rise.t && labels[1].t == set.t)
        // The label is the crossing's own minute of the day.
        #expect(minutes(labels[0].text) == Int((rise.t * 1440).rounded()))
        #expect(minutes(labels[1].text) == Int((set.t * 1440).rounded()))
    }

    @Test func polarDayAndPolarNightHaveNoCrossingsAndNoLabels() {
        let oslo = calendar("Europe/Oslo")
        for (month, isUp) in [(6, true), (12, false)] {
            let now = date(2026, month, 21, in: oslo)
            let cycle = SunCycle(now: now, latitude: 78.22, longitude: 15.65, calendar: oslo)
            #expect(cycle.samples.allSatisfy { ($0.elevation > 0) == isUp })
            #expect(SunArcView.horizonCrossings(in: cycle.samples).isEmpty)
            let (sunrise, sunset) = SunArcView.sunriseAndSunset(in: cycle.samples)
            #expect(sunrise == nil && sunset == nil)
            #expect(SunArcView.clockLabels(for: cycle.samples, calendar: oslo,
                                           locale: Locale(identifier: "en_GB")).isEmpty)
        }
    }

    @Test func crossingIsInterpolatedBetweenTheSamplesAroundIt() throws {
        let day = samples([-9, -1, 3, 6, 2, -2, -8])
        let crossings = SunArcView.horizonCrossings(in: day)
        #expect(crossings.count == 2)
        // -1 → 3 crosses a quarter of the way along; 2 → -2 halfway.
        #expect(abs(crossings[0].t - (1.25 / 6)) < 1e-12)
        #expect(crossings[0].rising)
        #expect(crossings[0].date == day[1].date.addingTimeInterval(900))
        #expect(abs(crossings[1].t - (4.5 / 6)) < 1e-12)
        #expect(!crossings[1].rising)
        #expect(crossings[1].date == day[4].date.addingTimeInterval(1_800))
    }

    @Test func crossingExactlyOnASampleIsThatSample() {
        let day = samples([-6, -3, 0, 3, 6, 0, -4])
        let crossings = SunArcView.horizonCrossings(in: day)
        #expect(crossings.count == 2)
        #expect(crossings[0] == SunArcView.HorizonCrossing(t: day[2].t, date: day[2].date, rising: true))
        #expect(crossings[1] == SunArcView.HorizonCrossing(t: day[5].t, date: day[5].date, rising: false))
    }

    @Test func touchingTheHorizonWithoutCrossingIsNotACrossing() {
        #expect(SunArcView.horizonCrossings(in: samples([4, 1, 0, 1, 4])).isEmpty)
        #expect(SunArcView.horizonCrossings(in: samples([-4, 0, 0, -1])).isEmpty)
        // A day that starts or ends on the horizon has nothing on the other side to cross from.
        #expect(SunArcView.horizonCrossings(in: samples([0, 2, 5, 2, 0])).isEmpty)
        #expect(SunArcView.horizonCrossings(in: samples([])).isEmpty)
        #expect(SunArcView.horizonCrossings(in: samples([3])).isEmpty)
        #expect(SunArcView.horizonCrossings(in: samples([.nan, 3, .nan, 4])).isEmpty)
    }

    @Test func briefDipAroundMidnightLabelsTheSunsetBeforeTheSunrise() {
        // Just past midnight sun: the sun sets and rises again early in the same local day.
        let day = samples([2, -1, 1, 6, 12, 9, 5, 3])
        let (sunrise, sunset) = SunArcView.sunriseAndSunset(in: day)
        #expect(sunset.map { $0.t < 1.0 / 7 } == true)
        #expect(sunrise.map { $0.t > 1.0 / 7 } == true)
        let labels = SunArcView.clockLabels(for: day, calendar: calendar("GMT"),
                                            locale: Locale(identifier: "en_GB"))
        #expect(labels.map(\.t) == [sunset!.t, sunrise!.t])
        #expect(labels.map { minutes($0.text) } == [40, 90])
    }

    @Test func clockTextUsesTheCalendarTheCycleWasBuiltWith() {
        let chicago = calendar("America/Chicago"), tokyo = calendar("Asia/Tokyo")
        let british = Locale(identifier: "en_GB")
        let dayStart = chicago.startOfDay(for: date(2026, 11, 23, in: chicago))
        // 06:13:40 rounds to the minute, not down.
        let instant = dayStart.addingTimeInterval(6 * 3_600 + 13 * 60 + 40)
        #expect(minutes(SunArcView.clockText(for: instant, dayStart: dayStart, calendar: chicago,
                                             locale: british)) == 6 * 60 + 14)
        // A cycle cut in another zone still shows its own wall clock.
        #expect(minutes(SunArcView.clockText(for: instant, dayStart: dayStart, calendar: tokyo,
                                             locale: british)) == 6 * 60 + 14)
        let american = SunArcView.clockText(for: instant, dayStart: dayStart, calendar: chicago,
                                            locale: Locale(identifier: "en_US"))
        #expect(american.hasPrefix("6:14") && american.hasSuffix("AM"))
    }

    @Test func clockTextFollowsTheWallClockAcrossAClockChange() {
        let chicago = calendar("America/Chicago")
        // Clocks go forward at 02:00 on 8 March 2026: 5 h after midnight is 06:00.
        let dayStart = chicago.startOfDay(for: date(2026, 3, 8, in: chicago))
        let instant = dayStart.addingTimeInterval(5 * 3_600)
        #expect(minutes(SunArcView.clockText(for: instant, dayStart: dayStart, calendar: chicago,
                                             locale: Locale(identifier: "en_GB"))) == 6 * 60)
    }

    @Test func bedtimeFallsAtItsWallClockTimeOnTheSampledDay() throws {
        let chicago = calendar("America/Chicago")
        let bedtime = try #require(Bedtime(hour: 22, minute: 30))
        let ordinary = SunCycle(now: date(2026, 11, 23, in: chicago), latitude: 41.88, longitude: -87.63,
                                calendar: chicago)
        let t = try #require(SunArcView.dayFraction(of: bedtime, in: ordinary.samples, calendar: chicago))
        #expect(abs(t - 22.5 / 24) < 1e-12)

        // A 23-hour day: 22:30 is 21.5 elapsed hours after midnight.
        let spring = SunCycle(now: date(2026, 3, 8, in: chicago), latitude: 41.88, longitude: -87.63,
                              calendar: chicago)
        let short = try #require(SunArcView.dayFraction(of: bedtime, in: spring.samples, calendar: chicago))
        #expect(abs(short - 21.5 / 23) < 1e-12)

        // A calendar the cycle was not built with: plain minutes of the day.
        let other = try #require(SunArcView.dayFraction(of: bedtime, in: spring.samples,
                                                        calendar: calendar("Asia/Kolkata")))
        #expect(abs(other - 22.5 / 24) < 1e-12)
        #expect(SunArcView.dayFraction(of: bedtime, in: [], calendar: chicago) == nil)

        let mark = try #require(SunArcView.mark(for: bedtime, in: ordinary.samples, calendar: chicago))
        #expect(mark.t == t)
        // Late evening in November: well below the horizon, and on the sampled curve.
        #expect(mark.elevation < -18)
        let exact = SolarCalculator.elevation(
            at: ordinary.samples[0].date.addingTimeInterval(22.5 * 3_600), latitude: 41.88, longitude: -87.63)
        #expect(abs(mark.elevation - exact) < 0.1)
    }

    @Test func elevationIsReadOffTheCurveBetweenSamples() {
        let day = samples([-10, 0, 20, 0, -10])
        #expect(SunArcView.elevation(at: 0, in: day) == -10)
        #expect(SunArcView.elevation(at: 0.25, in: day) == 0)
        #expect(SunArcView.elevation(at: 0.375, in: day) == 10)
        #expect(SunArcView.elevation(at: 1, in: day) == -10)
        #expect(SunArcView.elevation(at: -1, in: day) == -10)
        #expect(SunArcView.elevation(at: 2, in: day) == -10)
        #expect(SunArcView.elevation(at: 0.5, in: []) == nil)
    }

    @Test func moonFloatsAboveTheHorizonOrTheCurveWhicheverIsHigher() {
        // Sun down at bedtime: above the horizon, as in the design.
        #expect(SunArcView.moonTop(horizonY: 44, curveY: 70) == 29)
        // Sun still up: above the point on the curve, clear of the hairline.
        #expect(SunArcView.moonTop(horizonY: 44, curveY: 30) == 15)
        // No room above: under the horizon instead of off the top of the chart.
        #expect(SunArcView.moonTop(horizonY: 44, curveY: 10) == 48)
    }

    @Test func accessibilityTextCarriesEveryTimeDrawnOnTheChart() {
        let all = SunArcView.accessibilityDescription(
            currentElevation: 3.4, sunrise: "6:55 AM", sunset: "4:19 PM", bedtime: "10:30 PM")
        #expect(all == "Solar elevation +3°. Sunrise 6:55 AM. Sunset 4:19 PM. Bedtime 10:30 PM.")
        // It starts with the summary that stood alone before.
        #expect(all.hasPrefix(SunArcView.accessibilitySummary(currentElevation: 3.4)))
        // Polar day or night, and an arc without a bedtime mark: only what is drawn.
        #expect(SunArcView.accessibilityDescription(
            currentElevation: -12, sunrise: nil, sunset: nil, bedtime: nil) == "Solar elevation −12°.")
        #expect(SunArcView.accessibilityDescription(
            currentElevation: 0, sunrise: nil, sunset: "11:58 PM", bedtime: nil)
            == "Solar elevation 0°. Sunset 11:58 PM.")
    }

    @Test func accessibilityTimesAreTheOnesTheLabelsShow() throws {
        let chicago = calendar("America/Chicago")
        let british = Locale(identifier: "en_GB")
        let cycle = SunCycle(now: date(2026, 3, 20, in: chicago), latitude: 41.88, longitude: -87.63,
                             calendar: chicago)
        let labels = SunArcView.clockLabels(for: cycle.samples, calendar: chicago, locale: british)
        let times = SunArcView.sunTimes(for: cycle.samples, calendar: chicago, locale: british)
        #expect(times.sunrise == labels[0].text)
        #expect(times.sunset == labels[1].text)

        // A sunset before the sunrise on the chart is still named a sunset.
        let dip = samples([2, -1, 1, 6, 12, 9, 5, 3])
        let dipTimes = SunArcView.sunTimes(for: dip, calendar: calendar("GMT"), locale: british)
        #expect(dipTimes.sunset.flatMap(minutes) == 40)
        #expect(dipTimes.sunrise.flatMap(minutes) == 90)

        let oslo = calendar("Europe/Oslo")
        let polar = SunCycle(now: date(2026, 6, 21, in: oslo), latitude: 78.22, longitude: 15.65, calendar: oslo)
        let none = SunArcView.sunTimes(for: polar.samples, calendar: oslo, locale: british)
        #expect(none.sunrise == nil && none.sunset == nil)
        let empty = SunArcView.sunTimes(for: [], calendar: oslo, locale: british)
        #expect(empty.sunrise == nil && empty.sunset == nil)
    }

    @Test func bedtimeIsSpokenAsALocalizedWallClockTime() throws {
        let bedtime = try #require(Bedtime(hour: 22, minute: 30))
        #expect(minutes(SunArcView.bedtimeText(bedtime, locale: Locale(identifier: "en_GB"))) == 22 * 60 + 30)
        let american = SunArcView.bedtimeText(bedtime, locale: Locale(identifier: "en_US"))
        #expect(american.hasPrefix("10:30") && american.hasSuffix("PM"))
        let midnight = try #require(Bedtime(hour: 0, minute: 5))
        #expect(minutes(SunArcView.bedtimeText(midnight, locale: Locale(identifier: "en_GB"))) == 5)
    }
}

/// The two contrast measures every colour drawn on a fill is chosen by.
@Suite struct EmberContrastTests {
    private let red = EmberRGB(204, 44, 26)

    @Test func lateCurveIsTheOneTheAppLoadsForItsLatePreset() throws {
        let late = try #require(Preset.defaults.last)
        #expect(late.name == "Late" && late.intensity == 0)
        #expect(late.whitepoint == EmberContrast.lateWhitepoint)
        let identity = GammaTableComposer.resample(original: nil, tableSize: 256, invert: false)
        var table = GammaTableComposer.makeTable(size: 256)
        GammaTableComposer.render(identity, intensity: Float(late.intensity),
                                  whitepoint: Float(late.whitepoint), into: &table)
        for level in 0..<256 {
            #expect(abs(Double(table.r[level]) - EmberContrast.lateOutput(Double(level) / 255)) < 1e-5)
        }
        // Nothing but red reaches the screen, which is why only the red channel is scored.
        #expect(table.g.allSatisfy { $0 == 0 } && table.b.allSatisfy { $0 == 0 })
    }

    @Test func lateCurveSqueezesTheBrightHalfIntoASliver() {
        #expect(EmberContrast.lateOutput(0) == 0)
        #expect(abs(EmberContrast.lateOutput(1) - 0.3) < 1e-12)
        // More than half of the output range is used up by the darkest quarter of the input.
        #expect(EmberContrast.lateOutput(0.25) > 0.15)
        var previous = -1.0
        for level in 0...255 {
            let output = EmberContrast.lateOutput(Double(level) / 255)
            #expect(output > previous)
            previous = output
        }
        #expect(EmberContrast.lateOutput(-1) == 0)
        #expect(abs(EmberContrast.lateOutput(2) - 0.3) < 1e-12)
    }

    @Test func ordinaryContrastIsTheWCAGRatio() {
        #expect(abs(EmberContrast.wcag(.black, .white) - 21) < 1e-9)
        #expect(EmberContrast.wcag(red, red) == 1)
        #expect(EmberContrast.wcag(.white, .black) == EmberContrast.wcag(.black, .white))
        // #767676 on white is the textbook 4.54:1.
        #expect(abs(EmberContrast.wcag(EmberRGB(118, 118, 118), .white) - 4.54) < 0.01)
    }

    @Test func lateContrastSeesOnlyTheRedChannelRelativeToLateWhite() {
        // The brightest and darkest things Late can show are as far apart as black and white.
        #expect(abs(EmberContrast.late(.black, .white) - 21) < 1e-9)
        // Green and blue are gone: cyan is black, and yellow is white.
        #expect(abs(EmberContrast.late(EmberRGB(0, 255, 255), .black) - 1) < 1e-9)
        #expect(abs(EmberContrast.late(EmberRGB(255, 255, 0), .white) - 1) < 1e-9)
        // A pale mark on a bright red fill passes WCAG and vanishes under Late.
        #expect(EmberContrast.wcag(.white, red) > 4.5)
        #expect(EmberContrast.late(.white, red) < 1.5)
        // A dark mark on a dark fill does the opposite.
        let panel = EmberPalette.dark.background
        let dim = EmberRGB(0, 0, 0).mixed(0.5, over: panel)
        #expect(EmberContrast.late(dim, panel) > EmberContrast.wcag(dim, panel))
        #expect(EmberContrast.wcag(.black, panel) < 1.3)
    }

    @Test func scoreIsTheWorseOfTheTwo() {
        for (a, b) in [(EmberRGB.white, red), (.black, red), (.black, EmberPalette.dark.background),
                       (EmberRGB(35, 31, 28), EmberPalette.light.background)] {
            #expect(EmberContrast.score(a, b) == min(EmberContrast.wcag(a, b), EmberContrast.late(a, b)))
        }
        // White has the better WCAG ratio on the red end of the accent; black is the one that
        // also survives Late, so black is the best mark there.
        #expect(EmberContrast.wcag(.white, red) > EmberContrast.wcag(.black, red))
        #expect(EmberContrast.best(of: [.white, .black], on: red) == .black)
        #expect(EmberContrast.best(of: [.black, .white], on: EmberPalette.dark.background) == .white)
        #expect(EmberContrast.best(of: [.black, .white], on: EmberPalette.light.background) == .black)
        // The first of equals, and something even with nothing to choose from.
        #expect(EmberContrast.best(of: [red, red], on: .white) == red)
        #expect(EmberContrast.best(of: [], on: .white) == .black)
    }

    @Test func markTakesTheLeastStrengthThatReachesItsTarget() {
        let pale = EmberRGB(255, 226, 180)
        let mark = EmberContrast.mark(on: pale, minimumAlpha: 0.2, target: 3)
        #expect(mark.ink == .black)
        #expect(mark.alpha > 0.2 && mark.alpha < 1)
        #expect(EmberContrast.score(mark.over(pale), pale) >= 3)
        // A little less of it would not do.
        #expect(EmberContrast.score(EmberRGB.black.mixed(mark.alpha - 0.01, over: pale), pale) < 3)

        // Already enough at the least strength: that strength, untouched.
        #expect(EmberContrast.mark(on: pale, minimumAlpha: 0.95, target: 3).alpha == 0.95)
        // Out of reach: the solid ink, which is the best there is.
        let unreachable = EmberContrast.mark(on: red, minimumAlpha: 0.2, target: 7)
        #expect(unreachable == EmberContrast.Mark(ink: .black, alpha: 1))
        #expect(unreachable.over(red) == .black)
    }

    @Test func liftMovesAFillNoFurtherThanItsLabelNeeds() {
        let pale = EmberTint.palest
        func enough(_ fill: EmberRGB) -> Bool { EmberContrast.score(.black, fill) >= 4.5 }
        #expect(!enough(red))
        let lifted = EmberContrast.lifted(red, toward: pale, until: enough)
        #expect(enough(lifted))
        #expect(EmberContrast.score(.black, lifted) < 4.52)
        // Still a red: most of the way from the pale end.
        #expect(lifted.r - lifted.g > 120)
        // Enough already: unchanged. Never enough: the anchor.
        #expect(EmberContrast.lifted(pale, toward: .white, until: enough) == pale)
        #expect(EmberContrast.lifted(red, toward: pale) { _ in false } == pale)
    }
}

/// Every pair of colours that carries state, at every colour temp, both ways it is seen.
@Suite struct EmberPaletteContrastTests {
    private typealias Case = (name: String, scheme: ColorScheme, palette: EmberPalette)

    private let standard: [Case] = [
        ("dark", .dark, .dark), ("light", .light, .light),
    ]
    private let increased: [Case] = [
        ("dark increased", .dark, .darkIncreased), ("light increased", .light, .lightIncreased),
    ]
    private var all: [Case] { standard + increased }
    private let intensities = stride(from: 0.0, through: 1.0, by: 0.01).map { $0 }

    private func wcag(_ a: EmberRGB, _ b: EmberRGB) -> Double { EmberContrast.wcag(a, b) }
    private func late(_ a: EmberRGB, _ b: EmberRGB) -> Double { EmberContrast.late(a, b) }
    private func score(_ a: EmberRGB, _ b: EmberRGB) -> Double { EmberContrast.score(a, b) }

    @Test func paletteFollowsSchemeAndContrast() {
        #expect(EmberPalette.for(.dark) == .dark)
        #expect(EmberPalette.for(.light) == .light)
        #expect(EmberPalette.for(.dark, contrast: .standard) == EmberPalette.for(.dark))
        #expect(EmberPalette.for(.light, contrast: .standard) == EmberPalette.for(.light))
        #expect(EmberPalette.for(.dark, contrast: .increased) == .darkIncreased)
        #expect(EmberPalette.for(.light, contrast: .increased) == .lightIncreased)
        #expect(EmberPalette.darkIncreased.isDark && EmberPalette.darkIncreased.isIncreasedContrast)
        #expect(!EmberPalette.lightIncreased.isDark && EmberPalette.lightIncreased.isIncreasedContrast)
        #expect(!EmberPalette.dark.isIncreasedContrast && !EmberPalette.light.isIncreasedContrast)
        // The panel itself does not change, so the popover's window colour stays right.
        #expect(EmberPalette.darkIncreased.background == EmberPalette.dark.background)
        #expect(EmberPalette.lightIncreased.background == EmberPalette.light.background)
    }

    @Test func textHasThreeLevelsAndTheQuietestIsStillBodyTextContrast() {
        for (name, _, palette) in all {
            let panel = palette.background, card = palette.card
            for surface in [panel, card] {
                let text = wcag(palette.textRGB, surface)
                let secondary = wcag(palette.textRGB.mixed(palette.secondaryAlpha, over: surface), surface)
                let tertiary = wcag(palette.textRGB.mixed(palette.tertiaryAlpha, over: surface), surface)
                #expect(tertiary >= 4.5, "\(name) tertiary \(tertiary)")
                // Each level is a clear step from the next.
                #expect(secondary >= tertiary * 1.15, "\(name) secondary \(secondary) tertiary \(tertiary)")
                #expect(text >= secondary * 1.2, "\(name) text \(text) secondary \(secondary)")
                if palette.isIncreasedContrast {
                    #expect(tertiary >= 7, "\(name) tertiary \(tertiary)")
                }
            }
        }
    }

    @Test func increasedContrastStrengthensTextFillsAndMarks() {
        let fill = EmberTint.rgb(intensity: 0.7, scheme: .dark)
        for (plain, strong) in [(EmberPalette.dark, EmberPalette.darkIncreased),
                                (EmberPalette.light, EmberPalette.lightIncreased)] {
            #expect(strong.secondaryAlpha > plain.secondaryAlpha)
            #expect(strong.tertiaryAlpha > plain.tertiaryAlpha)
            #expect(strong.fillStrongAlpha > plain.fillStrongAlpha)
            #expect(strong.focusBand > plain.focusBand)
            #expect(wcag(strong.strong(onCard: true), strong.card) > wcag(plain.strong(onCard: true), plain.card))
            for kind in [EmberPalette.MarkKind.grabber, .notch, .check] {
                #expect(strong.markSpec(kind, on: fill).alpha >= plain.markSpec(kind, on: fill).alpha)
            }
            #expect(strong.markSpec(.grabber, on: fill).alpha > plain.markSpec(.grabber, on: fill).alpha)
        }
    }

    @Test func focusBandShowsOnPanelAndCardBothWays() {
        for (name, _, palette) in all {
            let band = palette.focusRingRGB
            for surface in [palette.background, palette.card] {
                #expect(wcag(band, surface) >= 3, "\(name)")
                #expect(late(band, surface) >= 3, "\(name) late \(late(band, surface))")
            }
            #expect(palette.focusBand >= 2)
        }
    }

    @Test func actionLabelIsBodyTextContrastAtEveryColourTemp() {
        for (name, scheme, palette) in all {
            for intensity in intensities {
                let accent = EmberTint.rgb(intensity: intensity, scheme: scheme)
                let action = palette.actionRGB(accent: accent)
                #expect(wcag(action.foreground, action.background) >= 4.5, "\(name) at \(intensity)")
                #expect(late(action.foreground, action.background) >= 4.5, "\(name) at \(intensity)")
            }
        }
        // Dark keeps the accent itself wherever the accent already carries its label, and
        // stays a red where it does not.
        for intensity in [0.3, 0.5, 0.7, 1.0] {
            let accent = EmberTint.rgb(intensity: intensity, scheme: .dark)
            #expect(EmberPalette.dark.actionRGB(accent: accent).background == accent)
        }
        let deepest = EmberPalette.dark.actionRGB(accent: EmberTint.rgb(intensity: 0, scheme: .dark)).background
        #expect(deepest.r > 200 && deepest.g < 80 && deepest.b < 60)
    }

    @Test func grabberReadsOnEveryFillAtEveryColourTemp() {
        for (name, scheme, palette) in all {
            for intensity in intensities {
                let accent = EmberTint.rgb(intensity: intensity, scheme: scheme)
                for tone in [EmberTone.accent, .soft] {
                    let fill = palette.sliderFillRGB(tone, accent: accent)
                    let rest = palette.markSpec(.grabber, on: fill).over(fill)
                    let strong = palette.markSpec(.solid, on: fill).over(fill)
                    #expect(wcag(rest, fill) >= 3, "\(name) \(tone) at \(intensity): \(wcag(rest, fill))")
                    #expect(late(rest, fill) >= 3, "\(name) \(tone) at \(intensity): \(late(rest, fill))")
                    // Pressed or focused it is never weaker than at rest.
                    #expect(score(strong, fill) >= score(rest, fill) - 1e-9)
                }
            }
        }
    }

    @Test func softFillStandsApartFromItsBandAtTheRedEndAndIsUnchangedAbove() {
        let palette = EmberPalette.dark
        for intensity in intensities {
            let accent = EmberTint.rgb(intensity: intensity, scheme: .dark)
            let soft = palette.sliderFillRGB(.soft, accent: accent)
            let plain = accent.mixed(palette.softFraction, over: palette.background)
            // It was 1.01:1 at the red end, a difference of hue alone.
            #expect(wcag(soft, palette.sliderBand) >= 1.45, "at \(intensity): \(wcag(soft, palette.sliderBand))")
            #expect(late(soft, palette.sliderBand) >= 1.6)
            if intensity >= 0.6 { #expect(soft == plain) }
            // Never brighter than the accent it is a tone of.
            #expect(EmberContrast.luminance(soft) <= EmberContrast.luminance(accent) + 1e-9)
            #expect(EmberContrast.luminance(soft) >= EmberContrast.luminance(plain) - 1e-9)
        }
        // Light never needed the lift.
        for intensity in intensities {
            let accent = EmberTint.rgb(intensity: intensity, scheme: .light)
            #expect(EmberPalette.light.sliderFillRGB(.soft, accent: accent)
                == accent.mixed(EmberPalette.light.softFraction, over: EmberPalette.light.background))
        }
    }

    @Test func checkReadsOnEveryPresetSwatch() {
        for (name, scheme, palette) in all {
            for preset in Preset.defaults {
                let swatch = EmberTint.rgb(intensity: preset.intensity, scheme: scheme)
                let check = palette.markSpec(.check, on: swatch).over(swatch)
                #expect(wcag(check, swatch) >= 3, "\(name) \(preset.name): \(wcag(check, swatch))")
                #expect(late(check, swatch) >= 3, "\(name) \(preset.name): \(late(check, swatch))")
            }
            for intensity in intensities {
                let swatch = EmberTint.rgb(intensity: intensity, scheme: scheme)
                #expect(score(palette.markSpec(.check, on: swatch).over(swatch), swatch) >= 3)
                // The token for a swatch of unknown colour is the ink every swatch takes.
                #expect(palette.markSpec(.check, on: swatch).ink == .black)
            }
        }
    }

    @Test func switchReadsAsASwitchOnAndOff() {
        for (name, scheme, palette) in all {
            // Off: the knob stands out from its track however faint the track is on the card.
            let offTrack = EmberSwitchFace.track(isOn: false, accent: .black, palette: palette)
            let offSpec = EmberSwitchFace.knob(isOn: false, accent: .black, palette: palette)
            let offKnob = offSpec.over(offTrack)
            #expect(wcag(offKnob, offTrack) >= 3, "\(name) off \(wcag(offKnob, offTrack))")
            if palette.isDark {
                // Under Late nothing reaches 3:1 on the off track; white is the best there is,
                // and it does reach 3:1 against the card around the track.
                #expect(offSpec == EmberContrast.Mark(ink: .white, alpha: 1))
                #expect(late(.white, palette.card) >= 3)
            } else {
                #expect(late(offKnob, offTrack) >= 3, "\(name) off late \(late(offKnob, offTrack))")
            }
            for intensity in intensities {
                let accent = EmberTint.rgb(intensity: intensity, scheme: scheme)
                let track = EmberSwitchFace.track(isOn: true, accent: accent, palette: palette)
                let knob = EmberSwitchFace.knob(isOn: true, accent: accent, palette: palette).over(track)
                #expect(track == accent)
                #expect(score(knob, track) >= 3, "\(name) on at \(intensity): \(score(knob, track))")
            }
        }
    }

    @Test func lightAccentIsDeepButNeverTooDeepForABlackMark() {
        for intensity in intensities {
            let accent = EmberTint.rgb(intensity: intensity, scheme: .light)
            #expect(wcag(.black, accent) >= 3)
            // Still darker than the panel and the card it sits on.
            #expect(wcag(accent, EmberPalette.light.card) >= 1.8)
        }
    }
}

/// Small rules of the controls that need no view to check.
@MainActor @Suite struct EmberControlRuleTests {
    @Test func sliderHandleShowsFocusOnlyWhenAKeyPressBroughtIt() {
        // The popover opening or a click hands a handle focus: nothing is drawn.
        #expect(!SliderFocus.drawsFocus(handleIsFocused: true, isDragging: false, event: nil))
        #expect(!SliderFocus.drawsFocus(handleIsFocused: true, isDragging: false, event: .leftMouseDown))
        #expect(!SliderFocus.drawsFocus(handleIsFocused: true, isDragging: false, event: .leftMouseUp))
        #expect(!SliderFocus.drawsFocus(handleIsFocused: true, isDragging: false, event: .appKitDefined))
        // Tab or Shift-Tab: drawn.
        #expect(SliderFocus.drawsFocus(handleIsFocused: true, isDragging: false, event: .keyDown))
        // Never during a drag, and never without focus.
        #expect(!SliderFocus.drawsFocus(handleIsFocused: true, isDragging: true, event: .keyDown))
        #expect(!SliderFocus.drawsFocus(handleIsFocused: false, isDragging: false, event: .keyDown))
    }

    @Test func backButtonIsNamedByItsVisibleWord() {
        #expect(EmberPageHeader.backTitle == "Back")
        #expect(EmberPageHeader(title: "Settings") {}.backLabel == "Back")
    }
}

// MARK: - Control sheet

/// A sheet of the controls in the states the popover snapshots cannot reach: keyboard focus,
/// Increase Contrast, a value resting on Auto's lower limit. Nothing here runs in a plain `swift test`:
///
///   REDLIGHT_EMBER_SHEET_DIR=/some/dir swift test --filter EmberControlSheet
///       writes sheet-<light|dark>[-increased]-<colour temp>.png and the same with -late
///
/// Hosted like the popover snapshots: a view in a window that is never ordered in.
@MainActor @Suite(.serialized) struct EmberControlSheetTests {
    nonisolated private static var directory: URL? {
        guard let path = ProcessInfo.processInfo.environment["REDLIGHT_EMBER_SHEET_DIR"], !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private struct Sheet: View {
        let intensity: Double
        @State private var isOn = true
        @State private var isOff = false
        @State private var value = 0.8
        @State private var lower = 0.2
        @State private var upper = 0.8
        @State private var pin = 0.6
        @State private var text = "41.88"
        @Environment(\.emberPalette) private var palette
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            EmberAccentScope(intensity: { intensity }) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(verbatim: "contrast \(palette.isIncreasedContrast ? "increased" : "standard")")
                        .font(.ember(11)).foregroundStyle(palette.tertiary)
                    HStack(spacing: 14) {
                        Text("Text").foregroundStyle(palette.text)
                        Text("Secondary").foregroundStyle(palette.secondary)
                        Text("Tertiary").foregroundStyle(palette.tertiary)
                    }
                    .font(.ember(12))
                    HStack(spacing: 16) {
                        EmberSwitch("On", isOn: $isOn)
                        EmberSwitch("Off", isOn: $isOff)
                        EmberSwitch("On", isOn: $isOn).emberFocusHalo(Capsule(), isFocused: true)
                        EmberSwitch("Off", isOn: $isOff).emberFocusHalo(Capsule(), isFocused: true)
                    }
                    EmberCard {
                        EmberRow {
                            Text("On a card").font(.ember(13))
                            Spacer(minLength: 0)
                            EmberChipLabel(title: "Invert", isFocused: true)
                            EmberChipLabel(title: "Invert", isProminent: true, isFocused: true)
                            EmberSwitch("Off", isOn: $isOff).emberFocusHalo(Capsule(), isFocused: true)
                        }
                        EmberRowButton(divider: true, action: {}) {
                            Text("Location").foregroundStyle(palette.text)
                            Spacer(minLength: 0)
                            Text("Automatic").foregroundStyle(palette.secondary)
                        }
                        .font(.ember(13))
                        .overlay {
                            Color.clear
                                .emberFocusHalo(RoundedRectangle(cornerRadius: 8, style: .continuous),
                                                isFocused: true, spread: 0)
                                .padding(.horizontal, -8).padding(.vertical, 3)
                        }
                        EmberRow(divider: true) {
                            EmberTextField(placeholder: "Latitude", text: $text)
                            EmberTextField(placeholder: "Longitude", text: $text)
                                .emberFocusHalo(RoundedRectangle(cornerRadius: 7, style: .continuous),
                                                isFocused: true, spread: 0)
                        }
                    }
                    EmberSegmented(label: "Mode", options: [(value: true, title: "Auto"), (value: false, title: "Manual")],
                                   selection: true) { _ in }
                        .overlay(alignment: .trailing) {
                            Color.clear.frame(width: 132, height: 26).padding(.trailing, 2)
                                .emberFocusHalo(RoundedRectangle(cornerRadius: 8, style: .continuous),
                                                isFocused: true, spread: 0)
                        }
                    HStack(spacing: 14) {
                        EmberPillButton(title: "Pause", systemImage: "pause.fill") {}
                            .emberFocusHalo(Capsule(), isFocused: true)
                        EmberPillButton(title: "Resume", systemImage: "play.fill", isProminent: true) {}
                            .emberFocusHalo(Capsule(), isFocused: true)
                        EmberIconButton(systemImage: "moon.fill") {}
                            .emberFocusHalo(Circle(), isFocused: true)
                        EmberLinkButton("Cancel") {}
                            .emberFocusHalo(RoundedRectangle(cornerRadius: 6, style: .continuous),
                                            isFocused: true, spread: 6)
                    }
                    // The split pause pill with each half focused in turn, as `PauseControl`
                    // draws it, and the apps list with its first line focused.
                    HStack(spacing: 14) {
                        ForEach([true, false], id: \.self) { leadingIsFocused in
                            HStack(spacing: 0) {
                                HStack(spacing: 6) {
                                    Image(systemName: "pause.fill").font(.system(size: 9, weight: .bold))
                                    Text("Pause").lineLimit(1).fixedSize()
                                }
                                .font(.ember(12.5, .medium))
                                .foregroundStyle(palette.text)
                                .padding(.leading, 11)
                                .padding(.trailing, 5)
                                .frame(height: EmberMetrics.controlHeight)
                                .emberFocusHalo(PauseControlShape.leading, isFocused: leadingIsFocused, spread: 0)
                                EmberChevron(direction: .down)
                                    .foregroundStyle(palette.tertiary)
                                    .padding(.leading, 6)
                                    .padding(.trailing, 11)
                                    .frame(height: EmberMetrics.controlHeight)
                                    .emberFocusHalo(PauseControlShape.trailing, isFocused: !leadingIsFocused, spread: 0)
                            }
                            .background(Capsule().fill(palette.fill))
                        }
                    }
                    EmberCard {
                        PauseForAppsRow.Column(rows: 2) {
                            PauseForAppsRow.RowFace(name: "Safari", symbol: "minus.circle.fill",
                                                    color: palette.text, isFocused: true)
                            PauseForAppsRow.RowFace(name: "Preview", symbol: "plus.circle",
                                                    color: palette.secondary, isFocused: false)
                        }
                        .padding(.vertical, 6)
                    }
                    HStack(spacing: 6) {
                        ForEach(Preset.defaults.indices, id: \.self) { index in
                            let swatch = EmberTint.rgb(intensity: Preset.defaults[index].intensity, scheme: scheme)
                            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                            shape.fill(swatch.color).frame(height: 38)
                                .overlay {
                                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(palette.check(on: swatch))
                                }
                                .emberFocusHalo(shape, isFocused: index == 2)
                        }
                    }
                    ForEach([EmberTone.accent, .soft], id: \.self) { tone in
                        EmberSlider(value: value, band: lower...upper, tone: tone) { value = $0 }
                        EmberSlider(value: lower, band: lower...upper, tone: tone) { lower = $0 }
                        EmberSlider(value: pin, band: pin...pin, tone: tone) { pin = $0 }
                        EmberCard(verticalPadding: 10) {
                            EmberRangeSlider(lower: $lower, upper: $upper, tone: tone)
                            EmberRangeSlider(lower: $pin, upper: $pin, tone: tone)
                        }
                    }
                }
                .padding(16)
                .frame(width: 300, alignment: .topLeading)
                .background(palette.background.color)
                .environment(\.emberAnimationsEnabled, false)
            }
        }
    }

    /// contrast.txt: every scored pair as "WCAG / Late", from the same functions the views use.
    @Test(.enabled(if: EmberControlSheetTests.directory != nil))
    func writesContrastTable() throws {
        let directory = try #require(Self.directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func pair(_ a: EmberRGB, _ b: EmberRGB) -> String {
            String(format: "%.2f/%.2f", EmberContrast.wcag(a, b), EmberContrast.late(a, b))
        }
        var lines: [String] = []
        let palettes: [(String, ColorScheme, EmberPalette)] = [
            ("dark", .dark, .dark), ("light", .light, .light),
            ("dark-increased", .dark, .darkIncreased), ("light-increased", .light, .lightIncreased),
        ]
        for (name, scheme, palette) in palettes {
            let panel = palette.background, card = palette.card, band = palette.sliderBand
            func level(_ alpha: Double, on surface: EmberRGB) -> String {
                pair(palette.textRGB.mixed(alpha, over: surface), surface)
            }
            lines.append("== \(name)")
            lines.append("text panel \(level(1, on: panel)) card \(level(1, on: card))"
                + " | secondary panel \(level(palette.secondaryAlpha, on: panel)) card \(level(palette.secondaryAlpha, on: card))"
                + " | tertiary panel \(level(palette.tertiaryAlpha, on: panel)) card \(level(palette.tertiaryAlpha, on: card))")
            lines.append("focus band vs panel \(pair(palette.focusRingRGB, panel)) vs card \(pair(palette.focusRingRGB, card))"
                + " vs strong-on-card \(pair(palette.focusRingRGB, palette.strong(onCard: true)))")
            let offTrack = EmberSwitchFace.track(isOn: false, accent: .black, palette: palette)
            let offKnob = EmberSwitchFace.knob(isOn: false, accent: .black, palette: palette)
            lines.append("switch off: track vs card \(pair(offTrack, card)) knob vs track \(pair(offKnob.over(offTrack), offTrack))"
                + " knob vs card \(pair(offKnob.over(offTrack), card)) (knob alpha \(String(format: "%.2f", offKnob.alpha)))")
            let upper = palette.markSpec(.notch, on: band)
            lines.append("upper notch on band \(pair(upper.over(band), band)) alpha \(String(format: "%.2f", upper.alpha))")
            for intensity in [0.0, 0.1, 0.2, 0.34, 0.5, 0.7, 0.85, 1.0] {
                let accent = EmberTint.rgb(intensity: intensity, scheme: scheme)
                let soft = palette.sliderFillRGB(.soft, accent: accent)
                let action = palette.actionRGB(accent: accent)
                func mark(_ kind: EmberPalette.MarkKind, _ fill: EmberRGB) -> String {
                    let spec = palette.markSpec(kind, on: fill)
                    return pair(spec.over(fill), fill) + String(format: " a%.2f", spec.alpha)
                }
                lines.append(String(format: "i=%.2f", intensity)
                    + " action \(pair(action.foreground, action.background))"
                    + " | grab/accent \(mark(.grabber, accent)) grab/soft \(mark(.grabber, soft))"
                    + " | notch/accent \(mark(.notch, accent)) notch/soft \(mark(.notch, soft))"
                    + " | soft vs band \(pair(soft, band)) accent vs band \(pair(accent, band))"
                    + " | check \(mark(.check, accent)) | on knob \(mark(.solid, accent))"
                    + " on track vs card \(pair(accent, card))")
            }
        }
        try lines.joined(separator: "\n").write(
            to: directory.appendingPathComponent("contrast.txt"), atomically: true, encoding: .utf8)
    }

    @Test(.enabled(if: EmberControlSheetTests.directory != nil))
    func writesControlSheets() async throws {
        let directory = try #require(Self.directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let appearances: [(name: String, scheme: ColorScheme, appearance: NSAppearance.Name, increased: Bool)] = [
            ("light", .light, .aqua, false), ("dark", .dark, .darkAqua, false),
            ("light-increased", .light, .accessibilityHighContrastAqua, true),
            ("dark-increased", .dark, .accessibilityHighContrastDarkAqua, true),
        ]
        for (name, scheme, appearanceName, increased) in appearances {
            for intensity in [0.0, 0.7] {
                let appearance = try #require(NSAppearance(named: appearanceName))
                // A hosting view takes its scheme from its appearance but its contrast from the
                // system setting, which a test must not change. The underscored key is the
                // only way to say it here; the app itself only ever reads the public one.
                let host = NSHostingView(rootView: Sheet(intensity: intensity)
                    .environment(\.colorScheme, scheme)
                    .environment(\._colorSchemeContrast, increased ? .increased : .standard)
                    .environment(\.controlActiveState, .key))
                host.appearance = appearance
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 700),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = appearance
                window.contentView = host
                defer { window.close() }
                for _ in 0..<4 {
                    await withCheckedContinuation { continuation in
                        DispatchQueue.main.async { continuation.resume() }
                    }
                    host.layoutSubtreeIfNeeded()
                }
                let size = host.fittingSize
                host.frame = CGRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32))
                bitmap.size = size
                appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
                let panel = EmberPalette.for(scheme).background
                let raster = try Raster(bitmap).composited(
                    over: (UInt8(panel.r), UInt8(panel.g), UInt8(panel.b)))
                #expect(raster.width == 600)
                let stem = "sheet-\(name)-\(Int(intensity * 100))"
                try raster.writePNG(to: directory.appendingPathComponent("\(stem).png"))
                try raster.mapped(LateFilter.lookup).writePNG(to: directory.appendingPathComponent("\(stem)-late.png"))
                print("EMBER-SHEET \(stem) \(raster.width)x\(raster.height) increased=\(increased)")
            }
        }
    }
}
