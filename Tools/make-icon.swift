#!/usr/bin/env swift
//
// make-icon.swift — builds the Redlight app icon set from its master artwork.
//
// The master is `Resources/AppIcon.png`: the face of a beige 1990s CRT monitor with a red sun
// setting over the sea on its screen, 1024×1024 and already on the macOS icon grid (an 824 px
// rounded-square tile with a 100 px transparent margin), prepared from generated artwork by
// cropping its tile and masking the corners.
// This script resamples the master to every size the .iconset format needs. Usage:
//
//   swift Tools/make-icon.swift [output.iconset] [master.png]
//   iconutil -c icns output.iconset -o Redlight.icns
//
import AppKit

let scriptDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let masterURL = CommandLine.arguments.count > 2
    ? URL(fileURLWithPath: CommandLine.arguments[2])
    : scriptDirectory.deletingLastPathComponent().appendingPathComponent("Resources/AppIcon.png")

guard let source = CGImageSourceCreateWithURL(masterURL as CFURL, nil),
      let master = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("could not read the icon master at \(masterURL.path)")
}
guard master.width == 1024, master.height == 1024 else {
    fatalError("the icon master must be 1024×1024; \(masterURL.path) is \(master.width)×\(master.height)")
}

/// Draws `image` at `px`×`px`. Large reductions are done in halving steps, which keeps small
/// sizes smooth instead of dropping detail between samples.
func resample(_ image: CGImage, to px: Int) -> CGImage {
    var current = image
    while current.width / 2 >= px * 2 {
        current = draw(current, size: current.width / 2)
    }
    return current.width == px ? current : draw(current, size: px)
}

func draw(_ image: CGImage, size: Int) -> CGImage {
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("could not create a \(size)px context") }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let result = ctx.makeImage() else { fatalError("could not render \(size)px") }
    return result
}

// MARK: - Output

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Redlight.iconset"
let outURL = URL(fileURLWithPath: outDir)
try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

let variants: [(px: Int, names: [String])] = [
    (16, ["icon_16x16.png"]),
    (32, ["icon_16x16@2x.png", "icon_32x32.png"]),
    (64, ["icon_32x32@2x.png"]),
    (128, ["icon_128x128.png"]),
    (256, ["icon_128x128@2x.png", "icon_256x256.png"]),
    (512, ["icon_256x256@2x.png", "icon_512x512.png"]),
    (1024, ["icon_512x512@2x.png"]),
]

for (px, names) in variants {
    let rep = NSBitmapImageRep(cgImage: resample(master, to: px))
    rep.size = NSSize(width: px, height: px)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(px)px icon")
    }
    for name in names {
        try png.write(to: outURL.appendingPathComponent(name), options: .atomic)
    }
}
print("wrote \(variants.reduce(0) { $0 + $1.names.count }) PNGs to \(outURL.path)")
