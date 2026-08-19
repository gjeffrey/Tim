import Foundation

public enum PublishTarget: String, Codable, CaseIterable, Identifiable {
    case sftp
    case cloudflare
    case githubPages

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .sftp: return "SFTP"
        case .cloudflare: return "Cloudflare"
        case .githubPages: return "GitHub Pages"
        }
    }

    public var symbol: String {
        switch self {
        case .sftp: return "server.rack"
        case .cloudflare: return "cloud"
        case .githubPages: return "arrow.triangle.branch"
        }
    }
}

/// A site the user owns: a URL origin mapped to a publish destination.
/// This mapping is what makes a browsed page "editable" in Tim.
public struct Site: Codable, Identifiable, Equatable {
    public var id: UUID = UUID()
    public var name: String = ""
    public var origin: String = ""           // e.g. "https://example.com" (may include a base path)
    public var target: PublishTarget = .sftp

    // SFTP
    public var host: String = ""
    public var username: String = ""
    public var port: String = "22"
    public var remoteRoot: String = ""       // e.g. "/var/www/html"

    // Cloudflare
    public var cfProjectName: String = ""    // Pages project name

    // Local folder: the deployed content for Cloudflare, the repo for
    // GitHub Pages, and (later) the framework project for any target.
    public var localProjectPath: String = ""

    public init() {}

    enum CodingKeys: String, CodingKey {
        case id, name, origin, target, host, username, port, remoteRoot, cfProjectName, localProjectPath
    }

    // decodeIfPresent throughout so sites saved by older builds keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        origin = try c.decodeIfPresent(String.self, forKey: .origin) ?? ""
        target = try c.decodeIfPresent(PublishTarget.self, forKey: .target) ?? .sftp
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        port = try c.decodeIfPresent(String.self, forKey: .port) ?? "22"
        remoteRoot = try c.decodeIfPresent(String.self, forKey: .remoteRoot) ?? ""
        cfProjectName = try c.decodeIfPresent(String.self, forKey: .cfProjectName) ?? ""
        localProjectPath = try c.decodeIfPresent(String.self, forKey: .localProjectPath) ?? ""
    }

    /// Does this URL live under the site's origin?
    public func matches(_ url: URL) -> Bool {
        // file:// origins let you browse and edit a local build (e.g. an
        // Astro dist/) before it's deployed anywhere.
        if let originURL = URL(string: origin), originURL.isFileURL || url.isFileURL {
            guard originURL.isFileURL, url.isFileURL else { return false }
            let base = originURL.path.hasSuffix("/") ? String(originURL.path.dropLast()) : originURL.path
            return url.path == base || url.path.hasPrefix(base + "/")
        }
        guard let originURL = URL(string: origin),
              let originScheme = originURL.scheme?.lowercased(),
              let originHost = originURL.host()?.lowercased(),
              let scheme = url.scheme?.lowercased(),
              let host = url.host()?.lowercased(),
              scheme == originScheme,
              host == originHost,
              url.port == originURL.port
        else { return false }

        let base = originURL.path
        if base.isEmpty || base == "/" { return true }
        let path = url.path.isEmpty ? "/" : url.path
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// Maps a page URL to a site-relative file path ("/about/" → "/about/index.html"),
    /// using the static-hosting convention that "/" and extensionless paths
    /// are directory indexes.
    public func relativePagePath(for url: URL) -> String {
        var rel = url.path
        if let originURL = URL(string: origin) {
            let base = originURL.path
            if !base.isEmpty, base != "/", rel.hasPrefix(base) {
                rel.removeFirst(base.count)
            }
        }
        if rel.isEmpty || rel == "/" {
            rel = "/index.html"
        } else if rel.hasSuffix("/") {
            rel += "index.html"
        } else if !(rel as NSString).lastPathComponent.contains(".") {
            rel += "/index.html"
        }
        return rel
    }

    /// Full path on an SFTP server for a page URL.
    public func remotePath(for url: URL) -> String {
        let root = remoteRoot.hasSuffix("/") ? String(remoteRoot.dropLast()) : remoteRoot
        return root + relativePagePath(for: url)
    }

    /// Normalizes user input: adds a scheme if missing (local paths become
    /// file:// origins), drops trailing "/".
    public static func normalizeOrigin(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return value }
        if value.hasPrefix("/") || value.hasPrefix("~") {
            value = "file://" + NSString(string: value).expandingTildeInPath
        } else if !value.contains("://") {
            value = "https://" + value
        }
        while value.hasSuffix("/") { value.removeLast() }
        // File paths are case-sensitive; only web origins get lowercased.
        return value.lowercased().hasPrefix("file://") ? value : value.lowercased()
    }
}

public final class SiteStore: ObservableObject {
    @Published public var sites: [Site] = [] {
        didSet { persist() }
    }

    private static let defaultsKey = "tim.sites.v1"

    public init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([Site].self, from: data) {
            sites = decoded
        }
    }

    public func match(_ url: URL?) -> Site? {
        guard let url else { return nil }
        return sites.first { $0.matches(url) }
    }

    /// Editing is a publishing act: only pages you own are editable —
    /// pages under a connected site, or local files.
    public func isEditable(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.isFileURL || match(url) != nil
    }

    public func upsert(_ site: Site) {
        if let index = sites.firstIndex(where: { $0.id == site.id }) {
            sites[index] = site
        } else {
            sites.append(site)
        }
    }

    public func delete(_ site: Site) {
        sites.removeAll { $0.id == site.id }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(sites) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
