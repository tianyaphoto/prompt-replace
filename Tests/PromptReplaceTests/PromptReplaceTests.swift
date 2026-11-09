import Carbon.HIToolbox
import XCTest
@testable import PromptReplace

final class StreamParserTests: XCTestCase {
    private func parse(_ s: String) -> StreamEvent? { StreamParser.parse(Data(s.utf8)) }

    func testTextDelta() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Help me"}}}"#
        XCTAssertEqual(parse(line), .delta("Help me"))
    }

    func testThinkingDeltaIgnored() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}}"#
        XCTAssertNil(parse(line))
    }

    func testSuccessResult() {
        let line = #"{"type":"result","subtype":"success","is_error":false,"result":"Make it async."}"#
        XCTAssertEqual(parse(line), .result(text: "Make it async.", isError: false))
    }

    func testErrorResult() {
        let line = #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["boom"]}"#
        XCTAssertEqual(parse(line), .result(text: "boom", isError: true))
    }

    func testGarbageIgnored() {
        XCTAssertNil(parse("not json"))
        XCTAssertNil(parse(#"{"type":"system","subtype":"init"}"#))
    }
}

final class ConfigTests: XCTestCase {
    func testMissingKeysFallBackToDefaults() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(config.presets.count, AppConfig.defaults.presets.count)
        XCTAssertEqual(config.mainHotKey, AppConfig.defaults.mainHotKey)
        XCTAssertEqual(config.model, "haiku")
        XCTAssertTrue(config.prefillSelection)
    }

    func testExplicitNullHotKeyStaysCleared() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"mainHotKey":null}"#.utf8))
        XCTAssertNil(config.mainHotKey)
    }

    func testRoundTrip() throws {
        var config = AppConfig.defaults
        config.autoPaste = true
        config.presets[0].model = "sonnet"
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded, config)
    }

    func testModifierSymbolsOrder() {
        let m = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        XCTAssertEqual(KeyCombo.modifierSymbols(m), "⌃⌥⇧⌘")
    }
}

final class TranscriptParserTests: XCTestCase {
    private func jsonl(_ objects: [[String: Any]]) -> Data {
        Data(objects.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
            .joined(separator: "\n").utf8)
    }

    func testKeepsTextDropsToolOutputThinkingAndMeta() {
        let data = jsonl([
            ["type": "user", "cwd": "/Users/x/proj", "message": ["content": "把 fetchUser 改成异步"]],
            ["type": "assistant", "message": ["content": [
                ["type": "thinking", "thinking": "secret"],
                ["type": "tool_use", "name": "Read", "input": ["file_path": "src/api.ts"]],
            ]]],
            ["type": "user", "message": ["content": [["type": "tool_result", "content": "HUGE FILE CONTENT"]]]],
            ["type": "assistant", "message": ["content": [["type": "text", "text": "Done, fetchUser is async now."]]]],
            ["type": "user", "isMeta": true, "message": ["content": "Base directory for this skill"]],
            ["type": "user", "isSidechain": true, "message": ["content": "subagent chatter"]],
            ["type": "user", "message": ["content": "hi<system-reminder>injected</system-reminder> there"]],
        ])
        let result = TranscriptParser.parse(data, characterBudget: 10_000)
        XCTAssertEqual(result.cwd, "/Users/x/proj")
        let rendered = result.turns.map { "\($0.role.rawValue):\($0.text)" }
        XCTAssertEqual(rendered, [
            "user:把 fetchUser 改成异步",
            "assistant:(tool: Read src/api.ts)\nDone, fetchUser is async now.",
            "user:hi there",
        ])
    }

    func testClearResetsHistory() {
        let data = jsonl([
            ["type": "user", "message": ["content": "old topic"]],
            ["type": "user", "message": ["content": "<command-name>/clear</command-name>\n<command-message>clear</command-message>"]],
            ["type": "user", "message": ["content": "new topic"]],
        ])
        XCTAssertEqual(TranscriptParser.parse(data, characterBudget: 10_000).turns.map(\.text), ["new topic"])
    }

    func testBudgetKeepsNewest() {
        let turns = (0..<10).map { SessionContext.Turn(role: $0 % 2 == 0 ? .user : .assistant, text: String(repeating: "\($0)", count: 300)) }
        let kept = TranscriptParser.trimToBudget(turns, 1_000)
        XCTAssertEqual(kept.last?.text, turns.last?.text)
        XCTAssertLessThanOrEqual(kept.reduce(0) { $0 + $1.text.count }, 1_001)
    }

    func testMigrationAddsRefinePresetOnce() throws {
        let old = #"{"presets":[{"name":"翻译成英文","prompt":"x"}]}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(old.utf8))
        XCTAssertEqual(config.presets.map(\.name), ["翻译成英文", "精炼为 agent 指令"])
        XCTAssertTrue(config.presets[1].includeContext)
        let again = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(again.presets.count, 2)
    }
}

