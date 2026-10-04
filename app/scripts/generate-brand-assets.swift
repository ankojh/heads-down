#!/usr/bin/env swift
// Original Heads Down artwork. Run: swift app/scripts/generate-brand-assets.swift
// Uses only macOS frameworks; generated assets are checked in so builds need no generator.
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("app/HeadsDown/Assets.xcassets")
let branding = root.appendingPathComponent("design")
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let imageContext = CIContext(options: [.workingColorSpace: colorSpace, .outputColorSpace: colorSpace])

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [
        CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255,
        CGFloat(hex & 255) / 255, alpha,
    ])!
}

func canvas(_ size: Int, logicalSize: CGFloat = 1024) -> CGContext {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: CGFloat(size) / logicalSize, y: -CGFloat(size) / logicalSize)
    ctx.setAllowsAntialiasing(true)
    return ctx
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fill(_ ctx: CGContext, _ rect: CGRect, _ radius: CGFloat, _ value: CGColor) {
    ctx.setFillColor(value)
    ctx.addPath(rounded(rect, radius))
    ctx.fillPath()
}

func stroke(_ ctx: CGContext, _ rect: CGRect, _ radius: CGFloat, _ value: CGColor, _ width: CGFloat) {
    ctx.setStrokeColor(value)
    ctx.setLineWidth(width)
    ctx.addPath(rounded(rect, radius))
    ctx.strokePath()
}

func drawImage(_ ctx: CGContext, _ image: CGImage, in rect: CGRect) {
    ctx.saveGState()
    ctx.translateBy(x: rect.minX, y: rect.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
    ctx.restoreGState()
}

func iconMaster() -> CGImage {
    let ctx = canvas(1024)
    let tile = CGRect(x: 64, y: 64, width: 896, height: 896)
    // A macOS-shaped tile with transparent margins and a restrained drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 24, color: color(0x02121B, 0.28))
    fill(ctx, tile, 200, color(0x0B2334))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(rounded(tile, 200))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: colorSpace,
                              colors: [color(0x193D4B), color(0x081A2C)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 150, y: 80),
                           end: CGPoint(x: 850, y: 944), options: [])
    let glow = CGGradient(colorsSpace: colorSpace,
                         colors: [color(0x67E6C4, 0.19), color(0x67E6C4, 0)] as CFArray,
                         locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 475, y: 480), startRadius: 0,
                          endCenter: CGPoint(x: 475, y: 480), endRadius: 470, options: [])

    // Soft peripheral panes: visual noise stays outside the crisp focus window.
    let peripheral = canvas(1024)
    fill(peripheral, CGRect(x: 118, y: 333, width: 142, height: 318), 30, color(0x8BCFC5, 0.25))
    fill(peripheral, CGRect(x: 766, y: 301, width: 139, height: 184), 28, color(0x77AFC4, 0.24))
    fill(peripheral, CGRect(x: 771, y: 520, width: 125, height: 190), 28, color(0x77AFC4, 0.18))
    let input = CIImage(cgImage: peripheral.makeImage()!)
    let softened = input.applyingGaussianBlur(sigma: 14).cropped(to: input.extent)
    drawImage(ctx, imageContext.createCGImage(softened, from: input.extent)!,
              in: CGRect(x: 0, y: 0, width: 1024, height: 1024))

    let window = CGRect(x: 226, y: 252, width: 572, height: 520)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 36, color: color(0x020F1B, 0.45))
    fill(ctx, window, 54, color(0x10313E))
    ctx.restoreGState()
    stroke(ctx, window, 54, color(0xB8F5DF), 14)
    ctx.setStrokeColor(color(0xB8F5DF, 0.35))
    ctx.setLineWidth(8)
    ctx.move(to: CGPoint(x: 233, y: 348))
    ctx.addLine(to: CGPoint(x: 791, y: 348))
    ctx.strokePath()
    for dotX in [274.0, 308.0, 342.0] {
        fill(ctx, CGRect(x: dotX, y: 292, width: 14, height: 14), 7, color(0xB8F5DF, 0.7))
    }

    // One bright, legible area; secondary content falls back into the background.
    let focus = CGRect(x: 278, y: 396, width: 290, height: 322)
    ctx.saveGState()
    ctx.addPath(rounded(focus, 26))
    ctx.clip()
    let mint = CGGradient(colorsSpace: colorSpace,
                         colors: [color(0xD3FFE9), color(0x70E3BB)] as CFArray,
                         locations: [0, 1])!
    ctx.drawLinearGradient(mint, start: CGPoint(x: 278, y: 396),
                           end: CGPoint(x: 568, y: 718), options: [])
    ctx.restoreGState()
    fill(ctx, CGRect(x: 320, y: 445, width: 171, height: 19), 9.5, color(0x124B45))
    fill(ctx, CGRect(x: 320, y: 492, width: 205, height: 15), 7.5, color(0x124B45, 0.60))
    fill(ctx, CGRect(x: 320, y: 531, width: 155, height: 15), 7.5, color(0x124B45, 0.60))
    // Small downward notch: a subtle reference to the app name, not a second symbol.
    ctx.setLineWidth(15)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(color(0x124B45))
    ctx.move(to: CGPoint(x: 395, y: 634))
    ctx.addLine(to: CGPoint(x: 423, y: 662))
    ctx.addLine(to: CGPoint(x: 451, y: 634))
    ctx.strokePath()

    for cardY in [407.0, 526.0, 645.0] {
        fill(ctx, CGRect(x: 614, y: cardY, width: 132, height: 64), 16, color(0x8AB9BE, 0.13))
        fill(ctx, CGRect(x: 634, y: cardY + 22, width: 74, height: 12), 6, color(0xA2CDD0, 0.19))
    }
    ctx.restoreGState()
    stroke(ctx, tile.insetBy(dx: 1.5, dy: 1.5), 199, color(0xC1EEE9, 0.12), 3)
    return ctx.makeImage()!
}

