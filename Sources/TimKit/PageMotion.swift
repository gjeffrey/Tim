import Foundation

/// Motion, the Tim way: two toggles, beautiful defaults, no panel.
///
/// `reveal` — every top-level object fades up 8px into place as it enters
/// view, staggered in reading order (top→bottom, left→right) 45ms apart.
/// Above the fold that is the page arriving one object at a time; below
/// it, the scroll reveal. `fade` — the page eases in on load and eases
/// out on a click to another page of the site, so moving through the site
/// feels like turning pages. Emitted at save as one small inline
/// style + script (no dependencies), inert while editing, invisible to
/// Reduce Motion, and fully visible without JavaScript.
public enum PageMotion {
    public static func modes(in html: String) -> Set<String> {
        guard let body = html.range(of: "<body[^>]*>", options: .regularExpression),
              let attr = MobileCSS.capture(String(html[body]), "data-tim-motion=\"([^\"]*)\"")
        else { return [] }
        return Set(attr.split(separator: " ").map(String.init).filter { !$0.isEmpty })
    }

    public static func ensure(in html: String) -> String {
        var out = html
        // Always strip the previous emission, then re-emit for the current modes.
        out = out.replacingOccurrences(of: "<style data-tim-motion>[\\s\\S]*?</style>\\n?", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "<script data-tim-motion>[\\s\\S]*?</script>\\n?", with: "", options: .regularExpression)
        let modes = modes(in: out)
        guard !modes.isEmpty else { return out }
        if let head = out.range(of: "</head>") {
            out.insert(contentsOf: style + "\n", at: head.lowerBound)
        }
        if let bodyEnd = out.range(of: "</body>", options: .backwards) {
            out.insert(contentsOf: script + "\n", at: bodyEnd.lowerBound)
        }
        return out
    }

    static let style = """
    <style data-tim-motion>
    html.tim-reveal .tim-canvas > .tim-object{transition:opacity .38s cubic-bezier(.2,.7,.2,1),transform .38s cubic-bezier(.2,.7,.2,1)}
    html.tim-reveal .tim-canvas > .tim-object:not(.tim-in){opacity:0;transform:translateY(8px)}
    html.tim-fade body{opacity:0;transition:opacity .26s ease-out}
    html.tim-fade.tim-ready body{opacity:1}
    @media (prefers-reduced-motion: reduce){html.tim-reveal .tim-canvas > .tim-object,html.tim-fade body{opacity:1 !important;transform:none !important;transition:none !important}}
    </style>
    """

    static let script = """
    <script data-tim-motion>
    (function(){var h=document.documentElement;if(h.classList.contains('tim-editing'))return;
    if(window.matchMedia&&matchMedia('(prefers-reduced-motion: reduce)').matches)return;
    var m=document.body.getAttribute('data-tim-motion')||'';
    if(m.indexOf('fade')>=0){h.classList.add('tim-fade');
      requestAnimationFrame(function(){requestAnimationFrame(function(){h.classList.add('tim-ready')})});
      window.addEventListener('pageshow',function(ev){if(ev.persisted)h.classList.add('tim-ready')});
      document.addEventListener('click',function(e){
        if(e.defaultPrevented||e.button!==0||e.metaKey||e.ctrlKey||e.shiftKey||e.altKey)return;
        var a=e.target&&e.target.closest?e.target.closest('a[href]'):null;
        if(!a||(a.target&&a.target!=='_self')||a.hasAttribute('download'))return;
        var u;try{u=new URL(a.getAttribute('href'),location.href)}catch(x){return}
        if(u.origin!==location.origin||(u.pathname===location.pathname&&u.hash))return;
        e.preventDefault();h.classList.remove('tim-ready');setTimeout(function(){location.href=u.href},190)},true);}
    if(m.indexOf('reveal')>=0&&'IntersectionObserver' in window){h.classList.add('tim-reveal');
      var els=[].slice.call(document.querySelectorAll('.tim-canvas > .tim-object'));
      var io=new IntersectionObserver(function(entries){
        var batch=[];for(var i=0;i<entries.length;i++){if(entries[i].isIntersecting)batch.push(entries[i].target)}
        if(!batch.length)return;
        batch.sort(function(a,b){var ra=a.getBoundingClientRect(),rb=b.getBoundingClientRect();return (ra.top-rb.top)||(ra.left-rb.left)});
        batch.forEach(function(el,i){el.style.transitionDelay=Math.min(i*45,450)+'ms';el.classList.add('tim-in');io.unobserve(el)})
      },{rootMargin:'0px 0px -8% 0px',threshold:0.05});
      els.forEach(function(el){io.observe(el)});}
    })();
    </script>
    """
}
