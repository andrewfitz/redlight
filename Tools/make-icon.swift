#!/usr/bin/env swift
//
// make-icon.swift — generates the Redlight app icon.
//
// Self-contained (AppKit/CoreGraphics only, no external deps). Draws a warm
// setting-sun half-disc over a horizon line on a dark rounded square — the
// red-shift idea in one mark — and writes every size the .iconset format
// needs. Usage:
//
//   swift Tools/make-icon.swift [output.iconset]
//   iconutil -c icns output.iconset -o Redlight.icns
//
import AppKit

// MARK: - Palette

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

let bgTop = rgb(44, 26, 32)          // dark plum, slightly warm
let bgBottom = rgb(16, 10, 16)       // near-black
let sunTop = rgb(255, 179, 102)      // warm amber
let sunBottom = rgb(232, 58, 44)     // deep red at the horizon
let horizonColor = rgb(255, 138, 84) // bright warm line: the lit top edge of the bezel
let glowColor = rgb(255, 94, 58)     // ambient glow behind the sun
let bezelTop = rgb(96, 76, 78)       // warm gray case, catching the sunset
let bezelBottom = rgb(32, 22, 26)    // case falling into shadow
let screenDark = rgb(10, 8, 10)      // black CRT glass
let termRed = rgb(255, 74, 58)       // red phosphor text

// MARK: - Drawing

/// A rect with only its top two corners rounded — the bottom runs straight off the edge.
/// (Y is up in this context, so "top" is `maxY`.)
func topRoundedPath(_ r: CGRect, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX, y: r.minY))
    p.addLine(to: CGPoint(x: r.minX, y: r.maxY - radius))
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY),
             tangent2End: CGPoint(x: r.minX + radius, y: r.maxY), radius: radius)
    p.addLine(to: CGPoint(x: r.maxX - radius, y: r.maxY))
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY),
             tangent2End: CGPoint(x: r.maxX, y: r.maxY - radius), radius: radius)
    p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
    p.closeSubpath()
    return p
}

/// The screen's content: a red-phosphor shell prompt reading `> redlight`.
///
/// Sized off the screen rather than the icon so it scales with the monitor. Below ~64px the
/// glyphs turn to mush, so at those sizes we draw the *shape* of a prompt — a caret and a
/// bar of text — which is what the eye resolves at 16pt anyway.
func drawTerminalLine(ctx: CGContext, screen: CGRect, pad: CGFloat, s: CGFloat) {
    let text = "> redlight" as NSString
    let targetW = screen.width * 0.80

    // Solve for the font size that makes the string exactly `targetW` wide.
    let probeSize: CGFloat = 100
    let probe = NSFont.monospacedSystemFont(ofSize: probeSize, weight: .medium)
    let probeW = text.size(withAttributes: [.font: probe]).width
    let fontSize = probeSize * targetW / probeW

    let x = screen.minX + pad
    let lineH = fontSize * 0.72                // cap height
    let y = screen.maxY - pad - lineH * 1.35   // first line, just under the top bezel

    if fontSize >= 5 {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        text.draw(at: NSPoint(x: x, y: y), withAttributes: [
            .font: font,
            .foregroundColor: NSColor(cgColor: termRed)!,
        ])
    } else {
        // Too small for type: draw what the eye would resolve anyway — a caret, then text.
        let barH = max(1, lineH * 0.5)
        let caretW = max(1, lineH * 0.45)
        ctx.setFillColor(termRed)
        ctx.fill(CGRect(x: x, y: y + lineH * 0.25, width: caretW, height: barH))
        ctx.setFillColor(termRed.copy(alpha: 0.9)!)
        ctx.fill(CGRect(x: x + caretW * 2, y: y + lineH * 0.25,
                        width: targetW - caretW * 2, height: barH))
    }
}

