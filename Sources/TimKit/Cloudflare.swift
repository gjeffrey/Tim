import Foundation
import CryptoKit
import Security

/// Cloudflare, handled: authenticate once with an API token (kept in the
/// Keychain, synced by iCloud Keychain where available) and Tim does the
/// rest over the REST API — no wrangler, no CLI, works on iPad. A site
/// publishes as a Worker with static assets, mounted on your own zone at
/// any path ("gabrieljeffrey.com/something"), route and all.
public enum CloudflareAPI {
    static let base = "https://api.cloudflare.com/client/v4"

    public enum CFError: LocalizedError {
        case noToken
        case api(String)
        public var errorDescription: String? {
            switch self {
            case .noToken: return "No Cloudflare token — connect Cloudflare in the site's settings."
            case .api(let message): return message
            }
        }
    }

    // MARK: Token, in the Keychain

    static let service = "com.gabrieljeffrey.tim"
    static let account = "cloudflare-api-token"

    public static var token: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty
        else { return nil }
        return value
    }

    @discardableResult
    public static func storeToken(_ value: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return true }
        var add = query
        add[kSecAttrSynchronizable as String] = true
        add[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Verifies the stored (or provided) token and returns a short status.
    public static func verify(_ candidate: String? = nil) throws -> String {
        let bearer = candidate ?? token
        guard let bearer else { throw CFError.noToken }
        let result = try call("GET", "\(base)/user/tokens/verify", bearer: bearer)
        let status = (result as? [String: Any])?["status"] as? String ?? "unknown"
        return status
    }

    // MARK: Account and zone

    static var cachedAccount: String?

    static func accountID(_ bearer: String) throws -> String {
        if let cachedAccount { return cachedAccount }
        let result = try call("GET", "\(base)/accounts?per_page=5", bearer: bearer)
        guard let list = result as? [[String: Any]], let id = list.first?["id"] as? String else {
            throw CFError.api("The token can't list accounts — it needs Account-scoped Workers permissions.")
        }
        cachedAccount = id
        return id
    }

    static func zoneID(host: String, bearer: String) throws -> String {
        var candidate = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        while candidate.contains(".") {
            let result = try call("GET", "\(base)/zones?name=\(candidate)", bearer: bearer)
            if let list = result as? [[String: Any]], let id = list.first?["id"] as? String {
                return id
            }
            candidate = candidate.split(separator: ".").dropFirst().joined(separator: ".")
        }
        throw CFError.api("No Cloudflare zone found for \(host) — is this domain on your Cloudflare account?")
    }

    // MARK: Publish — Worker with static assets, routed onto the zone

    /// Deploys a folder of static files as a Worker named `script`,
    /// serving under `basePath` of `host` (route created or updated).
    public static func deployStaticSite(folder: String, host: String, basePath: String, script: String) throws {
        guard let bearer = token else { throw CFError.noToken }
        let account = try accountID(bearer)

        // 1. Manifest of everything publishable in the folder.
        var files: [(rel: String, path: String)] = []
        let fm = FileManager.default
        for rel in (try? fm.subpathsOfDirectory(atPath: folder)) ?? [] {
            guard !rel.hasPrefix(".") , !rel.contains(".git"), !rel.contains("node_modules"),
                  !rel.hasPrefix("media/originals"), !rel.hasSuffix(".DS_Store")
            else { continue }
            let full = (folder as NSString).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue {
                files.append((rel, full))
            }
        }
        guard !files.isEmpty else { throw CFError.api("Nothing to publish in \(folder).") }

        var manifest: [String: Any] = [:]
        var byHash: [String: (path: String, mime: String)] = [:]
        for file in files {
            guard let data = fm.contents(atPath: file.path) else { continue }
            let hash = String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(32))
            manifest["/" + file.rel] = ["hash": hash, "size": data.count]
            byHash[hash] = (file.path, mime(for: file.rel))
        }

        // 2. Upload session: Cloudflare says which hashes it still needs.
        let session = try call(
            "POST", "\(base)/accounts/\(account)/workers/scripts/\(script)/assets-upload-session",
            bearer: bearer, json: ["manifest": manifest]
        )
        guard let sessionDict = session as? [String: Any],
              let sessionJWT = sessionDict["jwt"] as? String
        else { throw CFError.api("Cloudflare didn't open an upload session.") }
        var completionJWT = sessionJWT
        let buckets = sessionDict["buckets"] as? [[String]] ?? []

        // 3. Upload the missing files, bucket by bucket.
        for bucket in buckets {
            var parts: [(name: String, contentType: String, body: Data)] = []
            for hash in bucket {
                guard let entry = byHash[hash], let data = fm.contents(atPath: entry.path) else { continue }
                parts.append((hash, entry.mime, Data(data.base64EncodedString().utf8)))
            }
            guard !parts.isEmpty else { continue }
            let result = try upload(
                "\(base)/accounts/\(account)/workers/assets/upload?base64=true",
                bearer: sessionJWT, parts: parts
            )
            if let jwt = (result as? [String: Any])?["jwt"] as? String { completionJWT = jwt }
        }

        // 4. The worker: a tiny module that strips the mount path and
        //    serves the assets. The published page stays plain files.
        let cleanBase = basePath == "/" ? "" : basePath
        let workerJS = """
        export default {
          async fetch(request, env) {
            const url = new URL(request.url);
            const base = \(jsonString(cleanBase));
            if (base && url.pathname.startsWith(base)) {
              url.pathname = url.pathname.slice(base.length) || "/";
            }
            return env.ASSETS.fetch(new Request(url, request));
          }
        };
        """
        let metadata: [String: Any] = [
            "main_module": "worker.js",
            "compatibility_date": "2024-09-23",
            "bindings": [["type": "assets", "name": "ASSETS"]],
            "assets": [
                "jwt": completionJWT,
                "config": ["html_handling": "auto-trailing-slash"]
            ]
        ]
        let metaData = try JSONSerialization.data(withJSONObject: metadata)
        _ = try upload(
            "\(base)/accounts/\(account)/workers/scripts/\(script)",
            bearer: bearer, method: "PUT",
            parts: [
                ("metadata", "application/json", metaData),
                ("worker.js", "application/javascript+module", Data(workerJS.utf8))
            ]
        )

        // 5. The route: host + path, on your zone.
        let zone = try zoneID(host: host, bearer: bearer)
        let pattern = "\(host)\(cleanBase)*"
        let routes = try call("GET", "\(base)/zones/\(zone)/workers/routes", bearer: bearer)
        let existing = (routes as? [[String: Any]])?.first { ($0["pattern"] as? String) == pattern }
        if let existing, let routeID = existing["id"] as? String {
            _ = try call("PUT", "\(base)/zones/\(zone)/workers/routes/\(routeID)", bearer: bearer,
                         json: ["pattern": pattern, "script": script])
        } else {
            _ = try call("POST", "\(base)/zones/\(zone)/workers/routes", bearer: bearer,
                         json: ["pattern": pattern, "script": script])
        }
    }

    // MARK: HTTP plumbing

    static func call(_ method: String, _ url: String, bearer: String, json: [String: Any]? = nil) throws -> Any? {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return try perform(request)
    }

    static func upload(_ url: String, bearer: String, method: String = "POST",
                       parts: [(name: String, contentType: String, body: Data)]) throws -> Any? {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let boundary = "tim-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        for part in parts {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(part.name)\"; filename=\"\(part.name)\"\r\n".utf8))
            body.append(Data("Content-Type: \(part.contentType)\r\n\r\n".utf8))
            body.append(part.body)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return try perform(request)
    }

    static func perform(_ request: URLRequest) throws -> Any? {
        var outData: Data?
        var outError: Error?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, error in
            outData = data
            outError = error
            done.signal()
        }.resume()
        done.wait()
        if let outError { throw CFError.api(outError.localizedDescription) }
        guard let outData,
              let envelope = try? JSONSerialization.jsonObject(with: outData) as? [String: Any]
        else { throw CFError.api("Cloudflare returned something unreadable.") }
        if (envelope["success"] as? Bool) != true {
            let messages = (envelope["errors"] as? [[String: Any]])?
                .compactMap { $0["message"] as? String } ?? []
            throw CFError.api(messages.isEmpty ? "Cloudflare request failed." : messages.joined(separator: " · "))
        }
        return envelope["result"]
    }

    static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              var text = String(data: data, encoding: .utf8) else { return "\"\"" }
        text.removeFirst()
        text.removeLast()
        return text
    }

    static func mime(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js", "mjs": return "text/javascript"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        case "ico": return "image/x-icon"
        case "mp4", "m4v": return "video/mp4"
        case "webm": return "video/webm"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "txt": return "text/plain"
        case "xml": return "application/xml"
        case "pdf": return "application/pdf"
        default: return "application/octet-stream"
        }
    }
}
