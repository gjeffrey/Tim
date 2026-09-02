import Foundation

/// Unfinished edits survive anything: while a page is in edit mode its
/// DOM is stashed here (every few seconds, and before any navigation
/// away), keyed by page URL. A draft is a history entry that hasn't been
/// published: opening the page shows the PUBLISHED page, with the draft
/// offered — in the address bar, in History — to continue or discard.
/// Nothing drops you back into edit mode on its own; the page may have
/// changed from another Mac since. Done publishes and clears.
public enum DraftStore {
    public static let changed = Notification.Name("tim.draftsChanged")

    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tim/Drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func file(for url: String) -> URL {
        let key = Data(url.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return dir.appendingPathComponent(key + ".html")
    }

    public static func save(_ html: String, for url: String) {
        let isNew = !has(url)
        try? html.write(to: file(for: url), atomically: true, encoding: .utf8)
        if isNew { notify() }
    }

    public static func html(for url: String) -> String? {
        try? String(contentsOf: file(for: url), encoding: .utf8)
    }

    public static func date(for url: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file(for: url).path))?[.modificationDate] as? Date
    }

    public static func has(_ url: String) -> Bool {
        FileManager.default.fileExists(atPath: file(for: url).path)
    }

    public static func clear(for url: String) {
        guard has(url) else { return }
        try? FileManager.default.removeItem(at: file(for: url))
        notify()
    }

    private static func notify() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
}
