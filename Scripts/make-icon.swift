// Generates Design/AppIcon.icns: a placeholder icon — Apple-style squircle,
// the start page's blue→purple gradient, white "Tim" wordmark.
// Run: swift Scripts/make-icon.swift && iconutil -c icns Design/AppIcon.iconset -o Design/AppIcon.icns

import AppKit
import CoreText

let canvas = 1024
let inset: CGFloat = 100      // Apple icon grid margin
let radius: CGFloat = 185     // Big Sur-era squircle approximation

func drawIcon() -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: canvas, height: canvas,
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    let rect = CGRect(x: inset, y: inset, width: CGFloat(canvas) - 2 * inset, height: CGFloat(canvas) - 2 * inset)
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(squircle)
    ctx.clip()

    let colors = [
        CGColor(red: 0.04, green: 0.52, blue: 1.00, alpha: 1),
        CGColor(red: 0.75, green: 0.35, blue: 0.95, alpha: 1)
    ]
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: rect.minY),
        options: []
    )

    let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 330, nil)
    let attributes: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)
    ]
    let string = CFAttributedStringCreate(nil, "Tim" as CFString, attributes as CFDictionary)!
    let line = CTLineCreateWithAttributedString(string)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    ctx.textPosition = CGPoint(
        x: (CGFloat(canvas) - bounds.width) / 2 - bounds.minX,
        y: (CGFloat(canvas) - bounds.height) / 2 - bounds.minY
    )
    CTLineDraw(line, ctx)

    return ctx.makeImage()!
}

func scaled(_ image: CGImage, to px: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: px, height: px,
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: url)
}

let master = drawIcon()
let iconset = URL(fileURLWithPath: "Design/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for (name, px) in entries {
    writePNG(scaled(master, to: px), to: iconset.appendingPathComponent(name))
}
print("iconset written")
