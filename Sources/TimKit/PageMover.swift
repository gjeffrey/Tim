import Foundation

/// Moving a page is moving a file — and fixing what pointed at it.
/// Relative addresses in the page (media, links, styles) are rebased so
/// nothing breaks when the page changes depth, and the old address can
/// keep a small forwarding page so links out in the world still work.
public enum PageMover {
    /// Rewrites relative src/href/poster/url() values so they resolve the
    /// same after the page moves from `from` to `to` (site-relative paths
    /// like "/about.html", both starting with "/").
    public static func rebase(html: String, from: String, to: String, origin: String) -> String {
        guard let oldURL = URL(string: origin + from), let newURL = URL(string: origin + to),
              from.split(separator: "/").count != to.split(separator: "/").count || true
        else { return html }
        var out = html
        let patterns = ["(src|href|poster)=\"([^\"]*)\"", "url\\((['\"]?)([^)'\"]*)\\1\\)"]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = re.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed()
            for m in matches {
                let valueIndex = pattern.hasPrefix("url") ? 2 : 2
                guard let vr = Range(m.range(at: valueIndex), in: out) else { continue }
                let value = String(out[vr])
                guard isRelative(value), let abs = URL(string: value, relativeTo: oldURL)?.absoluteURL else { continue }
                let rel = relativePath(from: newURL, to: abs)
                out.replaceSubrange(vr, with: rel)
            }
        }
        return out
    }

    static func isRelative(_ v: String) -> Bool {
        !(v.isEmpty || v.hasPrefix("#") || v.hasPrefix("/") || v.contains("://") || v.hasPrefix("data:") || v.hasPrefix("mailto:") || v.hasPrefix("tel:") || v.hasPrefix("javascript:") || v.hasPrefix("//"))
    }

    /// "../media/x.jpg"-style path from the folder of `page` to `target`.
    static func relativePath(from page: URL, to target: URL) -> String {
        guard page.host == target.host else { return target.absoluteString }
        let pageDir = Array(page.pathComponents.dropLast().dropFirst())
        var targetParts = Array(target.pathComponents.dropFirst())
        var common = 0
        while common < pageDir.count, common < targetParts.count - 1, pageDir[common] == targetParts[common] { common += 1 }
        let ups = pageDir.count - common
        targetParts.removeFirst(common)
        var rel = String(repeating: "../", count: ups) + targetParts.joined(separator: "/")
        if let q = target.query { rel += "?" + q }
        if let f = target.fragment { rel += "#" + f }
        return rel
    }

    /// The small page left behind: forwards visitors and search engines.
    public static func forwardingPage(to newURL: String, title: String) -> String {
        let t = title.isEmpty ? "This page has moved" : title
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="generator" content="Tim (moved)">
        <meta http-equiv="refresh" content="0; url=\(newURL)">
        <link rel="canonical" href="\(newURL)">
        <meta name="robots" content="noindex">
        <title>\(t)</title>
        <style>body{font:17px/1.5 -apple-system,system-ui,sans-serif;color:#333;max-width:36em;margin:20vh auto;padding:0 24px}a{color:#0a84ff}</style>
        </head><body><p>This page has moved to <a href="\(newURL)">\(newURL)</a>.</p></body></html>
        """
    }

    /// Folders in a site mirror (site-relative, "/" first), for the picker.
    public static func folders(in mirror: String) -> [String] {
        guard let subpaths = try? FileManager.default.subpathsOfDirectory(atPath: mirror) else { return ["/"] }
        var dirs: [String] = ["/"]
        for rel in subpaths {
            let full = (mirror as NSString).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
            let first = rel.split(separator: "/").first.map(String.init) ?? rel
            if first.hasPrefix(".") || first.hasPrefix("_") || ["media", "components", "node_modules", "dist", "src", "public"].contains(first) { continue }
            dirs.append("/" + rel)
        }
        return dirs.sorted()
    }
}
