import Foundation

/// The fonts a site already uses — surfaced first in every font picker,
/// and prewarmed when the site opens. Sources: the theme stylesheet's
/// Google imports (syncs via the mirror), icon recipes in the manifest,
/// and the current page's font links.
public enum SiteFonts {
    public static func used(site: Site?, pageFonts: [String]) -> [String] {
        var names = pageFonts
        if let site, !site.localProjectPath.isEmpty {
            for cssPath in [
                (site.localProjectPath as NSString).appendingPathComponent("public/tim-theme.css"),
                (site.localProjectPath as NSString).appendingPathComponent("tim-theme.css")
            ] {
                if let css = try? String(contentsOfFile: cssPath, encoding: .utf8) {
                    names += googleFamilies(inCSS: css)
                }
            }
            var manifest = SiteManifest.load(fromMirror: site.localProjectPath)
            // The manifest's cached list is the workhorse: every family the
            // site has ever used, accumulated on Done and synced via tim.json.
            // An empty cache (older site, fresh mirror) backfills once from
            // the mirror's pages, so pinning works before the next Done.
            if manifest.fonts.isEmpty, !backfilled.contains(site.localProjectPath) {
                backfilled.insert(site.localProjectPath)
                if manifest.noteFonts(familiesInMirror(site.localProjectPath)) {
                    _ = manifest.save(toMirror: site.localProjectPath)
                }
            }
            names += manifest.fonts
            names += manifest.iconRecipes.values.map(\.fontFamily).filter { !$0.isEmpty }
        }
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static var backfilled = Set<String>()

    /// Every family declared by any page in the mirror.
    static func familiesInMirror(_ folder: String) -> [String] {
        guard let subpaths = try? FileManager.default.subpathsOfDirectory(atPath: folder) else { return [] }
        var out: [String] = []
        for rel in subpaths where rel.hasSuffix(".html") && !rel.contains(".git") && !rel.contains("node_modules") {
            if let html = try? String(contentsOfFile: (folder as NSString).appendingPathComponent(rel), encoding: .utf8) {
                out += families(inPageHTML: html)
            }
        }
        return out
    }

    /// Families a page declares via its data-tim-font links.
    public static func families(inPageHTML html: String) -> [String] {
        var out: [String] = []
        var search = html.startIndex
        while let r = html.range(of: "data-tim-font=\"", range: search..<html.endIndex) {
            guard let end = html.range(of: "\"", range: r.upperBound..<html.endIndex) else { break }
            out.append(String(html[r.upperBound..<end.lowerBound]))
            search = end.upperBound
        }
        return out
    }

    static func googleFamilies(inCSS css: String) -> [String] {
        var out: [String] = []
        var search = css.startIndex
        while let range = css.range(of: "family=", range: search..<css.endIndex) {
            var end = range.upperBound
            while end < css.endIndex, !":&'\")".contains(css[end]) {
                end = css.index(after: end)
            }
            let raw = String(css[range.upperBound..<end]).replacingOccurrences(of: "+", with: " ")
            if !raw.isEmpty { out.append(raw) }
            search = end
        }
        return out
    }
}
