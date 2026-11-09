import AppKit
import ApplicationServices

/// Where the result is going (Slack, email, a doc, a coding agent…). A scene adds tone/format guidance
/// on top of the preset, can pick a default preset, and decides whether Claude Code context makes sense.
struct Scene: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// Exact bundle IDs; a trailing `*` matches a prefix (e.g. `com.jetbrains.*`).
    var bundleIDs: [String]
    /// Case-insensitive substrings of the window title or page URL (for web apps in a browser).
    var keywords: [String]
    var guidance: String
    /// nil = remember the last preset used in this scene.
    var defaultPresetID: UUID?
    /// Whether presets that include Claude Code session context may use it here.
    var allowContext: Bool
    /// Deterministic formatting applied to the result before pasting. nil only while decoding old configs.
    var outputFormat: OutputFormat?

    var format: OutputFormat { outputFormat ?? .keep }

    init(id: UUID = UUID(), name: String, bundleIDs: [String] = [], keywords: [String] = [], guidance: String = "",
         defaultPresetID: UUID? = nil, allowContext: Bool = false, outputFormat: OutputFormat = .keep) {
        self.outputFormat = outputFormat
        self.id = id
        self.name = name
        self.bundleIDs = bundleIDs
        self.keywords = keywords
        self.guidance = guidance
        self.defaultPresetID = defaultPresetID
        self.allowContext = allowContext
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "未命名场景"
        bundleIDs = try c.decodeIfPresent([String].self, forKey: .bundleIDs) ?? []
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        guidance = try c.decodeIfPresent(String.self, forKey: .guidance) ?? ""
        defaultPresetID = try c.decodeIfPresent(UUID.self, forKey: .defaultPresetID)
        allowContext = try c.decodeIfPresent(Bool.self, forKey: .allowContext) ?? false
        outputFormat = try c.decodeIfPresent(OutputFormat.self, forKey: .outputFormat)
    }

    func matchesBundle(_ bundleID: String?) -> Bool {
        guard let bundleID = bundleID?.lowercased(), !bundleID.isEmpty else { return false }
        return bundleIDs.contains { rule in
            let r = rule.trimmingCharacters(in: .whitespaces).lowercased()
            if r.isEmpty { return false }
            if r.hasSuffix("*") { return bundleID.hasPrefix(String(r.dropLast())) }
            return bundleID == r
        }
    }

    func matchesKeywords(in haystacks: [String]) -> Bool {
        let hs = haystacks.map { $0.lowercased() }.filter { !$0.isEmpty }
        return keywords.contains { k in
            let key = k.trimmingCharacters(in: .whitespaces).lowercased()
            return !key.isEmpty && hs.contains { $0.contains(key) }
        }
    }
}

/// What we know about the app the user was in when they pressed the hotkey.
struct AppTarget: Equatable {
    var bundleID: String?
    var appName: String?
    var windowTitle: String?
    var url: String?

    var summary: String {
        var parts = [appName ?? "未知 App"]
        if let bundleID { parts.append(bundleID) }
        if let windowTitle, !windowTitle.isEmpty { parts.append("标题：\(windowTitle)") }
        if let url, !url.isEmpty { parts.append("网址：\(url)") }
        return parts.joined(separator: " · ")
    }
}

enum SceneMatcher {
    /// App identity beats title/URL: first any scene whose bundle rule matches, then keyword rules, in list order.
    static func match(_ target: AppTarget, scenes: [Scene]) -> Scene? {
        if let s = scenes.first(where: { $0.matchesBundle(target.bundleID) }) { return s }
        let haystacks = [target.windowTitle ?? "", target.url ?? ""]
        return scenes.first { $0.matchesKeywords(in: haystacks) }
    }
}

