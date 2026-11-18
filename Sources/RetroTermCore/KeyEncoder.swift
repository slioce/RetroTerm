import Foundation

public struct KeyModifiers: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift   = KeyModifiers(rawValue: 1)
    public static let option  = KeyModifiers(rawValue: 2)
    public static let control = KeyModifiers(rawValue: 4)
    public static let command = KeyModifiers(rawValue: 8)

    /// xterm modifier parameter (1 = none).
    var xtermParam: Int {
        var v = 1
        if contains(.shift) { v += 1 }
        if contains(.option) { v += 2 }
        if contains(.control) { v += 4 }
        return v
    }
}

/// Translates macOS key events into the byte sequences a VT/xterm terminal expects.
public enum KeyEncoder {
    public struct Options {
        public var applicationCursorKeys = false
        public var applicationKeypad = false
        public var lineFeedMode = false
        public var optionAsMeta = true
        public init() {}
    }

    // macOS virtual key codes
    public enum Code {
        public static let returnKey: UInt16 = 36
        public static let tab: UInt16 = 48
        public static let delete: UInt16 = 51
        public static let escape: UInt16 = 53
        public static let keypadEnter: UInt16 = 76
        public static let forwardDelete: UInt16 = 117
        public static let home: UInt16 = 115
        public static let end: UInt16 = 119
        public static let pageUp: UInt16 = 116
        public static let pageDown: UInt16 = 121
        public static let left: UInt16 = 123
        public static let right: UInt16 = 124
        public static let down: UInt16 = 125
        public static let up: UInt16 = 126
        public static let help: UInt16 = 114
        public static let f1: UInt16 = 122, f2: UInt16 = 120, f3: UInt16 = 99, f4: UInt16 = 118
        public static let f5: UInt16 = 96, f6: UInt16 = 97, f7: UInt16 = 98, f8: UInt16 = 100
        public static let f9: UInt16 = 101, f10: UInt16 = 109, f11: UInt16 = 103, f12: UInt16 = 111
        public static let f13: UInt16 = 105, f14: UInt16 = 107, f15: UInt16 = 113, f16: UInt16 = 106
        public static let f17: UInt16 = 64, f18: UInt16 = 79, f19: UInt16 = 80, f20: UInt16 = 90
    }

    private static let keypadApp: [UInt16: String] = [
        65: "n", 67: "j", 69: "k", 75: "o", 78: "m", 81: "X",
        82: "p", 83: "q", 84: "r", 85: "s", 86: "t", 87: "u", 88: "v", 89: "w", 91: "x", 92: "y",
    ]

