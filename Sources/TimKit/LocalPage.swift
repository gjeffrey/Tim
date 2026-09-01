import Foundation

/// A self-contained local canvas page: one .html file, no project, no
/// site — the fastest way to a surface you can edit and save.
public enum LocalPage {
    public static func html(title: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="generator" content="Tim">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style data-tim-styles>
          :root { color-scheme: light dark; }
          body {
            margin: 0;
            font-family: -apple-system, ui-sans-serif, system-ui, sans-serif;
            background: #fbfbfd;
            color: #1d1d1f;
          }
          @media (prefers-color-scheme: dark) {
            body { background: #161617; color: #f5f5f7; }
          }
          .tim-canvas {
            display: grid;
            grid-template-columns: repeat(24, 1fr);
            grid-auto-rows: 32px;
            gap: 16px;
            align-items: stretch;
            box-sizing: border-box;
            width: 100vw;
            padding: 48px max(32px, calc(50vw - 660px));
            min-height: 100vh;
          }
          .tim-object { min-width: 0; }
          .tim-text { min-height: 1em; outline: none; padding: 2px 4px; }
          html.tim-editing .tim-object { cursor: grab; }
          html.tim-editing .tim-object:active { cursor: grabbing; }
          .tim-canvas img.tim-object { width: 100%; height: 100%; object-fit: cover; display: block; }
          .tim-canvas video.tim-object { width: 100%; display: block; }
          @media (max-width: 700px) {
            .tim-canvas { grid-template-columns: 1fr; grid-auto-rows: auto; padding: 24px 16px; min-height: 0; }
            .tim-canvas > .tim-object { grid-area: auto !important; }
          }
          .tim-style-title { font-size: 2.5rem; font-weight: 700; line-height: 1.15; letter-spacing: -0.02em; }
          .tim-style-heading { font-size: 1.6rem; font-weight: 700; line-height: 1.25; }
          .tim-style-subheading { font-size: 1.25rem; font-weight: 600; line-height: 1.3; }
          .tim-style-body { font-size: 1rem; line-height: 1.6; }
          .tim-style-caption { font-size: 0.85rem; opacity: 0.7; line-height: 1.4; }
        </style>
        </head>
        <body data-tim-template="default">
        <div class="tim-canvas" data-tim-canvas>
          <div class="tim-object tim-text tim-style-title" style="grid-area: 1 / 1 / 3 / 17;">\(title)</div>
          <div class="tim-object tim-text tim-style-body" style="grid-area: 3 / 1 / 6 / 13;">Double-click any text to edit it. Drag objects to move them — everything snaps to the grid. Insert adds text boxes, images, and video. Save writes this file.</div>
        </div>
        </body>
        </html>
        """
    }

    /// A new page in the site's own design language: the seed page's head
    /// (styles, fonts, template rules, icons) with a fresh canvas. Falls
    /// back to the generic starter when the site has no pages yet.
    public static func html(title: String, likeSiteAt folder: String?) -> String {
        guard let folder, !folder.isEmpty,
              var page = seedHTML(in: folder),
              let canvasAttr = page.range(of: "data-tim-canvas")
        else { return html(title: title) }

        // Fresh canvas: title + starter text, plus the site's template
        // components so the new page matches its siblings immediately.
        var inner = """

          <div class="tim-object tim-text tim-style-title" style="grid-area: 4 / 2 / 7 / 18;">\(title)</div>
          <div class="tim-object tim-text tim-style-body" style="grid-area: 8 / 2 / 11 / 14;">Double-click any text to edit it. Drag objects to move them — everything snaps to the grid.</div>

        """
        for name in PageComponents.list(in: folder) where name.hasPrefix("tpl-") {
            if let content = PageComponents.html(named: name, in: folder),
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                inner = "\n" + PageComponents.stamped(name: name, content: content) + inner
            }
        }
        guard let open = page.range(of: ">", range: canvasAttr.upperBound..<page.endIndex),
              let bodyClose = page.range(of: "</body>"),
              let canvasClose = page.range(of: "</div>", options: .backwards, range: open.upperBound..<bodyClose.lowerBound)
        else { return html(title: title) }
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
