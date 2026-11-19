import Foundation
import RetroTermCore

/// A cursor position on the screen; `row` is absolute (scrollback included).
public struct ScreenCursor: Equatable {
    public var row: Int
    public var col: Int
    public init(row: Int, col: Int) { self.row = row; self.col = col }
}

/// What the console needs from the screen it edits on.
public protocol BasicScreen: AnyObject {
    var columns: Int { get }
    var cursor: ScreenCursor { get }
    /// Feeds raw terminal bytes.
    func write(_ text: String)
    /// Text of the logical line containing `row`, soft-wrapped rows rejoined, trailing blanks
    /// trimmed, plus the absolute row the logical line starts on.
    func logicalLine(at row: Int) -> (text: String, firstRow: Int)
}

/// A `BasicScreen` over a `Terminal`, every access taken under `lock` when one is given.
public final class TerminalScreen: BasicScreen {
    private let terminal: Terminal
    private let lock: NSLocking?

    public init(terminal: Terminal, lock: NSLocking?) {
        self.terminal = terminal
        self.lock = lock
    }

    private func locked<T>(_ body: (Terminal) -> T) -> T {
        lock?.lock(); defer { lock?.unlock() }
        return body(terminal)
    }

    public var columns: Int { locked { $0.cols } }

    public var cursor: ScreenCursor {
        locked { ScreenCursor(row: $0.scrollbackBase + $0.scrollback.count + $0.cursorY, col: $0.cursorX) }
    }

    public func write(_ text: String) { locked { $0.feed(text) } }

    public func logicalLine(at row: Int) -> (text: String, firstRow: Int) {
        locked { t in
            func line(_ index: Int) -> Line? {
                let i = index - t.scrollbackBase
                if i < 0 { return nil }
                if i < t.scrollback.count { return t.scrollback[i] }
                let s = i - t.scrollback.count
                return s < t.lines.count ? t.lines[s] : nil
            }
            var first = row, last = row
            while let prev = line(first - 1), prev.wrapped { first -= 1 }
            while let cur = line(last), cur.wrapped, line(last + 1) != nil { last += 1 }
            var text = ""
            for r in first...last {
                guard let l = line(r) else { break }
                text += l.text(trimTrailing: r == last)
            }
            return (text, first)
        }
    }
}

public enum DriveResult: Equatable {
    /// Nothing to do until the next key.
    case idle
    /// A program is running: call `drive` again soon.
    case moreWork
    /// BASIC asked to exit.
    case exited
}

/// The C64 screen editor on top of a `BasicMachine`: keys become cursor movement and typed
/// characters on the terminal, Return hands the row under the cursor to the machine.
public final class BasicConsole {
    private enum Mode {
        /// At READY, or at an INPUT prompt (`inputStart` = where the answer begins).
        case editing(inputStart: ScreenCursor?)
        case running
    }

    private let machine: BasicMachine
    private let screen: BasicScreen
    private var mode: Mode = .editing(inputStart: nil)

    public init(machine: BasicMachine, screen: BasicScreen) {
        self.machine = machine
        self.screen = screen
        machine.output = { [weak self] text in self?.screen.write(BasicConsole.vt(forPETSCII: text)) }
    }

    public func start() {
        machine.columns = screen.columns
        machine.powerOn()
        mode = .editing(inputStart: nil)
    }

    public func setColumns(_ n: Int) { machine.columns = n }

    /// Runs the machine for a while and updates the editing mode from its state.
    @discardableResult
    public func drive(budget: Int = 32) -> DriveResult {
        switch machine.step(budget: budget) {
        case .ready:
            mode = .editing(inputStart: nil)
            return .idle
        case .awaitingLine:
            if case .editing(.some) = mode {} else { mode = .editing(inputStart: screen.cursor) }
            return .idle
        case .running:
            mode = .running
            return .moreWork
        case .exit:
            return .exited
        }
    }

