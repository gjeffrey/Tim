import AppKit
import PhotosUI
import UniformTypeIdentifiers

/// The system Photos picker, on the Mac.
///
/// Worth having alongside the open panel for two reasons: a Photos library
/// is an opaque package, so a file dialog cannot see inside it at all; and
/// this picker runs out of process, which means Tim never gets access to
/// the library and macOS never asks anyone for permission.
///
/// SwiftUI's `PhotosPicker` is iOS-only — on macOS the picker is an
/// `NSViewController`, so it is presented as a sheet here.
enum PhotosBrowser {
    /// Presents the picker and hands back real files on disk: the chosen
    /// assets are copied out into a temporary folder, so everything after
    /// this point is Tim's ordinary media pipeline.
    static func pick(multiple: Bool, completion: @escaping ([URL]) -> Void) {
        guard let host = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentViewController else {
            completion([])
            return
        }
        // No `photoLibrary:` — that variant returns PHAssets and needs the
        // user's permission. File representations need none.
        var config = PHPickerConfiguration()
        config.selectionLimit = multiple ? 0 : 1
        config.filter = .any(of: [.images, .videos])
        // The asset as it actually is; Tim's own optimizer decides what the
        // web version should be.
        config.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: config)
        // A sheet with no stated size opens at the view controller's
        // minimum, which for the picker is a postage stamp.
        picker.preferredContentSize = NSSize(width: 820, height: 600)
        let delegate = Delegate(completion: completion)
        picker.delegate = delegate
        retained = delegate
        host.presentAsSheet(picker)
    }

    /// The picker's delegate is not retained by the picker.
    private static var retained: Delegate?

    private final class Delegate: NSObject, PHPickerViewControllerDelegate {
        private let completion: ([URL]) -> Void
        init(completion: @escaping ([URL]) -> Void) { self.completion = completion }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(nil)
            guard !results.isEmpty else { finish([]); return }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("tim-photos-\(UUID().uuidString.prefix(8))")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let group = DispatchGroup()
            let lock = NSLock()
            var picked: [(order: Int, url: URL)] = []
            for (index, result) in results.enumerated() {
                let provider = result.itemProvider
                let type: UTType = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) ? .movie : .image
                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { temp, _ in
                    defer { group.leave() }
                    // This URL is only valid inside the callback — copy now.
                    guard let temp else { return }
                    let dest = dir.appendingPathComponent(Self.name(for: provider, from: temp))
                    try? FileManager.default.removeItem(at: dest)
                    guard (try? FileManager.default.copyItem(at: temp, to: dest)) != nil else { return }
                    lock.lock(); picked.append((index, dest)); lock.unlock()
                }
            }
            group.notify(queue: .main) {
                self.finish(picked.sorted { $0.order < $1.order }.map(\.url))
            }
        }

        /// The library's own name for the asset, made safe to live in a URL.
        private static func name(for provider: NSItemProvider, from temp: URL) -> String {
            let ext = temp.pathExtension.isEmpty ? "jpg" : temp.pathExtension
            var base = provider.suggestedName ?? temp.deletingPathExtension().lastPathComponent
            base = base.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: " ", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if base.isEmpty { base = "photo" }
            if base.lowercased().hasSuffix("." + ext.lowercased()) { return base }
            return base + "." + ext
        }

        private func finish(_ urls: [URL]) {
            completion(urls)
            PhotosBrowser.retained = nil
        }
    }
}
