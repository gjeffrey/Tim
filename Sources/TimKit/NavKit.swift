import Foundation

/// Navigation, done as the web does it: a real list of links.
///
///     <nav class="tim-object tim-nav" data-nav-d="row" data-nav-m="menu"
///          data-nav-sel="underline" data-nav-align="start" data-nav-label="icon"
///          style="--nav-gap:24px">
///       <details open><summary>…</summary>
///         <ul><li><a href>Home</a></li><li><a>Work</a><ul>…submenu…</ul></li></ul>
///       </details>
///     </nav>
///
/// Desktop and phone each pick a layout — Row, Column, or Menu (a button
/// that opens a panel) — from one piece of markup. Row layouts open
/// submenus on hover/focus; Column and Menu show them indented. The
/// current page is marked `aria-current` by a few lines of script, and
/// the selected style (underline, pill, bold, dim) hangs off that. With
/// no script at all the list is simply visible, as a list should be.
public enum NavKit {
    public struct Item: Codable, Equatable {
        public var label: String
        public var href: String
        public var depth: Int
        public init(label: String, href: String, depth: Int = 0) { self.label = label; self.href = href; self.depth = depth }
    }

    public static let layouts = ["row", "column", "menu"]
    public static let selectedStyles = ["none", "underline", "pill", "bold", "dim"]

    /// A fresh navigation object for the Insert menu.
    public static func markup(items: [Item], desktop: String = "row", mobile: String = "menu",
                              selected: String = "underline", align: String = "start", gap: Int = 24, label: String = "icon") -> String {
        var list = ""
        var openSub = false
        for item in items {
            let a = "<a href=\"\(esc(item.href))\">\(esc(item.label))</a>"
            if item.depth > 0 {
                if !openSub { list += "<ul>"; openSub = true }
                list += "<li>\(a)</li>"
            } else {
                if openSub { list += "</ul></li>"; openSub = false } else if !list.isEmpty { list += "</li>" }
                list += "<li>\(a)"
            }
        }
        if openSub { list += "</ul></li>" } else if !list.isEmpty { list += "</li>" }
        return """
        <nav class="tim-object tim-nav" aria-label="Site" data-nav-d="\(desktop)" data-nav-m="\(mobile)" data-nav-sel="\(selected)" data-nav-align="\(align)" data-nav-label="\(label)" style="--nav-gap:\(gap)px"><details open><summary aria-label="Menu"><span class="tim-nav-bars"></span><span class="tim-nav-word">Menu</span></summary><ul>\(list)</ul></details></nav>
        """
    }

