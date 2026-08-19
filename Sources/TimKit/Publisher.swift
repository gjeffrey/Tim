import Foundation

// Publishing backends.
//
// On macOS, publishing drives the user's local toolchain (sftp/scp, git,
// wrangler, npm) through their login shell — credentials never pass
// through Tim.
//
// On iOS/iPadOS there is no Process, so each target gets an API-based
// backend with the same function shapes:
//   - Cloudflare → Pages Direct Upload / Workers API
//   - GitHub Pages → REST contents/commits API
//   - SFTP → an embedded SSH client (e.g. swift-nio-ssh)
// Astro builds move to the cloud on those platforms (git-connected CI:
// Workers Builds / GitHub Actions) — publish pushes source, CI builds.

public enum PublishError: LocalizedError {
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let output):
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// Writes an edited page into a local site folder at its URL-derived path.
public enum PageWriter {
    @discardableResult
    public static func write(html: String, folder: String, relativePath: String) throws -> String {
        var rel = relativePath
        while rel.hasPrefix("/") { rel.removeFirst() }
        let fileURL = URL(fileURLWithPath: folder).appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try html.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL.path
    }
}

#if os(macOS)

/// Runs a command through the user's login shell so PATH additions
/// (Homebrew, nvm, etc.) apply. Output is stdout+stderr combined.
public enum Shell {
    @discardableResult
    public static func run(_ command: String, in directory: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        if let directory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        // Read to EOF before waiting so large output can't fill the pipe
        // buffer and deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw PublishError.failed(output.isEmpty ? "exit code \(process.terminationStatus)" : output)
        }
        return output
    }

    public static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// SFTP target — the system `sftp` client, SSH keys only (BatchMode).
/// Tim never handles passwords.
public enum SFTP {
    public static func run(batch: String, host: String, username: String, port: String) throws -> String {
        let batchURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tim-batch-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: batchURL) }
        try batch.write(to: batchURL, atomically: true, encoding: .utf8)

        let command = "/usr/bin/sftp -P \(Shell.quoted(port.isEmpty ? "22" : port)) "
            + "-o BatchMode=yes -b \(Shell.quoted(batchURL.path)) "
            + Shell.quoted("\(username)@\(host)")
        return try Shell.run(command)
    }

    public static func upload(html: String, to remotePath: String, host: String, username: String, port: String) throws -> String {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tim-upload-\(UUID().uuidString).html")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try html.write(to: fileURL, atomically: true, encoding: .utf8)
        return try run(
            batch: "put \"\(fileURL.path)\" \"\(remotePath)\"\n",
            host: host, username: username, port: port
        )
    }

    /// Lists the remote root — proof the connection, key auth, and path
    /// are all good. Used by the site editor's Verify button.
    public static func verify(host: String, username: String, port: String, remoteRoot: String) throws -> String {
        try run(
            batch: "ls \"\(remoteRoot.isEmpty ? "." : remoteRoot)\"\n",
            host: host, username: username, port: port
        )
    }

    /// Pulls the remote site down into the local mirror.
    public static func downloadDirectory(remoteRoot: String, to local: String, host: String, username: String, port: String) throws -> String {
        try FileManager.default.createDirectory(atPath: local, withIntermediateDirectories: true)
        let root = remoteRoot.isEmpty ? "." : remoteRoot
        return try run(
            batch: "lcd \"\(local)\"\nget -r \(root)/* .\n",
            host: host, username: username, port: port
        )
    }

    /// Mirrors a local folder (an Astro `dist/`) to the remote root via scp.
    public static func uploadDirectory(local: String, host: String, username: String, port: String, remoteRoot: String) throws -> String {
        let destination = Shell.quoted("\(username)@\(host):\(remoteRoot.isEmpty ? "." : remoteRoot)")
        return try Shell.run(
            "/usr/bin/scp -r -P \(Shell.quoted(port.isEmpty ? "22" : port)) -o BatchMode=yes ./* \(destination)",
            in: local
        )
    }
}

/// Cloudflare target — deploys a folder with Wrangler. The user
/// authenticates once with `wrangler login`; Tim never sees credentials.
public enum CloudflarePublisher {
    public static func deploy(folder: String, projectName: String) throws -> String {
        try ensureWrangler()
        return try Shell.run(
            "wrangler pages deploy . --project-name \(Shell.quoted(projectName)) --commit-dirty=true",
            in: folder
        )
    }

    public static func verify() throws -> String {
        try ensureWrangler()
        return try Shell.run("wrangler whoami")
    }

    private static func ensureWrangler() throws {
        do {
            try Shell.run("command -v wrangler >/dev/null")
        } catch {
            throw PublishError.failed(
                "Wrangler isn’t installed. In Terminal: npm install -g wrangler && wrangler login"
            )
        }
    }
}

/// GitHub Pages target — the site folder is a git repo; publishing commits
/// the edit and pushes the current branch to origin. Auth is whatever git
/// is already set up with (SSH keys or credential helper).
public enum GitHubPagesPublisher {
    public static func publish(repo: String, message: String) throws -> String {
        try Shell.run(
            "git add -A && "
            + "if git diff --cached --quiet; then echo 'No changes to commit.'; "
            + "else git commit -m \(Shell.quoted(message)); fi && "
            + "git push origin HEAD",
            in: repo
        )
    }

    public static func verify(repo: String) throws -> String {
        try Shell.run(
            "git rev-parse --is-inside-work-tree >/dev/null && "
            + "git ls-remote --exit-code origin HEAD >/dev/null && "
            + "echo 'Repo and origin reachable.'",
            in: repo
        )
    }
}

#endif
