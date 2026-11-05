import Cocoa

// ClipboardHistory — a Win+V-style clipboard manager for macOS.
// Menu-bar app: no Dock icon, launches at login via LaunchAgent.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let config = Config.load()
let store = ClipboardStore(config: config)
let controller = PanelController(store: store, config: config)

store.start()

// Dev flag: ./ClipboardHistory --open → shows the panel after 1s (for screenshots/tests)
if CommandLine.arguments.contains("--open") {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { controller.openPanel() }
}

app.run()
