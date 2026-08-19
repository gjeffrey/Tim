import Foundation

/// Reusable components for plain sites — nav, header, footer. Each is an
/// HTML fragment in the mirror's components/ folder; pages carry stamped
/// copies inside `<div data-tim-component="name" style="display:contents">`
/// regions, so published pages stay self-contained flat HTML. Tim is the
/// build step: editing a component inline on any page updates the master
/// fragment and re-stamps every page that includes it.
public enum PageComponents {
    static func dir(_ folder: String) -> String {
        (folder as NSString).appendingPathComponent("components")
    }

    public static func list(in folder: String) -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir(folder)) else { return [] }
        return files.filter { $0.hasSuffix(".html") }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
    }

    public static func html(named name: String, in folder: String) -> String? {
        try? String(contentsOfFile: (dir(folder) as NSString).appendingPathComponent(name + ".html"), encoding: .utf8)
    }

    public static func save(name: String, html: String, in folder: String) throws {
        try FileManager.default.createDirectory(atPath: dir(folder), withIntermediateDirectories: true)
        try html.write(
            toFile: (dir(folder) as NSString).appendingPathComponent(name + ".html"),
            atomically: true, encoding: .utf8
        )
    }

    public static func stamped(name: String, content: String) -> String {
        "<div data-tim-component=\"\(name)\" style=\"display:contents\">\(content)</div>"
    }

    /// Component regions found in page HTML: [name: innerHTML].
    public static func harvest(fromPageHTML html: String) -> [String: String] {
        var out: [String: String] = [:]
        var search = html.startIndex
        while let attr = html.range(of: "data-tim-component=\"", range: search..<html.endIndex) {
            guard let nameEnd = html.range(of: "\"", range: attr.upperBound..<html.endIndex),
                  let region = regionBounds(in: html, attrEnd: nameEnd.upperBound)
            else { break }
            let name = String(html[attr.upperBound..<nameEnd.lowerBound])
            out[name] = String(html[region.inner])
            search = region.outerEnd
        }
        return out
    }

    /// Replaces the region for `name` with fresh content. Nil if absent.
    static func replaceRegion(in html: String, name: String, with content: String) -> String? {
        guard let attr = html.range(of: "data-tim-component=\"\(name)\""),
              let region = regionBounds(in: html, attrEnd: attr.upperBound)
        else { return nil }
        var updated = html
        updated.replaceSubrange(region.inner, with: content)
        return updated
    }

    /// From just past the component attribute, finds the inner range
    /// (between the opening tag's ">" and its matching "</div>").
    private static func regionBounds(
        in html: String, attrEnd: String.Index
    ) -> (inner: Range<String.Index>, outerEnd: String.Index)? {
        guard let tagEnd = html.range(of: ">", range: attrEnd..<html.endIndex) else { return nil }
        var depth = 1
        var i = tagEnd.upperBound
        while i < html.endIndex {
            if html[i...].hasPrefix("<div") {
                depth += 1
                i = html.index(i, offsetBy: 4)
            } else if html[i...].hasPrefix("</div>") {
                depth -= 1
                if depth == 0 {
                    return (tagEnd.upperBound..<i, html.index(i, offsetBy: 6))
                }
                i = html.index(i, offsetBy: 6)
            } else {
                i = html.index(after: i)
            }
        }
        return nil
    }

    /// Re-stamps every page in the mirror with current component content.
    /// Returns the site-relative paths of pages that changed.
    public static func restampAll(in folder: String, excludingRel: String?) -> [String] {
        guard let subpaths = try? FileManager.default.subpathsOfDirectory(atPath: folder) else { return [] }
        let names = list(in: folder)
        guard !names.isEmpty else { return [] }
        var changed: [String] = []
        for rel in subpaths {
            guard rel.hasSuffix(".html"), !rel.hasPrefix("components/"),
                  !rel.contains(".git"), !rel.contains("node_modules"),
                  rel != excludingRel
            else { continue }
            let path = (folder as NSString).appendingPathComponent(rel)
            guard var pageHTML = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            var pageChanged = false
            for name in names {
                guard let content = html(named: name, in: folder),
                      let updated = replaceRegion(in: pageHTML, name: name, with: content),
                      updated != pageHTML
                else { continue }
                pageHTML = updated
                pageChanged = true
            }
            if pageChanged {
                try? pageHTML.write(toFile: path, atomically: true, encoding: .utf8)
                changed.append(rel)
            }
        }
        return changed
    }
}
