import Foundation

/// Start a new page FROM one you're looking at.
///
/// Adopting a page keeps someone else's layout intact and leaves you able
/// to change only its words and pictures. Seeding does the opposite: it
/// takes the page's palette, its fonts, its writing and its photographs,
/// and composes a genuinely new Tim page from them — on Tim's grid, where
/// everything moves, resizes, restacks and carries shared objects.
///
/// It deliberately does not reproduce the original's arrangement. Nobody
/// expects a pixel match from "inspired by", which is exactly what makes
/// this honest where a rebuild would not be: there is no fidelity to fail.
public enum PageSeed {
    /// Reads the page as material: what it says, what it shows, and what
    /// it looks like. Runs on any page, with no editor loaded.
    public static let gatherJS = """
    (function () {
      function firstFamily(value) {
        return String(value || '').split(',')[0].replace(/["']/g, '').trim();
      }
      function visible(el) {
        var cs = getComputedStyle(el);
        if (cs.display === 'none' || cs.visibility === 'hidden' || parseFloat(cs.opacity || '1') < 0.05) { return false; }
        var r = el.getBoundingClientRect();
        return r.width > 1 && r.height > 1;
      }
      // Chrome is not content: menus, footers and sidebars would seed a
      // page with somebody else's furniture.
      function isChrome(el) {
        return !!(el.closest && el.closest('nav, footer, aside, header, [role=navigation], [role=banner], [role=contentinfo], [class*=nav], [class*=menu], [class*=side], [class*=banner], [class*=logo], [id*=nav], [id*=footer], [id*=side], [id*=banner], [id*=logo], [id*=header]'));
      }
      // A block that is nothing but a short link is a menu item wearing a
      // paragraph's clothes.
      function isJustALink(el) {
        var links = el.querySelectorAll('a');
        if (!links.length) { return false; }
        var linked = 0;
        for (var i = 0; i < links.length; i++) { linked += (links[i].textContent || '').trim().length; }
        var total = (el.textContent || '').trim().length;
        return total > 0 && total < 80 && linked >= total - 2;
      }
      var body = document.body, bodyStyle = getComputedStyle(body);
      var bodyColor = bodyStyle.color;
      var seed = {
        title: (document.title || '').trim(),
        background: (String(bodyStyle.backgroundImage || '').indexOf('gradient') >= 0)
          ? bodyStyle.backgroundImage : bodyStyle.backgroundColor,
        color: bodyColor,
        headingFont: '',
        bodyFont: firstFamily(bodyStyle.fontFamily),
        items: []
      };
      var heading = document.querySelector('h1, h2, h3');
      if (heading) { seed.headingFont = firstFamily(getComputedStyle(heading).fontFamily); }
      if (!seed.headingFont) { seed.headingFont = seed.bodyFont; }

      var taken = [];
      function alreadyInside(el) {
        for (var i = 0; i < taken.length; i++) { if (taken[i].contains(el)) { return true; } }
        return false;
      }
      var nodes = document.querySelectorAll('h1,h2,h3,h4,p,blockquote,li,figcaption,img');
      for (var i = 0; i < nodes.length && seed.items.length < 40; i++) {
        var el = nodes[i];
        if (!visible(el) || isChrome(el) || alreadyInside(el)) { continue; }
        if (el.tagName !== 'IMG' && isJustALink(el)) { continue; }
        if (el.tagName === 'IMG') {
          var w = el.naturalWidth || el.width, h = el.naturalHeight || el.height;
          var src = el.currentSrc || el.src;
          // Icons, spacers and tracking pixels are not photographs.
          if (!src || src.indexOf('data:') === 0 || w < 120 || h < 120) { continue; }
          seed.items.push({ kind: 'image', src: src, w: w, h: h, alt: el.getAttribute('alt') || '' });
          taken.push(el);
        } else {
          var text = (el.textContent || '').replace(/\\s+/g, ' ').trim();
          if (text.length < 2) { continue; }
          var cs = getComputedStyle(el);
          var size = parseFloat(cs.fontSize) || 16;
          seed.items.push({
            kind: 'text',
            tag: el.tagName.toLowerCase(),
            text: text.slice(0, 1200),
            size: size,
            bold: (parseInt(cs.fontWeight, 10) || 400) >= 600,
            color: cs.color === bodyColor ? '' : cs.color
          });
          taken.push(el);
        }
      }
      return JSON.stringify(seed);
    })()
    """

    public struct Item {
        public var isImage: Bool
        public var text: String
        public var size: Double
        public var bold: Bool
        public var color: String
        public var src: String
        public var width: Double
        public var height: Double
        public var alt: String
    }