func resized(_ image: CGImage, size: Int) -> CGImage {
    let ctx = canvas(size)
    ctx.interpolationQuality = .high
    drawImage(ctx, image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    return ctx.makeImage()!
}

func menuMark(active: Bool, scale: Int) -> CGImage {
    let ctx = canvas(18 * scale, logicalSize: 18)
    let ink = color(0x000000)
    stroke(ctx, CGRect(x: 1.5, y: 2.5, width: 15, height: 13), 2.5, ink, 1.5)
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(1)
    ctx.move(to: CGPoint(x: 2, y: 6))
    ctx.addLine(to: CGPoint(x: 16, y: 6))
    ctx.strokePath()
    let pane = CGRect(x: 4, y: 8, width: 6, height: 5)
    if active { fill(ctx, pane, 1, ink) } else { stroke(ctx, pane, 1, ink, 1) }
    fill(ctx, CGRect(x: 12, y: 8, width: 2, height: 2), 0.5, ink)
    fill(ctx, CGRect(x: 12, y: 11, width: 2, height: 2), 0.5, ink)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw NSError(domain: "BrandAssets", code: 1) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "BrandAssets", code: 2) }
}

func writeJSON(_ object: [String: Any], to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: directory.appendingPathComponent("Contents.json"))
}

let info: [String: Any] = ["author": "xcode", "version": 1]
try writeJSON(["info": info], to: assets)
let master = iconMaster()
var appImages: [[String: Any]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(size)x\(size)@\(scale)x.png"
        try writePNG(resized(master, size: size * scale),
                     to: assets.appendingPathComponent("AppIcon.appiconset/\(filename)"))
        appImages.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": filename])
    }
}
try writeJSON(["info": info, "images": appImages], to: assets.appendingPathComponent("AppIcon.appiconset"))

var brandImages: [[String: Any]] = []
for scale in [1, 2] {
    let filename = "brand@\(scale)x.png"
    try writePNG(resized(master, size: 64 * scale),
                 to: assets.appendingPathComponent("BrandIcon.imageset/\(filename)"))
    brandImages.append(["idiom": "mac", "scale": "\(scale)x", "filename": filename])
}
try writeJSON(["info": info, "images": brandImages, "properties": ["template-rendering-intent": "original"]],
              to: assets.appendingPathComponent("BrandIcon.imageset"))

for active in [false, true] {
    let name = active ? "MenuBarActive" : "MenuBarIcon"
    var images: [[String: Any]] = []
    for scale in [1, 2] {
        let filename = "mark@\(scale)x.png"
        try writePNG(menuMark(active: active, scale: scale),
                     to: assets.appendingPathComponent("\(name).imageset/\(filename)"))
        images.append(["idiom": "mac", "scale": "\(scale)x", "filename": filename])
    }
    try writeJSON(["info": info, "images": images, "properties": ["template-rendering-intent": "template"]],
                  to: assets.appendingPathComponent("\(name).imageset"))
}
try writePNG(master, to: branding.appendingPathComponent("heads-down-icon.png"))
print("Generated AppIcon, BrandIcon, and template menu-bar marks in \(assets.path)")
