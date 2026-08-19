import Foundation

/// A reusable component discovered in the site's Astro project.
public struct AstroComponent: Identifiable, Hashable {
    public var id: String { path }
    public let name: String        // "Hero"
    public let path: String        // absolute path to the .astro file
    public let props: [String]     // parsed from `const { … } = Astro.props`
}

/// Scans, inserts, and instantiates the site's own building blocks —
/// components are Keynote's objects, layouts are its masters.
public enum ComponentLibrary {
    public static func components(in projectPath: String) -> [AstroComponent] {
        let dir = (projectPath as NSString).appendingPathComponent("src/components")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return files.filter { $0.hasSuffix(".astro") }.sorted().map { file in
            let path = (dir as NSString).appendingPathComponent(file)
            let source = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            return AstroComponent(
                name: (file as NSString).deletingPathExtension,
                path: path,
                props: parseProps(from: source)
            )
        }
    }

    static func parseProps(from source: String) -> [String] {
        // const { heading, tagline = 'x' } = Astro.props;
        guard let match = source.range(
            of: #"const\s*\{([^}]*)\}\s*=\s*Astro\.props"#,
            options: .regularExpression
        ) else { return [] }
        let inner = String(source[match])
        guard let open = inner.firstIndex(of: "{"), let close = inner.firstIndex(of: "}") else { return [] }
        return inner[inner.index(after: open)..<close]
            .split(separator: ",")
            .map { $0.split(separator: "=")[0].trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Finds the source file for a built page path ("/about.html" →
    /// src/pages/about.astro, handling both file and directory formats).
    public static func pageSource(forRelativePagePath rel: String, projectPath: String) -> String? {
        var stem = rel
        while stem.hasPrefix("/") { stem.removeFirst() }
        if stem.hasSuffix(".html") { stem = String(stem.dropLast(5)) }
        if stem.hasSuffix("/index") { stem = String(stem.dropLast(6)) }
        if stem.isEmpty { stem = "index" }

        let pagesDir = (projectPath as NSString).appendingPathComponent("src/pages")
        let candidates = [
            "\(stem).astro",
            "\(stem)/index.astro",
            "\(stem).md",
            "\(stem).mdx"
        ]
        for candidate in candidates {
            let path = (pagesDir as NSString).appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// Inserts a component instance (with placeholder prop values the user
    /// then edits inline — placeholders round-trip as text edits) at the end
    /// of the page's layout block, adding the import if needed.
    public static func insert(_ component: AstroComponent, intoPageSource pagePath: String) throws {
        var source = try String(contentsOfFile: pagePath, encoding: .utf8)

        let importLine = "import \(component.name) from '../components/\(component.name).astro';"
        if !source.contains("components/\(component.name).astro") {
            if let frontmatterStart = source.range(of: "---"),
               let frontmatterEnd = source.range(of: "---", range: frontmatterStart.upperBound..<source.endIndex) {
                source.insert(contentsOf: importLine + "\n", at: frontmatterEnd.lowerBound)
            } else {
                source = "---\n\(importLine)\n---\n" + source
            }
        }

        let propsMarkup = component.props
            .map { " \($0)=\"Your \($0) here\"" }
            .joined()
        let instance = "  <\(component.name)\(propsMarkup) />\n"

        // Insert before the last closing capitalized (layout/component) tag;
        // fall back to appending.
        if let match = lastRange(of: #"</[A-Z][A-Za-z0-9]*>"#, in: source) {
            source.insert(contentsOf: instance, at: match.lowerBound)
        } else {
            source += "\n" + instance
        }
        try source.write(toFile: pagePath, atomically: true, encoding: .utf8)
    }

    /// Creates a new page from the site's own layout. `layoutPage: true`
    /// makes a canvas page (Pages' layout mode: no body text flow, free
    /// object placement); false makes a text page.
    /// Returns the built page's site-relative path.
    public static func createPage(slug: String, title: String, projectPath: String, layoutPage: Bool = false) throws -> String {
        let cleanSlug = slug
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        guard !cleanSlug.isEmpty else {
            throw PublishError.failed("The page needs a name.")
        }

        let layoutsDir = (projectPath as NSString).appendingPathComponent("src/layouts")
        let layoutFile = (try? FileManager.default.contentsOfDirectory(atPath: layoutsDir))?
            .filter { $0.hasSuffix(".astro") }.sorted().first
        let layoutName = layoutFile.map { ($0 as NSString).deletingPathExtension }

        // Every new page is a canvas: a 12-column grid of objects. A plain
        // article is just a full-width text box — text continues down the
        // page; the web has no pagination to fight.
        let body = """
          <div class="tim-canvas" data-tim-canvas>
            <div class="tim-object tim-text tim-style-title" style="grid-area: 2 / 2 / 5 / 20;">\(title)</div>
            <div class="tim-object tim-text tim-style-body" style="grid-area: 5 / 2 / 9 / 16;">Write something true.</div>
          </div>
        """
        _ = layoutPage

        let source: String
        if let layoutName {
            source = """
            ---
            import \(layoutName) from '../layouts/\(layoutName).astro';
            ---
            <\(layoutName) title="\(title)">
            \(body)
            </\(layoutName)>
            """
        } else {
            source = """
            <html>
              <head><title>\(title)</title></head>
              <body>
            \(body)
              </body>
            </html>
            """
        }

        let pagePath = (projectPath as NSString)
            .appendingPathComponent("src/pages/\(cleanSlug).astro")
        guard !FileManager.default.fileExists(atPath: pagePath) else {
            throw PublishError.failed("A page named \(cleanSlug) already exists.")
        }
        try source.write(toFile: pagePath, atomically: true, encoding: .utf8)
        return "/\(cleanSlug).html"
    }

    private static func lastRange(of pattern: String, in text: String) -> Range<String.Index>? {
        var result: Range<String.Index>? = nil
        var searchStart = text.startIndex
        while let range = text.range(of: pattern, options: .regularExpression, range: searchStart..<text.endIndex) {
            result = range
            searchStart = range.upperBound
        }
        return result
    }
}
