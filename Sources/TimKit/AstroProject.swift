import Foundation

/// The Astro round trip: apply text edits to project source, rebuild,
/// and hand `dist/` to a publish target.
///
/// Source-edit logic is cross-platform. The build step is macOS-only
/// today (local npm); on iOS/iPadOS builds move to git-connected CI
/// (Workers Builds / GitHub Actions) — publish pushes source, CI builds.
public enum AstroProject {
    public static func isAstroProject(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let fm = FileManager.default
        return ["astro.config.mjs", "astro.config.ts", "astro.config.js", "astro.config.cjs"].contains {
            fm.fileExists(atPath: (path as NSString).appendingPathComponent($0))
        }
    }

    public static func distPath(_ projectPath: String) -> String {
        (projectPath as NSString).appendingPathComponent("dist")
    }

    public struct EditResult {
        public var applied: [String] = []
        public var skipped: [String] = []
    }

    private static let editableExtensions: Set<String> = ["astro", "md", "mdx", "html", "txt"]

    /// Applies text edits (old → new) to source files under src/.
    /// A replacement happens only when the old text occurs exactly once
    /// across the whole source tree — ambiguity means refuse, not guess.
    public static func applyEdits(_ edits: [(String, String)], projectPath: String) -> EditResult {
        var result = EditResult()
        let srcPath = (projectPath as NSString).appendingPathComponent("src")

        var contents: [String: String] = [:]
        for file in sourceFiles(under: srcPath) {
            if let text = try? String(contentsOfFile: file, encoding: .utf8) {
                contents[file] = text
            }
        }
        var changedFiles: Set<String> = []

        for (oldRaw, newRaw) in edits {
            let old = oldRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            let new = newRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard old.count >= 2, old != new else { continue }

            var hits: [(file: String, count: Int)] = []
            for (file, text) in contents {
                let count = text.components(separatedBy: old).count - 1
                if count > 0 { hits.append((file, count)) }
            }

            let total = hits.reduce(0) { $0 + $1.count }
            if total == 1, let hit = hits.first {
                contents[hit.file] = contents[hit.file]?.replacingOccurrences(of: old, with: new)
                changedFiles.insert(hit.file)
                result.applied.append("“\(truncated(old))” → “\(truncated(new))”")
            } else if total == 0 {
                result.skipped.append("“\(truncated(old))” — not found in source")
            } else {
                result.skipped.append("“\(truncated(old))” — appears \(total) times in source, too ambiguous")
            }
        }

        for file in changedFiles {
            if let text = contents[file] {
                try? text.write(toFile: file, atomically: true, encoding: .utf8)
            }
        }
        return result
    }

    #if os(macOS)
    /// `npm install` if needed, then `npm run build`.
    public static func build(projectPath: String) throws -> String {
        do {
            try Shell.run("command -v npm >/dev/null")
        } catch {
            throw PublishError.failed("npm isn’t installed — install Node.js first (e.g. brew install node).")
        }
        let nodeModules = (projectPath as NSString).appendingPathComponent("node_modules")
        if !FileManager.default.fileExists(atPath: nodeModules) {
            _ = try Shell.run("npm install", in: projectPath)
        }
        return try Shell.run("npm run build", in: projectPath)
    }
    #endif

    private static func sourceFiles(under root: String) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }
        var files: [String] = []
        while let relative = enumerator.nextObject() as? String {
            let ext = (relative as NSString).pathExtension.lowercased()
            if editableExtensions.contains(ext) {
                files.append((root as NSString).appendingPathComponent(relative))
            }
        }
        return files
    }

    private static func truncated(_ text: String, to length: Int = 40) -> String {
        text.count <= length ? text : String(text.prefix(length)) + "…"
    }
}
