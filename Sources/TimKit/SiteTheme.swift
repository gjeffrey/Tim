import Foundation

/// The site's look, kept in step across its pages.
///
/// A Tim page carries its whole design in its <head>: the canvas styles
/// and named text styles (style[data-tim-styles]); the templates — sets of
/// page options keyed by body[data-tim-template] (style[data-tim-templates]);
/// the author's edits to named styles (style[data-tim-style-overrides]);
/// and the font links (link[data-tim-font]). New pages copy that head from
/// a sibling, so a site's look has always travelled forward. It never
/// travelled back: change the title font on one page and every other page
/// kept the old one — while Page Options promised "every page on this
/// template follows."
///
/// This pass keeps that promise. On Done, the page just saved becomes the
/// site's word on those four things, and they are written into every other
/// Tim page in the site — the way shared objects already propagate.
/// Templates and named styles merge by name (the saved page wins; a
/// template or style only another page has is kept), so no page loses what
/// it alone uses. A page that keeps its own look (body[data-tim-own-theme])
/// is passed by in both directions.
public enum SiteTheme {
    public struct Blocks {
        /// The whole <style data-tim-styles…>…</style> element.
        public var styles: String
        /// Template name → its options, as the editor stores them.
        public var templates: [String: [String: Any]]
        /// Named style class → its declarations.
        public var overrides: [String: String]
        /// Font family → its <link> element.
        public var fonts: [(family: String, tag: String)]
    }

    /// A page whose head is Tim's to manage: a canvas page Tim wrote — not
    /// a strip added to someone else's page — that hasn't opted out.
    public static func eligible(_ html: String) -> Bool {
        html.contains("data-tim-canvas")
            && html.range(of: "<style data-tim-styles[^>]*>", options: .regularExpression) != nil
            && !html.contains("tim-band")
            && !html.contains("data-tim-own-theme")
    }

    public static func blocks(in html: String) -> Blocks? {
        guard let styles = firstMatch(in: html, "<style data-tim-styles[^>]*>[\\s\\S]*?</style>") else { return nil }
        return Blocks(
            styles: styles,
            templates: templates(in: html),
            overrides: overrides(in: html),
            fonts: fontLinks(in: html)
        )
    }

    // MARK: Reading

