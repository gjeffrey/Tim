// Generates Design/AppIcon.icns from the Icon Composer document's art:
// near-white squircle (per icon.json fill) + the tim:// Garamond wordmark.
// Run: qlmanage renders the SVG first (see make-app.sh / below), then:
//   swift Scripts/make-icon.swift && iconutil -c icns Design/AppIcon.iconset -o Design/AppIcon.icns

import AppKit

let canvas = 1024
let inset: CGFloat = 100
let radius: CGFloat = 185
// The finished icon art (background + circle + wordmark), clipped to
// the Apple icon squircle.
let artPath = "Design/tim garamond@2x.png"

func drawIcon() -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: canvas, height: canvas,
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let rect = CGRect(x: inset, y: inset, width: CGFloat(canvas) - 2 * inset, height: CGFloat(canvas) - 2 * inset)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    if let nsImage = NSImage(contentsOfFile: artPath) {
        var proposed = rect
        if let cg = nsImage.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: rect)
        }
    }
    return ctx.makeImage()!
}

func scaled(_ image: CGImage, to px: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let master = drawIcon()
let iconset = URL(fileURLWithPath: "Design/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32),
                   ("icon_32x32@2x.png", 64), ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
                   ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
                   ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)] {
    writePNG(scaled(master, to: px), to: iconset.appendingPathComponent(name))
}
print("iconset written")
