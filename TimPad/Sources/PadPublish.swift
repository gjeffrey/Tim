import Foundation
import CryptoKit
import Security
import Citadel
import NIOCore
import TimKit
import WebKit
import UIKit

// Publishing from the iPad, for real: an embedded SSH client (Citadel)
// speaking SFTP with a key that was born on this device. The Mac keeps
// using the system sftp with ~/.ssh; the iPad's identity is its own —
// generated here, kept in the iCloud Keychain (so an iPhone would share
// it), never exported. Adding its public half to the server is the one
// manual step, and the key sheet hands it to you ready to paste.

/// The iPad's publishing identity.
enum PadKeys {
    private static let service = "tim.pad.sshkey"
    private static let account = "ed25519"

    static func privateKey() -> Curve25519.Signing.PrivateKey {
        if let data = read(), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        save(key.rawRepresentation)
        return key
    }

    /// One authorized_keys line: "ssh-ed25519 <blob> Tim-iPad".
    static var publicKeyLine: String {
        let pub = privateKey().publicKey.rawRepresentation
        var blob = Data()
        func field(_ d: Data) {
            var len = UInt32(d.count).bigEndian
            withUnsafeBytes(of: &len) { blob.append(contentsOf: $0) }
            blob.append(d)
        }
        field(Data("ssh-ed25519".utf8))
        field(pub)
        return "ssh-ed25519 " + blob.base64EncodedString() + " Tim-iPad"
    }

    private static func read() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func save(_ data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecAttrSynchronizable as String] = true
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }
}

/// SFTP publishing over Citadel. Same shapes as the Mac's SFTP enum —
/// upload a page, verify a connection — minus Process.
enum PadPublisher {
    static func remotePath(site: Site, pageURL: URL) -> String {
        var rel = site.relativePagePath(for: pageURL)
        while rel.hasPrefix("/") { rel.removeFirst() }
        let root = site.remoteRoot.isEmpty ? "." : site.remoteRoot
        return root.hasSuffix("/") ? root + rel : root + "/" + rel
    }

    private static func connect(site: Site, key: Curve25519.Signing.PrivateKey) async throws -> SSHClient {
        try await SSHClient.connect(
            host: site.host,
            port: Int(site.port) ?? 22,
            authenticationMethod: .ed25519(username: site.username, privateKey: key),
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
    }

    /// Lists the remote root — proof the connection, key, and path are
    /// all good (the same check the Mac's Verify button makes).
    static func verify(site: Site, key: Curve25519.Signing.PrivateKey? = nil) async throws {
        let client = try await connect(site: site, key: key ?? PadKeys.privateKey())
        do {
            let sftp = try await client.openSFTP()
            _ = try await sftp.listDirectory(atPath: site.remoteRoot.isEmpty ? "." : site.remoteRoot)
            try await sftp.close()
            try await client.close()
        } catch {
            try? await client.close()
            throw error
        }
    }

    /// Uploads one binary file (a share card, say), creating its folder.
    static func upload(data: Data, site: Site, remotePath: String, key: Curve25519.Signing.PrivateKey? = nil) async throws {
        let client = try await connect(site: site, key: key ?? PadKeys.privateKey())
        do {
            let sftp = try await client.openSFTP()
            try? await sftp.createDirectory(atPath: (remotePath as NSString).deletingLastPathComponent)
            let file = try await sftp.openFile(filePath: remotePath, flags: [.write, .create, .truncate])
            try await file.write(ByteBuffer(bytes: data), at: 0)
            try await file.close()
            try await sftp.close()
            try await client.close()
        } catch {
            try? await client.close()
            throw error
        }
    }

    /// Publishes one page: the edited HTML lands at its URL-derived path.
    static func publish(html: String, site: Site, pageURL: URL, key: Curve25519.Signing.PrivateKey? = nil) async throws {
        guard site.target == .sftp else {
            throw PublishError.failed("This site publishes from your Mac for now — iPad publishing covers SFTP sites first.")
        }
        guard !site.host.isEmpty, !site.username.isEmpty else {
            throw PublishError.failed("The site needs its server and username — set them on your Mac; they sync here.")
        }
        let path = remotePath(site: site, pageURL: pageURL)
        let client = try await connect(site: site, key: key ?? PadKeys.privateKey())
        do {
            let sftp = try await client.openSFTP()
            let file = try await sftp.openFile(
                filePath: path,
                flags: [.write, .create, .truncate]
            )
            try await file.write(ByteBuffer(string: html), at: 0)
            try await file.close()
            try await sftp.close()
            try await client.close()
        } catch {
            try? await client.close()
            throw error
        }
    }
}

/// The share card, made on the iPad the same way the Mac makes it: a
/// hidden 600×315 web view (the card's own aspect, under the phone
/// breakpoint so the bold mobile styles compose it) loads the published
/// page, snapshots at 1200×630, and ships social-<page>.png. A page
/// with a custom image is never touched.
final class PadSocialCards: NSObject, WKNavigationDelegate {
    static let shared = PadSocialCards()

    private struct Job { let url: URL; let site: Site; let slug: String }
    private var queue: [Job] = []
    private var busy = false
    private var current: Job?
    private lazy var webView: WKWebView = {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 315))
        view.navigationDelegate = self
        return view
    }()

    func capture(pageURL: URL, site: Site, pageHTML: String) {
        guard site.target == .sftp else { return }
        if let existing = PageMeta.content(in: pageHTML, property: "og:image"),
           !(existing as NSString).lastPathComponent.hasPrefix("social-") {
            return  // custom image — theirs, never touched
        }
        let slug = PageMeta.socialSlug(rel: site.relativePagePath(for: pageURL))
        DispatchQueue.main.async {
            guard !self.queue.contains(where: { $0.slug == slug }) else { return }
            self.queue.append(Job(url: pageURL, site: site, slug: slug))
            self.pump()
        }
    }

    private func pump() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        current = queue.removeFirst()
        var parts = URLComponents(url: current!.url, resolvingAgainstBaseURL: false)!
        parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "timcard", value: String(Int(Date().timeIntervalSince1970)))]
        webView.load(URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
        let started = current?.slug
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, self.busy, self.current?.slug == started else { return }
            self.finish()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, let job = self.current else { return }
            let config = WKSnapshotConfiguration()
            config.snapshotWidth = 1200
            self.webView.takeSnapshot(with: config) { image, _ in
                guard let image else { self.finish(); return }
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let card = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 630), format: format).image { _ in
                    let height = image.size.height * (1200 / image.size.width)
                    image.draw(in: CGRect(x: 0, y: 0, width: 1200, height: height))
                }
                guard let png = card.pngData() else { self.finish(); return }
                let root = job.site.remoteRoot.hasSuffix("/") ? String(job.site.remoteRoot.dropLast()) : job.site.remoteRoot
                let remote = root + "/media/social-\(job.slug).png"
                Task {
                    try? await PadPublisher.upload(data: png, site: job.site, remotePath: remote)
                    await MainActor.run { self.finish() }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish() }

    private func finish() {
        guard busy else { return }
        busy = false
        current = nil
        pump()
    }
}
