import AppKit
import Carbon.HIToolbox
import SwiftUI

enum RunState: Equatable {
    case idle
    case running
    case done
    case failed(String)
}

@MainActor
final class PanelModel: ObservableObject {
    @Published var input = ""
    @Published var output = ""
    @Published var state: RunState = .idle
    @Published var presetID: UUID?
    @Published var notice: String?
    @Published var targetAppName: String?
    @Published var lastRunInput: String?
    @Published var lastRunPresetID: UUID?
    @Published var lastRunUsedContext: Bool?
    /// Whether this run should include session context (starts from the preset, ⌘K toggles).
    @Published var useContext = false
    @Published var context: SessionContext?
    @Published var contextLoading = false
    /// Destination scene (nil = 通用, no scene matched).
    @Published var scene: Scene?
    @Published var target: AppTarget?
    @Published var lastRunSceneKey: String?
    weak var textView: NSTextView?

    var sceneKey: String { scene?.id.uuidString ?? "general" }

    var isStale: Bool {
        lastRunInput != input || lastRunPresetID != presetID || lastRunUsedContext != useContext
            || lastRunSceneKey != sceneKey
    }
    var canPaste: Bool {
        state == .done && !isStale && !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func reset() {
        input = ""
        output = ""
        state = .idle
        notice = nil
        lastRunInput = nil
        lastRunPresetID = nil
        lastRunUsedContext = nil
        lastRunSceneKey = nil
    }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let store: ConfigStore
    let model = PanelModel()
    var openSettings: () -> Void = {}

    private var panel: KeyPanel!
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private let runner = ClaudeRunner()
    private var runToken = 0

    init(store: ConfigStore) {
        self.store = store
        super.init()
        buildPanel()
    }

    private func buildPanel() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 440),
                         styleMask: [.titled, .fullSizeContentView, .resizable],
                         backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 520, height: 340)
        panel.delegate = self

        let view = PanelView(
            model: model, store: store,
            onSelectPreset: { [weak self] id in self?.selectPreset(id) },
            onPrimary: { [weak self] in self?.primaryAction() },
            onSettings: { [weak self] in
                self?.close(restoreFocus: false)
                self?.openSettings()
            },
            onToggleContext: { [weak self] in self?.toggleContext() },
            onSelectScene: { [weak self] id in self?.selectScene(id) })
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        let host = NSHostingView(rootView: view)
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        panel.contentView = effect
    }

    private var currentPreset: Preset? {
        store.config.presets.first { $0.id == model.presetID } ?? store.config.presets.first
    }

    // MARK: Show / hide

    /// Hotkey entry point. `presetID == nil` means "main hotkey: use the last preset".
    func toggle(presetID: UUID?) {
        if panel.isVisible && panel.isKeyWindow {
            if let presetID, presetID != model.presetID {
                selectPreset(presetID)
            } else {
                close(restoreFocus: true)
            }
            return
        }
        show(presetID: presetID)
    }

    func show(presetID: UUID?) {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        model.targetAppName = previousApp?.localizedName

        // Which destination is this? (bundle ID, then window title / page URL)
        let target = SceneDetector.target(for: previousApp)
        let detected = SceneMatcher.match(target, scenes: store.config.scenes)
        let sceneChanged = detected?.id != model.scene?.id
        model.target = target
        model.scene = detected
        store.lastDetection = target.summary + "  →  " + (detected?.name ?? "通用（未匹配场景）")

        // Must read the selection before we steal focus.
        var prefilled = false
        if store.config.prefillSelection, let selection = Paster.selectedText() {
            model.reset()
            model.input = selection
            prefilled = true
        }

        let wanted = presetID
            ?? detected?.defaultPresetID
            ?? store.config.lastPresetByScene[model.sceneKey]
            ?? store.config.lastPresetID
        let newPresetID = store.config.presets.contains { $0.id == wanted } ? wanted : store.config.presets.first?.id
        if newPresetID != model.presetID || model.lastRunPresetID == nil || sceneChanged {
            model.presetID = newPresetID
            model.useContext = defaultUseContext
        }
        model.notice = nil
        reloadContext()

        if !panel.isVisible { position() }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()

        if model.canPaste {
            panel.makeFirstResponder(nil)
        } else {
            focusInput()
        }
        // Selected text + a preset-specific hotkey: run immediately.
        if prefilled && presetID != nil { run() }
    }

    func close(restoreFocus: Bool) {
        removeKeyMonitor()
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        if restoreFocus { previousApp?.activate() }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking elsewhere dismisses the panel like Spotlight; the draft is kept.
        if panel.isVisible { close(restoreFocus: false) }
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { panel.center(); return }
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + visible.height * 0.62 - size.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: max(visible.minY, y)))
    }

    private func focusInput() {
        guard let tv = model.textView else { return }
        panel.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                return self.handleKey(event) ? nil : event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns true if the event was consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.window === panel else { return false }
        // Let the input method finish composing (Enter/Esc confirm or cancel candidates).
        if let tv = model.textView, tv.hasMarkedText() { return false }

        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let code = Int(event.keyCode)

        if code == kVK_Escape {
            escape()
            return true
        }
        if code == kVK_Return || code == kVK_ANSI_KeypadEnter {
            if flags == .command {
                primaryAction()
                return true
            }
            if flags.isEmpty, model.canPaste, panel.firstResponder !== model.textView {
                paste()
                return true
            }
            return false
        }
        if flags == .command, let ch = event.charactersIgnoringModifiers, let n = Int(ch), (1...9).contains(n) {
            let presets = store.config.presets
            if n <= presets.count { selectPreset(presets[n - 1].id) }
            return true
        }
        if flags == .command, code == kVK_ANSI_K {
            toggleContext()
            return true
        }
        if flags == [.command, .shift], code == kVK_ANSI_C {
            copyOnly()
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers == "," {
            close(restoreFocus: false)
            openSettings()
            return true
        }
        return false
    }

    // MARK: Actions

    /// ⌘↩: run, or paste if the current result is up to date.
    func primaryAction() {
        if model.canPaste {
            paste()
        } else if model.state != .running {
            run()
        }
    }

    /// Reads the latest Claude Code transcript off the main thread (only text turns, trimmed to budget).
    func reloadContext() {
        let maxAge = TimeInterval(max(1, store.config.contextMaxAgeMinutes) * 60)
        let budget = max(1_000, store.config.contextCharBudget)
        model.contextLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let context = SessionLocator.load(maxAge: maxAge, characterBudget: budget)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.model.context = context
                    self.model.contextLoading = false
                }
            }
        }
    }

    func toggleContext() {
        model.useContext.toggle()
        rerunIfHadResult()
    }

    /// Context is on when the preset wants it and the destination makes sense for Claude Code context.
    private var defaultUseContext: Bool {
        (currentPreset?.includeContext ?? false) && (model.scene?.allowContext ?? false)
    }

    func selectPreset(_ id: UUID) {
        guard id != model.presetID else { return }
        model.presetID = id
        model.useContext = defaultUseContext
        rerunIfHadResult()
    }

    /// Manual scene override from the panel (nil = 通用).
    func selectScene(_ id: UUID?) {
        guard id != model.scene?.id else { return }
        model.scene = store.config.scenes.first { $0.id == id }
        model.useContext = defaultUseContext
        rerunIfHadResult()
    }

    private func rerunIfHadResult() {
        let hadResult: Bool
        switch model.state {
        case .done, .failed: hadResult = true
        default: hadResult = false
        }
        if hadResult, !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { run() }
    }

    func run() {
        let text = model.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            model.notice = "先输入要处理的内容"
            return
        }
        guard let preset = currentPreset else { return }

        runner.cancel()
        runToken += 1
        let token = runToken
        model.presetID = preset.id
        model.state = .running
        model.output = ""
        model.notice = nil
        model.lastRunInput = model.input
        model.lastRunPresetID = preset.id
        model.lastRunUsedContext = model.useContext
        model.lastRunSceneKey = model.sceneKey
        var updated = store.config
        updated.lastPresetID = preset.id
        updated.lastPresetByScene[model.sceneKey] = preset.id
        store.config = updated

        var cfg = store.config
        var userMessage = text
        var systemPrompt = preset.prompt
        if let scene = model.scene { systemPrompt += Scene.promptAddendum(scene) }
        if model.useContext {
            if let context = model.context {
                userMessage = ContextPrompt.userMessage(draft: text, context: context)
                systemPrompt += ContextPrompt.systemAddendum
                // Context-based rewrites may guess wrong: always preview.
                cfg.autoPaste = false
            } else {
                model.notice = model.contextLoading
                    ? "会话上下文还在读取，本次未附带上下文"
                    : "没找到最近 \(cfg.contextMaxAgeMinutes) 分钟内的 Claude Code 会话，本次未附带上下文"
            }
        }

        runner.run(
            input: userMessage,
            systemPrompt: systemPrompt,
            model: preset.model.isEmpty ? cfg.model : preset.model,
            effort: cfg.effort,
            claudeOverride: cfg.claudePath,
            onDelta: { [weak self] delta in
                MainActor.assumeIsolated {
                    guard let self, token == self.runToken else { return }
                    self.model.output += delta
                }
            },
            completion: { [weak self] result in
                MainActor.assumeIsolated {
                    guard let self, token == self.runToken else { return }
                    self.finishRun(result, autoPaste: cfg.autoPaste)
                }
            })
    }

    private func finishRun(_ result: Result<String, Error>, autoPaste: Bool) {
        switch result {
        case .success(let text):
            model.output = OutputFormatter.apply(model.scene?.format ?? .keep, to: text)
            model.state = .done
            // Move focus off the editor so a plain ↩ pastes.
            if panel.firstResponder === model.textView { panel.makeFirstResponder(nil) }
            if autoPaste && panel.isVisible { paste() }
        case .failure(let error):
            if case ClaudeError.cancelled = error { return }
            model.state = .failed(error.localizedDescription)
        }
    }

    private func cancelRun() {
        runToken += 1
        runner.cancel()
        if model.state == .running { model.state = .idle }
    }

    private func escape() {
        cancelRun()
        close(restoreFocus: true)
    }

    func paste() {
        let text = model.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard Paster.isTrusted else {
            Paster.copy(text)
            model.notice = "结果已复制到剪贴板。没有辅助功能权限，无法自动粘贴：按 Esc 回到原窗口后手动 ⌘V，并到设置里授权。"
            Paster.requestTrust()
            return
        }
        let target = previousApp
        removeKeyMonitor()
        panel.orderOut(nil)
        model.reset()
        Paster.paste(text, into: target, restoreClipboard: store.config.restoreClipboard)
    }

    private func copyOnly() {
        let text = model.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Paster.copy(text)
        model.reset()
        close(restoreFocus: true)
    }
}

