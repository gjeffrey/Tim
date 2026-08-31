import Foundation

/// How an icon was made — so it can be reopened and edited, not rebuilt.
public struct IconRecipe: Codable, Equatable {
    public var text: String = "T"
    public var fontFamily: String = ""       // "" = system
    public var textColorHex: String = ""     // "" = auto contrast
    public var backgroundHex: String = "#FEED00"
    public var backgroundEndHex: String = "" // "" = solid; set = gradient
    public var imageBased: Bool = false      // built from a picked image
    public init() {}
}

/// The site manifest: tim.json at the site root. Machine-readable state
/// that should follow the site across Macs — recipes today, more later.
/// The mirror copy is the cache; per-section stamps make staleness
/// granular; freshness is one cheap fetch per site per session.
public struct SiteManifest: Codable {
    public var version: Int = 1
    public var updated: Date = Date()
    public var iconRecipesUpdated: Date = Date()
    public var iconRecipes: [String: IconRecipe] = [:]   // keyed by page rel path

    public init() {}

    static let coderDate = ISO8601DateFormatter()

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public static func path(inMirror folder: String) -> String {
        (folder as NSString).appendingPathComponent("tim.json")
    }

    public static func load(fromMirror folder: String) -> SiteManifest {
        guard !folder.isEmpty,
              let data = FileManager.default.contents(atPath: path(inMirror: folder)),
              let manifest = try? decoder().decode(SiteManifest.self, from: data)
        else { return SiteManifest() }
        return manifest
    }

    @discardableResult
    public mutating func save(toMirror folder: String) -> String? {
        updated = Date()
        guard let data = try? Self.encoder().encode(self) else { return nil }
        try? data.write(to: URL(fileURLWithPath: Self.path(inMirror: folder)))
        return String(data: data, encoding: .utf8)
    }

    // MARK: Freshness — pull the server copy if it's newer, once per
    // site per app session.
    private static var refreshedSites = Set<UUID>()

    public static func refreshIfStale(site: Site) {
        guard site.origin.hasPrefix("http"),
              !site.localProjectPath.isEmpty,
              !refreshedSites.contains(site.id),
              let url = URL(string: site.origin + "/tim.json")
        else { return }
        refreshedSites.insert(site.id)
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let data,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let remote = try? decoder().decode(SiteManifest.self, from: data)
            else { return }
            let local = load(fromMirror: site.localProjectPath)
            if remote.updated > local.updated {
                try? data.write(to: URL(fileURLWithPath: path(inMirror: site.localProjectPath)))
            }
        }.resume()
    }
}