    /// The page, and every picture it will need fetching.
    public static func compose(_ seed: [String: Any]) -> (html: String, resources: [String]) {
        let title = (seed["title"] as? String ?? "Untitled").trimmingCharacters(in: .whitespacesAndNewlines)
        let background = seed["background"] as? String ?? "#ffffff"
        let color = seed["color"] as? String ?? "#1d1d1f"
        let headingFont = seed["headingFont"] as? String ?? ""
        let bodyFont = seed["bodyFont"] as? String ?? ""
        let raw = seed["items"] as? [[String: Any]] ?? []

        var objects = ""
        var resources: [String] = []
        var row = 1
        let columns = 24

        for entry in raw {
            let kind = entry["kind"] as? String ?? "text"
            if kind == "image" {
                guard let src = entry["src"] as? String else { continue }
                let w = entry["w"] as? Double ?? 1
                let h = entry["h"] as? Double ?? 1
                let aspect = w > 0 ? h / w : 1
                // A picture is shown at the size it actually is, never
                // blown up to fill the page: a 480-pixel image stretched
                // across 1320 looks exactly as bad as it sounds. Column
                // tracks are 55pt at the canvas's content width.
                let natural = Int((w / 55.0).rounded())
                let span = min(columns, max(6, natural))
                let renderedWidth = 1320.0 * Double(span) / Double(columns)
                let rows = max(2, Int(((renderedWidth * aspect) + 16) / 48))
                objects += "<img class=\"tim-object\" src=\"\(escape(src))\" alt=\"\(escape(entry["alt"] as? String ?? ""))\" style=\"grid-area: \(row) / 1 / \(row + rows) / \(1 + span);\">\n"
                resources.append(src)
                row += rows + 1
            } else {
                let text = entry["text"] as? String ?? ""
                guard !text.isEmpty else { continue }
                let size = entry["size"] as? Double ?? 16
                let style = styleClass(for: size, bold: entry["bold"] as? Bool ?? false,
                                       tag: entry["tag"] as? String ?? "p")
                let rows = textRows(text, style: style)
                let tint = (entry["color"] as? String ?? "").isEmpty ? "" : " color: \(entry["color"] as! String);"
                objects += "<div class=\"tim-object tim-text \(style)\" style=\"grid-area: \(row) / 1 / \(row + rows) / \(1 + columns);\(tint)\">\(escape(text))</div>\n"
                row += rows + 1
            }
        }
        if objects.isEmpty {
            objects = "<div class=\"tim-object tim-text tim-style-body\" style=\"grid-area: 1 / 1 / 4 / 13;\">Nothing came across from that page. Double-click to start writing.</div>\n"
        }
        return (page(title: title, background: background, color: color,
                     headingFont: headingFont, bodyFont: bodyFont, objects: objects), resources)
    }

    /// Prominence carried over, not measurements: a big heading there
    /// becomes Tim's Title here, and stays editable as a Tim style. The
    /// tag and the rendered size both get a say, and the stronger wins —
    /// a site may set its headlines small, but an h1 is still a headline.
    static func styleClass(for size: Double, bold: Bool, tag: String) -> String {
        let order = ["tim-style-body", "tim-style-subheading", "tim-style-heading", "tim-style-title"]
        let bySize: String
        if size >= 40 { bySize = "tim-style-title" }
        else if size >= 28 { bySize = "tim-style-heading" }
        else if size >= 20 || bold { bySize = "tim-style-subheading" }
        else { bySize = "tim-style-body" }
        let byTag: String
        switch tag {
        case "h1": byTag = "tim-style-title"
        case "h2": byTag = "tim-style-heading"
        case "h3", "h4": byTag = "tim-style-subheading"
        default: byTag = "tim-style-body"
        }
        let winner = max(order.firstIndex(of: bySize) ?? 0, order.firstIndex(of: byTag) ?? 0)
        return order[winner]
    }

    static func textRows(_ text: String, style: String) -> Int {
        let perLine: Double
        switch style {
        case "tim-style-title": perLine = 26
        case "tim-style-heading": perLine = 44
        case "tim-style-subheading": perLine = 62
        default: perLine = 96
        }
        let lineHeight: Double
        switch style {
        case "tim-style-title": lineHeight = 60
        case "tim-style-heading": lineHeight = 36
        case "tim-style-subheading": lineHeight = 28
        default: lineHeight = 26
        }
        let lines = max(1.0, (Double(text.count) / perLine).rounded(.up))
        return max(1, Int(((lines * lineHeight) + 16) / 48) + 1)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func fontStack(_ family: String) -> String {
        family.isEmpty ? "-apple-system, ui-sans-serif, system-ui, sans-serif"
                       : "\"\(family)\", -apple-system, ui-sans-serif, system-ui, sans-serif"
    }

    static func page(title: String, background: String, color: String,
                     headingFont: String, bodyFont: String, objects: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="generator" content="Tim">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style data-tim-styles>
          :root { color-scheme: light dark; }
          body {
            margin: 0;
            font-family: \(fontStack(bodyFont));
            --tim-font-heading: \(fontStack(headingFont));
            --tim-font-body: \(fontStack(bodyFont));
          }
          .tim-canvas {
            display: grid;
            grid-template-columns: repeat(24, 1fr);
            grid-auto-rows: 32px;
            gap: 16px;
            align-items: stretch;
            box-sizing: border-box;
            width: 100vw;
            padding: 64px max(24px, calc(50vw - 660px));
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
          .tim-style-title { font-family: var(--tim-font-heading, inherit); font-size: 2.5rem; font-weight: 700; line-height: 1.15; letter-spacing: -0.02em; }
          .tim-style-heading { font-family: var(--tim-font-heading, inherit); font-size: 1.6rem; font-weight: 700; line-height: 1.25; }
          .tim-style-subheading { font-family: var(--tim-font-heading, inherit); font-size: 1.25rem; font-weight: 600; line-height: 1.3; }
          .tim-style-body { font-family: var(--tim-font-body, inherit); font-size: 1rem; line-height: 1.6; }
        </style>
        <style data-tim-templates>
        body[data-tim-template="default"]{background:\(background);color:\(color);}
        body[data-tim-template="default"] .tim-canvas{padding:64px max(24px, calc(50vw - 660px));}
        </style>
        </head>
        <body data-tim-template="default">
        <div class="tim-canvas" data-tim-canvas>
        \(objects)</div>
        </body>
        </html>
        """
    }
}
