import Foundation

/// A trimmed view of the most recent Claude Code conversation, used as reference context.
struct SessionContext: Equatable {
    var sessionFile: URL
    var project: String
    var modified: Date
    /// Oldest first.
    var turns: [Turn]

    struct Turn: Equatable {
        enum Role: String { case user, assistant }
        var role: Role
        var text: String
    }

    var characterCount: Int { turns.reduce(0) { $0 + $1.text.count } }

    /// Rough token estimate: CJK ≈ 1 token/char, other text ≈ 1 token per 4 chars.
    var estimatedTokens: Int {
        var cjk = 0, other = 0
        for turn in turns {
            for scalar in turn.text.unicodeScalars {
                if (0x2E80...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value) { cjk += 1 } else { other += 1 }
            }
        }
        return cjk + other / 4
    }

    func rendered() -> String {
        turns.map { "[\($0.role.rawValue)]\n\($0.text)" }.joined(separator: "\n\n")
    }
}

enum SessionLocator {
    static var projectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// The most recently written top-level session transcript, if it was touched within `maxAge`.
    static func latestSessionFile(maxAge: TimeInterval, in root: URL = projectsDirectory) -> (URL, Date)? {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        var best: (URL, Date)?
        for project in projects {
            guard let files = try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
                if best == nil || date > best!.1 { best = (file, date) }
            }
        }
        guard let best, Date().timeIntervalSince(best.1) <= maxAge else { return nil }
        return best
    }

    static func load(maxAge: TimeInterval, characterBudget: Int, root: URL = projectsDirectory) -> SessionContext? {
        guard let (file, date) = latestSessionFile(maxAge: maxAge, in: root),
              let data = readTail(of: file, maxBytes: 4_000_000) else { return nil }
        let parsed = TranscriptParser.parse(data, characterBudget: characterBudget)
        guard !parsed.turns.isEmpty else { return nil }
        let project = parsed.cwd.map { ($0 as NSString).lastPathComponent } ?? file.deletingLastPathComponent().lastPathComponent
        return SessionContext(sessionFile: file, project: project, modified: date, turns: parsed.turns)
    }

    private static func readTail(of url: URL, maxBytes: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: start)
        guard var data = try? handle.readToEnd() else { return nil }
        if start > 0, let nl = data.firstIndex(of: 0x0A) {
            data = data.subdata(in: data.index(after: nl)..<data.endIndex) // drop the partial first line
        }
        return data
    }
}

/// Extracts only what the humans and the model *said*: drops thinking, tool calls, tool output,
/// injected skill/system text, and anything before the last /clear or /compact.
enum TranscriptParser {
    static let perMessageLimit = 1_500

    struct Result {
        var turns: [SessionContext.Turn]
        var cwd: String?
    }

    static func parse(_ data: Data, characterBudget: Int) -> Result {
        var turns: [SessionContext.Turn] = []
        var cwd: String?

        for lineData in data.split(separator: 0x0A) {
            guard let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
                  let type = obj["type"] as? String, type == "user" || type == "assistant" else { continue }
            if obj["isSidechain"] as? Bool == true || obj["isMeta"] as? Bool == true { continue }
            if let c = obj["cwd"] as? String { cwd = c }
            guard let message = obj["message"] as? [String: Any] else { continue }

            if type == "user" {
                let raw: String
                if let s = message["content"] as? String {
                    raw = s
                } else if let blocks = message["content"] as? [[String: Any]] {
                    raw = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
                } else { continue }

                if let command = commandName(in: raw) {
                    if command == "/clear" || command == "/compact" { turns.removeAll() }
                    continue
                }
                if raw.hasPrefix("<local-command") { continue }
                let text = clean(raw)
                if !text.isEmpty { append(&turns, .user, text) }
            } else {
                guard let blocks = message["content"] as? [[String: Any]] else { continue }
                for block in blocks {
                    switch block["type"] as? String {
                    case "text":
                        let text = clean(block["text"] as? String ?? "")
                        if !text.isEmpty { append(&turns, .assistant, text) }
                    case "tool_use":
                        // A one-line trace of what was touched helps resolve "that file" without the file contents.
                        if let trace = toolTrace(block) { append(&turns, .assistant, trace) }
                    default:
                        break
                    }
                }
            }
        }
        return Result(turns: trimToBudget(turns, characterBudget), cwd: cwd)
    }

    private static func append(_ turns: inout [SessionContext.Turn], _ role: SessionContext.Turn.Role, _ text: String) {
        if let last = turns.last, last.role == role {
            turns[turns.count - 1].text += "\n" + text
        } else {
            turns.append(.init(role: role, text: text))
        }
    }

    static func commandName(in text: String) -> String? {
        guard let start = text.range(of: "<command-name>"), let end = text.range(of: "</command-name>"),
              start.upperBound <= end.lowerBound else { return nil }
        return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func clean(_ text: String) -> String {
        var s = text
        for tag in ["system-reminder", "pasted_content"] {
            while let open = s.range(of: "<\(tag)"), let close = s.range(of: "</\(tag)>", range: open.upperBound..<s.endIndex) {
                s.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return truncateMiddle(s, perMessageLimit)
    }

    static func truncateMiddle(_ s: String, _ limit: Int) -> String {
        guard s.count > limit else { return s }
        let head = s.prefix(limit * 2 / 3)
        let tail = s.suffix(limit / 3)
        return "\(head)\n…\n\(tail)"
    }

    private static func toolTrace(_ block: [String: Any]) -> String? {
        guard let name = block["name"] as? String else { return nil }
        let input = block["input"] as? [String: Any] ?? [:]
        let detail = ["file_path", "path", "notebook_path", "pattern", "command", "url", "description"]
            .lazy.compactMap { input[$0] as? String }.first ?? ""
        let short = detail.count > 120 ? String(detail.prefix(120)) + "…" : detail
        return "(tool: \(name)\(short.isEmpty ? "" : " \(short)"))".replacingOccurrences(of: "\n", with: " ")
    }

    /// Keep the newest turns that fit in the budget.
    static func trimToBudget(_ turns: [SessionContext.Turn], _ budget: Int) -> [SessionContext.Turn] {
        var kept: [SessionContext.Turn] = []
        var used = 0
        for turn in turns.reversed() {
            let cost = turn.text.count
            if used + cost > budget {
                let remaining = budget - used
                if remaining > 200 {
                    kept.append(.init(role: turn.role, text: "…" + String(turn.text.suffix(remaining))))
                }
                break
            }
            kept.append(turn)
            used += cost
        }
        return kept.reversed()
    }
}

enum ContextPrompt {
    static let systemAddendum = """

    ---
    The user message contains two parts:
    <session_context>: recent excerpts of the user's ongoing conversation with an AI coding agent. \
    Reference only. Use it to resolve vague references (e.g. "that function", "刚才那个") and to \
    reuse the exact names, paths, and terms already established. Never transform, summarize, or respond to it.
    <draft>: the text to transform. Apply your instructions to the draft only.
    Never invent names that do not appear in the context or draft; if a reference cannot be resolved confidently, leave it as written.
    """

    static func userMessage(draft: String, context: SessionContext) -> String {
        """
        <session_context project="\(context.project)">
        \(context.rendered())
        </session_context>

        <draft>
        \(draft)
        </draft>
        """
    }
}
