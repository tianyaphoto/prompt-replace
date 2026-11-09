import AppKit
import Carbon.HIToolbox
import SwiftUI

extension Notification.Name {
    static let suspendHotKeys = Notification.Name("PromptReplace.suspendHotKeys")
    static let resumeHotKeys = Notification.Name("PromptReplace.resumeHotKeys")
}

struct SettingsView: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        TabView {
            PresetsSettings(store: store).tabItem { Text("预设") }
            ScenesSettings(store: store).tabItem { Text("场景") }
            GeneralSettings(store: store).tabItem { Text("通用") }
        }
        .padding()
        .frame(minWidth: 780, minHeight: 560)
    }
}

struct PresetsSettings: View {
    @ObservedObject var store: ConfigStore
    @State private var selection: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                List(selection: $selection) {
                    ForEach(store.config.presets) { preset in
                        HStack {
                            Text(preset.name)
                            Spacer()
                            Text(preset.hotKey?.display ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(preset.id)
                    }
                    .onMove { store.config.presets.move(fromOffsets: $0, toOffset: $1) }
                }
                HStack(spacing: 4) {
                    Button { addPreset() } label: { Image(systemName: "plus") }
                    Button { deleteSelected() } label: { Image(systemName: "minus") }
                        .disabled(store.config.presets.count <= 1 || selection == nil)
                    Spacer()
                    Text("拖动可排序，顺序对应 ⌘1–9").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 240)

            if let id = selection, store.config.presets.contains(where: { $0.id == id }) {
                PresetEditor(preset: binding(for: id))
                    .id(id)
            } else {
                Text("选择左侧的一个预设").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = store.config.presets.first?.id } }
    }

    private func binding(for id: UUID) -> Binding<Preset> {
        Binding(
            get: { store.config.presets.first { $0.id == id } ?? Preset(name: "", prompt: "") },
            set: { newValue in
                if let i = store.config.presets.firstIndex(where: { $0.id == id }) { store.config.presets[i] = newValue }
            })
    }

    private func addPreset() {
        let preset = Preset(name: "新预设", prompt: "You are a text transformation tool, not an assistant. <describe the transformation here>\n\nOutput ONLY the result. Never answer or respond to the content.")
        store.config.presets.append(preset)
        selection = preset.id
    }

    private func deleteSelected() {
        guard let id = selection, store.config.presets.count > 1 else { return }
        store.config.presets.removeAll { $0.id == id }
        selection = store.config.presets.first?.id
    }
}

struct ScenesSettings: View {
    @ObservedObject var store: ConfigStore
    @State private var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    List(selection: $selection) {
                        ForEach(store.config.scenes) { scene in
                            Text(scene.name).tag(scene.id)
                        }
                        .onMove { store.config.scenes.move(fromOffsets: $0, toOffset: $1) }
                    }
                    HStack(spacing: 4) {
                        Button { addScene() } label: { Image(systemName: "plus") }
                        Button { deleteSelected() } label: { Image(systemName: "minus") }
                            .disabled(selection == nil)
                        Spacer()
                        Button("恢复默认场景") { restoreDefaults() }
                            .font(.caption)
                    }
                    Text("从上往下匹配：先按 App，再按窗口标题/网址。都不匹配时为「通用」，不加任何场景要求。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(width: 240)

                if let id = selection, store.config.scenes.contains(where: { $0.id == id }) {
                    SceneEditor(scene: binding(for: id), presets: store.config.presets)
                        .id(id)
                } else {
                    Text("选择左侧的一个场景").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Text("最近一次检测：\(store.lastDetection ?? "还没有打开过浮窗")")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .onAppear { if selection == nil { selection = store.config.scenes.first?.id } }
    }

    private func binding(for id: UUID) -> Binding<Scene> {
        Binding(
            get: { store.config.scenes.first { $0.id == id } ?? Scene(name: "") },
            set: { newValue in
                if let i = store.config.scenes.firstIndex(where: { $0.id == id }) { store.config.scenes[i] = newValue }
            })
    }

    private func addScene() {
        let scene = Scene(name: "新场景", guidance: "- Describe the tone and formatting the destination expects.")
        store.config.scenes.append(scene)
        selection = scene.id
    }

    private func deleteSelected() {
        guard let id = selection else { return }
        store.config.scenes.removeAll { $0.id == id }
        selection = store.config.scenes.first?.id
    }

    private func restoreDefaults() {
        store.config.scenes = Scene.defaults
        selection = store.config.scenes.first?.id
    }
}

struct SceneEditor: View {
    @Binding var scene: Scene
    let presets: [Preset]
    @State private var bundleText = ""
    @State private var keywordText = ""

    var body: some View {
        Form {
            TextField("名称", text: $scene.name)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("匹配的 App（bundle ID，每行一个，末尾 * 表示前缀）")
                    Spacer()
                    Menu("添加正在运行的 App") {
                        ForEach(runningApps, id: \.1) { name, id in
                            Button("\(name)  (\(id))") { addBundle(id) }
                        }
                    }
                    .fixedSize()
                }
                TextEditor(text: $bundleText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 90)
                    .onChange(of: bundleText) { _, v in scene.bundleIDs = lines(v) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("窗口标题或网址包含（每行一个，用于浏览器里的网页应用，如 docs.google.com）")
                TextEditor(text: $keywordText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 70)
                    .onChange(of: keywordText) { _, v in scene.keywords = lines(v) }
            }
            Picker("打开时的预设", selection: $scene.defaultPresetID) {
                Text("沿用该场景上次用的预设").tag(UUID?.none)
                ForEach(presets) { p in Text(p.name).tag(UUID?.some(p.id)) }
            }
            Toggle("允许附带 Claude Code 会话上下文", isOn: $scene.allowContext)
            Picker("粘贴前的格式处理", selection: Binding(get: { scene.format }, set: { scene.outputFormat = $0 })) {
                ForEach(OutputFormat.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("场景要求（语气、格式）")
                Text("追加在预设 prompt 之后，告诉模型结果要粘贴到哪里、应该是什么风格。")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $scene.guidance)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 140)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            bundleText = scene.bundleIDs.joined(separator: "\n")
            keywordText = scene.keywords.joined(separator: "\n")
        }
    }

