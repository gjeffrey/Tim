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
        var rules = [
            "[data-tim-mobile-hidden]{display:none !important}",
            // Multi-column text reads as one column on phones.
            ".tim-canvas .tim-text{column-count:1 !important}"
        ]
        rules += styleClassRules(in: out)
        rules += inlineSizeRules(in: out)
        // A hand-tuned mobile layout (data-tim-mobile-layout) is the
        // author's word — synthesis stays out of layout entirely then.
        // Group containers nest their own grids, whose child coordinates
        // would confuse the gap math — layout synthesis sits those out too.
        if !out.contains("data-tim-mobile-layout"), !out.contains("tim-container") {
            rules += layoutRules(in: out)
        }
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

    struct CanvasObject {
        let id: String
        let tag: String
        let rs: Int, cs: Int, re: Int, ce: Int
    }

    /// The desktop layout, read back from the saved page — every object's
    /// identity, tag, and grid placement (either grid-area shorthand or
    /// the longhand the DOM serializer writes).
    static func objects(in html: String) -> [CanvasObject] {
        guard let regex = try? NSRegularExpression(
            pattern: "<([a-zA-Z][a-zA-Z0-9]*)\\s[^>]*class=\"[^\"]*tim-object[^\"]*\"[^>]*>"
        ) else { return [] }
        var out: [CanvasObject] = []
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let tagRange = Range(match.range, in: html),
                  let nameRange = Range(match.range(at: 1), in: html) else { continue }
            let tag = String(html[tagRange])
            guard let id = capture(tag, "data-tim-id=\"([^\"]+)\"") else { continue }
            var rs = 0, cs = 0, re = 0, ce = 0
            if let area = capture(tag, "grid-area:\\s*([0-9]+)\\s*/\\s*([0-9]+)\\s*/\\s*([0-9]+)\\s*/\\s*([0-9]+)", groups: 4) {
                rs = area[0]; cs = area[1]; re = area[2]; ce = area[3]
            } else {
                rs = captureInt(tag, "grid-row-start:\\s*([0-9]+)") ?? 0
                cs = captureInt(tag, "grid-column-start:\\s*([0-9]+)") ?? 0
                re = captureInt(tag, "grid-row-end:\\s*([0-9]+)") ?? 0
                ce = captureInt(tag, "grid-column-end:\\s*([0-9]+)") ?? 0
            }
            guard rs > 0, re > rs else { continue }
            out.append(CanvasObject(id: id, tag: String(html[nameRange]).lowercased(), rs: rs, cs: cs, re: re, ce: ce))
        }
        return out.sorted { ($0.rs, $0.cs) < ($1.rs, $1.cs) }
    }

    /// Layout intent, carried to the phone: the vertical breathing between
    /// desktop sections survives as proportional margins, and runs of
    /// narrow side-by-side images stay side by side, two-up.
    static func layoutRules(in html: String) -> [String] {
        let objs = objects(in: html)
        guard objs.count > 1 else { return [] }
        var rules: [String] = []

        // Section rhythm: a gap of 3+ empty desktop rows before an object
        // becomes a proportional gap on mobile (8px per row, capped).
        var maxReSoFar = objs[0].re
        for obj in objs.dropFirst() {
            let gap = obj.rs - maxReSoFar
            if gap >= 3 {
                rules.append("[data-tim-id=\"\(obj.id)\"]{margin-top:\(min(gap * 8, 72))px !important}")
            }
            maxReSoFar = max(maxReSoFar, obj.re)
        }

        // Image galleries: consecutive narrow images sharing rows keep
        // their side-by-side intent as a two-up grid (an odd last image
        // goes full width, deliberately).
        var pairIDs: [String] = []
        var run: [CanvasObject] = []
        func flushRun() {
            if run.count >= 2 {
                var ids = run.map(\.id)
                if ids.count % 2 == 1 { ids.removeLast() }
                pairIDs += ids
            }
            run = []
        }
        for obj in objs {
            let isNarrowImage = obj.tag == "img" && (obj.ce - obj.cs) <= 12
            if isNarrowImage, let last = run.last, obj.rs < last.re, obj.cs >= last.ce {
                run.append(obj)
            } else {
                flushRun()
                if isNarrowImage { run = [obj] }
            }
        }
        flushRun()
        if !pairIDs.isEmpty {
            rules.append(".tim-canvas{grid-template-columns:repeat(2, 1fr) !important}")
            rules.append(".tim-canvas > .tim-object{grid-column:span 2 !important}")
            let selector = pairIDs.map { "[data-tim-id=\"\($0)\"]" }.joined(separator: ",")
            rules.append("\(selector){grid-column:span 1 !important}")
        }
        return rules
    }

    static func capture(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    static func captureInt(_ text: String, _ pattern: String) -> Int? {
        capture(text, pattern).flatMap(Int.init)
    }

    static func capture(_ text: String, _ pattern: String, groups: Int) -> [Int]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > groups
        else { return nil }
        var out: [Int] = []
        for index in 1...groups {
            guard let range = Range(match.range(at: index), in: text),
                  let value = Int(text[range]) else { return nil }
            out.append(value)
        }
        return out
    }

    /// N px of a 1320px composition is N/13.2 vw of any screen — display
    /// type keeps its share of the page on a phone. Body sizes (≤28px)
    /// stay put; a 26px floor keeps headlines readable.
    static func scaleRule(px: Double, selector: String) -> String? {
        guard px > 28 else { return nil }
        return String(format: "%@{font-size:clamp(26px, %.2fvw, %.0fpx) !important}", selector, px / 13.2, px)
    }
}
