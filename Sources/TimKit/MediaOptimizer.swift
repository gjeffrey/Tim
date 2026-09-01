import Foundation

#if os(macOS)
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Web-appropriate media, no questions asked: files that are already fine
/// publish untouched; camera originals, ProRes exports, HEICs, and other
/// heavyweights are converted automatically. Nobody chooses a codec — the
/// same promise Keynote makes about dragged-in video. Originals are never
/// uploaded; when a file is converted, the untouched original is kept in
/// the mirror's media/originals/ for safekeeping.
public enum MediaOptimizer {
    public enum Plan {
        case asIs
        case transcode
    }

    public enum OptimizeError: LocalizedError {
        case unreadable
        case failed(String)
        public var errorDescription: String? {
            switch self {
            case .unreadable: return "Couldn't read this media file."
            case .failed(let why): return why
            }
        }
    }

    /// Fast inspection — decides whether the file publishes as-is.
    public static func plan(fileURL: URL, kind: MediaKind) -> Plan {
        switch kind {
        case .video: return videoPlan(fileURL)
        case .image: return imagePlan(fileURL)
        default: return .asIs
        }
    }

    /// The slow half: converts to a web-appropriate rendition in a temp
    /// folder and returns its URL (same base name, right extension).
    public static func transcode(fileURL: URL, kind: MediaKind) throws -> URL {
        switch kind {
        case .video: return try transcodeVideo(fileURL)
        case .image: return try transcodeImage(fileURL)
        default: return fileURL
        }
    }

    /// The untouched original, kept locally beside the site (never uploaded).
    public static func stashOriginal(_ url: URL, mirror: String) {
        guard !mirror.isEmpty else { return }
        let dir = (mirror as NSString).appendingPathComponent("media/originals")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dest = (dir as NSString).appendingPathComponent(url.lastPathComponent)
        if !FileManager.default.fileExists(atPath: dest) {
            try? FileManager.default.copyItem(atPath: url.path, toPath: dest)
        }
    }

    // MARK: Video — H.264 mp4, ≤1080p, sane bitrate, faststart

    static func videoPlan(_ url: URL) -> Plan {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return .asIs }
        let size = track.naturalSize.applying(track.preferredTransform)
        let longEdge = max(abs(size.width), abs(size.height))
        let mbps = Double(track.estimatedDataRate) / 1_000_000
        var h264 = false
        for description in track.formatDescriptions {
            let desc = description as! CMFormatDescription
            if CMFormatDescriptionGetMediaSubType(desc) == kCMVideoCodecType_H264 { h264 = true }
        }
        let containerOK = ["mp4", "m4v"].contains(url.pathExtension.lowercased())
        return (h264 && containerOK && longEdge <= 1921 && mbps <= 10) ? .asIs : .transcode
    }

    static func transcodeVideo(_ url: URL) throws -> URL {
        let asset = AVURLAsset(url: url)
        let presets = AVAssetExportSession.exportPresets(compatibleWith: asset)
        let preset = presets.contains(AVAssetExportPreset1920x1080)
            ? AVAssetExportPreset1920x1080
            : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw OptimizeError.unreadable
        }
        let out = try scratchFile(named: url.deletingPathExtension().lastPathComponent + ".mp4")
        session.outputURL = out
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        let done = DispatchSemaphore(value: 0)
        session.exportAsynchronously { done.signal() }
        done.wait()
        guard session.status == .completed else {
            throw OptimizeError.failed(session.error?.localizedDescription ?? "Video conversion failed.")
        }
        return out
    }

    // MARK: Images — ≤2560px, JPEG (or PNG when transparency matters)

    static func imagePlan(_ url: URL) -> Plan {
        let ext = url.pathExtension.lowercased()
        // Vectors and animations are left exactly as authored.
        if ext == "svg" || ext == "gif" { return .asIs }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return .asIs }
        let width = (props[kCGImagePropertyPixelWidth] as? Double) ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? Double) ?? 0
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int ?? 0
        let webFormat = ["jpg", "jpeg", "png", "webp", "avif"].contains(ext)
        return (webFormat && max(width, height) <= 2560 && bytes <= 1_800_000) ? .asIs : .transcode
    }

    static func transcodeImage(_ url: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw OptimizeError.unreadable
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 2560,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw OptimizeError.unreadable
        }
        let alpha = image.alphaInfo
        let hasAlpha = !(alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast)
        let base = url.deletingPathExtension().lastPathComponent
        let out = try scratchFile(named: base + (hasAlpha ? ".png" : ".jpg"))
        let type: UTType = hasAlpha ? .png : .jpeg
        guard let destination = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else {
            throw OptimizeError.failed("Couldn't write the converted image.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw OptimizeError.failed("Couldn't write the converted image.")
        }
        return out
    }

    static func scratchFile(named name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tim-media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }
}
#endif
