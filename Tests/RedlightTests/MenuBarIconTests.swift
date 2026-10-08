import AppKit
import Testing
@testable import Redlight

@MainActor @Suite struct MenuBarIconTests {
    @Test(arguments: [false, true])
    func bothStatesAreTemplatesWithTheCircularSunCanvas(active: Bool) {
        let image = active ? MenuBarIcon.activeImage() : MenuBarIcon.inactiveImage()
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
    }

    @Test func monitorIsModestlyShorterAndKeepsItsTopBezel() {
        #expect(MenuBarIcon.monitorHeight < 11.6)
        #expect(abs(MenuBarIcon.monitorHeight - MenuBarIcon.screenRect.maxY - 1.5) < 1e-9)
        #expect(MenuBarIcon.sunCenter == CGPoint(x: 9, y: 12))
        #expect(MenuBarIcon.sunRadius == 5.4)
    }

    @Test(arguments: [1, 2])
    func disabledGlassHasTenPercentOpacityAndEnabledGlassHasSeventy(scale: Int) throws {
        let disabled = try rasterize(MenuBarIcon.inactiveImage(), scale: scale)
        let enabled = try rasterize(MenuBarIcon.activeImage(), scale: scale)
        // y=8 is inside the underlying sun, proving the hidden sun cannot fill the glass.
        for y in [4, 8] {
            let offAlpha = try alpha(in: disabled, x: 9 * scale, logicalY: y * scale)
            let onAlpha = try alpha(in: enabled, x: 9 * scale, logicalY: y * scale)
            #expect(offAlpha > 0.08 && offAlpha < 0.12)
            #expect(onAlpha > 0.68 && onAlpha < 0.72)
        }
    }

    @Test(arguments: [1, 2])
    func sunIsIdenticalInBothStatesAndHasNoEyeCutouts(scale: Int) throws {
        let disabled = try rasterize(MenuBarIcon.inactiveImage(), scale: scale)
        let enabled = try rasterize(MenuBarIcon.activeImage(), scale: scale)
        for bitmap in [disabled, enabled] {
            // The sun stays solid across its center and visible circular arc.
            for (x, y) in [(9, 12), (9, 14), (9, 16), (7, 13), (5, 12), (12, 12)] {
                #expect(try alpha(in: bitmap, x: x * scale, logicalY: y * scale) > 0.95)
            }
        }
        let firstSunRow = Int(ceil(MenuBarIcon.monitorHeight * CGFloat(scale)))
        for y in firstSunRow..<enabled.pixelsHigh {
            for x in 0..<enabled.pixelsWide {
                #expect(try alpha(in: enabled, x: x, logicalY: y)
                        == alpha(in: disabled, x: x, logicalY: y))
            }
        }
    }

    @Test(arguments: [1, 2])
    func monitorBezelRemainsOpaqueInBothStates(scale: Int) throws {
        let disabled = try rasterize(MenuBarIcon.inactiveImage(), scale: scale)
        let enabled = try rasterize(MenuBarIcon.activeImage(), scale: scale)
        for (x, y) in [(1, 4), (9, 0)] {
            let offAlpha = try alpha(in: disabled, x: x * scale, logicalY: y * scale)
            let onAlpha = try alpha(in: enabled, x: x * scale, logicalY: y * scale)
            #expect(offAlpha > 0.95)
            #expect(onAlpha == offAlpha)
        }
    }

    @Test(arguments: [false, true])
    func visibleSunFitsWithoutClippingAtTheTopOrAddingSideMarks(active: Bool) throws {
        let image = active ? MenuBarIcon.activeImage() : MenuBarIcon.inactiveImage()
        let bitmap = try rasterize(image, scale: 2)
        for x in 0..<bitmap.pixelsWide {
            #expect(try alpha(in: bitmap, x: x, logicalY: bitmap.pixelsHigh - 1) < 0.01)
        }
        for y in (11 * 2)..<bitmap.pixelsHigh {
            #expect(try alpha(in: bitmap, x: 0, logicalY: y) < 0.01)
            #expect(try alpha(in: bitmap, x: bitmap.pixelsWide - 1, logicalY: y) < 0.01)
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
