import Foundation
import Cocoa
import CryptoKit
import Security

enum ClipboardKind: String, Codable {
    case text
    case image
}

struct ClipboardItem: Codable {
    let id: String
    let kind: ClipboardKind
    var text: String?          // full text for text items, preview for images
    var imageFileName: String? // SHA-less content hash file name under images/
    var width: Int?            // image pixel size
    var height: Int?
    var byteCount: Int?
    var isSecure: Bool         // copied from a password manager (concealed type)
    var createdAt: Date
}

/// Captures clipboard changes (text + images), keeps a capped, expiring,
/// encrypted-on-disk history, and writes items back to the pasteboard.
final class ClipboardStore {
    private(set) var items: [ClipboardItem] = []
    private let config: Config
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?
    private let imagesDir = Config.directory.appendingPathComponent("images")
    private let indexURL = Config.directory.appendingPathComponent("index.enc")
    var paused = false
    var onChange: (() -> Void)?

    init(config: Config) {
        self.config = config
        self.lastChangeCount = pasteboard.changeCount - 1 // capture current content on first tick
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        load()
        prune()
    }

    // MARK: - Lifecycle

    func start() {
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard !paused else { return }
        capture()
    }

    // MARK: - Capture

    private func capture() {
        let types = pasteboard.types ?? []
        // Password managers (1Password, Bitwarden, Keychain) mark copies concealed.
        let secure = types.contains { $0.rawValue.contains("ConcealedType") }

        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            addItem(ClipboardItem(id: UUID().uuidString, kind: .text, text: text,
                                  imageFileName: nil, width: nil, height: nil,
                                  byteCount: nil, isSecure: secure, createdAt: Date()))
        } else if let image = readImage() {
            storeImage(image, secure: secure)
        }
    }

    private func readImage() -> NSImage? {
        if let objs = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let img = objs.first {
            return img
        }
        return nil
    }

    private func storeImage(_ image: NSImage, secure: Bool) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }

        let name = fnv1aHex(png) + ".png" // content hash → natural dedupe
        let url = imagesDir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? png.write(to: url, options: .atomic)
        }
        addItem(ClipboardItem(id: UUID().uuidString, kind: .image, text: "Image",
                              imageFileName: name, width: Int(image.size.width),
                              height: Int(image.size.height), byteCount: png.count,
                              isSecure: secure, createdAt: Date()))
    }

    /// FNV-1a — cheap content hash for image dedupe.
    private func fnv1aHex(_ data: Data) -> String {
        var h: UInt64 = 14695981039346656037
        for b in data { h ^= UInt64(b); h = h &* 1099511628211 }
        return String(format: "%016llx", h)
    }

    private func addItem(_ item: ClipboardItem) {
        // Dedupe: re-copying an existing item bumps it to the front.
        if let idx = items.firstIndex(where: { sameContent($0, item) }) {
            var existing = items.remove(at: idx)
            existing.createdAt = item.createdAt
            existing.isSecure = item.isSecure
            items.insert(existing, at: 0)
        } else {
            items.insert(item, at: 0)
            if items.count > config.maxItems {
                let removed = items.removeLast()
                if let name = removed.imageFileName {
                    try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(name))
                }
            }
        }
        save()
        onChange?()
    }

    private func sameContent(_ a: ClipboardItem, _ b: ClipboardItem) -> Bool {
        guard a.kind == b.kind else { return false }
        switch a.kind {
        case .text: return a.text == b.text
        case .image: return a.imageFileName == b.imageFileName
        }
    }

    // MARK: - Paste-back

    /// Write an item back to the pasteboard (the poller ignores its own write
    /// because lastChangeCount is updated synchronously here).
    func writeToPasteboard(_ item: ClipboardItem) {
        pasteboard.clearContents()
        switch item.kind {
        case .text:
            if let text = item.text { pasteboard.setString(text, forType: .string) }
        case .image:
            if let name = item.imageFileName,
               let img = NSImage(contentsOfFile: imagesDir.appendingPathComponent(name).path) {
                pasteboard.writeObjects([img])
            }
        }
        lastChangeCount = pasteboard.changeCount
    }

    func clear() {
        items.removeAll()
        try? FileManager.default.removeItem(at: imagesDir)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        save()
        onChange?()
    }

    // MARK: - Persistence (encrypted index, images on disk)

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Double(config.expiryDays) * 86400)
        let before = items.count
        items.removeAll { $0.createdAt < cutoff }
        guard items.count != before else { return }
        // Remove image files of expired items.
        let keep = Set(items.compactMap { $0.imageFileName })
        if let files = try? FileManager.default.contentsOfDirectory(at: imagesDir, includingPropertiesForKeys: nil) {
            for f in files where !keep.contains(f.lastPathComponent) {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        let payload = IndexCipher.seal(data) ?? data // fall back to plaintext only if keychain fails
        try? payload.write(to: indexURL, options: .atomic)
    }

    private func load() {
        guard let payload = try? Data(contentsOf: indexURL) else { return }
        // Accept encrypted payload; fall back to plaintext if the keychain was unavailable.
        let data = IndexCipher.open(payload) ?? payload
        items = (try? JSONDecoder().decode([ClipboardItem].self, from: data)) ?? []
    }
}

// MARK: - Encryption: AES-GCM with a key held in the macOS Keychain

enum IndexCipher {
    private static let service = "ClipboardHistory.IndexKey"

    private static func loadKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "index",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data {
            return SymmetricKey(data: data)
        }
        // Create a fresh 256-bit key and stash it in the keychain.
        let key = SymmetricKey(size: .bits256)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "index",
            kSecValueData as String: key.withUnsafeBytes { Data($0) },
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        return key
    }

    static func seal(_ data: Data) -> Data? {
        guard let key = loadKey() else { return nil }
        guard let box = try? AES.GCM.seal(data, using: key), let combined = box.combined else { return nil }
        return combined
    }

    static func open(_ payload: Data) -> Data? {
        guard let key = loadKey() else { return nil }
        guard let box = try? AES.GCM.SealedBox(combined: payload) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
}
