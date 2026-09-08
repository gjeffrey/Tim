import Foundation

/// Paper — Tim's all-purpose theme, and the templates that come with it.
///
/// One look, built entirely from what Tim already knows how to edit: the
/// five named text styles plus four of Paper's own (Eyebrow, Lead, Quote,
/// Button); two page templates (Home, and Page for everything else) whose
/// colors, type and spacing are Page Options; a navigation bar, a name and a
/// footer that live on every page as shared objects; reveal-and-fade motion;
/// a warm paper ground with one accent. Every color and face in it is a
/// custom property — change Accent or Headings once in Page Options and
/// every button, eyebrow and title on the site follows on Done.
///
/// Six templates: Blank, Home, About, Work, Writing, Contact. Each is a real
/// canvas — objects placed on the 24-column grid with plain-spoken starter
/// text, and photos you replace by dropping your own on top.
public enum Paper {
    public static let name = "Paper"

    public enum Template: String, CaseIterable, Identifiable {
        case blank, home, about, work, writing, contact
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .blank: return "Blank"
            case .home: return "Home"
            case .about: return "About"
            case .work: return "Work"
            case .writing: return "Writing"
            case .contact: return "Contact"
            }
        }
        public var summary: String {
            switch self {
            case .blank: return "A title and a paragraph. Start from nothing."
            case .home: return "A big introduction, a photograph, three short cards and a line you believe."
            case .about: return "A portrait, your story, a few facts and something someone said about you."
            case .work: return "Six photographs in a grid, each with a caption."
            case .writing: return "A long read: a measured column, one wide picture, room to think."
            case .contact: return "How to reach you, where to find you, and a place."
            }
        }
        /// The file each template usually becomes.
        public var file: String {
            switch self {
            case .blank: return "untitled.html"
            case .home: return "index.html"
            default: return rawValue + ".html"
            }
        }
        /// Home breathes more; every other page shares one template.
        public var pageTemplate: String { self == .home ? "home" : "page" }
        /// The templates a fresh site is made of, in navigation order.
        public static var site: [Template] { [.home, .about, .work, .writing, .contact] }
    }

    // MARK: The look

    static let headingFont = "'Fraunces', Georgia, serif"
    static let bodyFont = "'Manrope', -apple-system, ui-sans-serif, system-ui, sans-serif"
    static let ink = "#1c1b18"
    static let ground = "#f6f4ee"
    static let accent = "#ffd60a"

    public static var templateProps: [String: [String: Any]] {
        let page: [String: Any] = [
            "bg": ground, "fg": ink, "link": ink, "accent": accent,
            "headingFont": headingFont, "bodyFont": bodyFont,
            "padY": 72, "marginX": 32, "contentW": 1240
        ]
        var home = page
        home["bg"] = "linear-gradient(180deg, #fbfaf6, \(ground))"
        home["padY"] = 88
        return ["home": home, "page": page]
    }

    /// Paper's own text styles — in the overrides block, where the Style
    /// menu finds them, so they show up beside Title and Body.
    public static var overrideRules: [String: String] {
        [
            "tim-style-eyebrow": "font-family:var(--tim-font-body);font-size:0.78rem;font-weight:700;letter-spacing:0.12em;text-transform:uppercase;line-height:1.4;color:color-mix(in srgb, var(--tim-ink) 72%, transparent);",
            "tim-style-lead": "font-family:var(--tim-font-body);font-size:1.35rem;font-weight:400;line-height:1.5;letter-spacing:-0.01em;",
            "tim-style-quote": "font-family:var(--tim-font-heading);font-size:1.9rem;font-weight:400;font-style:italic;line-height:1.3;letter-spacing:-0.01em;",
            "tim-style-button": "font-family:var(--tim-font-body);font-size:0.95rem;font-weight:700;line-height:1;text-align:center;"
        ]
    }

    public static let fontLinks = """
    <link data-tim-font="Fraunces" href="https://fonts.googleapis.com/css2?family=Fraunces:ital,wght@0,400;0,500;0,600;1,400&amp;display=swap" rel="stylesheet">
    <link data-tim-font="Manrope" href="https://fonts.googleapis.com/css2?family=Manrope:wght@400;500;600;700&amp;display=swap" rel="stylesheet">
    """

    public static let styles = """
    <style data-tim-styles data-tim-theme="paper">
      :root {
        color-scheme: light;
        --tim-font-heading: \(headingFont);
        --tim-font-body: \(bodyFont);
        --tim-ink: \(ink);
        --tim-accent: \(accent);
        --tim-link: \(ink);
        --tim-radius: 14px;
        --tim-surface: color-mix(in srgb, var(--tim-ink) 5%, transparent);
        --tim-line: color-mix(in srgb, var(--tim-ink) 12%, transparent);
      }
      body { margin: 0; font-family: var(--tim-font-body); color: var(--tim-ink); background: \(ground); -webkit-font-smoothing: antialiased; }
      a { color: var(--tim-link); text-decoration-thickness: 1px; text-underline-offset: 0.14em; }
      .tim-canvas {
        display: grid;
        grid-template-columns: repeat(24, 1fr);
        grid-auto-rows: 32px;
        gap: 16px;
        align-items: stretch;
        box-sizing: border-box;
        width: 100vw;
        padding: 72px max(32px, calc(50vw - 620px));
        min-height: 100vh;
      }
      .tim-object { min-width: 0; }
      .tim-text { min-height: 1em; outline: none; padding: 2px 4px; }
      html.tim-editing .tim-object { cursor: grab; }
      html.tim-editing .tim-object:active { cursor: grabbing; }
      .tim-canvas img.tim-object { width: 100%; height: 100%; object-fit: cover; display: block; border-radius: var(--tim-radius); }
      .tim-canvas video.tim-object { width: 100%; display: block; border-radius: var(--tim-radius); }
      @media (max-width: 700px) {
        .tim-canvas { grid-template-columns: 1fr; grid-auto-rows: auto; padding: 24px 16px; min-height: 0; }
        .tim-canvas > .tim-object { grid-area: auto !important; }
      }

      /* The Style menu. Title and Heading wear the heading face. */
      .tim-style-title { font-family: var(--tim-font-heading); font-size: 4rem; font-weight: 500; line-height: 1.02; letter-spacing: -0.025em; }
      .tim-style-heading { font-family: var(--tim-font-heading); font-size: 2rem; font-weight: 500; line-height: 1.15; letter-spacing: -0.015em; }
      .tim-style-subheading { font-size: 1.15rem; font-weight: 600; line-height: 1.35; }
      .tim-style-body { font-size: 1.05rem; line-height: 1.65; }
      .tim-style-caption { font-size: 0.82rem; line-height: 1.5; opacity: 0.62; }

      /* Paper's own pieces — each a plain text box wearing a class. */
      .tim-canvas .tim-style-eyebrow::before { content: ""; display: inline-block; width: 1.5em; height: 2px; background: var(--tim-accent); margin-right: 0.7em; vertical-align: middle; }
      .tim-canvas .tim-style-button { display: inline-flex; align-items: center; justify-content: center; align-self: center; min-height: 46px; padding: 0 1.6em; background: var(--tim-accent); color: var(--tim-ink); border-radius: 999px; }
      .tim-style-button a { color: inherit; text-decoration: none; }
      .tim-canvas .tim-card { background: var(--tim-surface); border-radius: var(--tim-radius); padding: 22px 24px; }
      .tim-card strong { display: block; font-size: 1.1rem; font-weight: 600; margin-bottom: 0.35em; }
      .tim-canvas .tim-rule { height: 1px; background: var(--tim-line); align-self: center; }
      .tim-brand a, .tim-footer a { color: inherit; text-decoration: none; }
      .tim-nav { font-weight: 600; font-size: 0.95rem; }
    </style>
    """

    /// Paper's head, complete.
    static func head(title: String) -> String {
        """
        <meta charset="utf-8">
        <meta name="generator" content="Tim">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(title))</title>
        \(fontLinks)
        \(styles)
        \(SiteTheme.overridesBlock(overrideRules))
        \(SiteTheme.templatesBlock(templateProps))
        """
    }

    // MARK: Pages

    /// A page in Paper's own look. `siteName` and `origin` shape the shared
    /// objects; with neither, the page stands alone (a local page).
    public static func page(_ template: Template, title: String, siteName: String? = nil, origin: String? = nil) -> String {
        let body = objects(for: template, title: title)
        let lastRow = PageComponents.lastObjectRow(in: body)
        var before = "", after = ""
        if let siteName {
            for (name, content) in components(siteName: siteName, origin: origin) {
                let piece = PageComponents.stamped(name: name, content: content) + "\n"
                if let row = PageComponents.startRow(of: content), row > lastRow { after += piece } else { before += piece }
            }
        }
        let inner = before + body + after
        return MobileCSS.regenerate(in: """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        \(head(title: title))
        </head>
        <body data-tim-template="\(template.pageTemplate)" data-tim-motion="reveal fade">
        <div class="tim-canvas" data-tim-canvas>
        \(inner)</div>
        </body>
        </html>
        """)
    }

    /// A page laid out like `template`, in the look of the site at `folder`
    /// when it has one — Paper's look when it doesn't.
    public static func page(_ template: Template, title: String, likeSiteAt folder: String?, siteName: String?, origin: String?) -> String {
        if let folder, !folder.isEmpty,
           let composed = LocalPage.composed(title: title, objects: objects(for: template, title: title), likeSiteAt: folder) {
            return MobileCSS.regenerate(in: composed)
        }
        return page(template, title: title, siteName: siteName, origin: origin)
    }

    /// A whole site: Home, About, Work, Writing and Contact, with the
    /// navigation, name and footer as shared objects in components/.
    /// Returns the site-relative paths written, pages first.
    @discardableResult
    public static func installSite(in folder: String, siteName: String, origin: String) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var written: [String] = []
        for template in Template.site {
            let html = page(template, title: template == .home ? siteName : template.title, siteName: siteName, origin: origin)
            try PageWriter.write(html: html, folder: folder, relativePath: template.file)
            written.append("/" + template.file)
        }
        for (name, content) in components(siteName: siteName, origin: origin) {
            try PageComponents.save(name: name, html: content, in: folder)
            written.append("/components/\(name).html")
        }
        return written
    }

    // MARK: Shared objects

    static func components(siteName: String, origin: String?) -> [(String, String)] {
        [("tpl-brand", brandMarkup(siteName: siteName)),
         ("tpl-nav", navMarkup(origin: origin)),
         ("tpl-footer", footerMarkup(siteName: siteName))]
    }

    static func brandMarkup(siteName: String) -> String {
        "<div class=\"tim-object tim-text tim-style-subheading tim-brand\" style=\"grid-area: 1 / 1 / 2 / 9; z-index: 2; display: flex; align-items: center;\"><a href=\"index.html\">\(esc(siteName))</a></div>"
    }

    static func navMarkup(origin: String?) -> String {
        let base = origin.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        let items = Template.site.map { t in
            NavKit.Item(label: t.title, href: (base.map { $0 + "/" } ?? "") + (t == .home ? (base == nil ? "index.html" : "") : t.file))
        }
        var nav = NavKit.markup(items: items, desktop: "row", mobile: "menu", selected: "underline", align: "end", gap: 28)
        nav = nav.replacingOccurrences(of: "style=\"--nav-gap:28px\"",
                                       with: "style=\"--nav-gap: 28px; grid-area: 1 / 9 / 2 / 25; z-index: 2;\"")
        return nav.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func footerMarkup(siteName: String) -> String {
        let year = Calendar.current.component(.year, from: Date())
        return "<div class=\"tim-object tim-text tim-style-caption tim-footer\" style=\"grid-area: 35 / 1 / 36 / 25; z-index: 2;\">© \(year) \(esc(siteName)). All rights reserved.</div>"
    }

    // MARK: Objects

    public static func objects(for template: Template, title: String) -> String {
        switch template {
        case .blank:
            return text("tim-style-title", esc(title), 4, 1, 7, 15)
                + text("tim-style-body", "Double-click any text to edit it. Drag objects to move them — everything snaps to the grid. Insert adds text boxes, photos and video.", 7, 1, 10, 13)

        case .home:
            return text("tim-style-eyebrow", "Designer · Photographer · Writer", 4, 1, 5, 12)
                + text("tim-style-title", "Make something, and put it where people can find it.", 5, 1, 10, 14)
                + text("tim-style-lead", "This is your home page. Everything on it is an object: double-click any text to change it, drop a photo onto a picture to replace it, and drag anything anywhere. When it looks right, press Done.", 10, 1, 13, 12)
                + text("tim-style-button", "<a href=\"work.html\">See the work</a>", 13, 1, 15, 5)
                + image(4, 15, 17, 25, label: "Photo")
                + rule(18)
                + card("Recent", "What you've been making lately — three or four lines is plenty.", 20, 1, 24, 9)
                + card("About", "Who you are, in a sentence or two, and where you are.", 20, 9, 24, 17)
                + card("Say hello", "An email address, and how quickly you tend to reply.", 20, 17, 24, 25)
                + text("tim-style-quote", "A line you believe about your work — the kind of thing you'd say out loud.", 26, 3, 30, 23, extra: "text-align: center;")

        case .about:
            return text("tim-style-eyebrow", "About", 4, 1, 5, 9)
                + text("tim-style-title", "A few true things about me.", 5, 1, 8, 15)
                + image(4, 16, 16, 25, label: "Portrait")
                + text("tim-style-lead", "Start with what you do and who it's for. One paragraph, plain words.", 9, 1, 11, 15)
                + text("tim-style-body", "Then the longer story: how you got here, what you care about, what you're working on now. Keep the sentences short.<br><br>This box grows as you type. Anything below it stays put, so drag it down if you need the room.", 11, 1, 16, 15)
                + rule(18)
                + text("tim-style-eyebrow", "Based in", 20, 1, 21, 8)
                + text("tim-style-body", "A city, a country.", 21, 1, 23, 8)
                + text("tim-style-eyebrow", "Working on", 20, 9, 21, 16)
                + text("tim-style-body", "A project, a book, a season.", 21, 9, 23, 16)
                + text("tim-style-eyebrow", "Say hello", 20, 17, 21, 25)
                + text("tim-style-body", "<a href=\"mailto:hello@example.com\">hello@example.com</a>", 21, 17, 23, 25)
                + text("tim-style-quote", "“Something someone said about working with you — kind, specific, and short.”", 25, 3, 29, 23, extra: "text-align: center;")
                + text("tim-style-caption", "— A client, a colleague, a friend", 29, 3, 30, 23, extra: "text-align: center;")

        case .work:
            var out = text("tim-style-eyebrow", "Work · 2019 – 2026", 4, 1, 5, 9)
                + text("tim-style-title", "Selected work", 5, 1, 8, 14)
                + text("tim-style-body", "Six pieces. Drop your own photos onto these, then write a line under each — what it is, who it was for, when.", 5, 16, 8, 25)
            let cols = [(1, 9), (9, 17), (17, 25)]
            for (rowIndex, rowStart) in [10, 19].enumerated() {
                for (i, c) in cols.enumerated() {
                    let n = rowIndex * 3 + i + 1
                    out += image(rowStart, c.0, rowStart + 7, c.1, label: "Photo \(n)")
                    out += text("tim-style-caption", "Project \(n) — what it is, and when", rowStart + 7, c.0, rowStart + 8, c.1)
                }
            }
            return out

        case .writing:
            return text("tim-style-eyebrow", "Writing · September 2026", 4, 6, 5, 19)
                + text("tim-style-title", "An essay title that takes its time", 5, 5, 9, 21)
                + text("tim-style-lead", "The first paragraph earns the second. Say the one thing the piece is about, plainly, and trust the reader to keep going.", 9, 6, 11, 19)
                + image(12, 3, 19, 23, label: "Photo")
                + text("tim-style-caption", "A caption: where, when, and what we're looking at.", 19, 6, 20, 19)
                + text("tim-style-body", "Then the argument, in short paragraphs. One idea each. If a sentence can lose a word, it loses it.<br><br>Pictures go between paragraphs where they earn their place, not where they fill space. A photo here is worth a paragraph; a chart is worth three.<br><br>End the section before the reader wants you to.", 21, 6, 26, 19)
                + text("tim-style-heading", "A second section", 27, 6, 28, 19)
                + text("tim-style-body", "Headings are for readers who skim. Make each one a small promise the paragraph below keeps.", 28, 6, 30, 19)

        case .contact:
            return text("tim-style-eyebrow", "Contact", 4, 1, 5, 9)
                + text("tim-style-title", "Let's make something together.", 5, 1, 9, 15)
                + text("tim-style-lead", "Tell me about the project, the timeline, and what a good outcome looks like.", 9, 1, 11, 13)
                + text("tim-style-button", "<a href=\"mailto:hello@example.com\">Email me</a>", 12, 1, 14, 5)
                + text("tim-style-eyebrow", "Email", 5, 17, 6, 25)
                + text("tim-style-body", "<a href=\"mailto:hello@example.com\">hello@example.com</a>", 6, 17, 7, 25)
                + text("tim-style-eyebrow", "Elsewhere", 8, 17, 9, 25)
                + text("tim-style-body", "<a href=\"#\">Instagram</a><br><a href=\"#\">LinkedIn</a><br><a href=\"#\">Are.na</a>", 9, 17, 12, 25)
                + text("tim-style-eyebrow", "Studio", 13, 17, 14, 25)
                + text("tim-style-body", "A street, a city, a country.<br>By appointment.", 14, 17, 16, 25)
                + rule(17)
                + image(19, 1, 31, 25, label: "A place")
        }
    }

    // MARK: Pieces

    static func text(_ style: String, _ html: String, _ r: Int, _ c: Int, _ re: Int, _ ce: Int, cls: String = "", extra: String = "") -> String {
        let classes = "tim-object tim-text \(style)" + (cls.isEmpty ? "" : " " + cls)
        return "  <div class=\"\(classes)\" style=\"grid-area: \(r) / \(c) / \(re) / \(ce);\(extra.isEmpty ? "" : " " + extra)\">\(html)</div>\n"
    }

    static func card(_ heading: String, _ body: String, _ r: Int, _ c: Int, _ re: Int, _ ce: Int) -> String {
        text("tim-style-body", "<strong>\(esc(heading))</strong>\(esc(body))", r, c, re, ce, cls: "tim-card")
    }

    static func rule(_ r: Int) -> String {
        "  <div class=\"tim-object tim-rule\" style=\"grid-area: \(r) / 1 / \(r + 1) / 25;\"></div>\n"
    }

    /// A photograph-shaped placeholder: a soft rectangle with a word on it,
    /// the exact proportions of its cells, and nothing to download. Drop a
    /// picture on it and it's gone.
    static func image(_ r: Int, _ c: Int, _ re: Int, _ ce: Int, label: String) -> String {
        let w = (ce - c) * 52 - 16, h = (re - r) * 48 - 16
        return "  <img class=\"tim-object\" alt=\"\" src=\"\(placeholder(w: w, h: h, label: label))\" style=\"grid-area: \(r) / \(c) / \(re) / \(ce);\">\n"
    }

    static func placeholder(w: Int, h: Int, label: String) -> String {
        let size = max(13, min(w, h) / 12)
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 \(w) \(h)'><rect width='\(w)' height='\(h)' fill='#e8e3d6'/><text x='50%' y='50%' dominant-baseline='middle' text-anchor='middle' font-family='-apple-system, system-ui, sans-serif' font-size='\(size)' font-weight='600' fill='#8f8878' letter-spacing='1'>\(esc(label))</text></svg>"
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~,'/:=()*!;")
        return "data:image/svg+xml;charset=utf-8," + (svg.addingPercentEncoding(withAllowedCharacters: allowed) ?? svg)
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
