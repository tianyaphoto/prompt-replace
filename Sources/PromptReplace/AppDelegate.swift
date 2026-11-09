import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = ConfigStore()
    private(set) lazy var panel = PanelController(store: store)
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var hotKeysSuspended = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "Prompt Replace")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        panel.openSettings = { [weak self] in self?.showSettings() }
        store.onHotKeysChanged = { [weak self] in self?.registerHotKeys() }

        let center = NotificationCenter.default
        center.addObserver(forName: .suspendHotKeys, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hotKeysSuspended = true
                HotKeyCenter.shared.unregisterAll()
            }
        }
        center.addObserver(forName: .resumeHotKeys, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hotKeysSuspended = false
                self?.registerHotKeys()
            }
        }

        registerHotKeys()
        if !Paster.isTrusted { Paster.requestTrust() }

        // Resolve the claude binary up front so the first run isn't slowed by the shell lookup.
        let override = store.config.claudePath
        DispatchQueue.global(qos: .utility).async { _ = try? ClaudeRunner.resolve(override: override) }
    }

    func registerHotKeys() {
        let center = HotKeyCenter.shared
        center.unregisterAll()
        guard !hotKeysSuspended else { return }

        var failures: [String] = []
        if let main = store.config.mainHotKey,
           !center.register(main, action: { [weak self] in self?.panel.toggle(presetID: nil) }) {
            failures.append(main.display)
        }
        for preset in store.config.presets {
            guard let combo = preset.hotKey else { continue }
            let id = preset.id
            if !center.register(combo, action: { [weak self] in self?.panel.toggle(presetID: id) }) {
                failures.append("\(combo.display)（\(preset.name)）")
            }
        }
        store.hotKeyErrors = failures
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let open = NSMenuItem(title: "打开浮窗", action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        if let main = store.config.mainHotKey { open.title += "    \(main.display)" }
        menu.addItem(open)
        menu.addItem(.separator())

        for preset in store.config.presets {
            var title = preset.name
            if let hk = preset.hotKey { title += "    \(hk.display)" }
            let item = NSMenuItem(title: title, action: #selector(openPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.id
            menu.addItem(item)
        }
        menu.addItem(.separator())

        if !Paster.isTrusted {
            let ax = NSMenuItem(title: "⚠️ 授予辅助功能权限…", action: #selector(grantAccessibility), keyEquivalent: "")
            ax.target = self
            menu.addItem(ax)
        }
        if !store.hotKeyErrors.isEmpty {
            let warn = NSMenuItem(title: "⚠️ 有快捷键注册失败，见设置", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
        }
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "退出 Prompt Replace", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func openPanel() { panel.show(presetID: nil) }

    @objc private func openPreset(_ sender: NSMenuItem) {
        panel.show(presetID: sender.representedObject as? UUID)
    }

    @objc private func grantAccessibility() {
        Paster.requestTrust()
        Paster.openAccessibilitySettings()
    }

    @objc private func openSettingsAction() { showSettings() }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store)))
            window.title = "Prompt Replace 设置"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 820, height: 600))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Accessory apps still need an Edit menu for ⌘C/⌘V/⌘A/⌘Z to work in text fields.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "Prompt Replace")
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}