// MARK: - SwiftUI

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var store: ConfigStore
    var onSelectPreset: (UUID) -> Void
    var onPrimary: () -> Void
    var onSettings: () -> Void
    var onToggleContext: () -> Void
    var onSelectScene: (UUID?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack(alignment: .topLeading) {
                InputTextView(text: $model.input) { tv in model.textView = tv }
                if model.input.isEmpty {
                    Text("输入要处理的内容…")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 15))
                        .padding(.leading, 13)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 110, maxHeight: 170)
            Divider()
            ScrollView {
                outputContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(store.config.presets.enumerated()), id: \.element.id) { index, preset in
                        let selected = preset.id == model.presetID
                        Button { onSelectPreset(preset.id) } label: {
                            HStack(spacing: 4) {
                                Text(preset.name)
                                if index < 9 {
                                    Text("⌘\(index + 1)").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(selected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.07)))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            sceneChip
            contextChip
            Button(action: onSettings) { Image(systemName: "gearshape") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("设置 (⌘,)")
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var sceneChip: some View {
        Menu {
            ForEach(store.config.scenes) { scene in
                Button { onSelectScene(scene.id) } label: {
                    if scene.id == model.scene?.id { Label(scene.name, systemImage: "checkmark") } else { Text(scene.name) }
                }
            }
            Divider()
            Button { onSelectScene(nil) } label: {
                if model.scene == nil { Label("通用（不加场景要求）", systemImage: "checkmark") } else { Text("通用（不加场景要求）") }
            }
        } label: {
            Text("场景：\(model.scene?.name ?? "通用")").font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("检测到：\(model.target?.summary ?? "未知")\n规则在 设置 → 场景 里修改")
    }

    private var contextLabel: String {
        guard model.useContext else { return "上下文：关" }
        if model.contextLoading && model.context == nil { return "上下文：读取中…" }
        guard let c = model.context else { return "上下文：无会话" }
        let minutes = max(0, Int(Date().timeIntervalSince(c.modified) / 60))
        let age = minutes == 0 ? "刚刚" : "\(minutes) 分钟前"
        return "上下文：\(c.project) · \(age) · ~\(c.estimatedTokens / 100 * 100 + 100) tok"
    }

    private var contextChip: some View {
        Button(action: onToggleContext) {
            HStack(spacing: 4) {
                Image(systemName: model.useContext ? "text.bubble.fill" : "text.bubble")
                Text(contextLabel).lineLimit(1)
                Text("⌘K").font(.caption2).foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(model.useContext && model.context != nil ? Color.accentColor : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().strokeBorder(Color.primary.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(model.context.map { "会话文件：\($0.sessionFile.path)\n只发送对话文字，不含工具输出和思考过程" } ?? "附带最近的 Claude Code 会话作为参考上下文")
    }

    @ViewBuilder
    private var outputContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.state {
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            default:
                if model.output.isEmpty {
                    if model.state == .running {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("处理中…").foregroundStyle(.secondary)
                        }
                    } else {
                        Text("结果会显示在这里").foregroundStyle(.tertiary)
                    }
                } else {
                    Text(model.output)
                        .font(.system(size: 15))
                        .textSelection(.enabled)
                        .opacity(model.state == .done && model.isStale ? 0.5 : 1)
                }
            }
            if let notice = model.notice {
                Text(notice).font(.callout).foregroundStyle(.orange)
            }
        }
    }

    private var statusText: String {
        switch model.state {
        case .running: return "处理中…  Esc 取消"
        case .failed: return "出错了，⌘↩ 重试"
        case .done where model.isStale: return "内容或预设已变化，⌘↩ 重新执行"
        case .done: return "↩ 粘贴到 \(model.targetAppName ?? "原窗口")"
        case .idle: return "⌘↩ 执行"
        }
    }

    private var footer: some View {
        HStack {
            Text(statusText)
                .font(.callout)
                .foregroundStyle(model.canPaste ? Color.accentColor : .secondary)
            Spacer()
            Text("⌘↩ 执行/粘贴 · ⌘K 上下文 · ⇧⌘C 复制 · ⌘1–9 切换 · Esc 关闭")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// NSTextView wrapper so we can query IME composition state and control focus.
struct InputTextView: NSViewRepresentable {
    @Binding var text: String
    var onCreate: (NSTextView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.font = .systemFont(ofSize: 15)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.textContainerInset = NSSize(width: 8, height: 10)
        tv.string = text
        onCreate(tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text && !tv.hasMarkedText() {
            tv.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InputTextView
        init(_ parent: InputTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}
