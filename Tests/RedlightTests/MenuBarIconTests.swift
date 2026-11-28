import AppKit
import Testing
@testable import Redlight

@MainActor @Suite struct MenuBarIconTests {
    @Test(arguments: MenuBarIcon.Level.allCases)
    func everyLevelIsAnEighteenPointTemplate(level: MenuBarIcon.Level) {
        let image = MenuBarIcon.image(for: level)
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
    }

    @Test func levelFollowsTheFilterAndIsOffWheneverNothingShows() {
        // Inactive wins whatever the slider says: off, paused and suspended all look off.
        for intensity in [0.0, 0.25, 0.7, 1.0] {
            #expect(MenuBarIcon.Level(isActive: false, intensity: intensity) == .off)
        }
        // An inversion alone is a level of its own, whatever the slider says: the lines count
        // a tint's depth, and a tint that is off, paused or suspended is not on screen.
        for intensity in [0.0, 0.25, 0.7, 1.0] {
            #expect(MenuBarIcon.Level(isActive: true, showsTint: false, intensity: intensity) == .inverted)
            #expect(MenuBarIcon.Level(isActive: false, showsTint: false, intensity: intensity) == .off)
        }
        #expect(MenuBarIcon.Level.inverted.accessibilityValue == "Active, colors inverted")
        // The default presets land on the level named for them. Day is 100 %: no line.
        let expected: [MenuBarIcon.Level] = [.clear, .low, .mid, .deep, .deep]
        #expect(Preset.defaults.map { MenuBarIcon.Level(isActive: true, intensity: $0.intensity) } == expected)
        // The first line comes with the first whole percent under 100, as the popover
        // writes it: a value shown as 100 % has no line, and one shown as 99 % has one.
        for intensity in [1.0, 0.999, 0.996] {
            #expect(SliderCore.percentText(intensity) == "100%")
            #expect(MenuBarIcon.Level(isActive: true, intensity: intensity) == .clear)
        }
        for intensity in [0.994, 0.99] {
            #expect(SliderCore.percentText(intensity) == "99%")
            #expect(MenuBarIcon.Level(isActive: true, intensity: intensity) == .low)
        }
        #expect(MenuBarIcon.Level.clear.accessibilityValue == "Active, no color filter")
        #expect(MenuBarIcon.Level.off.accessibilityValue == "Inactive")
        // The second and third lines come a third and two thirds of the way down, at the
        // whole percent the popover writes: 67 % is one line and 66 % two, 34 % is two and
        // 33 % three.
        for (intensity, shown, level) in [
            (0.67, "67%", MenuBarIcon.Level.low), (0.666, "67%", .low), (0.664, "66%", .mid), (0.66, "66%", .mid),
            (0.34, "34%", .mid), (0.336, "34%", .mid), (0.334, "33%", .deep), (0.33, "33%", .deep), (0, "0%", .deep),
        ] {
            #expect(SliderCore.percentText(intensity) == shown)
            #expect(MenuBarIcon.Level(isActive: true, intensity: intensity) == level, "\(intensity)")
        }
        // Out-of-range and non-finite values never trap and never read as off.
        #expect(MenuBarIcon.Level(isActive: true, intensity: -1) == .deep)
        #expect(MenuBarIcon.Level(isActive: true, intensity: 2) == .clear)
        #expect(MenuBarIcon.Level(isActive: true, intensity: .nan) == .clear)
    }

