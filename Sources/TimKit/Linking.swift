import Foundation

/// A page Tim has created, saved, or published — so linking to your own
/// work is always one click, on any domain.
public struct PageRecord: Codable, Identifiable, Equatable {
    public var id: String { url }
    public let url: String
    public let title: String
    public let date: Date

    public init(url: String, title: String, date: Date = Date()) {
        self.url = url
        self.title = title
        self.date = date
    }
}

public enum PageRegistry {
    private static let key = "tim.pages.v1"

    public static func record(url: String, title: String) {
        guard !url.isEmpty else { return }
        var all = self.all().filter { $0.url != url }
        all.insert(PageRecord(url: url, title: title.isEmpty ? url : title), at: 0)
        if all.count > 50 { all = Array(all.prefix(50)) }
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    public static func all() -> [PageRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([PageRecord].self, from: data)
        else { return [] }
        return decoded
    }
}

public struct LinkOption: Identifiable, Equatable {
    public var id: String { href }
    public let label: String
    public let href: String

    public init(label: String, href: String) {
        self.label = label
        self.href = href
    }
}

/// Link sources in proximity order: this page's anchors come from the DOM
/// (Tab.pageAnchors); these are the sibling pages — the site's built pages
/// for a connected site, the folder's other .html files for a local page.
public enum LinkSources {
    public static func siblings(pageURL: URL?, site: Site?) -> [LinkOption] {
        guard let pageURL else { return [] }

        if let site, !site.localProjectPath.isEmpty, AstroProject.isAstroProject(site.localProjectPath) {
            let dist = AstroProject.distPath(site.localProjectPath)
            guard let files = try? FileManager.default.subpathsOfDirectory(atPath: dist) else { return [] }
            return files
                .filter { $0.hasSuffix(".html") && !$0.hasPrefix(".") }
                .sorted()
                .compactMap { rel in
                    if pageURL.path.hasSuffix("/" + rel) { return nil }  // not this page
                    var name = (rel as NSString).deletingPathExtension
                    if name == "index" { name = "Home" }
                    name = name.replacingOccurrences(of: "/index", with: "")
                        .replacingOccurrences(of: "-", with: " ")
                    return LinkOption(label: name.capitalized, href: "./" + rel)
                }
        }

        if pageURL.isFileURL {
            let dir = pageURL.deletingLastPathComponent()
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
            return files
                .filter { $0.hasSuffix(".html") && $0 != pageURL.lastPathComponent }
                .sorted()
                .map { LinkOption(label: ($0 as NSString).deletingPathExtension, href: $0) }
        }
        return []
    }

    /// Every page of a connected site, from its mirror (dist/ for Astro).
    public static func pages(for site: Site) -> [LinkOption] {
        let root = AstroProject.isAstroProject(site.localProjectPath)
            ? AstroProject.distPath(site.localProjectPath)
            : site.localProjectPath
        guard !root.isEmpty,
              let subpaths = try? FileManager.default.subpathsOfDirectory(atPath: root)
        else { return [] }
        return subpaths
            .filter {
                $0.hasSuffix(".html") && !$0.hasPrefix(".")
                    && !$0.contains(".git") && !$0.contains("node_modules")
            }
            .sorted()
            .map { rel in
                var name = (rel as NSString).deletingPathExtension
                if name == "index" { name = "Home" }
                name = name.replacingOccurrences(of: "/index", with: "")
                    .replacingOccurrences(of: "-", with: " ")
                return LinkOption(label: name.capitalized, href: "/" + rel)
            }
    }

    /// Pages you've made elsewhere — everything in the registry that isn't
    /// on the current page's origin (those are already covered above).
    public static func yourPages(excluding pageURL: URL?) -> [LinkOption] {
        let currentHost = pageURL?.host()?.lowercased()
        return PageRegistry.all().compactMap { record in
            guard let url = URL(string: record.url) else { return nil }
            if let currentHost, url.host()?.lowercased() == currentHost { return nil }
            if let pageURL, url.isFileURL, pageURL.isFileURL,
               url.deletingLastPathComponent().path == pageURL.deletingLastPathComponent().path {
                return nil  // same folder — already a sibling
            }
            return LinkOption(label: record.title, href: record.url)
        }
    }

    /// Pasted-text fallback: make a reasonable href out of whatever it is.
    public static func normalize(_ input: String) -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        if value.hasPrefix("#") || value.hasPrefix("/") || value.hasPrefix("./")
            || value.hasPrefix("../") || value.contains("://") || value.hasPrefix("mailto:") {
            return value
        }
        if value.hasSuffix(".html") { return value }
        if value.contains("."), !value.contains(" ") { return "https://" + value }
        return value
    }
}
