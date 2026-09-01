import Foundation
import CryptoKit

/// "Make It Mine": the page you're looking at becomes a page you own —
/// a faithful frozen copy with every asset localized, published to your
/// server at a path you choose. Tier 1 semantics, promised honestly:
/// text, media, links, and metadata become editable; the layout stays
/// exactly as its author built it. JS-driven behavior imports as what it
/// rendered; forms keep their look but post to their old (absolutized)
/// endpoints.
public enum PageImporter {

    /// Runs in the live page first: strips <base>, absolutizes every
    /// href/src/srcset/action/poster against the page's own base, and
    /// lists the media, stylesheets, and icons worth localizing.
    public static let gatherJS = """
    (function () {
      var base = document.querySelector('base');
      if (base) { base.remove(); }
      function abs(el, attr) {
        var v = el.getAttribute(attr);
        if (!v || v.indexOf('data:') === 0 || v.indexOf('#') === 0 || v.indexOf('javascript:') === 0 || v.indexOf('mailto:') === 0) { return; }
        try { el.setAttribute(attr, new URL(v, document.baseURI).href); } catch (e) {}
      }
      var all = document.querySelectorAll('[href], [src], [srcset], [action], [poster]');
      for (var i = 0; i < all.length; i++) {
        var el = all[i];
        abs(el, 'href'); abs(el, 'src'); abs(el, 'action'); abs(el, 'poster');
        var ss = el.getAttribute('srcset');
        if (ss) {
          el.setAttribute('srcset', ss.split(',').map(function (part) {
            var bits = part.trim().split(/\\s+/);
            if (bits[0]) { try { bits[0] = new URL(bits[0], document.baseURI).href; } catch (e2) {} }
            return bits.join(' ');
          }).join(', '));
        }
      }
      var wants = [];
      function want(u) {
        if (u && u.indexOf('http') === 0 && wants.indexOf(u) < 0) { wants.push(u); }
      }
      var media = document.querySelectorAll('img, source, video, audio');
      for (var m = 0; m < media.length; m++) {
        want(media[m].getAttribute('src'));
        want(media[m].getAttribute('poster'));
        var mss = media[m].getAttribute('srcset');
        if (mss) {
          mss.split(',').forEach(function (part) { want(part.trim().split(/\\s+/)[0]); });
        }
      }
      var links = document.querySelectorAll('link[rel~="stylesheet"], link[rel~="icon"], link[rel~="apple-touch-icon"], link[rel~="shortcut"]');
      for (var l = 0; l < links.length; l++) { want(links[l].getAttribute('href')); }
      return JSON.stringify({ html: '<!doctype html>\\n' + document.documentElement.outerHTML, resources: wants });
    })()
    """

    public struct ImportedPage {
        public var html: String
        public var assets: [(name: String, data: Data)]
    }

    /// Downloads every listed resource, chases url(...) references one
    /// level inside stylesheets (fonts, background images), and rewrites
    /// the page to its new local assets/ folder.
    public static func localize(html: String, resources: [String], pageURL: URL) async -> ImportedPage {
        var out = html
        var assets: [(name: String, data: Data)] = []
        let session = URLSession(configuration: .ephemeral)
        for raw in resources {
            guard let url = URL(string: raw) else { continue }
            guard let (data, response) = try? await session.data(from: url), !data.isEmpty else { continue }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { continue }
            let name = assetName(for: url)
            let isCSS = url.pathExtension.lowercased() == "css"
                || (response.mimeType ?? "").contains("text/css")
            if isCSS, let css = String(data: data, encoding: .utf8) {
                let localized = await localizeCSS(css, cssURL: url, session: session)
                assets.append((name, Data(localized.css.utf8)))
                assets.append(contentsOf: localized.extras)
            } else {
                assets.append((name, data))
            }
            let rel = "assets/\(name)"
            out = out.replacingOccurrences(of: escapedForHTML(raw), with: rel)
            out = out.replacingOccurrences(of: raw, with: rel)
        }
        // The generator meta is what lights the pencil up: this copy is
        // Tim's to edit now (text, media, links, metadata).
        if out.range(of: "meta name=\"generator\"") == nil, let head = out.range(of: "</head>") {
            out.insert(contentsOf: "<meta name=\"generator\" content=\"Tim (imported page)\">\n", at: head.lowerBound)
        }
        return ImportedPage(html: out, assets: assets)
    }

    static func localizeCSS(_ css: String, cssURL: URL, session: URLSession) async -> (css: String, extras: [(name: String, data: Data)]) {
        var out = css
        var extras: [(name: String, data: Data)] = []
        guard let regex = try? NSRegularExpression(pattern: "url\\(\\s*['\"]?([^'\")\\s]+)['\"]?\\s*\\)") else {
            return (out, extras)
        }
        var seen = Set<String>()
        for match in regex.matches(in: css, range: NSRange(css.startIndex..., in: css)) {
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: css) else { continue }
            let ref = String(css[range])
            guard !ref.hasPrefix("data:"), !ref.hasPrefix("#"), !seen.contains(ref),
                  let refURL = URL(string: ref, relativeTo: cssURL)?.absoluteURL
            else { continue }
            seen.insert(ref)
            guard let (data, response) = try? await session.data(from: refURL), !data.isEmpty else { continue }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { continue }
            let name = assetName(for: refURL)
            extras.append((name, data))
            // CSS lives in assets/ too — siblings reference by bare name.
            out = out.replacingOccurrences(of: ref, with: name)
        }
        return (out, extras)
    }

    /// Stable, collision-free local names: a content-address prefix plus
    /// the original filename, query strings shed.
    static func assetName(for url: URL) -> String {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(8)
        var file = url.lastPathComponent
        if let q = file.firstIndex(of: "?") { file = String(file[..<q]) }
        if file.isEmpty || file == "/" { file = "asset" }
        return "\(hash)-\(file)"
    }

    static func escapedForHTML(_ url: String) -> String {
        url.replacingOccurrences(of: "&", with: "&amp;")
    }

    /// The destination path a page defaults to: the original site's host
    /// plus its path, under /imported — never colliding with your pages.
    public static func defaultPath(for url: URL) -> String {
        var path = url.path
        if path.isEmpty || path == "/" {
            path = "/index.html"
        } else if path.hasSuffix("/") {
            path += "index.html"
        } else if !(path as NSString).lastPathComponent.contains(".") {
            path += "/index.html"
        }
        let host = (url.host() ?? "page").replacingOccurrences(of: "www.", with: "")
        return "/imported/\(host)\(path)"
    }
}
