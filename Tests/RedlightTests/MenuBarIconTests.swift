import AppKit
import Testing
@testable import Redlight

@MainActor @Suite struct MenuBarIconTests {
    @Test(arguments: [false, true])
    func isTemplateWithTranslucentScreenAndOpaqueBezel(active: Bool) throws {
        let image = active ? MenuBarIcon.activeImage() : MenuBarIcon.inactiveImage()

        let screen = try pixel(in: image, x: 9, logicalY: 4)
        let bezel = try pixel(in: image, x: 1, logicalY: 4)
        // A template image carries state in alpha only; macOS supplies the color.
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 14))
        #expect(MenuBarIcon.sunRadius == 5.4)
        #expect(screen.alphaComponent > 0.65 && screen.alphaComponent < 0.75)
        #expect(bezel.alphaComponent > 0.95)

        // No stray marks in the corners either side of the sun (no rays, no halo bleed).
        for (x, y) in [(1, 10), (1, 13), (17, 10), (17, 13)] {
            let corner = try pixel(in: image, x: x, logicalY: y)
            #expect(corner.alphaComponent < 0.1)
        }
    }

    @Test func activeSunIsFilledInactiveSunIsHollow() throws {
        let active = MenuBarIcon.activeImage()
        let inactive = MenuBarIcon.inactiveImage()

        // The sun is present in both states: near the top of the arc the filled disc and the
        // stroked ring both cover this pixel.
        #expect(try pixel(in: active, x: 9, logicalY: 12).alphaComponent > 0.9)
        #expect(try pixel(in: inactive, x: 9, logicalY: 12).alphaComponent > 0.4)

        // Deeper in the interior discriminates state: filled disc (active) vs hollow arc
        // (inactive), whose center is empty.
        #expect(try pixel(in: active, x: 9, logicalY: 10).alphaComponent > 0.9)
        #expect(try pixel(in: inactive, x: 9, logicalY: 10).alphaComponent < 0.1)
    }

    @Test func offStateHasTwoRaysPerSideActiveHasNone() throws {
        let active = MenuBarIcon.activeImage()
        let inactive = MenuBarIcon.inactiveImage()

        // Two rays each side, outside the disc: a near-horizontal ray and a diagonal ray on
        // the right (x > 9) and their mirrors on the left. Present only when off.
        let rays = [(15, 10), (14, 13), (2, 10), (3, 13)]
        for (x, y) in rays {
            #expect(try pixel(in: inactive, x: x, logicalY: y).alphaComponent > 0.25)
            #expect(try pixel(in: active, x: x, logicalY: y).alphaComponent < 0.1)
        }
    }

    private func pixel(in image: NSImage, x: Int, logicalY: Int) throws -> NSColor {
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        // This bitmap representation addresses rows from the top, while the AppKit drawing
        // handler uses a bottom-left origin.
        let bitmapY = bitmap.pixelsHigh - 1 - logicalY
        return try #require(bitmap.colorAt(x: x, y: bitmapY))
    }
}
