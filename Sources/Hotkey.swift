import Foundation
import Carbon
import Cocoa

/// Global hotkey via Carbon RegisterEventHotKey — works in any app.
/// Configured from config.json ("option+v", "command+shift+v", …).
final class Hotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onPressed: (() -> Void)?

    private static let hotKeyHandler: EventHandlerUPP = { _, event, userData in
        guard let event = event, let userData = userData else { return noErr }
        let hotkey = Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue()
        var hkID = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject),
                          EventParamType(typeEventHotKeyID), nil,
                          MemoryLayout<EventHotKeyID>.size, nil, &hkID)
        if hkID.id == 1 {
            DispatchQueue.main.async { hotkey.onPressed?() }
        }
        return noErr
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = handlerRef { RemoveEventHandler(ref) }
    }

    /// Returns false if the combo string can't be parsed or registration fails.
    func register(combo: String) -> Bool {
        guard let spec = Self.parse(combo) else {
            NSLog("ClipboardHistory: invalid hotkey '%@' in config.json", combo)
            return false
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), Self.hotKeyHandler, 1,
                            &eventType, userData, &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x434C4856 /* 'CLHV' */), id: 1)
        let status = RegisterEventHotKey(spec.keyCode, spec.modifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            NSLog("ClipboardHistory: RegisterEventHotKey failed (%d) for '%@'", status, combo)
            return false
        }
        return true
    }

    struct Spec { var keyCode: UInt32; var modifiers: UInt32 }

    static func parse(_ combo: String) -> Spec? {
        var modifiers: UInt32 = 0
        var key: String?
        for part in combo.lowercased().split(whereSeparator: { $0 == "+" || $0 == "-" }) {
            switch part {
            case "option", "alt", "opt":  modifiers |= UInt32(optionKey)
            case "command", "cmd":       modifiers |= UInt32(cmdKey)
            case "control", "ctrl":      modifiers |= UInt32(controlKey)
            case "shift":                modifiers |= UInt32(shiftKey)
            default:                     key = String(part)
            }
        }
        guard let key, let keyCode = Self.keyCodes[key] else { return nil }
        return Spec(keyCode: keyCode, modifiers: modifiers)
    }

    private static let keyCodes: [String: UInt32] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12,
        "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "9": 0x19,
        "7": 0x1A, "8": 0x1C, "0": 0x1D, "o": 0x1F, "u": 0x20, "i": 0x22,
        "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E
    ]
}
