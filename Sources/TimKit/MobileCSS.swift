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
            ".tim-canvas .tim-text{column-count:1 !important;overflow-wrap:anywhere}",
            // A narrow viewport must never be widened by one ambitious
            // object, even after the author opts into a custom layout.
            ".tim-canvas .tim-object{box-sizing:border-box;min-width:0;max-width:100%}"
        ]
        rules += styleClassRules(in: out)
        rules += inlineSizeRules(in: out)
        // Media keeps its own shape on phones — natural aspect at column
        // width, never stretched or cropped into row-derived boxes. This
        // holds even under hand-tuned mobile layouts.
        for obj in objects(in: out) where obj.tag == "img" || obj.tag == "video" {
            rules.append("[data-tim-id=\"\(obj.id)\"]{height:auto !important;align-self:start}")
        }
        // A hand-tuned mobile layout (data-tim-mobile-layout) is the
        // author's word — synthesis stays out of layout entirely then.
        // Until that point mobile is deliberately a resilient content
        // flow, not a miniature attempt to preserve desktop geometry.
        if !out.contains("data-tim-mobile-layout") {
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
        // Editor chrome never ships: any leaked __tim-* style element goes.
        out = out.replacingOccurrences(of: "<style[^>]*id=\"__tim-[^\"]*\"[^>]*>[\\s\\S]*?</style>\\n?", with: "", options: .regularExpression)
        out = ensuringPasteboardRules(in: out)
        // Page motion rides the same save-time pass (both platforms call it).
        out = PageMotion.ensure(in: out)
        out = NavKit.ensure(in: out)
        return out
    }

    /// Keynote semantics for the pasteboard: an object resting wholly past
    /// the page's columns stays in the document but doesn't render for
    /// visitors — it shows only while editing (the tim-editing session).
    /// Per layout: off the desktop page hides at desktop widths, off the
    /// phone stack hides at phone widths.
    static func ensuringPasteboardRules(in html: String) -> String {
        var out = html
        var blocks: [String] = []
        let deskOff = objects(in: out).filter { $0.cs > 24 }.map(\.id)
        if !deskOff.isEmpty {
            let sel = deskOff.map { "html:not(.tim-editing) [data-tim-id=\"\($0)\"]" }.joined(separator: ",")
            blocks.append("@media (min-width: 701px){\(sel){display:none !important}}")
        }
        let mobileOff = mobileEntries(in: out).filter { $0.value.count == 4 && $0.value[1] > 8 }.map(\.key)
        if !mobileOff.isEmpty {
            let sel = mobileOff.map { "html:not(.tim-editing) [data-tim-id=\"\($0)\"]" }.joined(separator: ",")
            blocks.append("@media (max-width: 700px){\(sel){display:none !important}}")
        }
        let block = "<style data-tim-pasteboard>" + blocks.joined(separator: "\n") + "</style>"
        if let existing = out.range(of: "<style data-tim-pasteboard>[\\s\\S]*?</style>", options: .regularExpression) {
            out.replaceSubrange(existing, with: block)
        } else if let head = out.range(of: "</head>") {
            out.insert(contentsOf: block + "\n", at: head.lowerBound)
        }
        return out
    }

    /// The explicit mobile layout, read back from its style element.
    static func mobileEntries(in html: String) -> [String: [Int]] {
        guard let tagRange = html.range(of: "<style[^>]*data-tim-mobile-layout[^>]*>", options: .regularExpression) else { return [:] }
        let tag = String(html[tagRange])
        guard let raw = capture(tag, "data-props=\"([^\"]*)\"") ?? capture(tag, "data-props='([^']*)'") else { return [:] }
        let json = raw
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [Int]]
        else { return [:] }
        return dict
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

    /// Objects whose mobile size was set BY HAND (style[data-tim-mobile-type])
    /// are the author's word — synthesis leaves them alone entirely.
    static func handSizedIDs(in html: String) -> Set<String> {
        guard let tagRange = html.range(of: "<style[^>]*data-tim-mobile-type[^>]*>", options: .regularExpression) else { return [] }
        let tag = String(html[tagRange])
        guard let raw = capture(tag, "data-props=\"([^\"]*)\"") ?? capture(tag, "data-props='([^']*)'") else { return [] }
        let json = raw
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return Set(dict.keys)
    }

    /// Objects with big inline sizes (set from the inspector) get the
    /// same treatment, addressed by their identity.
    static func inlineSizeRules(in html: String) -> [String] {
        let handSized = handSizedIDs(in: html)
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
                guard !handSized.contains(id), let px = Double(html[idFirst ? b : a]) else { continue }
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

    /// The automatic phone rendition is a reading-order flow. Desktop owns
    /// composition; mobile starts from legibility and gives every object a
    /// natural-height row. The `tim-mobile-custom` guard matters during the
    /// live handoff into mobile editing: its explicit grid is written before
    /// the page can be regenerated and replace these automatic rules.
    static func layoutRules(in html: String) -> [String] {
        let objs = objects(in: html)
        let auto = "html:not(.tim-mobile-custom)"
        var rules = [
            "\(auto) .tim-canvas{grid-template-columns:minmax(0,1fr) !important;grid-auto-rows:auto !important;overflow-x:clip}",
            "\(auto) .tim-canvas .tim-object{grid-area:auto !important;transform:none !important;margin-left:0 !important;margin-right:0 !important}",
            "\(auto) .tim-canvas>.tim-text{width:auto !important}",
            // Groups retain their semantic boundary but shed their desktop
            // mini-canvas on phones, so their contents read top to bottom.
            "\(auto) .tim-canvas .tim-container{grid-template-columns:minmax(0,1fr) !important;grid-auto-rows:auto !important;height:auto !important}"
        ]
        guard objs.count > 1, !html.contains("tim-container") else { return rules }

        // Section rhythm: a gap of 3+ empty desktop rows before an object
        // becomes a proportional gap on mobile (8px per row, capped).
        var maxReSoFar = objs[0].re
        for obj in objs.dropFirst() {
            let gap = obj.rs - maxReSoFar
            if gap >= 3 {
                rules.append("\(auto) [data-tim-id=\"\(obj.id)\"]{margin-top:\(min(gap * 8, 72))px !important}")
            }
            maxReSoFar = max(maxReSoFar, obj.re)
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

    /// Display type compresses toward the phone, hierarchy intact: body
    /// sizes (≤28px) stay put, everything above shrinks by the same
    /// gentle curve (28 + a quarter of the excess, capped at 48px) — so
    /// a 96px title lands near 44, a 40px subhead near 31, and their
    /// ORDER never flattens the way a hard floor did.
    static func scaleRule(px: Double, selector: String) -> String? {
        guard px > 28 else { return nil }
        let mobile = min(48.0, 28 + (px - 28) * 0.24)
        return String(format: "%@{font-size:%.0fpx !important}", selector, mobile)
    }
}