final class SceneTests: XCTestCase {
    private let scenes = Scene.defaults
    private func name(_ t: AppTarget) -> String? { SceneMatcher.match(t, scenes: scenes)?.name }

    func testBundleMatching() {
        XCTAssertEqual(name(AppTarget(bundleID: "com.mitchellh.ghostty")), "AI 编程 / 终端")
        XCTAssertEqual(name(AppTarget(bundleID: "com.tinyspeck.slackmacgap")), "Slack / 即时通讯")
        XCTAssertEqual(name(AppTarget(bundleID: "com.apple.mail")), "邮件")
        XCTAssertEqual(name(AppTarget(bundleID: "COM.APPLE.IWORK.PAGES")), "文档")
    }

    func testWildcardBundle() {
        XCTAssertEqual(name(AppTarget(bundleID: "com.jetbrains.intellij")), "AI 编程 / 终端")
    }

    func testBrowserWebAppsByURLOrTitle() {
        XCTAssertEqual(name(AppTarget(bundleID: "com.google.Chrome", url: "https://docs.google.com/document/d/abc/edit")), "文档")
        XCTAssertEqual(name(AppTarget(bundleID: "com.google.Chrome", windowTitle: "Q3 plan - Google Docs")), "文档")
        XCTAssertEqual(name(AppTarget(bundleID: "com.apple.Safari", url: "https://mail.google.com/mail/u/0/#inbox")), "邮件")
        XCTAssertEqual(name(AppTarget(bundleID: "com.google.Chrome", windowTitle: "general (Channel) - Acme - Slack")), "Slack / 即时通讯")
    }

    func testTitleMentioningSlackInsideADocIsADoc() {
        XCTAssertEqual(name(AppTarget(bundleID: "com.google.Chrome", windowTitle: "Slack onboarding notes - Google Docs")), "文档")
    }

    func testAppIdentityBeatsTitle() {
        // A terminal tab titled like a Gmail page is still the terminal.
        XCTAssertEqual(name(AppTarget(bundleID: "com.googlecode.iterm2", windowTitle: "debug - Gmail")), "AI 编程 / 终端")
    }

    func testUnknownFallsBackToGeneral() {
        XCTAssertNil(name(AppTarget(bundleID: "com.google.Chrome", windowTitle: "Hacker News")))
        XCTAssertNil(name(AppTarget()))
    }

    func testOnlyAgentSceneAllowsContextByDefault() {
        XCTAssertEqual(scenes.filter(\.allowContext).map(\.name), ["AI 编程 / 终端"])
    }

    func testAddendum() {
        XCTAssertEqual(Scene.promptAddendum(Scene(name: "x", guidance: "  ")), "")
        XCTAssertTrue(Scene.promptAddendum(scenes[2]).contains("pasted into 邮件"))
    }

    func testV2ConfigMigratesToV3() throws {
        let v2 = AppConfig(presets: [
            Preset(name: "翻译成英文", prompt: AppConfig.legacyTranslatePromptV1),
            Preset(name: "自定义", prompt: "my own prompt"),
        ], mainHotKey: nil, configVersion: 2)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(v2)) as! [String: Any]
        json.removeValue(forKey: "scenes")
        json.removeValue(forKey: "lastPresetByScene")
        let migrated = try JSONDecoder().decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(migrated.configVersion, AppConfig.currentVersion)
        XCTAssertEqual(migrated.presets[0].prompt, AppConfig.defaultTranslatePrompt)
        XCTAssertEqual(migrated.presets[1].prompt, "my own prompt")
        XCTAssertEqual(migrated.scenes.map(\.name), Scene.defaults.map(\.name))
        XCTAssertFalse(AppConfig.defaultTranslatePrompt.contains("coding agent"))
    }
}

final class OutputFormatterTests: XCTestCase {
    let md = "# Weekly update\n**This week**\n* Fixed `auth.ts`\n- See [docs](https://x.y)\n```\nlet a = 1\n```\n2 * 3 = 6"

    func testPlainText() {
        XCTAssertEqual(OutputFormatter.plainText(md),
                       "Weekly update\nThis week\n- Fixed auth.ts\n- See docs (https://x.y)\nlet a = 1\n2 * 3 = 6")
    }

    func testSlack() {
        XCTAssertEqual(OutputFormatter.slack("# Title\n**bold** and `code`\n[docs](https://x.y)"),
                       "*Title*\n*bold* and `code`\n<https://x.y|docs>")
    }

    func testV3ScenesGetDefaultFormats() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppConfig.defaults)) as! [String: Any]
        json["configVersion"] = 3
        json["scenes"] = (json["scenes"] as! [[String: Any]]).map { var s = $0; s.removeValue(forKey: "outputFormat"); return s }
        let c = try JSONDecoder().decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(c.scenes.map(\.format), [.keep, .slack, .plainText, .plainText])
    }
}