    /// Returns the bytes for a key press, or nil when the event should go through
    /// the normal text input path (insertText).
    public static func encode(keyCode: UInt16,
                              characters: String,
                              charactersIgnoringModifiers: String,
                              modifiers: KeyModifiers,
                              options: Options) -> [UInt8]? {
        let mods = modifiers
        if mods.contains(.command) { return nil }
        let esc: UInt8 = 0x1B
        let modParam = mods.xtermParam
        let app = options.applicationCursorKeys

        func cursor(_ letter: String) -> [UInt8] {
            if modParam == 1 {
                return Array(((app ? "\u{1b}O" : "\u{1b}[") + letter).utf8)
            }
            return Array("\u{1b}[1;\(modParam)\(letter)".utf8)
        }
        func tilde(_ n: Int) -> [UInt8] {
            if modParam == 1 { return Array("\u{1b}[\(n)~".utf8) }
            return Array("\u{1b}[\(n);\(modParam)~".utf8)
        }
        func fkey(_ letter: String) -> [UInt8] {
            if modParam == 1 { return Array("\u{1b}O\(letter)".utf8) }
            return Array("\u{1b}[1;\(modParam)\(letter)".utf8)
        }

        switch keyCode {
        case Code.up: return cursor("A")
        case Code.down: return cursor("B")
        case Code.right: return cursor("C")
        case Code.left: return cursor("D")
        case Code.home: return cursor("H")
        case Code.end: return cursor("F")
        case Code.pageUp: return tilde(5)
        case Code.pageDown: return tilde(6)
        case Code.forwardDelete: return tilde(3)
        case Code.help: return tilde(2)
        case Code.f1: return fkey("P")
        case Code.f2: return fkey("Q")
        case Code.f3: return fkey("R")
        case Code.f4: return fkey("S")
        case Code.f5: return tilde(15)
        case Code.f6: return tilde(17)
        case Code.f7: return tilde(18)
        case Code.f8: return tilde(19)
        case Code.f9: return tilde(20)
        case Code.f10: return tilde(21)
        case Code.f11: return tilde(23)
        case Code.f12: return tilde(24)
        case Code.f13: return tilde(25)
        case Code.f14: return tilde(26)
        case Code.f15: return tilde(28)
        case Code.f16: return tilde(29)
        case Code.f17: return tilde(31)
        case Code.f18: return tilde(32)
        case Code.f19: return tilde(33)
        case Code.f20: return tilde(34)
        case Code.escape:
            return mods.contains(.option) && options.optionAsMeta ? [esc, esc] : [esc]
        case Code.returnKey, Code.keypadEnter:
            if keyCode == Code.keypadEnter && options.applicationKeypad && modParam == 1 {
                return Array("\u{1b}OM".utf8)
            }
            var out: [UInt8] = options.lineFeedMode ? [0x0D, 0x0A] : [0x0D]
            if mods.contains(.option) && options.optionAsMeta { out.insert(esc, at: 0) }
            return out
        case Code.tab:
            if mods.contains(.shift) { return Array("\u{1b}[Z".utf8) }
            var out: [UInt8] = [0x09]
            if mods.contains(.option) && options.optionAsMeta { out.insert(esc, at: 0) }
            return out
        case Code.delete:
            var out: [UInt8] = mods.contains(.control) ? [0x08] : [0x7F]
            if mods.contains(.option) && options.optionAsMeta { out.insert(esc, at: 0) }
            return out
        default:
            break
        }

        if options.applicationKeypad, modParam == 1, let k = keypadApp[keyCode] {
            return Array("\u{1b}O\(k)".utf8)
        }

        if mods.contains(.control) {
            guard let ch = charactersIgnoringModifiers.unicodeScalars.first else { return nil }
            var byte: UInt8? = nil
            let v = ch.value
            switch v {
            case 0x61...0x7A: byte = UInt8(v - 0x60)         // a-z
            case 0x41...0x5A: byte = UInt8(v - 0x40)         // A-Z
            case 0x40, 0x20, 0x32: byte = 0x00               // @ space 2
            case 0x5B, 0x33: byte = 0x1B                     // [ 3
            case 0x5C, 0x34: byte = 0x1C                     // \ 4
            case 0x5D, 0x35: byte = 0x1D                     // ] 5
            case 0x5E, 0x36: byte = 0x1E                     // ^ 6
            case 0x5F, 0x2D, 0x37, 0x2F: byte = 0x1F         // _ - 7 /
            case 0x3F, 0x38: byte = 0x7F                     // ? 8
            default: break
            }
            if let b = byte {
                if mods.contains(.option) && options.optionAsMeta { return [esc, b] }
                return [b]
            }
            return nil
        }

        if mods.contains(.option) && options.optionAsMeta {
            // Meta: ESC + the unmodified character.
            let base = charactersIgnoringModifiers
            guard !base.isEmpty else { return nil }
            return [esc] + Array(base.utf8)
        }

        return nil
    }
}

/// Builds xterm mouse report sequences.
public enum MouseEncoder {
    public enum Button: Int { case left = 0, middle = 1, right = 2, none = 3, wheelUp = 64, wheelDown = 65 }

    public static func encode(button: Button, pressed: Bool, motion: Bool, x: Int, y: Int,
                              modifiers: KeyModifiers, encoding: MouseEncoding) -> [UInt8] {
        var code = button.rawValue
        if modifiers.contains(.shift) { code += 4 }
        if modifiers.contains(.option) { code += 8 }
        if modifiers.contains(.control) { code += 16 }
        if motion { code += 32 }

        switch encoding {
        case .sgr:
            return Array("\u{1b}[<\(code);\(x + 1);\(y + 1)\(pressed ? "M" : "m")".utf8)
        case .urxvt:
            let c = pressed ? code : (button.rawValue >= 64 ? code : (code & ~3) | 3)
            return Array("\u{1b}[\(c + 32);\(x + 1);\(y + 1)M".utf8)
        case .utf8, .x10:
            var c = code
            if !pressed && button.rawValue < 64 { c = (code & ~3) | 3 }
            var out: [UInt8] = [0x1B, 0x5B, 0x4D, UInt8(clamping: c + 32)]
            func coord(_ v: Int) -> [UInt8] {
                let n = v + 1 + 32
                if encoding == .utf8 && n >= 128 && n < 2048 {
                    return [UInt8(0xC0 | (n >> 6)), UInt8(0x80 | (n & 0x3F))]
                }
                return [UInt8(clamping: min(n, 255))]
            }
            out += coord(x)
            out += coord(y)
            return out
        }
    }
}
