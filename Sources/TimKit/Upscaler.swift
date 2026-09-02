import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

/// Making a small image bigger, as well as this Mac can without a
/// download: Lanczos resampling with a touch of luminance sharpening —
/// Core Image, hardware-accelerated, instant. A learned upscaler can
/// slot in here later; the call site never needs to change.
public enum Upscaler {
    public static var methodName: String { "Lanczos" }

    public struct Size: Equatable { public var width: Int; public var height: Int }

    public static func pixelSize(of url: URL) -> Size? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return Size(width: w, height: h)
    }

    /// Writes an enlarged copy next to the original's name: photo.jpg → photo@2x.jpg.
    public static func enlarge(_ url: URL, factor: CGFloat = 2) throws -> URL {
        guard let image = CIImage(contentsOf: url) else {
            throw NSError(domain: "Tim.Upscaler", code: 1, userInfo: [NSLocalizedDescriptionKey: "That file isn't an image Tim can read."])
        }
        let scale = CIFilter.lanczosScaleTransform()
        scale.inputImage = image
        scale.scale = Float(factor)
        scale.aspectRatio = 1
        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = scale.outputImage
        sharpen.sharpness = 0.35
        sharpen.radius = 1.2
        guard let out = sharpen.outputImage else {
            throw NSError(domain: "Tim.Upscaler", code: 2, userInfo: [NSLocalizedDescriptionKey: "The enlargement failed."])
        }
        let context = CIContext()
        let ext = url.pathExtension.lowercased()
        let base = url.deletingPathExtension().lastPathComponent
        let stem = base.hasSuffix("@2x") ? base : base + "@2x"
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(stem).\(ext.isEmpty ? "jpg" : ext)")
        try? FileManager.default.removeItem(at: dest)
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        if ext == "png" {
            try context.writePNGRepresentation(of: out, to: dest, format: .RGBA8, colorSpace: colorSpace)
        } else if ext == "heic" {
            try context.writeHEIFRepresentation(of: out, to: dest, format: .RGBA8, colorSpace: colorSpace, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9])
        } else {
            try context.writeJPEGRepresentation(of: out, to: dest, colorSpace: colorSpace, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9])
        }
        return dest
    }
}
