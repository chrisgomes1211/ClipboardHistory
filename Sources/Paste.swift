import Foundation
import Cocoa
import Carbon
import ApplicationServices

/// Writes items back to the pasteboard and simulates ⌘V into the frontmost app.
enum Paster {

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Ask macOS for Accessibility permission (shows the system prompt).
    /// Returns true if we already have it.
    @discardableResult
    static func ensureTrusted(interactive: Bool) -> Bool {
        if AXIsProcessTrusted() { return true }
        if interactive {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        }
        return false
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Post ⌘V to the HID event tap so the frontmost app receives a real paste.
    static func simulateCommandV() {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
