import AppKit
import Carbon
import AudioPilotCore

/// Human-readable hotkey strings (US layout names for key codes).
enum KeyNames {
    static let keys: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
        13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
        35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
        47: ".", 50: "`", 36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20", 123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘",
        116: "⇞", 121: "⇟",
    ]

    static func string(_ spec: HotKeySpec) -> String {
        var s = ""
        if spec.modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if spec.modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if spec.modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if spec.modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + (keys[spec.keyCode] ?? "Key\(spec.keyCode)")
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    static func describe(_ status: OSStatus) -> String {
        switch status {
        case noErr: ""
        case OSStatus(eventHotKeyExistsErr): "That shortcut is already used by another app."
        case OSStatus(eventHotKeyInvalidErr), -9868: "macOS doesn't allow this shortcut. Include ⌘ or ⌃."
        default: "Couldn't register shortcut (error \(status))."
        }
    }
}
