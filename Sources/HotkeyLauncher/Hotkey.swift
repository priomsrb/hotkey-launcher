import Foundation
import CoreGraphics
import Carbon

/// Represents a hotkey configuration mapping a key combination to an application
struct Hotkey: Codable, Equatable, Identifiable {
    var id: String { bundleId }
    
    /// The key character (e.g., "t", "s", "f")
    let key: String
    
    /// Modifier keys (e.g., ["cmd"], ["cmd", "shift"], ["opt"])
    let modifiers: [String]
    
    /// Bundle identifier of the target application (e.g., "com.apple.Terminal")
    let bundleId: String
    
    /// Convert modifier strings to CGEventFlags
    var cgEventFlags: CGEventFlags {
        var flags = CGEventFlags()
        for modifier in modifiers {
            switch modifier.lowercased() {
            case "cmd", "command":
                flags.insert(.maskCommand)
            case "opt", "option", "alt":
                flags.insert(.maskAlternate)
            case "ctrl", "control":
                flags.insert(.maskControl)
            case "shift":
                flags.insert(.maskShift)
            default:
                break
            }
        }
        return flags
    }
    
    /// Convert modifier strings to Carbon modifier flags (for RegisterEventHotKey)
    var carbonModifiers: UInt32 {
        var mods: UInt32 = 0
        for modifier in modifiers {
            switch modifier.lowercased() {
            case "cmd", "command":
                mods |= UInt32(cmdKey)
            case "opt", "option", "alt":
                mods |= UInt32(optionKey)
            case "ctrl", "control":
                mods |= UInt32(controlKey)
            case "shift":
                mods |= UInt32(shiftKey)
            default:
                break
            }
        }
        return mods
    }

    /// Get the key code for the key character
    var keyCode: UInt16? {
        return Hotkey.keyCodeMap[key.lowercased()]
    }
    
    /// Human-readable display string (e.g., "⌘T")
    var displayString: String {
        var result = ""
        for modifier in modifiers {
            switch modifier.lowercased() {
            case "cmd", "command": result += "⌘"
            case "opt", "option", "alt": result += "⌥"
            case "ctrl", "control": result += "⌃"
            case "shift": result += "⇧"
            default: break
            }
        }
        result += key.uppercased()
        return result
    }
    
    /// Map of key characters to key codes
    private static let keyCodeMap: [String: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04,
        "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09,
        "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F,
        "y": 0x10, "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14,
        "4": 0x15, "6": 0x16, "5": 0x17, "7": 0x1A, "8": 0x1C,
        "9": 0x19, "0": 0x1D, "o": 0x1F, "u": 0x20, "i": 0x22,
        "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D,
        "m": 0x2E, "space": 0x31, "escape": 0x35, "`": 0x32, "-": 0x1B, "=": 0x18,
        "[": 0x21, "]": 0x1E, "\\": 0x2A, ";": 0x29, "'": 0x27,
        ",": 0x2B, ".": 0x2F, "/": 0x2C
    ]
}

/// Configuration wrapper for JSON encoding/decoding
struct HotkeyConfig: Codable {
    var hotkeys: [Hotkey]
    var exceptions: [String]
    
    enum CodingKeys: String, CodingKey {
        case hotkeys
        case exceptions
    }
    
    init(hotkeys: [Hotkey], exceptions: [String]) {
        self.hotkeys = hotkeys
        self.exceptions = exceptions
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hotkeys = try container.decode([Hotkey].self, forKey: .hotkeys)
        exceptions = try container.decodeIfPresent([String].self, forKey: .exceptions) ?? []
    }
}