    /// Save-time pass: pages with a nav carry the canonical style + script;
    /// pages without lose them. Per-visit state (open menu, current-page
    /// marks) is scrubbed so the file stays clean and the no-script
    /// fallback is a visible list.
    public static func ensure(in html: String) -> String {
        var out = html
        // Same trap as the motion block: a bare attribute serialises as
        // data-tim-nav="", so the old pattern matched nothing and every
        // save added another copy. Holland had thirteen.
        out = out.replacingOccurrences(of: "<style data-tim-nav[^>]*>[\\s\\S]*?</style>\\n?", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "<script data-tim-nav[^>]*>[\\s\\S]*?</script>\\n?", with: "", options: .regularExpression)
        guard out.contains("tim-nav") else { return out }
        out = out.replacingOccurrences(of: " aria-current=\"page\"", with: "")
        out = out.replacingOccurrences(of: " tim-nav-open", with: "")
        out = out.replacingOccurrences(of: "<details>", with: "<details open>")
        out = out.replacingOccurrences(of: "<details open=\"\">", with: "<details open>")
        if let head = out.range(of: "</head>") {
            out.insert(contentsOf: "<style data-tim-nav>\n" + css + "\n</style>\n", at: head.lowerBound)
        }
        if let bodyEnd = out.range(of: "</body>", options: .backwards) {
            out.insert(contentsOf: "<script data-tim-nav>\n" + script + "\n</script>\n", at: bodyEnd.lowerBound)
        }
        return out
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: The style sheet

    static let panel = "background:var(--nav-panel,rgba(255,255,255,.96));color:var(--nav-panel-ink,#111);border-radius:12px;box-shadow:0 1px 2px rgba(0,0,0,.08),0 14px 40px -12px rgba(0,0,0,.28);-webkit-backdrop-filter:blur(18px);backdrop-filter:blur(18px)"

    /// Rules for one layout, under one selector prefix (desktop or phone).
    static func layoutRules(_ s: String, _ layout: String) -> String {
        switch layout {
        case "row": return """
            \(s)>details>ul{flex-direction:row;flex-wrap:wrap;align-items:center;justify-content:var(--nav-justify,flex-start)}
            \(s) li>ul{display:none;position:absolute;top:100%;left:0;flex-direction:column;gap:2px;min-width:180px;padding:10px 14px;\(panel);z-index:40}
            \(s) li:hover>ul,\(s) li:focus-within>ul{display:flex}
            \(s) li:has(>ul)>a::after{content:"";display:inline-block;width:.38em;height:.38em;border-right:1.5px solid currentColor;border-bottom:1.5px solid currentColor;transform:rotate(45deg) translateY(-.2em);margin-left:.5em;vertical-align:middle;opacity:.7}
            """
        case "column": return """
            \(s)>details>ul{flex-direction:column;align-items:var(--nav-items,flex-start);gap:calc(var(--nav-gap,24px)*.45)}
            \(s) li>ul{display:flex;flex-direction:column;padding-left:1.1em;gap:.15em;margin-top:.2em;font-size:.92em}
            """
        default: return """
            \(s)>details>summary{display:inline-flex}
            \(s)>details{display:flex;justify-content:var(--nav-justify,flex-start)}
            \(s):not(.tim-nav-open)>details>ul{display:none}
            \(s)>details>ul{position:absolute;top:calc(100% + 8px);left:0;flex-direction:column;align-items:flex-start;gap:.15em;min-width:220px;padding:14px 18px;\(panel);z-index:60}
            \(s)[data-nav-align=end]>details>ul{left:auto;right:0}
            \(s)[data-nav-align=center]>details>ul{left:50%;transform:translateX(-50%)}
            \(s) li>ul{display:flex;flex-direction:column;padding-left:1.1em;gap:.1em;margin-top:.15em;font-size:.92em}
            """
        }
    }

    public static let css: String = {
        var out = """
        .tim-nav{position:relative;font-weight:500}
        .tim-nav ul{list-style:none;margin:0;padding:0}
        .tim-nav li{position:relative;margin:0}
        .tim-nav a{color:inherit;text-decoration:none;display:inline-block;padding:.3em .15em;border-radius:.5em;transition:opacity .15s}
        .tim-nav a:hover{opacity:.65}
        .tim-nav>details{position:relative}
        .tim-nav>details>summary{list-style:none;cursor:pointer;display:none;align-items:center;gap:10px;padding:.35em .15em;-webkit-user-select:none;user-select:none}
        .tim-nav>details>summary::-webkit-details-marker{display:none}
        .tim-nav .tim-nav-bars{display:inline-block;width:22px;height:2px;background:currentColor;box-shadow:0 -7px 0 currentColor,0 7px 0 currentColor;border-radius:1px}
        .tim-nav[data-nav-label=icon] .tim-nav-word{display:none}
        .tim-nav[data-nav-label=word] .tim-nav-bars{display:none}
        .tim-nav>details>ul{display:flex;gap:var(--nav-gap,24px)}
        .tim-nav[data-nav-align=center]{--nav-justify:center;--nav-items:center}
        .tim-nav[data-nav-align=end]{--nav-justify:flex-end;--nav-items:flex-end}
        .tim-nav[data-nav-align=between]{--nav-justify:space-between;--nav-items:stretch}
        .tim-nav[data-nav-sel=underline] a[aria-current]{text-decoration:underline;text-underline-offset:.28em;text-decoration-thickness:2px}
        .tim-nav[data-nav-sel=pill] a{padding:.35em .85em;border-radius:999px}
        .tim-nav[data-nav-sel=pill] a[aria-current]{background:color-mix(in srgb,currentColor 13%,transparent)}
        .tim-nav[data-nav-sel=bold] a[aria-current]{font-weight:700}
        .tim-nav[data-nav-sel=dim] a:not([aria-current]){opacity:.5}
        .tim-nav[data-nav-sel=dim] a:not([aria-current]):hover{opacity:.85}
        @media (prefers-color-scheme:dark){.tim-nav{--nav-panel:rgba(30,30,30,.96);--nav-panel-ink:#f2f2f2}}
        """
        out += "\n@media (min-width:701px){\n" + layouts.map { layoutRules(".tim-nav[data-nav-d=\($0)]", $0) }.joined(separator: "\n") + "\n}"
        out += "\n@media (max-width:700px){\n" + layouts.map { layoutRules(".tim-nav[data-nav-m=\($0)]", $0) }.joined(separator: "\n") + "\n}"
        return out
    }()

    // MARK: The script

    public static let script = """
    (function(){
    function mode(nav){return (window.matchMedia&&matchMedia('(max-width: 700px)').matches)?(nav.getAttribute('data-nav-m')||'menu'):(nav.getAttribute('data-nav-d')||'row')}
    function norm(p){p=p.replace(/\\/index\\.html?$/,'/');if(p.length>1&&p.slice(-1)==='/')p=p.slice(0,-1);return p||'/'}
    function refresh(){var here=norm(location.pathname);
      var navs=document.querySelectorAll('.tim-nav');
      for(var i=0;i<navs.length;i++){var nav=navs[i];var m=mode(nav);var d=nav.querySelector(':scope > details');
        if(d){d.open=true}
        if(nav.__timMode!==m){nav.classList.remove('tim-nav-open')}
        nav.__timMode=m;
        var links=nav.querySelectorAll('a[href]');
        for(var j=0;j<links.length;j++){var a=links[j],u;try{u=new URL(a.getAttribute('href'),location.href)}catch(e){continue}
          if(u.origin===location.origin&&norm(u.pathname)===here){a.setAttribute('aria-current','page')}else{a.removeAttribute('aria-current')}}}}
    window.__timNavRefresh=refresh;
    function closeAll(except){var open=document.querySelectorAll('.tim-nav.tim-nav-open');for(var i=0;i<open.length;i++){if(open[i]!==except){open[i].classList.remove('tim-nav-open')}}}
    document.addEventListener('click',function(e){
      var s=e.target&&e.target.closest?e.target.closest('.tim-nav > details > summary'):null;
      if(s){e.preventDefault();var nav=s.parentElement.parentElement;nav.classList.toggle('tim-nav-open');closeAll(nav);return}
      var inside=e.target&&e.target.closest?e.target.closest('.tim-nav'):null;
      closeAll(inside)});
    document.addEventListener('keydown',function(e){if(e.key==='Escape'){closeAll(null)}});
    var t;window.addEventListener('resize',function(){clearTimeout(t);t=setTimeout(refresh,80)});
    if(document.readyState==='loading'){document.addEventListener('DOMContentLoaded',refresh)}else{refresh()}
    })();
    """
}