    public static func templates(in html: String) -> [String: [String: Any]] {
        guard let tag = firstMatch(in: html, "<style[^>]*data-tim-templates[^>]*>"),
              let raw = capture(tag, "data-props=\"([^\"]*)\"") ?? capture(tag, "data-props='([^']*)'")
        else { return [:] }
        let json = raw
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return [:] }
        return dict
    }

    public static func overrides(in html: String) -> [String: String] {
        guard let block = firstMatch(in: html, "<style[^>]*data-tim-style-overrides[^>]*>[\\s\\S]*?</style>"),
              let regex = try? NSRegularExpression(pattern: "\\.(tim-style-[a-z]+)\\s*\\{([^}]*)\\}")
        else { return [:] }
        var out: [String: String] = [:]
        for m in regex.matches(in: block, range: NSRange(block.startIndex..., in: block)) {
            guard let c = Range(m.range(at: 1), in: block), let d = Range(m.range(at: 2), in: block) else { continue }
            out[String(block[c])] = String(block[d])
        }
        return out
    }

    public static func fontLinks(in html: String) -> [(family: String, tag: String)] {
        guard let regex = try? NSRegularExpression(pattern: "<link[^>]*data-tim-font=\"([^\"]*)\"[^>]*>") else { return [] }
        var out: [(String, String)] = []
        for m in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let f = Range(m.range(at: 1), in: html), let t = Range(m.range, in: html) else { continue }
            out.append((String(html[f]), String(html[t])))
        }
        return out
    }

    // MARK: Writing

    /// The templates stylesheet, rendered exactly as the editor renders it
    /// (writeTemplates in the canvas engine) — so a block written here and
    /// one the editor rewrites a moment later are the same block.
    public static func templatesCSS(_ props: [String: [String: Any]]) -> String {
        var out = ""
        for name in props.keys.sorted() {
            let p = props[name] ?? [:]
            let scope = "body[data-tim-template=\"\(name)\"]"
            var bodyRule = ""
            if let bg = str(p["bg"]) { bodyRule += "background:\(bg);" }
            if let fg = str(p["fg"]) { bodyRule += "color:\(fg);--tim-ink:\(fg);" }
            if let link = str(p["link"]) { bodyRule += "--tim-link:\(link);" }
            if let accent = str(p["accent"]) { bodyRule += "--tim-accent:\(accent);" }
            if let hf = str(p["headingFont"]) { bodyRule += "--tim-font-heading:\(hf);" }
            if let bf = str(p["bodyFont"]) { bodyRule += "--tim-font-body:\(bf);font-family:\(bf);" }
            if !bodyRule.isEmpty { out += "\(scope){\(bodyRule)}\n" }
            if let link = str(p["link"]) { out += "\(scope) a{color:\(link);}\n" }
            if let hf = str(p["headingFont"]) { out += "\(scope) .tim-style-title,\(scope) .tim-style-heading{font-family:\(hf);}\n" }
            if let base = num(p["baseSize"]) { out += "html:has(\(scope)){font-size:\(base)px;}\n" }
            if p["padY"] != nil || p["marginX"] != nil || p["contentW"] != nil {
                let pad = num(p["padY"]) ?? "48"
                let mx = num(p["marginX"]) ?? "32"
                let cw = (numValue(p["contentW"]) ?? 1320) / 2
                out += "\(scope) .tim-canvas{padding:\(pad)px max(\(mx)px, calc(50vw - \(fmt(cw))px));}\n"
            }
        }
        return out
    }

    public static func templatesBlock(_ props: [String: [String: Any]]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: props, options: [.sortedKeys])) ?? Data("{}".utf8)
        let json = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return "<style data-tim-templates data-props=\"\(json)\">\n\(templatesCSS(props))</style>"
    }

    public static func overridesBlock(_ rules: [String: String]) -> String {
        var out = ""
        for cls in rules.keys.sorted() { out += ".\(cls){\(rules[cls] ?? "")}\n" }
        return "<style data-tim-style-overrides>\(out)</style>"
    }

    /// Writes `blocks` into a page. Nil when the page already agrees.
    public static func applying(_ blocks: Blocks, to html: String) -> String? {
        var out = html
        var changed = false

        // Canvas + named styles: the saved page's block, wholesale.
        if let r = out.range(of: "<style data-tim-styles[^>]*>[\\s\\S]*?</style>", options: .regularExpression),
           out[r] != blocks.styles {
            out.replaceSubrange(r, with: blocks.styles)
            changed = true
        }

        // Templates: merge by name — the saved page's win, the rest stay.
        var merged = templates(in: out)
        for (name, props) in blocks.templates { merged[name] = props }
        if !merged.isEmpty, !same(merged, templates(in: out)) || !hasTag(out, "data-tim-templates") {
            let block = templatesBlock(merged)
            if let r = out.range(of: "<style[^>]*data-tim-templates[^>]*>[\\s\\S]*?</style>", options: .regularExpression) {
                if out[r] != block { out.replaceSubrange(r, with: block); changed = true }
            } else if let head = out.range(of: "</head>") {
                out.insert(contentsOf: block + "\n", at: head.lowerBound)
                changed = true
            }
        }

        // Named-style edits: merge by class the same way.
        var rules = overrides(in: out)
        for (cls, decl) in blocks.overrides { rules[cls] = decl }
        if !rules.isEmpty, rules != overrides(in: out) || !hasTag(out, "data-tim-style-overrides") {
            let block = overridesBlock(rules)
            if let r = out.range(of: "<style[^>]*data-tim-style-overrides[^>]*>[\\s\\S]*?</style>", options: .regularExpression) {
                if out[r] != block { out.replaceSubrange(r, with: block); changed = true }
            } else if let head = out.range(of: "</head>") {
                out.insert(contentsOf: block + "\n", at: head.lowerBound)
                changed = true
            }
        }

        // Fonts the page doesn't load yet — added ahead of the styles so
        // they're requested early. Fonts it has and the source doesn't stay.
        let present = Set(fontLinks(in: out).map(\.family))
        for font in blocks.fonts where !present.contains(font.family) {
            if let r = out.range(of: "<style data-tim-styles[^>]*>", options: .regularExpression) {
                out.insert(contentsOf: font.tag + "\n", at: r.lowerBound)
                changed = true
            }
        }
        return changed ? out : nil
    }

    /// The saved page's look → every other eligible page in the mirror.
    /// Returns the site-relative paths of pages that changed.
    public static func propagate(from savedHTML: String, in folder: String, excludingRel: String?) -> [String] {
        guard eligible(savedHTML), let blocks = blocks(in: savedHTML),
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
            guard let pageHTML = try? String(contentsOfFile: path, encoding: .utf8),
                  eligible(pageHTML),
                  let updated = applying(blocks, to: pageHTML)
            else { continue }
            try? updated.write(toFile: path, atomically: true, encoding: .utf8)
            changed.append(rel)
        }
        return changed
    }

    // MARK: Helpers

    static func firstMatch(in text: String, _ pattern: String) -> String? {
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[r])
    }
    static func capture(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text)
        else { return nil }
        return String(text[r])
    }
    static func hasTag(_ html: String, _ attr: String) -> Bool {
        html.range(of: "<style[^>]*\(attr)[^>]*>", options: .regularExpression) != nil
    }
    static func str(_ v: Any?) -> String? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        return s
    }
    static func numValue(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
    static func num(_ v: Any?) -> String? { numValue(v).map(fmt) }
    /// JavaScript's number-to-string: 72 → "72", 72.5 → "72.5".
    static func fmt(_ d: Double) -> String {
        d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
    }
    static func same(_ a: [String: [String: Any]], _ b: [String: [String: Any]]) -> Bool {
        guard a.keys.sorted() == b.keys.sorted() else { return false }
        for (k, pa) in a {
            guard let pb = b[k], NSDictionary(dictionary: pa).isEqual(to: pb) else { return false }
        }
        return true
    }
}
