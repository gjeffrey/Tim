import Foundation

/// The mobile rendition, generated — never asked about. Desktop is the
/// composition; on phones the canvas stacks into one column, and this
/// pass writes the per-page CSS that keeps the stack looking designed:
/// display type scales with the viewport in the same proportion it had
/// on the desktop canvas (floored for readability), and objects marked
/// desktop-only disappear. Regenerated on every save, so it always
/// reflects the page as published.
public enum MobileCSS {
    public static func regenerate(in html: String) -> String {
        var out = assignIDs(in: html)
        var rules = ["[data-tim-mobile-hidden]{display:none !important}"]
        rules += styleClassRules(in: out)
        rules += inlineSizeRules(in: out)
        let block = "<style data-tim-mobile>@media (max-width: 700px){\n"
            + rules.joined(separator: "\n")
            + "\n}</style>"
        if let existing = out.range(of: "<style data-tim-mobile>[\\s\\S]*?</style>", options: .regularExpression) {
            out.replaceSubrange(existing, with: block)
        } else if let head = out.range(of: "</head>") {
            out.insert(contentsOf: block + "\n", at: head.lowerBound)
        }
        return out
    }

    /// Every canvas object gets a stable identity the first time it's
    /// saved — what lets generated CSS (and one day, per-breakpoint
    /// placements) address it across edits.
    static func assignIDs(in html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "<[a-zA-Z][a-zA-Z0-9]*\\s[^>]*class=\"[^\"]*tim-object[^\"]*\"[^>]*>"
        ) else { return html }
        var out = html
        // Back to front, so earlier ranges stay valid while inserting.
        for match in regex.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            let tag = String(out[range])
            guard !tag.contains("data-tim-id=") else { continue }
            let id = " data-tim-id=\"t\(UUID().uuidString.prefix(6).lowercased())\""
            let insertAt = tag.hasSuffix("/>")
                ? out.index(range.upperBound, offsetBy: -2)
                : out.index(range.upperBound, offsetBy: -1)
            out.insert(contentsOf: id, at: insertAt)
        }
        return out
    }

    /// Named styles with big fixed sizes get viewport-proportional mobile
    /// sizes. Styles already using clamp()/vw don't match and are left be.
    static func styleClassRules(in html: String) -> [String] {
        guard let styleRange = html.range(of: "<style data-tim-styles>[\\s\\S]*?</style>", options: .regularExpression) else { return [] }
        let styles = String(html[styleRange])
        guard let regex = try? NSRegularExpression(
            pattern: "\\.(tim-style-[a-z0-9-]+)[^{]*\\{[^}]*?font-size:\\s*([0-9.]+)(px|rem)"
        ) else { return [] }
        var rules: [String] = []
        for match in regex.matches(in: styles, range: NSRange(styles.startIndex..., in: styles)) {
            guard let cls = Range(match.range(at: 1), in: styles),
                  let num = Range(match.range(at: 2), in: styles),
                  let unit = Range(match.range(at: 3), in: styles),
                  let value = Double(styles[num])
            else { continue }
            let px = styles[unit] == "rem" ? value * 16 : value
            if let rule = scaleRule(px: px, selector: "." + styles[cls]) { rules.append(rule) }
        }
        return rules
    }

    /// Objects with big inline sizes (set from the inspector) get the
    /// same treatment, addressed by their identity.
    static func inlineSizeRules(in html: String) -> [String] {
        var rules: [String] = []
        for pattern in [
            "data-tim-id=\"([^\"]+)\"[^>]*style=\"[^\"]*?font-size:\\s*([0-9.]+)px",
            "style=\"[^\"]*?font-size:\\s*([0-9.]+)px[^\"]*\"[^>]*data-tim-id=\"([^\"]+)\""
        ] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let idFirst = pattern.hasPrefix("data-tim-id")
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let a = Range(match.range(at: 1), in: html),
                      let b = Range(match.range(at: 2), in: html)
                else { continue }
                let id = String(html[idFirst ? a : b])
                guard let px = Double(html[idFirst ? b : a]) else { continue }
                if let rule = scaleRule(px: px, selector: "[data-tim-id=\"\(id)\"]") { rules.append(rule) }
            }
        }
        return rules
    }

    /// N px of a 1320px composition is N/13.2 vw of any screen — display
    /// type keeps its share of the page on a phone. Body sizes (≤28px)
    /// stay put; a 26px floor keeps headlines readable.
    static func scaleRule(px: Double, selector: String) -> String? {
        guard px > 28 else { return nil }
        return String(format: "%@{font-size:clamp(26px, %.2fvw, %.0fpx) !important}", selector, px / 13.2, px)
    }
}