    @Test func eachDeeperLevelAddsOneSlitAboveTheLast() {
        #expect(MenuBarIcon.slits(for: .off).isEmpty)
        // A color temp of 100 % and an inversion with no tint: the whole sun, no line.
        #expect(MenuBarIcon.slits(for: .clear).isEmpty)
        #expect(MenuBarIcon.slits(for: .inverted).isEmpty)
        #expect(MenuBarIcon.slits(for: .low).map(\.minY) == [4])
        #expect(MenuBarIcon.slits(for: .mid).map(\.minY) == [4, 7])
        #expect(MenuBarIcon.slits(for: .deep).map(\.minY) == [4, 7, 10])
        for slit in MenuBarIcon.slits(for: .deep) {
            // Whole-point bottoms and 1.5 pt height: three clean pixel rows at 2x.
            #expect(slit.minY == slit.minY.rounded())
            #expect(slit.height == 1.5)
            #expect(slit.minX == 0 && slit.width == MenuBarIcon.size.width)
        }
    }

    @Test(arguments: [1, 2])
    func offFullColorTempAndAnInversionAloneAreTheSameWholeSun(scale: Int) throws {
        let levels: [MenuBarIcon.Level] = [.off, .clear, .inverted]
        let bitmaps = try levels.map { try rasterize(MenuBarIcon.image(for: $0), scale: scale) }
        let off = bitmaps[0]
        // Solid at the centre and a point inside the edge at the four compass points.
        let near = 3 * scale, far = 18 * scale - 1 - near
        for (x, y) in [(9 * scale, 9 * scale), (9 * scale, near), (9 * scale, far), (near, 9 * scale), (far, 9 * scale)] {
            #expect(try alpha(in: off, x: x, logicalY: y) > 0.99)
        }
        for bitmap in bitmaps.dropFirst() {
            for y in 0..<off.pixelsHigh {
                for x in 0..<off.pixelsWide {
                    #expect(try alpha(in: bitmap, x: x, logicalY: y) == alpha(in: off, x: x, logicalY: y))
                }
            }
        }
    }

    @Test(arguments: [1, 2])
    func everyLevelIsASunCutByItsSlitsAndFadedUnderThem(scale: Int) throws {
        for level in MenuBarIcon.Level.allCases {
            let bitmap = try rasterize(MenuBarIcon.image(for: level), scale: scale)
            let slits = MenuBarIcon.slits(for: level)
            let rungs = MenuBarIcon.rungs(for: level)
            let sunTop = MenuBarIcon.center.y + MenuBarIcon.sunRadius(for: level)
            // Down the middle of the disc, away from its rounded edge, one pixel at a time.
            // A pixel wholly inside a slit is clear, one wholly inside a rung under a slit is
            // faded, and one wholly above the last slit is solid up to the top of
            // the sun, which is lower for each line. A pixel that a slit's half-point edge
            // crosses at 1x is left out.
            for pixel in (2 * scale)..<(16 * scale) {
                let low = CGFloat(pixel) / CGFloat(scale), high = CGFloat(pixel + 1) / CGFloat(scale)
                let value = try alpha(in: bitmap, x: 9 * scale, logicalY: pixel)
                if slits.contains(where: { $0.minY <= low && high <= $0.maxY }) {
                    #expect(value < 0.01, "level \(level) pixel row \(pixel) should be a slit")
                } else if rungs.contains(where: { $0.minY <= low && high <= $0.maxY }) {
                    #expect(abs(value - MenuBarIcon.rungAlpha) < 0.02, "level \(level) pixel row \(pixel): \(value)")
                } else if low >= (slits.last?.maxY ?? 0), high <= sunTop - 0.5 {
                    // Half a point clear of the sun's rounded tip.
                    #expect(value > 0.99, "level \(level) pixel row \(pixel) should be solid")
                } else if low >= sunTop {
                    #expect(value < 0.01, "level \(level) pixel row \(pixel) should be above the sun")
                }
            }
        }
    }

