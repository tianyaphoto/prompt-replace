import Foundation

enum StreamEvent: Equatable {
    case delta(String)
    case result(text: String, isError: Bool)
}

/// Parses one line of `claude -p --output-format stream-json --include-partial-messages`.
enum StreamParser {
    static func parse(_ line: Data) -> StreamEvent? {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = obj["type"] as? String else { return nil }

        if type == "stream_event",
           let event = obj["event"] as? [String: Any],
           event["type"] as? String == "content_block_delta",
           let delta = event["delta"] as? [String: Any],
           delta["type"] as? String == "text_delta",
           let text = delta["text"] as? String {
            return .delta(text)
        }

        if type == "result" {
            let isError = (obj["is_error"] as? Bool) ?? (obj["subtype"] as? String != "success")
            let text = (obj["result"] as? String)
                ?? (obj["errors"] as? [String])?.joined(separator: "\n")
                ?? ""
            return .result(text: text, isError: isError)
        }
        return nil
    }
}

struct ClaudeEnvironment {
    let executable: String
    let path: String
}

enum ClaudeError: LocalizedError {
    case notFound
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "找不到 claude 命令。请在设置 → 通用里填写 claude 的完整路径（在终端运行 `which claude` 可以查到）。"
        case .failed(let message):
            return message
        case .cancelled:
            return "已取消"
        }
    }
}

/// Runs `claude -p` as a pure text transformer: no tools, no MCP, no project settings.
final class ClaudeRunner: @unchecked Sendable {
    private static let envLock = NSLock()
    nonisolated(unsafe) private static var cachedEnv: [String: ClaudeEnvironment] = [:]

    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    static func resetCache() {
        envLock.lock()
        cachedEnv.removeAll()
        envLock.unlock()
    }

    /// GUI apps don't inherit the shell PATH, so ask a login+interactive shell where claude and node live.
    static func resolve(override: String) throws -> ClaudeEnvironment {
        envLock.lock()
        defer { envLock.unlock() }
        if let env = cachedEnv[override] { return env }

        let fm = FileManager.default
        let (shellPath, shellClaude) = loginShellLookup()
        var candidates: [String] = []
        let manual = (override.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        if !manual.isEmpty { candidates.append(manual) }
        if let shellClaude { candidates.append(shellClaude) }
        candidates += ["~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .map { ($0 as NSString).expandingTildeInPath }

        guard let exe = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else { throw ClaudeError.notFound }
        let dir = (exe as NSString).deletingLastPathComponent
        let base = shellPath ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let env = ClaudeEnvironment(executable: exe, path: "\(dir):\(base):/opt/homebrew/bin:/usr/local/bin")
        cachedEnv[override] = env
        return env
    }

    private static func loginShellLookup() -> (path: String?, claude: String?) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-i", "-c", #"printf '\n__PATH__%s\n__CLAUDE__%s\n' "$PATH" "$(command -v claude)""#]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (nil, nil) }

        var data = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: .now() + 8) == .timedOut {
            p.terminate()
            return (nil, nil)
        }

        var path: String?
        var claude: String?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("__PATH__") {
                let v = String(line.dropFirst(8))
                if !v.isEmpty { path = v }
            } else if line.hasPrefix("__CLAUDE__") {
                let v = String(line.dropFirst(10))
                if v.hasPrefix("/") { claude = v }
            }
        }
        return (path, claude)
    }

    static var workDirectory: URL {
        let dir = ConfigStore.supportDirectory.appendingPathComponent("workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    /// Callbacks are delivered on the main queue.
    func run(input: String, systemPrompt: String, model: String, effort: String, claudeOverride: String,
             onDelta: @escaping (String) -> Void, completion: @escaping (Result<String, Error>) -> Void) {
        lock.lock()
        cancelled = false
        lock.unlock()

        let deliverDelta: (String) -> Void = { text in DispatchQueue.main.async { onDelta(text) } }
        let finish: (Result<String, Error>) -> Void = { result in DispatchQueue.main.async { completion(result) } }

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let env: ClaudeEnvironment
            do { env = try ClaudeRunner.resolve(override: claudeOverride) } catch { return finish(.failure(error)) }

            let prompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Rewrite the user's text. Output only the result." : systemPrompt
            var args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                        "--system-prompt", prompt,
                        "--tools", "", "--strict-mcp-config", "--setting-sources", "",
                        "--no-session-persistence"]
            if !model.isEmpty { args += ["--model", model] }
            if !effort.isEmpty { args += ["--effort", effort] }

            let p = Process()
            p.executableURL = URL(fileURLWithPath: env.executable)
            p.arguments = args
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = env.path
            p.environment = environment
            p.currentDirectoryURL = ClaudeRunner.workDirectory

            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            p.standardInput = inPipe
            p.standardOutput = outPipe
            p.standardError = errPipe

            let errLock = NSLock()
            var errData = Data()
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData
                errLock.lock(); errData.append(chunk); errLock.unlock()
            }

            lock.lock()
            if cancelled { lock.unlock(); return finish(.failure(ClaudeError.cancelled)) }
            process = p
            lock.unlock()

            do { try p.run() } catch {
                return finish(.failure(ClaudeError.failed("无法启动 claude：\(error.localizedDescription)")))
            }
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()

            var resultEvent: (text: String, isError: Bool)?
            var streamed = ""
            var buffer = Data()
            let reader = outPipe.fileHandleForReading
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    switch StreamParser.parse(line) {
                    case .delta(let t):
                        streamed += t
                        deliverDelta(t)
                    case .result(let text, let isError):
                        resultEvent = (text, isError)
                    case nil:
                        break
                    }
                }
            }
            p.waitUntilExit()
            errPipe.fileHandleForReading.readabilityHandler = nil

            lock.lock()
            let wasCancelled = cancelled
            process = nil
            lock.unlock()
            if wasCancelled { return finish(.failure(ClaudeError.cancelled)) }

            errLock.lock()
            let stderr = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            errLock.unlock()

            if let r = resultEvent {
                if r.isError {
                    let msg = r.text.isEmpty ? stderr : r.text
                    return finish(.failure(ClaudeError.failed("claude 返回错误：\(msg.isEmpty ? "未知错误" : msg)")))
                }
                let text = r.text.isEmpty ? streamed : r.text
                return finish(.success(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            if p.terminationStatus == 0, !streamed.isEmpty {
                return finish(.success(streamed.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            let tail = String(stderr.suffix(800))
            finish(.failure(ClaudeError.failed("claude 退出码 \(p.terminationStatus)\(tail.isEmpty ? "" : "：\n\(tail)")")))
        }
    }
}
