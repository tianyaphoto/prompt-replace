import AppKit
import ApplicationServices

// `PromptReplace --run "文本" [preset index]` runs one transformation in the terminal (for debugging).
let arguments = CommandLine.arguments

// `PromptReplace --detect [seconds]`: wait, then print what the frontmost app looks like to scene detection.
if arguments.count >= 2, arguments[1] == "--detect" {
    MainActor.assumeIsolated {
        let delay = arguments.count >= 3 ? (Double(arguments[2]) ?? 4) : 4
        print("Switch to the app/window to test; detecting in \(Int(delay))s…")
        Thread.sleep(forTimeInterval: delay)
        let app = NSWorkspace.shared.frontmostApplication
        let target = SceneDetector.target(for: app)
        let scene = SceneMatcher.match(target, scenes: ConfigStore().config.scenes)
        print("accessibility: \(AXIsProcessTrusted())")
        print("bundle: \(target.bundleID ?? "-")\ntitle:  \(target.windowTitle ?? "-")\nurl:    \(target.url ?? "-")")
        print("scene:  \(scene?.name ?? "通用（未匹配）")")
        exit(0)
    }
}
if arguments.count >= 3, arguments[1] == "--run" {
    MainActor.assumeIsolated {
        let config = ConfigStore().config
        let index = arguments.count >= 4 ? (Int(arguments[3]) ?? 0) : 0
        let preset = config.presets[min(max(index, 0), config.presets.count - 1)]
        FileHandle.standardError.write(Data("[\(preset.name)] model=\(preset.model.isEmpty ? config.model : preset.model)\n".utf8))
        var input = arguments[2]
        var systemPrompt = preset.prompt
        var outputFormat = OutputFormat.keep
        if let sceneName = ProcessInfo.processInfo.environment["SCENE"] {
            if let scene = config.scenes.first(where: { $0.name.contains(sceneName) }) {
                outputFormat = scene.format
                FileHandle.standardError.write(Data("[scene] \(scene.name)\n".utf8))
                systemPrompt += Scene.promptAddendum(scene)
            } else {
                FileHandle.standardError.write(Data("[scene] no scene matching \(sceneName)\n".utf8))
            }
        }
        if preset.includeContext {
            if let context = SessionLocator.load(maxAge: TimeInterval(config.contextMaxAgeMinutes * 60),
                                                 characterBudget: config.contextCharBudget) {
                FileHandle.standardError.write(Data("[context] \(context.sessionFile.lastPathComponent) turns=\(context.turns.count) chars=\(context.characterCount) ~tokens=\(context.estimatedTokens)\n".utf8))
                if ProcessInfo.processInfo.environment["SHOW_CONTEXT"] != nil {
                    FileHandle.standardError.write(Data((context.rendered() + "\n----\n").utf8))
                }
                input = ContextPrompt.userMessage(draft: input, context: context)
                systemPrompt += ContextPrompt.systemAddendum
            } else {
                FileHandle.standardError.write(Data("[context] none found\n".utf8))
            }
        }
        let runner = ClaudeRunner()
        runner.run(input: input, systemPrompt: systemPrompt,
                   model: preset.model.isEmpty ? config.model : preset.model,
                   effort: config.effort, claudeOverride: config.claudePath,
                   onDelta: { FileHandle.standardError.write(Data($0.utf8)) },
                   completion: { result in
                       switch result {
                       case .success(let text):
                           print("\n---\n\(OutputFormatter.apply(outputFormat, to: text))")
                           exit(0)
                       case .failure(let error):
                           print("\nERROR: \(error.localizedDescription)")
                           exit(1)
                       }
                   })
        RunLoop.main.run()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
