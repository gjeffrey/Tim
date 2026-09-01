import Foundation

/// Shared metadata plumbing — the auto share-card tags belong to every
/// platform that publishes, not just the Mac (the iPad publishing pages
/// without them is how cards quietly stopped updating).
public enum PageMeta {
    /// Every published page carries share-card tags. Absent → inserted
    /// pointing at the deterministic per-page filename; an auto card
    /// pointing anywhere else is a leftover of the one-per-site era and
    /// migrates; a custom image is theirs and stays untouched.
    public static func ensureAutoSocial(in html: String, rel: String, site: Site) -> String {
        let slug = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
        let value = site.origin.hasPrefix("http")
            ? site.origin + "/media/social-\(slug).png"
            : "media/social-\(slug).png"
        if let existing = content(in: html, property: "og:image") {
            let name = (existing as NSString).lastPathComponent
            guard name.hasPrefix("social-"), name != "social-\(slug).png" else { return html }
            return html
                .replacingOccurrences(of: "property=\"og:image\" content=\"\(existing)\"",
                                      with: "property=\"og:image\" content=\"\(value)\"")
                .replacingOccurrences(of: "name=\"twitter:image\" content=\"\(existing)\"",
                                      with: "name=\"twitter:image\" content=\"\(value)\"")
        }
        guard let head = html.range(of: "</head>") else { return html }
        var out = html
        out.insert(contentsOf: "<meta property=\"og:image\" content=\"\(value)\">\n"
            + "<meta name=\"twitter:image\" content=\"\(value)\">\n"
            + "<meta name=\"twitter:card\" content=\"summary_large_image\">\n", at: head.lowerBound)
        return out
    }

    public static func content(in html: String, property: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "property=\"\(property)\" content=\"([^\"]*)\""),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[range])
    }

    /// The per-page card filename for a page path.
    public static func socialSlug(rel: String) -> String {
        ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
