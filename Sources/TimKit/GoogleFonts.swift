import Foundation
import CoreText

/// The full Google Fonts catalog, with native previews: families come from
/// Google's public metadata endpoint (no API key), and a font is downloaded
/// and registered with CoreText the moment its row scrolls into view — so
/// the picker shows every family in its own face.
public enum GoogleFonts {
    public struct Family: Identifiable, Hashable, Codable {
        public var id: String { family }
        public let family: String
        public let category: String    // sans-serif, serif, display, handwriting, monospace
        public let popularity: Int
        public let weights: [Int]
    }

    private static let cacheDir = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TimFonts")

    private static var memoryCatalog: [Family]?
    private static var registered = Set<String>()
    private static var waiters: [String: [(Bool) -> Void]] = [:]

    // MARK: Catalog

    public static func catalog(_ completion: @escaping ([Family]) -> Void) {
        if let memoryCatalog {
            completion(memoryCatalog)
            return
        }
        let diskURL = cacheDir.appendingPathComponent("catalog.json")
        func finish(_ families: [Family]) {
            DispatchQueue.main.async {
                memoryCatalog = families
                completion(families)
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            if let data = try? Data(contentsOf: diskURL),
               let families = try? JSONDecoder().decode([Family].self, from: data),
               !families.isEmpty {
                finish(families)
                return
            }
            let url = URL(string: "https://fonts.google.com/metadata/fonts")!
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data else { finish([]); return }
                // The endpoint prefixes JSON with an anti-JSONP guard.
                var text = String(decoding: data, as: UTF8.self)
                if let brace = text.firstIndex(of: "{") { text = String(text[brace...]) }
                guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      let list = object["familyMetadataList"] as? [[String: Any]]
                else { finish([]); return }
                let families = list.compactMap { entry -> Family? in
                    guard let name = entry["family"] as? String else { return nil }
                    let fonts = entry["fonts"] as? [String: Any] ?? [:]
                    let weights = fonts.keys.compactMap { Int($0) }.sorted()
                    return Family(
                        family: name,
                        category: ((entry["category"] as? String) ?? "sans-serif").lowercased(),
                        popularity: entry["popularity"] as? Int ?? 9999,
                        weights: weights.isEmpty ? [400] : weights
                    )
                }
                .sorted { $0.popularity < $1.popularity }
                try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                try? JSONEncoder().encode(families).write(to: diskURL)
                finish(families)
            }.resume()
        }
    }

    // MARK: URLs

    /// The weights worth shipping: the usual design range, limited to what
    /// the family actually has (css2 rejects unavailable weights).
    public static func shippedWeights(for family: Family) -> [Int] {
        let preferred = [400, 500, 600, 700].filter { family.weights.contains($0) }
        return preferred.isEmpty ? [family.weights.first ?? 400] : preferred
    }

    /// css2 query fragment, e.g. "Playfair+Display:wght@400;600;700".
    public static func query(for family: Family) -> String {
        let name = family.family.replacingOccurrences(of: " ", with: "+")
        let weights = shippedWeights(for: family).map(String.init).joined(separator: ";")
        return "\(name):wght@\(weights)"
    }

    public static func cssURL(for family: Family) -> String {
        "https://fonts.googleapis.com/css2?family=\(query(for: family))&display=swap"
    }

    public static func genericFallback(_ category: String) -> String {
        switch category {
        case "serif": return "serif"
        case "monospace": return "monospace"
        case "handwriting": return "cursive"
        default: return "sans-serif"
        }
    }

    // MARK: Native preview registration

    /// Downloads (once, cached on disk) and registers the family with
    /// CoreText so SwiftUI can render it via Font.custom.
    public static func registerForPreview(_ family: Family, _ completion: @escaping (Bool) -> Void) {
        let key = family.family
        if registered.contains(key) {
            completion(true)
            return
        }
        if waiters[key] != nil {
            waiters[key]?.append(completion)
            return
        }
        waiters[key] = [completion]

        func finish(_ ok: Bool) {
            DispatchQueue.main.async {
                if ok { registered.insert(key) }
                waiters.removeValue(forKey: key)?.forEach { $0(ok) }
            }
        }

        let fileURL = cacheDir.appendingPathComponent(
            key.replacingOccurrences(of: " ", with: "_") + ".ttf"
        )
        DispatchQueue.global(qos: .utility).async {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                CTFontManagerRegisterFontsForURL(fileURL as CFURL, .process, nil)
                finish(true)
                return
            }
            // An unrecognized user agent makes Google serve TrueType files,
            // which CoreText registers everywhere.
            var request = URLRequest(url: URL(string: cssURL(for: family))!)
            request.setValue("Tim/0.3 (font preview)", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: request) { data, _, _ in
                guard let data,
                      let fontURL = firstFontURL(in: String(decoding: data, as: UTF8.self))
                else { finish(false); return }
                URLSession.shared.dataTask(with: fontURL) { fontData, _, _ in
                    guard let fontData else { finish(false); return }
                    try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                    do {
                        try fontData.write(to: fileURL)
                        CTFontManagerRegisterFontsForURL(fileURL as CFURL, .process, nil)
                        finish(true)
                    } catch {
                        finish(false)
                    }
                }.resume()
            }.resume()
        }
    }

    static func firstFontURL(in css: String) -> URL? {
        var search = css.startIndex
        while let start = css.range(of: "url(", range: search..<css.endIndex) {
            guard let end = css.range(of: ")", range: start.upperBound..<css.endIndex) else { return nil }
            let candidate = String(css[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            if candidate.hasSuffix(".ttf") || candidate.hasSuffix(".otf"),
               let url = URL(string: candidate) {
                return url
            }
            search = end.upperBound
        }
        return nil
    }
}
