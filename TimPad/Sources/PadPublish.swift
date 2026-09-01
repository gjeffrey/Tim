import Foundation
import CryptoKit
import Security
import Citadel
import NIOCore
import TimKit

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
