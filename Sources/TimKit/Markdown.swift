import Foundation

/// Just enough Markdown for a dropped .md to become a Tim text object:
/// headings, paragraphs, lists, quotes, rules, emphasis, code, links.
public enum Markdown {
    public static func html(_ source: String) -> String {
        var out: [String] = []
        var para: [String] = []
        var list: (tag: String, items: [String])? = nil
        func flushPara() {
            if !para.isEmpty { out.append("<p>\(inline(para.joined(separator: " ")))</p>"); para = [] }
        }
        func flushList() {
            if let l = list { out.append("<\(l.tag)>" + l.items.map { "<li>\($0)</li>" }.joined() + "</\(l.tag)>"); list = nil }
        }
        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushPara(); flushList(); continue }
            if let m = line.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                flushPara(); flushList()
                let level = line.distance(from: line.startIndex, to: m.upperBound) - 1
                out.append("<h\(min(level, 4))>\(inline(String(line[m.upperBound...])))</h\(min(level, 4))>")
            } else if line.range(of: "^(-{3,}|\\*{3,}|_{3,})$", options: .regularExpression) != nil {
                flushPara(); flushList(); out.append("<hr>")
            } else if line.hasPrefix("> ") || line == ">" {
                flushPara(); flushList()
                out.append("<blockquote><p>\(inline(String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces)))</p></blockquote>")
            } else if let m = line.range(of: "^[-*+]\\s+", options: .regularExpression) {
                flushPara()
                if list?.tag != "ul" { flushList(); list = ("ul", []) }
                list?.items.append(inline(String(line[m.upperBound...])))
            } else if let m = line.range(of: "^\\d+[.)]\\s+", options: .regularExpression) {
                flushPara()
                if list?.tag != "ol" { flushList(); list = ("ol", []) }
                list?.items.append(inline(String(line[m.upperBound...])))
            } else {
                flushList(); para.append(line)
            }
        }
        flushPara(); flushList()
        return out.joined(separator: "\n")
    }

    static func inline(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        t = re(t, "`([^`]+)`", "<code>$1</code>")
        t = re(t, "\\*\\*([^*]+)\\*\\*", "<strong>$1</strong>")
        t = re(t, "__([^_]+)__", "<strong>$1</strong>")
        t = re(t, "(?<![*\\w])\\*([^*]+)\\*(?!\\w)", "<em>$1</em>")
        t = re(t, "(?<![_\\w])_([^_]+)_(?!\\w)", "<em>$1</em>")
        t = re(t, "!\\[([^\\]]*)\\]\\(([^)\\s]+)\\)", "<img src=\"$2\" alt=\"$1\">")
        t = re(t, "\\[([^\\]]+)\\]\\(([^)\\s]+)\\)", "<a href=\"$2\">$1</a>")
        return t
    }
    static func re(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let r = try? NSRegularExpression(pattern: pattern) else { return s }
        return r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    public static func escapeText(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