    @Test func eachLineMakesTheSunSmallerAndTheSeaWider() throws {
        let lined: [MenuBarIcon.Level] = [.low, .mid, .deep]
        for level in [MenuBarIcon.Level.off, .clear, .inverted] {
            #expect(MenuBarIcon.sunRadius(for: level) == MenuBarIcon.radius)
        }
        #expect(lined.map(MenuBarIcon.sunRadius) == [6.75, 6.25, 5.75])
        #expect(lined.map { MenuBarIcon.sea(for: $0).width } == [16, 17, 18])
        for level in lined {
            // As tall as the whole sun, centred on it, and inside the image.
            let sea = MenuBarIcon.sea(for: level)
            #expect(sea.height == 2 * MenuBarIcon.radius && sea.midX == MenuBarIcon.center.x && sea.midY == MenuBarIcon.center.y)
            #expect(CGRect(origin: .zero, size: MenuBarIcon.size).contains(sea))
        }
        // Measured in the drawing, large enough that the sun's hair is several pixels: the
        // width of the sun on its widest row and of the sea on the row under the last line.
        let scale = 8
        for level in lined {
            let bitmap = try rasterize(MenuBarIcon.image(for: level), scale: scale)
            let slit = try #require(MenuBarIcon.slits(for: level).last)
            let rung = try #require(MenuBarIcon.rungs(for: level).last)
            let sea = MenuBarIcon.sea(for: level)

            let sunRow = Int(max(slit.maxY, MenuBarIcon.center.y) * CGFloat(scale))
            let sunOffset = (CGFloat(sunRow) + 0.5) / CGFloat(scale) - MenuBarIcon.center.y
            let sunRadius = MenuBarIcon.sunRadius(for: level)
            let sunWidth = 2 * (sunRadius * sunRadius - sunOffset * sunOffset).squareRoot()
            let solid = try width(in: bitmap, row: sunRow, above: 0.5)
            #expect(abs(CGFloat(solid) - sunWidth * CGFloat(scale)) <= 2, "level \(level): sun \(solid) px, not \(sunWidth) pt")

            let seaRow = Int(rung.maxY * CGFloat(scale)) - 1
            let seaOffset = ((CGFloat(seaRow) + 0.5) / CGFloat(scale) - sea.midY) / (sea.height / 2)
            let seaWidth = sea.width * (1 - seaOffset * seaOffset).squareRoot()
            let faded = try width(in: bitmap, row: seaRow, above: MenuBarIcon.rungAlpha / 2)
            #expect(abs(CGFloat(faded) - seaWidth * CGFloat(scale)) <= 2, "level \(level): sea \(faded) px, not \(seaWidth) pt")
        }
    }

    /// How many pixels of a row are stronger than a threshold.
    private func width(in bitmap: NSBitmapImageRep, row: Int, above threshold: CGFloat) throws -> Int {
        try (0..<bitmap.pixelsWide).count { try alpha(in: bitmap, x: $0, logicalY: row) > threshold }
    }

    @Test func eachSlitHasOneRungUnderItAndTheSunAboveTheLastIsNotOne() {
        #expect(MenuBarIcon.rungAlpha == 0.4)
        #expect(MenuBarIcon.rungs(for: .off).isEmpty)
        #expect(MenuBarIcon.rungs(for: .clear).isEmpty)
        #expect(MenuBarIcon.rungs(for: .inverted).isEmpty)
        #expect(MenuBarIcon.rungs(for: .low).map { [$0.minY, $0.maxY] } == [[0, 4]])
        #expect(MenuBarIcon.rungs(for: .mid).map { [$0.minY, $0.maxY] } == [[0, 4], [5.5, 7]])
        #expect(MenuBarIcon.rungs(for: .deep).map { [$0.minY, $0.maxY] } == [[0, 4], [5.5, 7], [8.5, 10]])
    }