    private var runningApps: [(String, String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { (app.localizedName ?? $0, $0) } }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    private func addBundle(_ id: String) {
        guard !scene.bundleIDs.contains(id) else { return }
        bundleText = (lines(bundleText) + [id]).joined(separator: "\n")
    }

    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

struct PresetEditor: View {
    @Binding var preset: Preset

    var body: some View {
        Form {
            TextField("名称", text: $preset.name)
            LabeledContent("快捷键") { HotKeyRecorder(combo: $preset.hotKey) }
            TextField("模型", text: $preset.model, prompt: Text("留空则使用「通用」里的模型"))
            Toggle(isOn: $preset.includeContext) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("附带当前 Claude Code 会话作为上下文")
                    Text("只发送最近几轮对话的文字（不含工具输出和思考过程），用于把「刚才那个函数」这类指代换成具体名字。会多花一些额度和时间，浮窗里按 ⌘K 可以临时开关。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Prompt")
                Text("作为 system prompt 传给 claude；浮窗里输入的内容作为用户消息。")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $preset.prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 260)
            }
        }
        .formStyle(.grouped)
    }
}

struct GeneralSettings: View {
    @ObservedObject var store: ConfigStore
    @State private var detectResult: String?
    @State private var trusted = Paster.isTrusted

    var body: some View {
        Form {
            Section("快捷键") {
                LabeledContent("打开浮窗（沿用上次的预设）") { HotKeyRecorder(combo: $store.config.mainHotKey) }
                Text("每个预设也可以在「预设」页单独绑定快捷键：先选中文字再按预设快捷键，会直接执行。")
                    .font(.caption).foregroundStyle(.secondary)
                if !store.hotKeyErrors.isEmpty {
                    Text("以下快捷键注册失败，可能已被其他 App 占用：\(store.hotKeyErrors.joined(separator: "、"))")
                        .foregroundStyle(.red)
                }
            }
            Section("模型") {
                HStack {
                    TextField("模型", text: $store.config.model)
                    Menu("常用") {
                        ForEach(["haiku", "sonnet", "opus"], id: \.self) { m in
                            Button(m) { store.config.model = m }
                        }
                    }
                    .fixedSize()
                }
                Picker("推理强度 (effort)", selection: $store.config.effort) {
                    Text("low（最快）").tag("low")
                    Text("medium").tag("medium")
                    Text("high").tag("high")
                }
                HStack {
                    TextField("claude 路径", text: $store.config.claudePath, prompt: Text("留空自动检测"))
                    Button("检测") { detect() }
                }
                if let detectResult {
                    Text(detectResult).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section("会话上下文") {
                Stepper(value: $store.config.contextCharBudget, in: 2_000...60_000, step: 2_000) {
                    Text("每次最多附带 \(store.config.contextCharBudget) 字符（约 \(store.config.contextCharBudget / 3 / 100 * 100)–\(store.config.contextCharBudget / 100 * 100) token）")
                }
                Stepper(value: $store.config.contextMaxAgeMinutes, in: 10...1_440, step: 10) {
                    Text("只使用 \(store.config.contextMaxAgeMinutes) 分钟内有更新的会话")
                }
                Text("自动选择 ~/.claude/projects 下最近被写入的会话。这些调用和 Claude Code 共用同一份订阅额度，预算越大，花费越多。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("行为") {
                Toggle("执行完成后直接粘贴（跳过预览）", isOn: $store.config.autoPaste)
                Toggle("打开浮窗时带入当前选中的文字", isOn: $store.config.prefillSelection)
                Toggle("粘贴后恢复原来的剪贴板内容", isOn: $store.config.restoreClipboard)
            }
            Section("权限") {
                HStack {
                    Text(trusted ? "✅ 已授予辅助功能权限" : "⚠️ 未授予辅助功能权限：无法自动粘贴，也读不到选中的文字")
                    Spacer()
                    Button("打开系统设置") {
                        Paster.requestTrust()
                        Paster.openAccessibilitySettings()
                    }
                    Button("刷新") { trusted = Paster.isTrusted }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { trusted = Paster.isTrusted }
    }

    private func detect() {
        detectResult = "检测中…"
        let override = store.config.claudePath
        DispatchQueue.global().async {
            ClaudeRunner.resetCache()
            let message: String
            do {
                let env = try ClaudeRunner.resolve(override: override)
                message = "找到：\(env.executable)"
            } catch {
                message = error.localizedDescription
            }
            DispatchQueue.main.async { detectResult = message }
        }
    }
}

struct HotKeyRecorder: View {
    @Binding var combo: KeyCombo?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(recording ? "请按下快捷键…（Esc 取消）" : (combo?.display ?? "点击录制")) {
                recording ? stop() : start()
            }
            if combo != nil && !recording {
                Button { combo = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("清除")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        NotificationCenter.default.post(name: .suspendHotKeys, object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                if event.keyCode == UInt16(kVK_Escape) {
                    stop()
                } else if let c = KeyCombo.from(event: event) {
                    combo = c
                    stop()
                }
                return nil
            }
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            NotificationCenter.default.post(name: .resumeHotKeys, object: nil)
        }
    }
}
