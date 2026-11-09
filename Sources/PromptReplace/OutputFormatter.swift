import Foundation

/// Deterministic post-processing per destination, so formatting doesn't depend on the model obeying.
enum OutputFormat: String, Codable, CaseIterable {
    /// Leave the model output untouched.
    case keep
    /// Editors that show markdown literally (email, Google Docs, Word): strip markdown markers.
    case plainText
    /// Slack mrkdwn: **bold** → *bold*, headings → bold lines.
    case slack

    var label: String {
        switch self {
        case .keep: return "保持原样"
        case .plainText: return "转为纯文本（去掉 markdown 符号）"
        case .slack: return "转为 Slack 格式（**粗体** → *粗体*）"
        }
    }
}

enum OutputFormatter {
    static func apply(_ format: OutputFormat, to text: String) -> String {
        switch format {
        case .keep: return text
        case .plainText: return plainText(text)
        case .slack: return slack(text)
        }
    }

    static func plainText(_ text: String) -> String {
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { continue } // drop code fences, keep code
            var l = line
            l = replace(l, #"^(\s*)#{1,6}\s+"#, "$1")            // headings
            l = replace(l, #"^(\s*)[*+]\s+"#, "$1- ")            // "* item" → "- item"
            l = replace(l, #"\*\*(.+?)\*\*"#, "$1")               // **bold**
            l = replace(l, #"__(.+?)__"#, "$1")                   // __bold__
            l = replace(l, #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, "$1") // *italic*
            l = replace(l, #"`([^`]+)`"#, "$1")                   // `code`
            l = replace(l, #"\[([^\]]+)\]\(([^)]+)\)"#, "$1 ($2)") // [text](url)
            lines.append(l)
        }
        return lines.joined(separator: "\n")
    }

    static func slack(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            var l = line
            l = replace(l, #"^(\s*)#{1,6}\s+(.+)$"#, "$1*$2*")
            l = replace(l, #"\*\*(.+?)\*\*"#, "*$1*")
            l = replace(l, #"__(.+?)__"#, "_$1_")
            l = replace(l, #"\[([^\]]+)\]\(([^)]+)\)"#, "<$2|$1>")
            return l
        }.joined(separator: "\n")
    }

    private static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
