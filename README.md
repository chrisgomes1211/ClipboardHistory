# ClipboardHistory — Win+V for your Mac 🍎

A free-for-lifetime clipboard history manager for macOS. Menu-bar app, no
subscriptions, no telemetry, 100% local, source in this folder.

## Features

- **⌥V anywhere** — searchable clipboard history panel (change the key in config)
- **Text + images** — screenshots and copied pictures, with thumbnails
- **Auto-paste** — pick an item and it's pasted into the app you were using
- **Password-manager copies included** — flagged with 🔒 so you always know
- **Encrypted at rest** — history index is AES-256-GCM encrypted, key in your
  macOS Keychain (if someone copies the file off your disk, it's useless)
- **Auto-expires** — items deleted after 7 days (default), max 100 items
- **Dedupe** — re-copying an item bumps it to the top instead of duplicating
- **Pause / clear** from the menu-bar icon

## Install

```sh
./build.sh --install
```

Builds the app, copies it to `~/Applications`, and registers a LaunchAgent so
it starts at login. Look for the 📋 icon in the menu bar.

## First run — Accessibility permission

Auto-paste needs Accessibility permission (macOS requirement — no way to skip):

1. Press ⌥V, pick an item → macOS shows a prompt → **Open System Settings**
2. Toggle **ClipboardHistory** ON under *Privacy & Security → Accessibility*
3. ⌥V again → Enter → it now pastes directly into your app

Without the permission it still *copies* (you press ⌘V yourself) — it never
silently fails.

## Usage

| Key | Action |
|---|---|
| `⌥V` | Open / close history panel |
| `↑ ↓` | Navigate items |
| `⏎` | Paste selected item into frontmost app |
| Double-click | Same as ⏎ |
| `Esc` | Close panel |
| Type | Live search |

Menu-bar icon: pause/resume capture, clear history, Accessibility settings, quit.

## Customize

Edit `~/Library/Application Support/ClipboardHistory/config.json`, relaunch:

```json
{
  "hotkey": "option+v",   // any combo: "command+shift+v", "control+v"…
  "maxItems": 100,
  "expiryDays": 7
}
```

## Files on disk

```
~/Library/Application Support/ClipboardHistory/
├── config.json     // your settings
├── index.enc       // history index — AES-GCM encrypted (key in Keychain)
└── images/         // image clips, content-hashed filenames
```

## Uninstall

```sh
launchctl bootout gui/$(id -u)/com.chrisgomes.clipboardhistory
rm ~/Library/LaunchAgents/com.chrisgomes.clipboardhistory.plist
rm -rf ~/Applications/ClipboardHistory.app
rm -rf ~/Library/Application\ Support/ClipboardHistory
```

## Notes

- ⌥V normally types `√` — registering the hotkey consumes it. Not a fan?
  Change `hotkey` in config.json (e.g. `command+shift+v`).
- Built with plain `swiftc` — no Xcode project, no dependencies, no cost.
