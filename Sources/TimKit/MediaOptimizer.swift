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

    // MARK: Bounce — forward + reversed, baked into one file. A plain
    // looping <video> then bounces everywhere, with zero runtime tricks.
    // Silent by design (reversed audio is nonsense; bounces are ambient).

    public static func bounceVideo(_ url: URL) throws -> URL {
        // Work from a web-ready rendition so frames are 1080p at most.
        let source: URL
        if case .transcode = videoPlan(url) {
            source = try transcodeVideo(url)
        } else {
            source = url
        }
        let reversed = try reversedVideo(source)
        let forward = AVURLAsset(url: source)
        let backward = AVURLAsset(url: reversed)
        let composition = AVMutableComposition()
        guard let forwardTrack = forward.tracks(withMediaType: .video).first,
              let backwardTrack = backward.tracks(withMediaType: .video).first,
              let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw OptimizeError.unreadable }
        // Trim one frame from each end of the reversed half so the turn
        // and the loop restart don't hold a doubled frame.
        let fps = forwardTrack.nominalFrameRate > 0 ? Double(forwardTrack.nominalFrameRate) : 30
        let oneFrame = CMTime(seconds: 1 / fps, preferredTimescale: 600)
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: forward.duration), of: forwardTrack, at: .zero)
        let trimmed = CMTimeRange(start: oneFrame, duration: CMTimeSubtract(backward.duration, CMTimeMultiply(oneFrame, multiplier: 2)))
        try track.insertTimeRange(trimmed, of: backwardTrack, at: forward.duration)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw OptimizeError.unreadable
        }
        let base = url.deletingPathExtension().lastPathComponent
        let out = try scratchFile(named: base + "-bounce.mp4")
        session.outputURL = out
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        let done = DispatchSemaphore(value: 0)
        session.exportAsynchronously { done.signal() }
        done.wait()
        guard session.status == .completed else {
            throw OptimizeError.failed(session.error?.localizedDescription ?? "Couldn't build the bounce.")
        }
        return out
    }

    /// Decodes the video in one-second chunks from the end and writes the
    /// frames back-to-front — memory stays bounded regardless of length.
    static func reversedVideo(_ url: URL) throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { throw OptimizeError.unreadable }
        let size = track.naturalSize.applying(track.preferredTransform)
        let fps = track.nominalFrameRate > 0 ? Double(track.nominalFrameRate) : 30
        let timescale = CMTimeScale(max(1, Int32(fps.rounded())))
        let out = try scratchFile(named: "reversed.mp4")
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(abs(size.width).rounded()),
            AVVideoHeightKey: Int(abs(size.height).rounded()),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else {
            throw OptimizeError.failed(writer.error?.localizedDescription ?? "Couldn't start writing.")
        }
        writer.startSession(atSourceTime: .zero)

        let total = asset.duration.seconds
        var end = total
        var frameIndex = 0
        while end > 0.0005 {
            let start = max(0, end - 1.0)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ])
            reader.add(output)
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                end: CMTime(seconds: end, preferredTimescale: 600)
            )
            reader.startReading()
            var frames: [CVPixelBuffer] = []
            while let sample = output.copyNextSampleBuffer() {
                if let buffer = CMSampleBufferGetImageBuffer(sample) { frames.append(buffer) }
            }
            reader.cancelReading()
            for frame in frames.reversed() {
                while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
                adaptor.append(frame, withPresentationTime: CMTime(value: CMTimeValue(frameIndex), timescale: timescale))
                frameIndex += 1
            }
            end = start
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw OptimizeError.failed(writer.error?.localizedDescription ?? "Couldn't reverse the video.")
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
