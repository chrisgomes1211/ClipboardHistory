import Foundation
import Cocoa

/// The Win+V experience: menu-bar icon, floating searchable panel, auto-paste.
/// Styled like a native macOS overlay — vibrancy material, SF Symbols,
/// system accent selection, hover feedback, light/dark adaptive.
final class PanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    private let store: ClipboardStore
    private let config: Config
    private let hotkey = Hotkey()

    // Layout
    private let panelW: CGFloat = 480
    private let panelH: CGFloat = 460
    private let margin: CGFloat = 16
    private let rowH: CGFloat = 40

    private let panel: FloatingPanel
    private let effectView = NSVisualEffectView()
    private let searchField = NSSearchField()
    private let sectionLabel = NSTextField(labelWithString: "HISTORY")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyBox = NSView()
    private let emptyIcon = NSImageView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "⏎ Paste     ↑↓ Navigate     Esc Close")

    private var filtered: [ClipboardItem] = []
    private var statusItem: NSStatusItem?
    private var keyMonitor: Any?
    private var pauseMenuItem: NSMenuItem?
    private let colID = NSUserInterfaceItemIdentifier("clip")

    // MARK: - Init

    init(store: ClipboardStore, config: Config) {
        self.store = store
        self.config = config

        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: panelW, height: panelH),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear   // required for rounded corners + real shadow
        panel.hasShadow = true

        buildPanelUI()
        buildStatusItem()
        installKeyMonitor()

        store.onChange = { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.refilter(keepingSelection: true)
        }

        hotkey.onPressed = { [weak self] in self?.togglePanel() }
        if !hotkey.register(combo: config.hotkey) {
            NSLog("ClipboardHistory: hotkey registration failed; menu-bar icon still works")
        }
    }

    // MARK: - Panel construction

    private func buildPanelUI() {
        // Native vibrancy material — adapts automatically to light/dark mode.
        effectView.frame = NSRect(x: 0, y: 0, width: panelW, height: panelH)
        effectView.autoresizingMask = [.width, .height]
        effectView.material = .popover
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 18          // System-Settings-style radius
        effectView.layer?.masksToBounds = true       // REQUIRED: cornerRadius alone doesn't clip
        effectView.layer?.borderWidth = 1
        effectView.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = effectView

        let innerW = panelW - margin * 2

        // Spotlight-style search field
        searchField.placeholderString = "Search clipboard history…"
        searchField.font = .systemFont(ofSize: 14)
        searchField.focusRingType = .none
        searchField.frame = NSRect(x: margin, y: panelH - margin - 32, width: innerW, height: 32)
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.delegate = self
        effectView.addSubview(searchField)

        // Section header
        sectionLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        sectionLabel.textColor = .secondaryLabelColor
        sectionLabel.frame = NSRect(x: margin + 4, y: searchField.frame.minY - 24,
                                    width: innerW, height: 14)
        effectView.addSubview(sectionLabel)

        // Table
        let col = NSTableColumn(identifier: colID)
        col.width = innerW
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowHeight = rowH
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.style = .fullWidth
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(doubleClicked(_:))
        tableView.target = self

        let footerH: CGFloat = 18
        let tableY = margin + footerH + 6
        let tableH = sectionLabel.frame.minY - 8 - tableY

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.frame = NSRect(x: margin, y: tableY, width: innerW, height: tableH)
        effectView.addSubview(scrollView)

        // Footer key hints — like native macOS overlays
        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.alignment = .center
        footerLabel.frame = NSRect(x: margin, y: margin - 6, width: innerW, height: footerH)
        effectView.addSubview(footerLabel)

        // Empty state: SF Symbol + caption, centered
        emptyBox.frame = scrollView.frame
        emptyBox.autoresizingMask = [.width, .height]
        emptyBox.isHidden = true

        emptyIcon.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: nil)
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .light)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyIcon.imageScaling = .scaleProportionallyUpOrDown
        let iconSize: CGFloat = 56
        emptyIcon.frame = NSRect(x: (innerW - iconSize) / 2,
                                 y: (scrollView.frame.height - iconSize - 10 - 18) / 2 + 28,
                                 width: iconSize, height: iconSize)
        emptyIcon.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        emptyBox.addSubview(emptyIcon)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.frame = NSRect(x: 0, y: emptyIcon.frame.minY - 10 - 18,
                                  width: innerW, height: 18)
        emptyLabel.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        emptyBox.addSubview(emptyLabel)

        effectView.addSubview(emptyBox)
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "clipboard",
                                     accessibilityDescription: "Clipboard History")
        item.button?.toolTip = "Clipboard History"

        let menu = NSMenu()
        let open = NSMenuItem(title: "Open (\(Self.displayHotkey(config.hotkey)))",
                              action: #selector(toggleFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        pauseMenuItem = NSMenuItem(title: "Pause Capture", action: #selector(togglePause), keyEquivalent: "")
        pauseMenuItem?.target = self
        menu.addItem(pauseMenuItem!)

        let clear = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())

        let ax = NSMenuItem(title: "Accessibility Settings…", action: #selector(openAX), keyEquivalent: "")
        ax.target = self
        menu.addItem(ax)

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, self.panel.isVisible else { return ev }
            switch ev.keyCode {
            case 125: self.moveSelection(1);  return nil   // ↓
            case 126: self.moveSelection(-1); return nil   // ↑
            case 36, 76: self.pasteSelected(); return nil  // ⏎
            case 53: self.closePanel(); return nil          // esc
            default: return ev
            }
        }
    }

    // MARK: - Show / hide

    func togglePanel() {
        panel.isVisible ? closePanel() : openPanel()
    }

    @objc private func toggleFromMenu() { togglePanel() }

    func openPanel() {
        refilter(keepingSelection: false)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let x = f.midX - panelW / 2
            let y = f.maxY - panelH - f.height * 0.22   // upper third, Spotlight-style
            panel.setFrame(NSRect(x: x, y: y, width: panelW, height: panelH), display: true)
        }
        searchField.stringValue = ""
        refilter(keepingSelection: false)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        if !Paster.isTrusted { Paster.ensureTrusted(interactive: false) } // gentle nudge, no dialog
    }

    func closePanel() {
        panel.orderOut(nil)
    }

    // MARK: - Data

    private func refilter(keepingSelection: Bool) {
        let selectedID = keepingSelection ? selectedIDFromTable() : nil
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        filtered = query.isEmpty ? store.items : store.items.filter { item in
            guard item.kind == .text, let t = item.text else { return query.contains("image") }
            return t.lowercased().contains(query)
        }
        tableView.reloadData()
        refreshLabelColors()

        let empty = filtered.isEmpty
        emptyBox.isHidden = !empty
        emptyLabel.stringValue = query.isEmpty ? "Copy something to get started"
                                               : "No matches for “\(searchField.stringValue)”"
        sectionLabel.stringValue = query.isEmpty ? "HISTORY"
            : "RESULTS · \(filtered.count)"

        if let id = selectedID, let row = filtered.firstIndex(where: { $0.id == id }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if !empty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        refreshLabelColors()
    }

    private func selectedIDFromTable() -> String? {
        let row = tableView.selectedRow
        guard row >= 0 && row < filtered.count else { return nil }
        return filtered[row].id
    }

    @objc private func searchChanged(_ sender: NSTextField) { refilter(keepingSelection: false) }

    // Live filtering as the user types
    func controlTextDidChange(_ obj: Notification) { refilter(keepingSelection: false) }

    /// Selection changes: swap label colors to white on the accent-blue row.
    func tableViewSelectionDidChange(_ notification: Notification) { refreshLabelColors() }

    private func refreshLabelColors() {
        for row in 0..<filtered.count {
            guard let rv = tableView.rowView(atRow: row, makeIfNecessary: false) else { continue }
            let selected = rv.isSelected
            for cell in rv.subviews {
                if let cv = cell as? NSTableCellView {
                    cv.textField?.textColor = selected ? .white : .labelColor
                }
                for case let tf as NSTextField in cell.subviews where tf.tag == 999 {
                    tf.textColor = selected ? NSColor.white.withAlphaComponent(0.7)
                                            : .secondaryLabelColor
                }
            }
        }
    }

    // MARK: - Actions

    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let current = max(0, tableView.selectedRow)
        let next = min(max(0, current + delta), filtered.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    @objc private func doubleClicked(_ sender: NSTableView) { pasteSelected() }

    private func pasteSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < filtered.count else { return }
        let item = filtered[row]

        let trusted = Paster.ensureTrusted(interactive: true)
        store.writeToPasteboard(item)
        closePanel()

        if trusted {
            // Let focus return to the previous app, then send a real ⌘V.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                Paster.simulateCommandV()
            }
        }
    }

    @objc private func togglePause() {
        store.paused.toggle()
        pauseMenuItem?.title = store.paused ? "Resume Capture" : "Pause Capture"
    }

    @objc private func clearHistory() {
        store.clear()
        refilter(keepingSelection: false)
    }

    @objc private func openAX() { Paster.openAccessibilitySettings() }

    @objc private func quit() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        NSApp.terminate(nil)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rv = ClipRowView()
        rv.isLastRow = row == filtered.count - 1
        return rv
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filtered.count else { return nil }
        let item = filtered[row]
        let rowW = panelW - margin * 2

        let cell = NSTableCellView()

        // Thumbnail for images
        let leadingX: CGFloat
        if item.kind == .image, let name = item.imageFileName {
            let img = NSImage(contentsOfFile: Config.directory
                .appendingPathComponent("images").appendingPathComponent(name).path)
            let iv = NSImageView(frame: NSRect(x: 8, y: 6, width: 28, height: 28))
            iv.image = img
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.wantsLayer = true
            iv.layer?.cornerRadius = 4
            cell.addSubview(iv)
            leadingX = 44
        } else {
            leadingX = 12
        }

        // Date (right side, tagged so selection styling can find it)
        let dateLabel = NSTextField(labelWithString: Self.dateFormatter.string(from: item.createdAt))
        dateLabel.font = .systemFont(ofSize: 11)
        dateLabel.textColor = .secondaryLabelColor
        dateLabel.alignment = .right
        dateLabel.tag = 999
        let dateW: CGFloat = 76
        dateLabel.frame = NSRect(x: rowW - dateW - 10, y: 12, width: dateW, height: 16)
        cell.addSubview(dateLabel)

        // Main label
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: leadingX, y: 11,
                             width: dateLabel.frame.minX - 8 - leadingX, height: 18)

        var text: String
        if item.kind == .image {
            let kb = (item.byteCount ?? 0) / 1024
            text = "Image · \(item.width ?? 0)×\(item.height ?? 0) · \(kb) KB"
        } else {
            text = (item.text ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
        }
        if item.isSecure { text = "🔒 " + text }
        label.stringValue = String(text.prefix(120))
        cell.addSubview(label)

        cell.textField = label
        return cell
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(Date()) ? "HH:mm" : "MMM d, HH:mm"
        return f
    }()

    private static func displayHotkey(_ combo: String) -> String {
        combo.split(whereSeparator: { $0 == "+" || $0 == "-" }).map { part in
            switch part {
            case "option", "alt", "opt": return "⌥"
            case "command", "cmd": return "⌘"
            case "control", "ctrl": return "⌃"
            case "shift": return "⇧"
            default: return part.uppercased()
            }
        }.joined()
    }
}

// MARK: - Row view with hover feedback and accent selection

final class ClipRowView: NSTableRowView {
    private var hovered = false
    private var trackArea: NSTrackingArea?
    var isLastRow = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = trackArea { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: bounds,
                              options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                              owner: self, userInfo: nil)
        addTrackingArea(a)
        trackArea = a
    }

    override func mouseEntered(with event: NSEvent) {
        if !isSelected { hovered = true; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false; needsDisplay = true
    }

    override func drawBackground(in rect: NSRect) {
        if isSelected {
            NSColor.controlAccentColor.setFill()
            bounds.fill()
        } else if hovered {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            bounds.fill()
        }
    }

    /// Inset hairline between rows — the Settings-list look.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if !isSelected && !isLastRow && bounds.height > 1 {
            let sep = NSRect(x: 12, y: 0, width: bounds.width - 24, height: 1 / (window?.backingScaleFactor ?? 2))
            NSColor.separatorColor.withAlphaComponent(0.7).setFill()
            sep.fill()
        }
    }
}

/// Borderless panel that can become key (so the search field accepts typing)
/// while remaining non-activating (focus stays with your previous app).
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
