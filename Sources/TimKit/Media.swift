import Foundation

/// What a picked file should become on the page: an embedded element for
/// media HTML supports natively, a link for everything else.
public enum MediaKind {
    case image, video, audio, pdf, file

    public static func of(fileExtension ext: String) -> MediaKind {
        switch ext.lowercased() {
        case "pdf":
            return .pdf
        case "jpg", "jpeg", "png", "gif", "webp", "avif", "svg", "heic":
            return .image
        case "mp4", "mov", "m4v", "webm":
            return .video
        case "mp3", "m4a", "wav", "aac", "ogg", "flac":
            return .audio
        default:
            return .file
        }
    }
}
