import Foundation

/// The Showcase: a hand-picked gallery of sites made with Tim. The app
/// submits; a person approves. Just enough friction to mean it.
public enum ShowcaseAPI {
    public static var endpoint: URL {
        if let custom = UserDefaults.standard.string(forKey: "tim.showcase.endpoint"), let url = URL(string: custom) { return url }
        return URL(string: "https://gabrieljeffrey.com/tim/showcase")!
    }
    public static var galleryURL: URL { endpoint }

    public struct Inspection: Sendable {
        public var reachable = false
        public var madeWithTim = false
        public var title = ""
        public var image: URL?
    }

    /// What the world sees at this address right now: live? Tim-made? title, social image.
    public static func inspect(_ url: URL) async -> Inspection {
        var out = Inspection()
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data.prefix(200_000), encoding: .utf8)
        else { return out }
        out.reachable = true
        out.madeWithTim = html.range(of: "<meta\\s+name=[\"']generator[\"']\\s+content=[\"']Tim", options: [.regularExpression, .caseInsensitive]) != nil
            || html.range(of: "<meta\\s+content=[\"']Tim[^\"']*[\"']\\s+name=[\"']generator[\"']", options: [.regularExpression, .caseInsensitive]) != nil
        out.title = meta(html, "og:title") ?? capture(html, "<title[^>]*>([^<]*)</title>")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let img = meta(html, "og:image"), let u = URL(string: img, relativeTo: url) { out.image = u.absoluteURL }
        return out
    }

    public enum SubmitError: LocalizedError {
        case server(String)
        public var errorDescription: String? { if case .server(let s) = self { return s }; return nil }
    }

    /// Returns the server's thank-you line.
    public static func submit(url: URL, name: String, note: String) async throws -> String {
        var request = URLRequest(url: endpoint.appending(path: "submit"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "url": url.absoluteString, "name": name, "note": note, "agree": true
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SubmitError.server(body["error"] as? String ?? "The Showcase didn't answer. Try again in a little while.")
        }
        return body["message"] as? String ?? "Thanks — we'll take a look."
    }

    static func meta(_ html: String, _ property: String) -> String? {
        let p = NSRegularExpression.escapedPattern(for: property)
        return capture(html, "<meta\\s+property=[\"']\(p)[\"']\\s+content=[\"']([^\"']*)[\"']")
            ?? capture(html, "<meta\\s+content=[\"']([^\"']*)[\"']\\s+property=[\"']\(p)[\"']")
    }
    static func capture(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r]).replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
    }
}