    @Test(arguments: MenuBarIcon.Level.allCases)
    func awayFromTheCurvedEdgeEveryPixelIsClearSolidOrAFadedRung(level: MenuBarIcon.Level) throws {
        // Three strengths and nothing between them, and the faded one only ever under a slit.
        // Inside the smallest sun, every level's edges are further out.
        let scale = 2
        let bitmap = try rasterize(MenuBarIcon.image(for: level), scale: scale)
        let inner = (MenuBarIcon.sunRadius(for: .deep) - 0.5) * CGFloat(scale)
        let centre = CGFloat(9 * scale) - 0.5
        let lastSlit = MenuBarIcon.slits(for: level).last?.maxY ?? 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where hypot(CGFloat(x) - centre, CGFloat(y) - centre) < inner {
                let value = try alpha(in: bitmap, x: x, logicalY: y)
                let isHalf = abs(value - MenuBarIcon.rungAlpha) < 0.02
                #expect(value < 0.01 || value > 0.99 || isHalf)
                if isHalf { #expect(CGFloat(y) / CGFloat(scale) < lastSlit) }
            }
        }
    }

    @Test(arguments: MenuBarIcon.Level.allCases)
    func theGlyphStaysInsideItsSeaAndLeavesTheCornersClear(level: MenuBarIcon.Level) throws {
        // The sea is the whole disc with no line and an oval a little wider with each one;
        // the sun is never outside it.
        let scale = 2
        let bitmap = try rasterize(MenuBarIcon.image(for: level), scale: scale)
        let sea = MenuBarIcon.sea(for: level)
        let across = (sea.width / 2 + 0.75) * CGFloat(scale), down = (sea.height / 2 + 0.75) * CGFloat(scale)
        let centre = CGFloat(9 * scale) - 0.5
        var checked = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide
            where hypot((CGFloat(x) - centre) / across, (CGFloat(y) - centre) / down) > 1 {
                #expect(try alpha(in: bitmap, x: x, logicalY: y) < 0.01)
                checked += 1
            }
        }
        #expect(checked > 100)
    }

    @Test func everyNumberOfLinesLooksDifferentFromEveryOther() throws {
        // The whole sun and one, two and three lines. Off, 100 % and an inversion alone are
        // all the whole sun.
        let levels: [MenuBarIcon.Level] = [.clear, .low, .mid, .deep]
        let bitmaps = try levels.map { try rasterize(MenuBarIcon.image(for: $0), scale: 1) }
        for first in bitmaps.indices {
            for second in bitmaps.indices where second > first {
                var differing = 0
                for y in 0..<18 {
                    for x in 0..<18 where abs(try alpha(in: bitmaps[first], x: x, logicalY: y)
                                              - alpha(in: bitmaps[second], x: x, logicalY: y)) > 0.5 {
                        differing += 1
                    }
                }
                // A whole slit across the disc is at least ten pixels at 1x.
                #expect(differing >= 10)
            }
        }
    }

    /// Writes every level as a picture, to look at:
    ///   REDLIGHT_ICON_SHEET_DIR=/some/dir swift test --filter MenuBarIcon
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLIGHT_ICON_SHEET_DIR"]?.isEmpty == false))
    func writesEveryLevelAsAPicture() throws {
        let path = try #require(ProcessInfo.processInfo.environment["REDLIGHT_ICON_SHEET_DIR"])
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for level in MenuBarIcon.Level.allCases {
            let bitmap = try rasterize(MenuBarIcon.image(for: level), scale: 8)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("icon-\(level.rawValue)-\(level).png"))
        }
    }

    private func rasterize(_ image: NSImage, scale: Int) throws -> NSBitmapImageRep {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(image.size.width) * scale,
            pixelsHigh: Int(image.size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        image.draw(in: NSRect(origin: .zero, size: image.size),
                   from: .zero, operation: .sourceOver, fraction: 1)
        return bitmap
    }

    private func alpha(in bitmap: NSBitmapImageRep, x: Int, logicalY: Int) throws -> CGFloat {
        // Bitmap rows run from the top; the icon's drawing context has a bottom-left origin.
        let bitmapY = bitmap.pixelsHigh - 1 - logicalY
        return try #require(bitmap.colorAt(x: x, y: bitmapY)).alphaComponent
    }
}
