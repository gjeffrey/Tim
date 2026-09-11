import AppKit
import Foundation
import TimKit

/// Tim's home: the page a new tab opens on. Your sites and their pages as
/// pictures, your recent local pages, and the one button someone with no
/// server at all needs — make something now, decide where it lives later.
///
/// It is a web page rather than a panel because that is what Tim is: the
/// browser is the app. Actions a page can't perform on its own arrive as
/// `tim:` links, which the tab intercepts.
enum HomePage {
    static func html(sites: [Site]) -> String {
        var sections = ""

        for site in sites {
            let pages = LinkSources.pages(for: site)
            let name = site.name.isEmpty ? (URL(string: site.origin)?.host() ?? site.origin) : site.name
            let host = URL(string: site.origin)?.host() ?? site.origin
            var cards = ""
            for page in pages.prefix(24) {
                let full = site.origin + page.href
                cards += card(title: page.label, subtitle: page.href, href: full, thumbnail: full)
            }
            if cards.isEmpty {
                cards = """
                <a class="card empty" href="\(esc(site.origin))"><div class="shot"></div>
                <div class="meta"><b>Nothing here yet</b><span>\(esc(host))</span></div></a>
                """
            }
            sections += """
            <section><h2>\(esc(name))<a class="visit" href="\(esc(site.origin))">\(esc(host))</a></h2>
            <div class="grid">\(cards)</div></section>
            """
        }

        // Local pages have no site to belong to, so they get their own shelf.
        let locals = PageRegistry.all().filter { URL(string: $0.url)?.isFileURL == true }
        if !locals.isEmpty {
            var cards = ""
            for page in locals.prefix(12) {
                let file = URL(string: page.url)
                let label = page.title.isEmpty ? (file?.deletingPathExtension().lastPathComponent ?? "Untitled") : page.title
                cards += card(title: label, subtitle: "On this Mac", href: page.url, thumbnail: page.url)
            }
            sections += """
            <section><h2>On This Mac<span class="note">Not published — yours alone until you put them somewhere</span></h2>
            <div class="grid">\(cards)</div></section>
            """
        }

        if sites.isEmpty {
            sections += """
            <section class="intro"><p>A page for your photographs. A tiny magazine. A love letter to something obscure.
            Start here on your Mac; connect a site when you’re ready to share it.</p></section>
            """
        }

        return page(sections)
    }

    private static func card(title: String, subtitle: String, href: String, thumbnail: String) -> String {
        let shot = ThumbnailStore.image(for: thumbnail).flatMap(dataURI)
        let img = shot.map { "<img class=\"shot\" src=\"\($0)\" alt=\"\">" } ?? "<div class=\"shot\"></div>"
        return """
        <a class="card" href="\(esc(href))">\(img)<div class="meta"><b>\(esc(title))</b><span>\(esc(subtitle))</span></div></a>
        """
    }