func drawIcon(px: Int) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("could not create bitmap rep (\(px)px)") }
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("could not create graphics context (\(px)px)")
    }
    NSGraphicsContext.current = gctx
    let ctx = gctx.cgContext
    let s = CGFloat(px)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // macOS Big Sur+ icon grid: content is a rounded square inset ~10%.
    let margin = s * 100.0 / 1024.0
    let square = CGRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let radius = square.width * 185.0 / 824.0
    let squircle = CGPath(roundedRect: square, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // Background: dark, faintly warm vertical gradient.
    let bg = CGGradient(colorsSpace: space, colors: [bgTop, bgBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        bg,
        start: CGPoint(x: square.midX, y: square.maxY),
        end: CGPoint(x: square.midX, y: square.minY),
        options: []
    )

    // Geometry: sun disc setting behind the top bezel of a chunky old monitor —
    // the monitor's top edge *is* the horizon.
    let horizonY = square.minY + square.height * 0.38
    let sunR = square.width * 0.33
    let sunCenter = CGPoint(x: square.midX, y: horizonY)

    // Ambient glow radiating from the sun.
    let glow = CGGradient(
        colorsSpace: space,
        colors: [glowColor.copy(alpha: 0.5)!, glowColor.copy(alpha: 0)!] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        glow,
        startCenter: sunCenter, startRadius: 0,
        endCenter: sunCenter, endRadius: sunR * 2.1,
        options: []
    )

    // Sun: upper half-disc, amber → red toward the horizon.
    ctx.saveGState()
    ctx.clip(to: CGRect(x: square.minX, y: horizonY, width: square.width, height: square.maxY - horizonY))
    ctx.addEllipse(in: CGRect(x: sunCenter.x - sunR, y: sunCenter.y - sunR, width: sunR * 2, height: sunR * 2))
    ctx.clip()
    let sun = CGGradient(colorsSpace: space, colors: [sunTop, sunBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        sun,
        start: CGPoint(x: sunCenter.x, y: sunCenter.y + sunR),
        end: CGPoint(x: sunCenter.x, y: horizonY),
        options: []
    )
    ctx.restoreGState()

    // Monitor: a chunky bezeled CRT whose top edge the sun sets behind. It bleeds off the
    // bottom of the square (the squircle clip cuts it), so only the bezel and screen read.
    let bezelInsetX = square.width * 0.055
    let bezel = CGRect(
        x: square.minX + bezelInsetX,
        y: square.minY - margin,
        width: square.width - 2 * bezelInsetX,
        height: horizonY - (square.minY - margin)
    )
    let bezelR = bezel.width * 0.10

    ctx.saveGState()
    ctx.addPath(topRoundedPath(bezel, radius: bezelR))
    ctx.clip()

    // Case: lit along the top by the sun behind it, falling into shadow below.
    let caseGrad = CGGradient(colorsSpace: space, colors: [bezelTop, bezelBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        caseGrad,
        start: CGPoint(x: bezel.midX, y: bezel.maxY),
        end: CGPoint(x: bezel.midX, y: bezel.minY),
        options: []
    )

    // Screen: chunky bezel across the top and down both sides, rounded CRT glass at the top
    // corners — and then it runs straight off the bottom of the icon. We're seeing the top
    // of a monitor that continues below the frame, not a whole boxed-in one. Black glass with
    // a red-phosphor terminal line on it.
    let pad = bezel.width * 0.11
    let screen = CGRect(
        x: bezel.minX + pad, y: bezel.minY,
        width: bezel.width - 2 * pad,
        height: (bezel.maxY - pad) - bezel.minY
    )
    let screenR = max(1, screen.width * 0.11)
    let screenPath = topRoundedPath(screen, radius: screenR)

    ctx.saveGState()
    ctx.addPath(screenPath)
    ctx.clip()
    ctx.setFillColor(screenDark)
    ctx.fill(screen)

    // Faint phosphor bloom, so the glass isn't dead flat.
    let bloom = CGGradient(
        colorsSpace: space,
        colors: [termRed.copy(alpha: 0.16)!, termRed.copy(alpha: 0)!] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        bloom,
        start: CGPoint(x: screen.midX, y: screen.maxY),
        end: CGPoint(x: screen.midX, y: screen.minY),
        options: []
    )

    drawTerminalLine(ctx: ctx, screen: screen, pad: screen.width * 0.10, s: s)
    ctx.restoreGState()

    // Recessed rim: a dark stroke sunk into the bezel around the glass, so the screen
    // reads as set *into* the case.
    ctx.addPath(screenPath)
    ctx.setStrokeColor(rgb(18, 12, 14, 0.75))
    ctx.setLineWidth(max(1, s * 0.008))
    ctx.strokePath()

    // The bezel's lit top edge — the crisp warm line that used to be the horizon.
    // Keep it >= 1px so it survives the 16pt size. Still inside the bezel clip, so the
    // rounded top corners cut it cleanly.
    let lineH = max(1, s * 0.014)
    ctx.setFillColor(horizonColor)
    ctx.fill(CGRect(x: bezel.minX, y: horizonY - lineH, width: bezel.width, height: lineH))

    ctx.restoreGState()   // bezel clip

    ctx.restoreGState()   // squircle clip
    return rep
}

// MARK: - Output

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Redlight.iconset"
let outURL = URL(fileURLWithPath: outDir)
try? FileManager.default.removeItem(at: outURL)
try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

let variants: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, px) in variants {
    let rep = drawIcon(px: px)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(name)")
    }
    try png.write(to: outURL.appendingPathComponent(name))
}
print("wrote \(variants.count) PNGs to \(outURL.path)")
