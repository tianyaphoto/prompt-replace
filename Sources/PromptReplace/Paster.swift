import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Selected text in the focused element of the frontmost app, via Accessibility. Nil if unavailable.
    static func selectedText() -> String? {
        guard isTrusted else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    private static func snapshot(_ pb: NSPasteboard) -> Snapshot {
        (pb.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
    }

    private static func restore(_ snapshot: Snapshot, to pb: NSPasteboard) {
        pb.clearContents()
        let items = snapshot.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Puts `text` on the clipboard, reactivates `app`, sends ⌘V, then optionally restores the old clipboard.
    @MainActor
    static func paste(_ text: String, into app: NSRunningApplication?, restoreClipboard: Bool) {
        let pb = NSPasteboard.general
        let saved = restoreClipboard ? snapshot(pb) : nil
        copy(text)
        let ourChange = pb.changeCount

        app?.activate()
        waitUntilFrontmost(app, deadline: Date().addingTimeInterval(1.0)) {
            sendCommandV()
            guard let saved else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                // Don't clobber something the user copied in the meantime.
                if pb.changeCount == ourChange { restore(saved, to: pb) }
            }
        }
    }

    private static func waitUntilFrontmost(_ app: NSRunningApplication?, deadline: Date, then action: @escaping () -> Void) {
        let isFront = app == nil || NSWorkspace.shared.frontmostApplication?.processIdentifier == app?.processIdentifier
        if isFront || Date() > deadline {
            // Give the target window a moment to become key before the keystroke lands.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: action)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            waitUntilFrontmost(app, deadline: deadline, then: action)
        }
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
