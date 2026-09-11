import Foundation

/// A self-contained local canvas page: one .html file, no project, no
/// site — the fastest way to a surface you can edit and save.
public enum LocalPage {
    /// A page on its own — no site, no project — in Paper, Tim's theme.
    public static func html(title: String) -> String {
        Paper.page(.blank, title: title)
    }

    /// A small, offline playground made entirely from ordinary canvas objects.
    public static var playground: String {
        let objects = """
        <div class="tim-object tim-text tim-style-caption" style="grid-area:1 / 2 / 2 / 22;">YOUR OWN LITTLE CORNER OF THE WEB</div>
        <div class="tim-object tim-text tim-style-title" style="grid-area:3 / 2 / 7 / 17;">Something only<br>you would make.</div>
        <div class="tim-object tim-text tim-style-body" style="grid-area:8 / 2 / 11 / 14;">Double-click these words. Write about something you love, however small or strange.</div>
        <div class="tim-object tim-text tim-style-heading" style="grid-area:3 / 18 / 8 / 25;background:#ffd60a;color:#202020;border-radius:50%;display:flex;align-items:center;justify-content:center;text-align:center;padding:20px;">Move<br>me.</div>
        <div class="tim-object tim-text tim-style-body" style="grid-area:12 / 2 / 16 / 12;background:#d6e9de;color:#202020;padding:24px;border-radius:6px;">Try a different shape.<br>Click this card, then drag an edge to resize it.</div>
        <div class="tim-object tim-text tim-style-body" style="grid-area:12 / 14 / 16 / 24;background:#f4c1b4;color:#202020;padding:24px;border-radius:6px;">Make a happy accident.<br>Move something somewhere unexpected. Undo is always ⌘Z.</div>
        <div class="tim-object tim-text tim-style-caption" style="grid-area:18 / 2 / 20 / 23;">Try the phone preview above. When you’re happy, press Done to save this page on your Mac.</div>
        """
        // System fonts keep the very first experiment independent of a connection.
        let head = Paper.head(title: "My playground")
            .replacingOccurrences(of: Paper.fontLinks, with: "")
            .replacingOccurrences(of: Paper.headingFont, with: "Georgia, serif")
            .replacingOccurrences(of: Paper.bodyFont, with: "-apple-system, ui-sans-serif, system-ui, sans-serif")
        return MobileCSS.regenerate(in: """
        <!DOCTYPE html><html lang="en"><head>
        \(head)
        </head><body data-tim-template="page">
        <div class="tim-canvas" data-tim-canvas>\(objects)</div>
        </body></html>
        """)
    }

    /// A new page in the site's own design language: the seed page's head
    /// (styles, fonts, template rules, icons) with a fresh canvas. Falls
    /// back to the generic starter when the site has no pages yet.
    public static func html(title: String, likeSiteAt folder: String?) -> String {
        let starter = """

          <div class="tim-object tim-text tim-style-title" style="grid-area: 4 / 2 / 7 / 18;">\(title)</div>
          <div class="tim-object tim-text tim-style-body" style="grid-area: 8 / 2 / 11 / 14;">Double-click any text to edit it. Drag objects to move them — everything snaps to the grid.</div>

        """
        return composed(title: title, objects: starter, likeSiteAt: folder) ?? html(title: title)
    }

    /// The site's head (styles, fonts, templates, icons) around a fresh
    /// canvas holding `objects`, plus the site's shared objects so the new
    /// page matches its siblings immediately. Nil when the site has no page
    /// to take the look from.
    public static func composed(title: String, objects: String, likeSiteAt folder: String?) -> String? {
        guard let folder, !folder.isEmpty,
              var page = seedHTML(in: folder),
              let canvasAttr = page.range(of: "data-tim-canvas")
        else { return nil }

        var inner = objects
        let lastRow = PageComponents.lastObjectRow(in: objects)
        for name in PageComponents.list(in: folder) where name.hasPrefix("tpl-") {
            if let content = PageComponents.html(named: name, in: folder),
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let piece = PageComponents.stamped(name: name, content: content)
                if let row = PageComponents.startRow(of: content), row > lastRow {
                    inner += piece + "\n"
                } else {
                    inner = "\n" + piece + inner
                }
            }
        }
        guard let open = page.range(of: ">", range: canvasAttr.upperBound..<page.endIndex),
              let bodyClose = page.range(of: "</body>"),
              let canvasClose = page.range(of: "</div>", options: .backwards, range: open.upperBound..<bodyClose.lowerBound)
        else { return nil }
        page.replaceSubrange(open.upperBound..<canvasClose.lowerBound, with: inner)

        // The seed's identity goes; the design stays.
        page = replacing(in: page, pattern: "<title>[\\s\\S]*?</title>", with: "<title>\(title)</title>")
        page = replacing(in: page, pattern: "<meta name=\"description\" content=\"[^\"]*\">\\n?", with: "")
        page = replacing(in: page, pattern: "<meta property=\"og:[^\"]*\" content=\"[^\"]*\">\\n?", with: "")
        page = replacing(in: page, pattern: "<meta name=\"twitter:[^\"]*\" content=\"[^\"]*\">\\n?", with: "")
        page = replacing(in: page, pattern: "<meta name=\"robots\" content=\"[^\"]*\">\\n?", with: "")
        page = page.replacingOccurrences(of: " data-tim-own-icons=\"\"", with: "")
            .replacingOccurrences(of: " data-tim-own-icons", with: "")
        if let head = page.range(of: "</head>") {
            page.insert(contentsOf: "<meta property=\"og:title\" content=\"\(title)\">\n", at: head.lowerBound)
        }
        return page
    }

    static func seedHTML(in folder: String) -> String? {
        let index = (folder as NSString).appendingPathComponent("index.html")
        if let html = try? String(contentsOfFile: index, encoding: .utf8), html.contains("data-tim-canvas") {
            return html
        }
        guard let subpaths = try? FileManager.default.subpathsOfDirectory(atPath: folder) else { return nil }
        for rel in subpaths.sorted() {
            guard rel.hasSuffix(".html"), !rel.hasPrefix("components/"),
                  !rel.hasPrefix("_h/"), !rel.hasPrefix("_hidden/"),
                  !rel.contains(".git"), !rel.contains("node_modules")
            else { continue }
            if let html = try? String(contentsOfFile: (folder as NSString).appendingPathComponent(rel), encoding: .utf8),
               html.contains("data-tim-canvas") {
                return html
            }
        }
        return nil
    }

    static func replacing(in text: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text),
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }
}
