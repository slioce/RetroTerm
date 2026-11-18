import Foundation

public struct CellAttributes: OptionSet, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let bold          = CellAttributes(rawValue: 1 << 0)
    public static let dim           = CellAttributes(rawValue: 1 << 1)
    public static let italic        = CellAttributes(rawValue: 1 << 2)
    public static let underline     = CellAttributes(rawValue: 1 << 3)
    public static let blink         = CellAttributes(rawValue: 1 << 4)
    public static let inverse       = CellAttributes(rawValue: 1 << 5)
    public static let invisible     = CellAttributes(rawValue: 1 << 6)
    public static let strikethrough = CellAttributes(rawValue: 1 << 7)
    /// First half of a double-width character.
    public static let wide          = CellAttributes(rawValue: 1 << 8)
    /// Second half (placeholder) of a double-width character.
    public static let wideSpacer    = CellAttributes(rawValue: 1 << 9)

    public static let styleMask: CellAttributes = [.bold, .dim, .italic, .underline, .blink, .inverse, .invisible, .strikethrough]
}

public enum TermColor: Hashable {
    case `default`
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

public struct CellStyle: Hashable {
    public var fg: TermColor = .default
    public var bg: TermColor = .default
    public var attrs: CellAttributes = []
    public init() {}
    public init(fg: TermColor, bg: TermColor, attrs: CellAttributes) {
        self.fg = fg; self.bg = bg; self.attrs = attrs
    }
}

public struct Cell: Hashable {
    public var scalar: Unicode.Scalar
    /// Combining marks attached to `scalar`, if any.
    public var combining: String?
    public var style: CellStyle

    public init(scalar: Unicode.Scalar = " ", style: CellStyle = CellStyle()) {
        self.scalar = scalar
        self.combining = nil
        self.style = style
    }

    public static let blank = Cell()

    public var text: String {
        if let c = combining { return String(scalar) + c }
        return String(scalar)
    }
    public var isWide: Bool { style.attrs.contains(.wide) }
    public var isWideSpacer: Bool { style.attrs.contains(.wideSpacer) }
    /// True when the cell shows nothing (used for trimming when copying text).
    public var isTextBlank: Bool { scalar == " " && combining == nil || isWideSpacer }
}

public struct Line: Hashable {
    public var cells: [Cell]
    /// True when the line was soft-wrapped onto the next line (used when copying text).
    public var wrapped: Bool

    public init(cells: [Cell], wrapped: Bool = false) {
        self.cells = cells
        self.wrapped = wrapped
    }

    public init(cols: Int, fill: Cell = .blank) {
        self.cells = Array(repeating: fill, count: cols)
        self.wrapped = false
    }

    /// True when every cell is a blank space with default background.
    public var isEmpty: Bool {
        cells.allSatisfy { $0.scalar == " " && $0.combining == nil && $0.style.bg == .default }
    }

    /// The text of the line, trailing blanks trimmed.
    public func text(from: Int = 0, to: Int? = nil, trimTrailing: Bool = true) -> String {
        let end = min(to ?? cells.count, cells.count)
        guard from < end else { return "" }
        var s = ""
        var lastNonBlank = -1
        var parts: [String] = []
        for i in from..<end {
            let c = cells[i]
            if c.isWideSpacer { parts.append(""); continue }
            parts.append(c.text)
            if !c.isTextBlank { lastNonBlank = parts.count - 1 }
        }
        let upto = trimTrailing ? (lastNonBlank + 1) : parts.count
        for i in 0..<upto { s += parts[i] }
        return s
    }
}
