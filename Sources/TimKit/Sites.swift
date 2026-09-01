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

    // Crawler permissions (expressed as robots.txt; honor-system).
    public var allowSearchEngines: Bool = true
    public var allowAICrawlers: Bool = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case id, name, origin, target, host, username, port, remoteRoot, cfProjectName, localProjectPath
        case allowSearchEngines, allowAICrawlers
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
        allowSearchEngines = try c.decodeIfPresent(Bool.self, forKey: .allowSearchEngines) ?? true
        allowAICrawlers = try c.decodeIfPresent(Bool.self, forKey: .allowAICrawlers) ?? true
    }

    /// The Worker name a Cloudflare-API site deploys as: the custom
    /// project name when set, else a slug of the origin.
    public var cfScriptName: String {
        if !cfProjectName.isEmpty { return cfProjectName }
        let slug = origin
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "tim-" + (trimmed.isEmpty ? "site" : String(trimmed.prefix(50)))
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
              let scheme = url.scheme?.lowercased(),
              scheme == originScheme,
              Site.hostsMatch(url.host(), originURL.host()),
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

    /// The same site answers with and without www — one host, two spellings.
    public static func hostsMatch(_ a: String?, _ b: String?) -> Bool {
        func canonical(_ host: String?) -> String? {
            guard let host = host?.lowercased() else { return nil }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        guard let ca = canonical(a), let cb = canonical(b) else { return false }
        return ca == cb
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

/// Every site gets a Tim-managed local mirror — the folder new pages are
/// written to, published edits are cached in, and remote sites can be
/// downloaded into. Lives visibly at ~/Tim/<site name>.
public enum SiteWorkspace {
    public static func defaultFolder(for name: String) -> String {
        let slug = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return NSHomeDirectory() + "/Tim/" + (slug.isEmpty ? "site" : slug)
    }

    @discardableResult
    public static func ensure(_ folder: String) -> Bool {
        (try? FileManager.default.createDirectory(
            atPath: folder, withIntermediateDirectories: true
        )) != nil
    }

    /// No home page yet — the next page created should be index.html.
    public static func needsHomePage(_ folder: String) -> Bool {
        guard !folder.isEmpty else { return true }
        return !FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent("index.html"))
    }

    #if os(macOS)
    public struct PageVersion: Identifiable {
        public var id: String { sha }
        public let sha: String
        public let date: Date
    }

    /// The invisible git history of one page, newest first.
    public static func versions(of relPath: String, in folder: String) -> [PageVersion] {
        guard let output = try? Shell.run(
            "git log --format='%h|%at' -- \(Shell.quoted(relPath))",
            in: folder
        ) else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let timestamp = TimeInterval(parts[1]) else { return nil }
            return PageVersion(sha: String(parts[0]), date: Date(timeIntervalSince1970: timestamp))
        }
    }

    /// Latest commit touching one page — pairs saves with their thumbnails.
    public static func latestSha(of relPath: String, in folder: String) -> String? {
        guard let output = try? Shell.run(
            "git log -1 --format=%h -- \(Shell.quoted(relPath))",
            in: folder
        ) else { return nil }
        let sha = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// Restores one page file to a previous version (working tree only —
    /// the caller republishes and snapshots).
    public static func restore(_ relPath: String, to sha: String, in folder: String) throws {
        _ = try Shell.run("git checkout \(sha) -- \(Shell.quoted(relPath))", in: folder)
    }

    /// Invisible history: every mirror is quietly a git repo, committed on
    /// each publish. Never surfaced in UI — it's the undo layer that later
    /// powers page versions and conflict handling.
    public static func snapshot(_ folder: String, message: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder) else { return }
        let gitDir = (folder as NSString).appendingPathComponent(".git")
        if !fm.fileExists(atPath: gitDir) {
            _ = try? Shell.run("git init -q", in: folder)
            let ignorePath = (folder as NSString).appendingPathComponent(".gitignore")
            if !fm.fileExists(atPath: ignorePath) {
                try? "node_modules/\ndist/\n.DS_Store\n".write(toFile: ignorePath, atomically: true, encoding: .utf8)
            }
        }
        _ = try? Shell.run(
            "git add -A && (git diff --cached --quiet || git commit -q -m \(Shell.quoted(message)))",
            in: folder
        )
    }
    #endif
}

public final class SiteStore: ObservableObject {
    @Published public var sites: [Site] = [] {
        didSet { persist() }
    }

    private static let defaultsKey = "tim.sites.v1"
    private static let stampKey = "tim.sites.updated"
    private var observer: NSObjectProtocol?

    public init() {
        // iCloud carries the site list between Macs (and one day iPads):
        // the newer copy wins, and everything degrades gracefully to
        // UserDefaults when the app isn't signed for iCloud. Connection
        // details are addresses, not secrets — SSH keys stay in ~/.ssh
        // and never ride along.
        let cloud = NSUbiquitousKeyValueStore.default
        cloud.synchronize()
        let localStamp = UserDefaults.standard.double(forKey: Self.stampKey)
        let cloudStamp = cloud.double(forKey: Self.stampKey)
        let data = (cloudStamp > localStamp ? cloud.data(forKey: Self.defaultsKey) : nil)
            ?? UserDefaults.standard.data(forKey: Self.defaultsKey)
        if let data, let decoded = try? JSONDecoder().decode([Site].self, from: data) {
            sites = decoded
        }
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let remoteStamp = cloud.double(forKey: Self.stampKey)
            guard remoteStamp > UserDefaults.standard.double(forKey: Self.stampKey),
                  let remote = cloud.data(forKey: Self.defaultsKey),
                  let decoded = try? JSONDecoder().decode([Site].self, from: remote)
            else { return }
            self.sites = decoded
        }
    }

    public func match(_ url: URL?) -> Site? {
        guard let url else { return nil }
        return sites.first { $0.matches(url) }
    }

    /// Credentials belong to the server, not the folder. When a URL lives
    /// on a host we already publish to over SFTP but outside every
    /// connected site, derive a sibling site for its top-level folder:
    /// same credentials, remote root mapped through the shared docroot
    /// (an origin of …/tim rooted at /home/u/site.com/tim means /timtest
    /// lives at /home/u/site.com/timtest). Returned unsaved — it becomes
    /// a real connection the first time it's actually edited.
    public func derivedSite(for url: URL) -> Site? {
        guard match(url) == nil, !url.isFileURL,
              let scheme = url.scheme?.lowercased(),
              let host = url.host()?.lowercased()
        else { return nil }
        for site in sites where site.target == .sftp && !site.remoteRoot.isEmpty {
            guard let originURL = URL(string: site.origin),
                  originURL.scheme?.lowercased() == scheme,
                  Site.hostsMatch(host, originURL.host()),
                  url.port == originURL.port
            else { continue }
            let originPath = (originURL.path.isEmpty || originURL.path == "/") ? "" : originURL.path
            let root = site.remoteRoot.hasSuffix("/") ? String(site.remoteRoot.dropLast()) : site.remoteRoot
            guard originPath.isEmpty || root.hasSuffix(originPath) else { continue }
            let docroot = originPath.isEmpty ? root : String(root.dropLast(originPath.count))
            let first = url.path.split(separator: "/").first.map(String.init) ?? ""
            // A file at the domain root belongs to a site at the domain root.
            let base = (first.isEmpty || first.contains(".")) ? "" : "/" + first
            // Canonical host (no www): both spellings derive the same site.
            let canonicalHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            var derived = Site()
            derived.name = canonicalHost + base
            derived.origin = scheme + "://" + canonicalHost + base
            derived.target = .sftp
            derived.host = site.host
            derived.username = site.username
            derived.port = site.port
            derived.remoteRoot = docroot + base
            derived.localProjectPath = SiteWorkspace.defaultFolder(for: derived.name)
            return derived
        }
        return nil
    }

    /// Editing is a publishing act: pages under a connected site, local
    /// files — and any Tim-authored page on a server we can write to.
    public func isEditable(_ url: URL?, timAuthored: Bool = false) -> Bool {
        guard let url else { return false }
        if url.isFileURL || match(url) != nil { return true }
        return timAuthored && derivedSite(for: url) != nil
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
        guard let data = try? JSONEncoder().encode(sites) else { return }
        let stamp = Date().timeIntervalSince1970
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        UserDefaults.standard.set(stamp, forKey: Self.stampKey)
        let cloud = NSUbiquitousKeyValueStore.default
        cloud.set(data, forKey: Self.defaultsKey)
        cloud.set(stamp, forKey: Self.stampKey)
        cloud.synchronize()
    }
}