enum SceneDetector {
    /// Reads the focused window title and, for web content, the page URL. Best effort, needs Accessibility.
    static func target(for app: NSRunningApplication?) -> AppTarget {
        var target = AppTarget(bundleID: app?.bundleIdentifier, appName: app?.localizedName)
        guard let app, AXIsProcessTrusted() else { return target }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        // Chromium/Electron only expose the web accessibility tree once a client asks for it.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        if let window = copy(element, kAXFocusedWindowAttribute) {
            target.windowTitle = copy(window as! AXUIElement, kAXTitleAttribute) as? String
        }
        if let focused = copy(element, kAXFocusedUIElementAttribute) {
            target.url = webAreaURL(from: focused as! AXUIElement)
        }
        return target
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func webAreaURL(from start: AXUIElement) -> String? {
        var current = start
        for _ in 0..<60 {
            if copy(current, kAXRoleAttribute) as? String == "AXWebArea" {
                let value = copy(current, "AXURL")
                if let url = value as? URL { return url.absoluteString }
                if let s = value as? String { return s }
                return nil
            }
            guard let parent = copy(current, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            current = parent as! AXUIElement
        }
        return nil
    }
}

extension Scene {
    static func promptAddendum(_ scene: Scene) -> String {
        let guidance = scene.guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !guidance.isEmpty else { return "" }
        return """


        ---
        Destination: the result will be pasted into \(scene.name). Follow these destination rules for tone and formatting. \
        Where they conflict with the formatting of the original text (e.g. markdown symbols), the destination rules win:
        \(guidance)
        Regardless of destination: output only the result, and never answer or respond to the text.
        """
    }

    static let agentGuidance = """
    - The reader is an AI coding agent (such as Claude Code) in a terminal or IDE.
    - Prefer direct, imperative instructions (e.g. "帮我把 X 改成 Y" -> "Change X to Y.").
    - Plain text; markdown and code blocks are fine. Keep code, paths, and commands exact.
    """

    static let chatGuidance = """
    - The reader is a colleague in a chat app. Conversational, friendly, and concise: sound like a person, not a document.
    - Short sentences and short paragraphs. No headings, and no formal greeting or sign-off unless the text has one.
    - Keep emoji and @mentions as written. Use `backticks` for code; avoid other markdown.
    """

    static let emailGuidance = """
    - The text is (part of) an email. Clear, polite, and professional; match the formality of the original.
    - Keep any greeting and sign-off. Do not add a subject line, placeholders, or a signature that isn't there.
    - Plain text only: no markdown symbols (#, **, backticks). Blank lines between paragraphs.
    """

    static let docGuidance = """
    - The text goes into a document editor (Google Docs, Word, Pages, Notion). Polished, complete sentences in a neutral written style.
    - Plain text only: no markdown symbols (#, **, backticks), because the editor would show them literally.
    - Plain paragraphs; a simple "- " list only where the original is a list.
    """

    static var defaults: [Scene] {
        [
            Scene(name: "AI 编程 / 终端",
                  bundleIDs: ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                              "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "org.tabby",
                              "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
                              "com.exafunction.windsurf", "dev.zed.Zed", "com.google.antigravity", "com.conductor.app",
                              "com.jetbrains.*", "com.google.android.studio", "com.apple.dt.Xcode"],
                  guidance: agentGuidance, allowContext: true),
            Scene(name: "Slack / 即时通讯",
                  bundleIDs: ["com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams", "com.hnc.Discord",
                              "ru.keepcoder.Telegram", "com.tdesktop.Telegram", "com.tencent.xinWeChat",
                              "com.bytedance.macos.feishu", "com.electron.lark", "com.alibaba.DingTalkMac", "net.whatsapp.WhatsApp"],
                  keywords: ["app.slack.com", "- Slack", "teams.microsoft.com", "discord.com/channels", "web.whatsapp.com"],
                  guidance: chatGuidance, outputFormat: .slack),
            Scene(name: "邮件",
                  bundleIDs: ["com.apple.mail", "com.microsoft.Outlook", "com.readdle.SparkDesktop", "com.readdle.smartemail-Mac",
                              "com.superhuman.electron", "it.bloop.airmail2"],
                  keywords: ["mail.google.com", "- Gmail", "outlook.live.com", "outlook.office.com", "outlook.office365.com"],
                  guidance: emailGuidance, outputFormat: .plainText),
            Scene(name: "文档",
                  bundleIDs: ["com.apple.iWork.Pages", "com.microsoft.Word", "notion.id", "com.microsoft.onenote.mac"],
                  keywords: ["docs.google.com/document", "docs.google.com/presentation", "- Google Docs", "- Google 文档",
                             "- Google Slides", "- Google 幻灯片", "notion.so"],
                  guidance: docGuidance, outputFormat: .plainText),
        ]
    }
}