    /// One key event (or one chunk of bytes from the host).
    @discardableResult
    public func handleInput(_ bytes: [UInt8]) -> DriveResult {
        var result = DriveResult.idle
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            i += 1
            switch b {
            case 0x1B:
                let (action, consumed) = BasicConsole.escape(bytes, from: i)
                i += consumed
                if let a = action { result = merge(result, edit(a)) }
            case 0x0D:
                if i < bytes.count, bytes[i] == 0x0A { i += 1 }
                result = merge(result, returnKey())
            case 0x7F, 0x08:
                result = merge(result, edit(.backspace))
            case 0x03:
                result = merge(result, interrupt())
            case 0x20...0x7E:
                result = merge(result, type(Character(Unicode.Scalar(b))))
            default:
                break
            }
        }
        return result
    }

    /// Pasted text: printable characters as typed, line ends as Return, anything else dropped.
    @discardableResult
    public func paste(_ text: String) -> DriveResult {
        var result = DriveResult.idle
        for ch in text {   // "\r\n" is one Character in Swift, so isNewline covers every line end
            if ch.isNewline {
                result = merge(result, returnKey())
            } else if let a = ch.asciiValue, a >= 0x20, a <= 0x7E {
                result = merge(result, type(ch))
            }
        }
        return result
    }

    /// Machine output is PETSCII-flavoured text; the terminal wants VT sequences.
    public static func vt(forPETSCII text: String) -> String {
        var out = ""
        for ch in text {
            switch ch {
            case "\n": out += "\r\n"
            case "\u{93}": out += "\u{1b}[H\u{1b}[2J"
            case "\u{13}": out += "\u{1b}[H"
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - Keys

    private enum EditAction { case up, down, left, right, home, clear, backspace, delete }

    /// Decodes the escape sequence after ESC. Returns the action and how many bytes it used.
    private static func escape(_ bytes: [UInt8], from start: Int) -> (EditAction?, Int) {
        guard start < bytes.count else { return (nil, 0) }
        let rest = bytes[start...]
        let intro = rest.first!
        guard intro == 0x5B || intro == 0x4F else { return (nil, 0) }   // "[" or "O"
        var i = start + 1
        var params = ""
        while i < bytes.count, (0x30...0x3F).contains(bytes[i]) { params.append(Character(Unicode.Scalar(bytes[i]))); i += 1 }
        guard i < bytes.count else { return (nil, i - start) }
        let final = bytes[i]
        i += 1
        let consumed = i - start
        if params == "3", final == 0x7E { return (.delete, consumed) }
        if params == "1;2", final == 0x48 { return (.clear, consumed) }
        switch final {
        case 0x41: return (.up, consumed)
        case 0x42: return (.down, consumed)
        case 0x43: return (.right, consumed)
        case 0x44: return (.left, consumed)
        case 0x48: return (.home, consumed)
        default: return (nil, consumed)
        }
    }

    private func edit(_ action: EditAction) -> DriveResult {
        guard case .editing = mode else { return .idle }
        switch action {
        case .up: screen.write("\u{1b}[A")
        case .down: screen.write("\u{1b}[B")
        case .right: screen.write("\u{1b}[C")
        case .left: screen.write("\u{1b}[D")
        case .home: screen.write("\u{1b}[H")
        case .clear: screen.write("\u{1b}[H\u{1b}[2J")
        case .delete: screen.write("\u{1b}[P")
        case .backspace: if screen.cursor.col > 0 { screen.write("\u{8}\u{1b}[P") }
        }
        return .idle
    }

    private func type(_ ch: Character) -> DriveResult {
        guard case .editing = mode else { return .idle }
        screen.write(String(ch).uppercased())
        return .idle
    }

    private func returnKey() -> DriveResult {
        guard case .editing(let inputStart) = mode else { return .idle }
        let c = screen.cursor
        let (text, first) = screen.logicalLine(at: c.row)
        var line = text
        if let start = inputStart, start.row >= first, start.row <= c.row {
            let offset = (start.row - first) * screen.columns + start.col
            line = String(text.dropFirst(offset))
        }
        screen.write("\r\n")
        if inputStart != nil { machine.supplyLine(line) } else { machine.submitLine(line) }
        return drive()
    }

    private func interrupt() -> DriveResult {
        switch mode {
        case .editing(.none): return .idle
        case .editing(.some), .running:
            machine.interrupt()
            return drive()
        }
    }

    private func merge(_ a: DriveResult, _ b: DriveResult) -> DriveResult {
        if a == .exited || b == .exited { return .exited }
        if a == .moreWork || b == .moreWork { return .moreWork }
        return .idle
    }
}
