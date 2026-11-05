import Foundation

/// User configuration, stored as JSON in
/// ~/Library/Application Support/ClipboardHistory/config.json
/// Edit the file (or just the hotkey) and relaunch — no recompile needed.
struct Config: Codable {
    /// Global hotkey, e.g. "option+v", "command+shift+v", "control+v".
    var hotkey: String = "option+v"
    /// Maximum number of history items kept.
    var maxItems: Int = 100
    /// Items older than this many days are deleted on load/save.
    var expiryDays: Int = 7

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClipboardHistory")
    static let url = directory.appendingPathComponent("config.json")

    static func load() -> Config {
        var cfg = Config()
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Config.self, from: data) {
            cfg = decoded
        } else {
            // First run: write the defaults so the user has something to edit.
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            cfg.save()
        }
        return cfg
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: Self.url, options: .atomic)
        }
    }
}
