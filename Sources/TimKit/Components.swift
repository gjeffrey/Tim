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

    /// A component that belongs on every page has to be VISIBLE on every
    /// page. Pages differ: the rows a nav occupies may be empty on one and
    /// hold a hero photograph on another, and that photograph may carry a
    /// z-index of its own. So the injected copy lands above whatever the
    /// page already stacks, rather than behind it — which reads, exactly
    /// and wrongly, as the component never having been added.
    static func raised(_ stamped: String, above pageHTML: String) -> String {
        // Only what objects themselves stack by — an inline style. A
        // stylesheet's own z-index (NavKit's menu panel sits at 60) says
        // nothing about how the page's objects are ordered.
        var top = 0
        if let re = try? NSRegularExpression(pattern: "style=\"([^\"]*)\"") {
            for match in re.matches(in: pageHTML, range: NSRange(pageHTML.startIndex..., in: pageHTML)) {
                guard let r = Range(match.range(at: 1), in: pageHTML) else { continue }
                let style = String(pageHTML[r])
                guard let zr = style.range(of: "z-index:\\s*(-?[0-9]+)", options: .regularExpression),
                      let value = Int(style[zr].replacingOccurrences(of: "z-index:", with: "").trimmingCharacters(in: .whitespaces))
                else { continue }
                top = max(top, value)
            }
        }
        // The wrapper is display:contents — the element inside it is what
        // actually stacks, so that is the one to raise.
        guard let wrapperEnd = stamped.range(of: "display:contents\">", options: .literal),
              let tagStart = stamped.range(of: "<", range: wrapperEnd.upperBound..<stamped.endIndex),
              let tagEnd = stamped.range(of: ">", range: tagStart.upperBound..<stamped.endIndex)
        else { return stamped }

        var tag = String(stamped[tagStart.lowerBound..<tagEnd.upperBound])
        let z = "z-index: \(top + 1)"
        if let styleAttr = tag.range(of: "style=\""),
           let styleEnd = tag.range(of: "\"", range: styleAttr.upperBound..<tag.endIndex) {
            var style = String(tag[styleAttr.upperBound..<styleEnd.lowerBound])
            style = style.replacingOccurrences(of: "z-index:\\s*-?[0-9]+;?\\s*", with: "", options: .regularExpression)
            if !style.isEmpty, !style.hasSuffix(";") { style += ";" }
            style += " \(z);"
            tag.replaceSubrange(styleAttr.upperBound..<styleEnd.lowerBound, with: style)
        } else {
            let selfClosing = tag.hasSuffix("/>")
            let insertAt = tag.index(tag.endIndex, offsetBy: selfClosing ? -2 : -1)
            tag.insert(contentsOf: " style=\"\(z)\"", at: insertAt)
        }
        var out = stamped
        out.replaceSubrange(tagStart.lowerBound..<tagEnd.upperBound, with: tag)
        return out
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
            let inner = String(html[region.inner])
            // An empty region is a husk, not an edit — harvesting it would
            // blank the master and wipe the component from every page. And
            // a copy this page owns is this page's business, not the site's.
            if !inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !ownsItsCopy(html, name) {
                out[name] = inner
            }
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

    /// A page may keep its OWN copy of a shared object: marked
    /// data-tim-own, the master stops overwriting it and its edits stop
    /// becoming the master. Everything else still follows the master, so
    /// the common case — change the nav once, everywhere — is unchanged.
    static func ownsItsCopy(_ pageHTML: String, _ name: String) -> Bool {
        guard let attr = pageHTML.range(of: "data-tim-component=\"\(name)\""),
              let tagEnd = pageHTML.range(of: ">", range: attr.upperBound..<pageHTML.endIndex)
        else { return false }
        return pageHTML[attr.upperBound..<tagEnd.lowerBound].contains("data-tim-own")
    }

    /// Is this shared object on the page at all?
    public static func present(_ pageHTML: String, _ name: String) -> Bool {
        pageHTML.contains("data-tim-component=\"\(name)\"")
    }

    /// Every shared object a site has, with a readable name.
    public static func shared(in folder: String) -> [(name: String, label: String)] {
        list(in: folder).filter { $0.hasPrefix("tpl-") }.map { name in
            let content = html(named: name, in: folder) ?? ""
            let label: String
            if content.contains("tim-nav") { label = "Navigation" }
            else if content.contains("<header") { label = "Header" }
            else if content.contains("<footer") { label = "Footer" }
            else { label = "Shared object" }
            return (name, label)
        }
    }

    /// Deleting a template component on a page marks the page's body with
    /// data-tim-omit="name …" — the page keeps its opt-out across Dones.
    static func omits(_ pageHTML: String, _ name: String) -> Bool {
        guard let attr = pageHTML.range(of: "data-tim-omit=\""),
              let end = pageHTML.range(of: "\"", range: attr.upperBound..<pageHTML.endIndex)
        else { return false }
        return pageHTML[attr.upperBound..<end.lowerBound]
            .split(separator: " ").map(String.init).contains(name)
    }

    /// Template components (tpl-*) belong on every page: this injects any
    /// missing ones right after each page's canvas opening tag — objects
    /// carry explicit grid positions, so they land in the same place
    /// everywhere. Returns the pages that changed.
    public static func injectTemplateComponents(in folder: String, excludingRel: String?) -> [String] {
        let names = list(in: folder).filter { $0.hasPrefix("tpl-") }
        guard !names.isEmpty,
              let subpaths = try? FileManager.default.subpathsOfDirectory(atPath: folder)
        else { return [] }
        var changed: [String] = []
        for rel in subpaths {
            guard rel.hasSuffix(".html"), !rel.hasPrefix("components/"),
                  !rel.hasPrefix("_h/"), !rel.hasPrefix("_hidden/"),
                  !rel.contains(".git"), !rel.contains("node_modules"),
                  rel != excludingRel
            else { continue }
            let path = (folder as NSString).appendingPathComponent(rel)
            guard var pageHTML = try? String(contentsOfFile: path, encoding: .utf8),
                  let canvasAttr = pageHTML.range(of: "data-tim-canvas")
            else { continue }
            var pageChanged = false
            for name in names where !pageHTML.contains("data-tim-component=\"\(name)\"") {
                // A page that deleted this component opted out — respect it.
                guard !omits(pageHTML, name) else { continue }
                guard let content = html(named: name, in: folder),
                      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let tagEnd = pageHTML.range(of: ">", range: canvasAttr.upperBound..<pageHTML.endIndex)
                else { continue }
                pageHTML.insert(contentsOf: "\n" + raised(stamped(name: name, content: content), above: pageHTML),
                                at: tagEnd.upperBound)
                pageChanged = true
            }
            if pageChanged {
                try? pageHTML.write(toFile: path, atomically: true, encoding: .utf8)
                changed.append(rel)
            }
        }
        return changed
    }

    /// Site icons: the favicon and app icon are site-level by default —
    /// stored in the manifest, stamped onto every page on Done. A page
    /// that claimed its own (body[data-tim-own-icons]) is passed by.
    public enum PageIcons {
        public static func stampAll(in folder: String, favicon: String, touchIcon: String, excludingRel: String?) -> [String] {
            guard !favicon.isEmpty || !touchIcon.isEmpty,
                  let subpaths = try? FileManager.default.subpathsOfDirectory(atPath: folder)
            else { return [] }
            var changed: [String] = []
            for rel in subpaths {
                guard rel.hasSuffix(".html"), !rel.hasPrefix("components/"),
                      !rel.hasPrefix("_h/"), !rel.hasPrefix("_hidden/"),
                      !rel.contains(".git"), !rel.contains("node_modules"),
                      rel != excludingRel
                else { continue }
                let path = (folder as NSString).appendingPathComponent(rel)
                guard var html = try? String(contentsOfFile: path, encoding: .utf8),
                      !html.contains("data-tim-own-icons"),
                      html.contains("</head>")
                else { continue }
                // Hrefs are page-depth-relative so they hold under any base path.
                let depth = max(0, rel.split(separator: "/").count - 1)
                let prefix = String(repeating: "../", count: depth)
                var pageChanged = false
                if !favicon.isEmpty { pageChanged = upsertLink(&html, rel: "icon", href: prefix + favicon) || pageChanged }
                if !touchIcon.isEmpty { pageChanged = upsertLink(&html, rel: "apple-touch-icon", href: prefix + touchIcon) || pageChanged }
                if pageChanged {
                    try? html.write(toFile: path, atomically: true, encoding: .utf8)
                    changed.append(rel)
                }
            }
            return changed
        }

        static func upsertLink(_ html: inout String, rel: String, href: String) -> Bool {
            let tag = "<link rel=\"\(rel)\" href=\"\(href)\">"
            if let range = html.range(of: "<link[^>]*rel=\"\(rel)\"[^>]*>", options: .regularExpression) {
                if html[range] == tag { return false }
                html.replaceSubrange(range, with: tag)
                return true
            }
            guard let head = html.range(of: "</head>") else { return false }
            html.insert(contentsOf: tag + "\n", at: head.lowerBound)
            return true
        }
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
                guard !ownsItsCopy(pageHTML, name),
                      let content = html(named: name, in: folder),
                      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
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