    /// Thumbnails travel inside the page, small enough not to weigh it down.
    private static func dataURI(_ image: NSImage) -> String? {
        let width: CGFloat = 320
        let scale = width / max(image.size.width, 1)
        let size = NSSize(width: width, height: max(1, (image.size.height * scale).rounded()))
        let scaled = NSImage(size: size)
        scaled.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        scaled.unlockFocus()
        guard let tiff = scaled.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.72])
        else { return nil }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func page(_ sections: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Start</title>
        <style>
          :root { color-scheme: light dark; --ink:#1d1d1f; --dim:#6e6e73; --paper:#fbfbfd; --card:#fff; --line:rgba(0,0,0,0.10); }
          @media (prefers-color-scheme: dark) { :root { --ink:#f5f5f7; --dim:#a1a1a6; --paper:#161617; --card:#1e1e20; --line:rgba(255,255,255,0.14); } }
          * { margin:0; padding:0; box-sizing:border-box; }
          body { font-family:-apple-system, ui-sans-serif, system-ui, sans-serif; background:var(--paper); color:var(--ink); }
          main { max-width:60rem; margin:0 auto; padding:3.2rem 2rem 4rem; }
          h1 { font-family:Georgia, serif; font-size:3rem; font-weight:400; letter-spacing:-0.06em; }
          .welcome { padding:2rem 0 2.5rem; }
          .welcome h2 { display:block; color:var(--ink); font-family:Georgia, serif; font-size:clamp(2.4rem, 5vw, 4.5rem); font-weight:400; line-height:1.06; letter-spacing:-0.045em; text-transform:none; max-width:12ch; margin-bottom:1rem; }
          .welcome p { color:var(--dim); font-size:1.05rem; line-height:1.6; max-width:38rem; margin-bottom:1.3rem; }
          .welcome .actions { margin-bottom:0.8rem; }
          .welcome .reassurance { font-size:0.8rem; margin-bottom:0; }
          a:focus-visible { outline:3px solid #0a84ff; outline-offset:5px; }
          @media(max-width:520px) { main { padding:2rem 1.2rem; } h2 { flex-wrap:wrap; } .grid { grid-template-columns:repeat(auto-fill,minmax(150px,1fr)); } }
          .tagline { font-size:1.05rem; color:var(--dim); margin:0.1rem 0 1.8rem; }
          .actions { display:flex; gap:0.6rem; align-items:center; flex-wrap:wrap; margin-bottom:2.6rem; }
          a.primary { background:#ffd60a; color:#111; font-weight:600; font-size:0.95rem;
                      padding:0.62rem 1.15rem; border-radius:999px; text-decoration:none; }
          a.ghost { border:1px solid var(--line); color:var(--ink); font-size:0.95rem;
                    padding:0.6rem 1.05rem; border-radius:999px; text-decoration:none; }
          a.primary:hover { filter:brightness(1.05); } a.ghost:hover { border-color:var(--ink); }
          section { margin-bottom:2.6rem; }
          h2 { font-size:0.82rem; font-weight:600; text-transform:uppercase; letter-spacing:0.06em;
               color:var(--dim); margin-bottom:0.85rem; display:flex; align-items:baseline; gap:0.7rem; }
          h2 .visit, h2 .note { text-transform:none; letter-spacing:0; font-weight:400; font-size:0.8rem; color:var(--dim); text-decoration:none; }
          h2 .visit:hover { color:#0a84ff; }
          .grid { display:grid; grid-template-columns:repeat(auto-fill, minmax(190px, 1fr)); gap:1rem; }
          .card { display:block; text-decoration:none; color:inherit; }
          .shot { display:block; width:100%; aspect-ratio:16/10; object-fit:cover; object-position:top center;
                  background:var(--card); border:1px solid var(--line); border-radius:10px; }
          .card:hover .shot { border-color:#0a84ff; }
          .meta { padding:0.5rem 0.15rem 0; }
          .meta b { display:block; font-size:0.9rem; font-weight:600; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
          .meta span { display:block; font-size:0.78rem; color:var(--dim); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
          .intro p { font-size:1rem; line-height:1.6; color:var(--dim); max-width:38rem; margin-bottom:1rem; }
          .empty .shot { opacity:0.5; }
        </style></head>
        <body><main>
          <h1>Tim</h1>
          <p class="tagline">The web, editable again.</p>
          <div class="welcome">
          <h2>The web could use a little more you.</h2>
          <p>Make something just because. Move the words, change the colors, follow an idea. Every piece is yours to play with.</p>
          <div class="actions">
            <a class="primary" href="tim:playground">Start playing ↗</a>
            <a class="ghost" href="tim:new-local">Start a blank page…</a>
            <a class="ghost" href="tim:open">Open…</a>
            <a class="ghost" href="tim:connect">Connect a Site…</a>
          </div>
          <p class="reassurance">The playground opens on your Mac. No account. Nothing goes online.</p>
          </div>
          \(sections)
        </main></body></html>
        """
    }
}
