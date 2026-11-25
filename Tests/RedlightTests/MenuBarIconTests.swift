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
        // The default presets land on the level named for them.
        let expected: [MenuBarIcon.Level] = [.low, .low, .mid, .mid, .deep]
        #expect(Preset.defaults.map { MenuBarIcon.Level(isActive: true, intensity: $0.intensity) } == expected)
        // The steps sit between presets, and each boundary belongs to the deeper level.
        #expect(MenuBarIcon.Level(isActive: true, intensity: 0.6) == .mid)
        #expect(MenuBarIcon.Level(isActive: true, intensity: 0.6001) == .low)
        #expect(MenuBarIcon.Level(isActive: true, intensity: 0.125) == .deep)
        #expect(MenuBarIcon.Level(isActive: true, intensity: 0.1251) == .mid)
        // Out-of-range and non-finite values never trap and never read as off.
        #expect(MenuBarIcon.Level(isActive: true, intensity: -1) == .deep)
        #expect(MenuBarIcon.Level(isActive: true, intensity: 2) == .low)
        #expect(MenuBarIcon.Level(isActive: true, intensity: .nan) == .low)
    }

    @Test func eachDeeperLevelAddsOneSlitAboveTheLast() {
        #expect(MenuBarIcon.slits(for: .off).isEmpty)
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
    func offIsARingWithAClearCentre(scale: Int) throws {
        let bitmap = try rasterize(MenuBarIcon.image(for: .off), scale: scale)
        #expect(try alpha(in: bitmap, x: 9 * scale, logicalY: 9 * scale) < 0.01)
        #expect(try alpha(in: bitmap, x: 9 * scale, logicalY: 4 * scale) < 0.01)
        // The ring itself, at the four compass points, half a line width in from the edge.
        // The line is 1.25 pt wide, so at 1x it covers three quarters of its pixel.
        let inset = Int((1.5 + 0.625) * CGFloat(scale))
        let far = 18 * scale - 1 - inset
        for (x, y) in [(9 * scale, inset), (9 * scale, far), (inset, 9 * scale), (far, 9 * scale)] {
            #expect(try alpha(in: bitmap, x: x, logicalY: y) > 0.6)
        }
    }

    @Test(arguments: [1, 2])
    func activeLevelsAreASolidDiscCutOnlyByTheirSlits(scale: Int) throws {
        for level in [MenuBarIcon.Level.low, .mid, .deep] {
            let bitmap = try rasterize(MenuBarIcon.image(for: level), scale: scale)
            let slits = MenuBarIcon.slits(for: level)
            // Down the middle of the disc, away from its rounded edge, one pixel at a time.
            // A pixel wholly inside a slit is clear, one wholly outside every slit is solid,
            // and a pixel a slit's half-point edge crosses at 1x is left out.
            for pixel in (2 * scale)..<(16 * scale) {
                let low = CGFloat(pixel) / CGFloat(scale), high = CGFloat(pixel + 1) / CGFloat(scale)
                let value = try alpha(in: bitmap, x: 9 * scale, logicalY: pixel)
                if slits.contains(where: { $0.minY <= low && high <= $0.maxY }) {
                    #expect(value < 0.01, "level \(level) pixel row \(pixel) should be a slit")
                } else if !slits.contains(where: { $0.minY < high && low < $0.maxY }) {
                    #expect(value > 0.99, "level \(level) pixel row \(pixel) should be solid")
                }
            }
        }
    }

    @Test(arguments: MenuBarIcon.Level.allCases)
    func nothingIsPartlyTransparentAwayFromTheCurvedEdge(level: MenuBarIcon.Level) throws {
        // State is shape, not alpha: inside the disc every pixel is fully on or fully off.
        let scale = 2
        let bitmap = try rasterize(MenuBarIcon.image(for: level), scale: scale)
        let inner = (MenuBarIcon.radius - MenuBarIcon.ringWidth - 1) * CGFloat(scale)
        let centre = CGFloat(9 * scale) - 0.5
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where hypot(CGFloat(x) - centre, CGFloat(y) - centre) < inner {
                let value = try alpha(in: bitmap, x: x, logicalY: y)
                #expect(value < 0.01 || value > 0.99)
            }
        }
    }

    @Test(arguments: MenuBarIcon.Level.allCases)
    func theGlyphStaysInsideItsCircleAndLeavesTheCornersClear(level: MenuBarIcon.Level) throws {
        let scale = 2
        let bitmap = try rasterize(MenuBarIcon.image(for: level), scale: scale)
        let limit = (MenuBarIcon.radius + 0.75) * CGFloat(scale)
        let centre = CGFloat(9 * scale) - 0.5
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where hypot(CGFloat(x) - centre, CGFloat(y) - centre) > limit {
                #expect(try alpha(in: bitmap, x: x, logicalY: y) < 0.01)
            }
        }
    }

    @Test func everyLevelLooksDifferentFromEveryOther() throws {
        let bitmaps = try MenuBarIcon.Level.allCases.map { try rasterize(MenuBarIcon.image(for: $0), scale: 1) }
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
