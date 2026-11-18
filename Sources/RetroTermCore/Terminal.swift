import Foundation

public enum MouseMode { case none, x10, normal, buttonEvent, anyEvent }
public enum MouseEncoding { case x10, utf8, sgr, urxvt }
public enum Charset { case ascii, decSpecial, uk }

/// xterm-compatible terminal emulator state. Not thread safe: callers serialise access.
public final class Terminal {
    public private(set) var cols: Int
    public private(set) var rows: Int

    /// Rows of the active screen (primary or alternate).
    public private(set) var lines: [Line]
    /// Lines that scrolled off the top of the primary screen (oldest first).
    public private(set) var scrollback: [Line] = []
    /// Number of lines trimmed from the front of `scrollback` since start; keeps absolute line numbers stable.
    public private(set) var scrollbackBase: Int = 0
    public var maxScrollback: Int = 10_000

    public private(set) var cursorX = 0
    public private(set) var cursorY = 0
    private var pendingWrap = false
    public private(set) var style = CellStyle()

    public private(set) var scrollTop = 0
    public private(set) var scrollBottom: Int

    // Modes
    public private(set) var applicationCursorKeys = false
    public private(set) var applicationKeypad = false
    public private(set) var originMode = false
    public private(set) var autoWrap = true
    public private(set) var insertMode = false
    public private(set) var lineFeedMode = false
    public private(set) var cursorVisible = true
    /// DECSET 12 overrides the application's blink preference when set.
    public private(set) var cursorBlinkOverride: Bool? = nil
    public private(set) var bracketedPaste = false
    public private(set) var mouseMode: MouseMode = .none
    public private(set) var mouseEncoding: MouseEncoding = .x10
    public private(set) var focusEvents = false
    public private(set) var altScreen = false
    public private(set) var alternateScroll = true
    /// DECSCUSR value: 0/1 blinking block, 2 steady block, 3/4 underline, 5/6 bar.
    public private(set) var cursorStyle = 0
    public private(set) var reverseVideo = false

    public private(set) var title = ""
    public private(set) var iconTitle = ""
    public private(set) var cwd: String?
    private var titleStack: [String] = []

    private var tabStops = Set<Int>()
    private var charsets: [Charset] = [.ascii, .ascii, .ascii, .ascii]
    private var activeCharset = 0
    private var singleShift: Int? = nil

    private struct SavedCursor {
        var x = 0, y = 0
        var style = CellStyle()
        var originMode = false
        var pendingWrap = false
        var charsets: [Charset] = [.ascii, .ascii, .ascii, .ascii]
        var activeCharset = 0
    }
    private var savedCursor = SavedCursor()
    private var savedCursorAlt = SavedCursor()
    private var primaryLines: [Line]? = nil

    /// Incremented whenever the terminal content or state may have changed.
    public private(set) var generation: UInt64 = 0

    // Callbacks
    public var output: (([UInt8]) -> Void)?
    public var onBell: (() -> Void)?
    public var onTitleChange: ((String) -> Void)?
    public var onClipboard: ((String) -> Void)?
    public var onCursorStyleChange: (() -> Void)?

    private var parser: VTParser!

    public init(cols: Int, rows: Int) {
        let c = max(1, cols), r = max(1, rows)
        self.cols = c
        self.rows = r
        self.lines = (0..<r).map { _ in Line(cols: c) }
        self.scrollBottom = r - 1
        resetTabStops()
        parser = VTParser(delegate: self)
    }

    // MARK: - Input

    public func feed(_ bytes: UnsafeBufferPointer<UInt8>) {
        parser.feed(bytes)
        generation &+= 1
    }

    public func feed(_ bytes: [UInt8]) {
        parser.feed(bytes)
        generation &+= 1
    }

    public func feed(_ string: String) {
        parser.feed(string)
        generation &+= 1
    }

    public func markDirty() { generation &+= 1 }

    // MARK: - Public operations

    public func clearScrollback() {
        scrollbackBase += scrollback.count
        scrollback.removeAll()
        generation &+= 1
    }

    /// Clears the visible screen and the scrollback (like Cmd+K).
    public func clearAll() {
        clearScrollback()
        for y in 0..<rows { lines[y] = blankLine() }
        cursorY = 0
        pendingWrap = false
        generation &+= 1
    }

    public func resize(cols newCols: Int, rows newRows: Int) {
        let newCols = max(2, newCols)
        let newRows = max(1, newRows)
        guard newCols != cols || newRows != rows else { return }

        // Columns: pad / truncate each line of the active screen (and the saved primary screen).
        func fitCols(_ ls: inout [Line]) {
            for i in ls.indices {
                if ls[i].cells.count < newCols {
                    ls[i].cells.append(contentsOf: Array(repeating: Cell.blank, count: newCols - ls[i].cells.count))
                } else if ls[i].cells.count > newCols {
                    ls[i].cells.removeSubrange(newCols...)
                    if ls[i].cells.last?.isWide == true { ls[i].cells[newCols - 1] = .blank }
                }
            }
        }
        fitCols(&lines)
        if primaryLines != nil { fitCols(&primaryLines!) }

        // Rows.
        func fitRows(_ ls: inout [Line], cursorY: inout Int, useScrollback: Bool) {
            let current = ls.count
            if newRows < current {
                var toRemove = current - newRows
                // Drop empty lines below the cursor first.
                while toRemove > 0, ls.count - 1 > cursorY, ls[ls.count - 1].isEmpty {
                    ls.removeLast(); toRemove -= 1
                }
                if toRemove > 0 {
                    let moved = Array(ls[0..<toRemove])
                    ls.removeSubrange(0..<toRemove)
                    if useScrollback { pushScrollback(moved) }
                    cursorY = max(0, cursorY - toRemove)
                }
            } else if newRows > current {
                var toAdd = newRows - current
                if useScrollback {
                    while toAdd > 0, let last = scrollback.popLast() {
                        var l = last
                        if l.cells.count < newCols {
                            l.cells.append(contentsOf: Array(repeating: Cell.blank, count: newCols - l.cells.count))
                        } else if l.cells.count > newCols {
                            l.cells.removeSubrange(newCols...)
                        }
                        ls.insert(l, at: 0)
                        cursorY += 1
                        toAdd -= 1
                    }
                }
                while toAdd > 0 { ls.append(Line(cols: newCols)); toAdd -= 1 }
            }
        }

        if altScreen {
            var dummy = savedCursor.y
            fitRows(&primaryLines!, cursorY: &dummy, useScrollback: true)
            savedCursor.y = dummy
            var cy = cursorY
            fitRows(&lines, cursorY: &cy, useScrollback: false)
            cursorY = cy
        } else {
            var cy = cursorY
            fitRows(&lines, cursorY: &cy, useScrollback: true)
            cursorY = cy
        }

        cols = newCols
        rows = newRows
        scrollTop = 0
        scrollBottom = rows - 1
        cursorX = min(cursorX, cols - 1)
        cursorY = min(cursorY, rows - 1)
        savedCursor.x = min(savedCursor.x, cols - 1)
        savedCursor.y = min(savedCursor.y, rows - 1)
        savedCursorAlt.x = min(savedCursorAlt.x, cols - 1)
        savedCursorAlt.y = min(savedCursorAlt.y, rows - 1)
        pendingWrap = false
        generation &+= 1
    }

    /// Full reset (RIS).
    public func hardReset() {
        softReset()
        if altScreen { leaveAltScreen() }
        for y in 0..<rows { lines[y] = Line(cols: cols) }
        cursorX = 0; cursorY = 0
        pendingWrap = false
        title = ""; iconTitle = ""
        onTitleChange?(title)
        generation &+= 1
    }

    /// DECSTR soft reset.
    public func softReset() {
        applicationCursorKeys = false
        applicationKeypad = false
        originMode = false
        autoWrap = true
        insertMode = false
        lineFeedMode = false
        cursorVisible = true
        bracketedPaste = false
        mouseMode = .none
        mouseEncoding = .x10
        focusEvents = false
        reverseVideo = false
        cursorStyle = 0
        cursorBlinkOverride = nil
        scrollTop = 0
        scrollBottom = rows - 1
        style = CellStyle()
        charsets = [.ascii, .ascii, .ascii, .ascii]
        activeCharset = 0
        singleShift = nil
        savedCursor = SavedCursor()
        savedCursorAlt = SavedCursor()
        resetTabStops()
        onCursorStyleChange?()
        generation &+= 1
    }

    // MARK: - Helpers

    private func resetTabStops() {
        tabStops.removeAll()
        var i = 8
        while i < 1024 { tabStops.insert(i); i += 8 }
    }

    private func blankCell() -> Cell {
        var c = Cell()
        c.style.bg = style.bg
        return c
    }

    private func blankLine() -> Line {
        Line(cols: cols, fill: blankCell())
    }

    private func pushScrollback(_ newLines: [Line]) {
        scrollback.append(contentsOf: newLines)
        if scrollback.count > maxScrollback + 512 {
            let drop = scrollback.count - maxScrollback
            scrollback.removeFirst(drop)
            scrollbackBase += drop
        }
    }

    private func send(_ s: String) {
        output?(Array(s.utf8))
    }

    private func clampCursor() {
        cursorX = max(0, min(cursorX, cols - 1))
        cursorY = max(0, min(cursorY, rows - 1))
    }

    private var effectiveTop: Int { originMode ? scrollTop : 0 }
    private var effectiveBottom: Int { originMode ? scrollBottom : rows - 1 }

    private func moveCursor(x: Int, y: Int) {
        cursorX = max(0, min(x, cols - 1))
        cursorY = max(effectiveTop, min(y, effectiveBottom))
        pendingWrap = false
    }

    // MARK: - Cell writing

    private func putCell(_ cell: Cell, x: Int, y: Int) {
        guard x >= 0, x < cols, y >= 0, y < rows else { return }
        var line = lines[y]
        // Clear overlapped wide characters.
        let existing = line.cells[x]
        if existing.isWideSpacer, x > 0 {
            line.cells[x - 1] = Cell(scalar: " ", style: strip(line.cells[x - 1].style))
        }
        if existing.isWide, x + 1 < cols {
            line.cells[x + 1] = Cell(scalar: " ", style: strip(line.cells[x + 1].style))
        }
        line.cells[x] = cell
        lines[y] = line
    }

    private func strip(_ s: CellStyle) -> CellStyle {
        var r = s
        r.attrs.remove([.wide, .wideSpacer])
        return r
    }

    private func translate(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        let set: Charset
        if let ss = singleShift {
            set = charsets[ss]
            singleShift = nil
        } else {
            set = charsets[activeCharset]
        }
        switch set {
        case .ascii:
            return scalar
        case .uk:
            return scalar == "#" ? "£" : scalar
        case .decSpecial:
            return Terminal.decSpecialGraphics[scalar] ?? scalar
        }
    }

    private static let decSpecialGraphics: [Unicode.Scalar: Unicode.Scalar] = [
        "`": "◆", "a": "▒", "b": "␉", "c": "␌", "d": "␍", "e": "␊", "f": "°", "g": "±",
        "h": "␤", "i": "␋", "j": "┘", "k": "┐", "l": "┌", "m": "└", "n": "┼", "o": "⎺",
        "p": "⎻", "q": "─", "r": "⎼", "s": "⎽", "t": "├", "u": "┤", "v": "┴", "w": "┬",
        "x": "│", "y": "≤", "z": "≥", "{": "π", "|": "≠", "}": "£", "~": "·",
    ]

    private func printScalar(_ raw: Unicode.Scalar) {
        let scalar = translate(raw)
        let width = CharWidth.width(scalar)

        if width == 0 {
            // Combining mark: attach to previous cell.
            var x = pendingWrap ? cols - 1 : cursorX - 1
            if x < 0 { return }
            if lines[cursorY].cells[x].isWideSpacer { x -= 1 }
            if x < 0 { return }
            var c = lines[cursorY].cells[x]
            c.combining = (c.combining ?? "") + String(scalar)
            lines[cursorY].cells[x] = c
            return
        }

        if pendingWrap {
            pendingWrap = false
            if autoWrap {
                lines[cursorY].wrapped = true
                cursorX = 0
                lineFeed()
            } else {
                cursorX = cols - 1
            }
        }

        if width == 2 && cursorX == cols - 1 {
            // Wide char does not fit at the end of the line.
            if autoWrap {
                putCell(blankCell(), x: cursorX, y: cursorY)
                lines[cursorY].wrapped = true
                cursorX = 0
                lineFeed()
            } else {
                cursorX = max(0, cols - 2)
            }
        }

        if insertMode {
            var line = lines[cursorY]
            for _ in 0..<width {
                line.cells.insert(blankCell(), at: cursorX)
                line.cells.removeLast()
            }
            lines[cursorY] = line
        }

        var cell = Cell(scalar: scalar, style: style)
        cell.style.attrs.remove([.wide, .wideSpacer])
        if width == 2 {
            cell.style.attrs.insert(.wide)
            putCell(cell, x: cursorX, y: cursorY)
            var spacer = Cell(scalar: " ", style: style)
            spacer.style.attrs.remove(.wide)
            spacer.style.attrs.insert(.wideSpacer)
            putCell(spacer, x: cursorX + 1, y: cursorY)
        } else {
            putCell(cell, x: cursorX, y: cursorY)
        }

        cursorX += width
        if cursorX >= cols {
            cursorX = cols - 1
            pendingWrap = true
        }
    }

    // MARK: - Scrolling

    private func scrollUp(_ n: Int, top: Int? = nil, bottom: Int? = nil) {
        let t = top ?? scrollTop
        let b = bottom ?? scrollBottom
        guard b >= t else { return }
        let n = min(n, b - t + 1)
        guard n > 0 else { return }
        if t == 0 && !altScreen && top == nil {
            pushScrollback(Array(lines[0..<n]))
        }
        lines.removeSubrange(t..<(t + n))
        for _ in 0..<n { lines.insert(blankLine(), at: b - n + 1) }
    }

    private func scrollDown(_ n: Int, top: Int? = nil, bottom: Int? = nil) {
        let t = top ?? scrollTop
        let b = bottom ?? scrollBottom
        guard b >= t else { return }
        let n = min(n, b - t + 1)
        guard n > 0 else { return }
        lines.removeSubrange((b - n + 1)...b)
        for _ in 0..<n { lines.insert(blankLine(), at: t) }
    }

    private func lineFeed() {
        if cursorY == scrollBottom {
            scrollUp(1)
        } else if cursorY < rows - 1 {
            cursorY += 1
        }
    }

    private func reverseIndex() {
        if cursorY == scrollTop {
            scrollDown(1)
        } else if cursorY > 0 {
            cursorY -= 1
        }
    }

    // MARK: - Erase

    private func eraseLine(_ y: Int, from: Int, to: Int) {
        guard y >= 0, y < rows else { return }
        let lo = max(0, from), hi = min(cols, to)
        guard lo < hi else { return }
        var line = lines[y]
        if lo > 0, line.cells[lo].isWideSpacer { line.cells[lo - 1] = blankCell() }
        if hi < cols, line.cells[hi].isWideSpacer { line.cells[hi] = blankCell() }
        for x in lo..<hi { line.cells[x] = blankCell() }
        if hi == cols { line.wrapped = false }
        lines[y] = line
    }

    // MARK: - Alternate screen

    private func enterAltScreen() {
        guard !altScreen else { return }
        primaryLines = lines
        lines = (0..<rows).map { _ in blankLine() }
        altScreen = true
    }

    private func leaveAltScreen() {
        guard altScreen else { return }
        if let p = primaryLines { lines = p }
        primaryLines = nil
        altScreen = false
    }

    private func saveCursor() {
        var s = SavedCursor()
        s.x = cursorX; s.y = cursorY; s.style = style
        s.originMode = originMode; s.pendingWrap = pendingWrap
        s.charsets = charsets; s.activeCharset = activeCharset
        if altScreen { savedCursorAlt = s } else { savedCursor = s }
    }

    private func restoreCursor() {
        let s = altScreen ? savedCursorAlt : savedCursor
        cursorX = min(s.x, cols - 1); cursorY = min(s.y, rows - 1)
        style = s.style
        originMode = s.originMode
        pendingWrap = s.pendingWrap && cursorX == cols - 1
        charsets = s.charsets; activeCharset = s.activeCharset
    }
}

// MARK: - Parser delegate

extension Terminal: VTParserDelegate {
    public func parserPrint(_ scalar: Unicode.Scalar) {
        printScalar(scalar)
    }

    public func parserExecute(_ byte: UInt8) {
        switch byte {
        case 0x07:
            onBell?()
        case 0x08:
            if cursorX > 0 { cursorX -= 1 }
            pendingWrap = false
        case 0x09:
            tabForward(1)
        case 0x0A, 0x0B, 0x0C:
            lineFeed()
            if lineFeedMode { cursorX = 0 }
            pendingWrap = false
        case 0x0D:
            cursorX = 0
            pendingWrap = false
        case 0x0E:
            activeCharset = 1
        case 0x0F:
            activeCharset = 0
        default:
            break
        }
    }

    private func tabForward(_ n: Int) {
        var x = cursorX
        for _ in 0..<n {
            if let next = tabStops.filter({ $0 > x }).min() { x = min(next, cols - 1) } else { x = cols - 1 }
        }
        cursorX = x
        pendingWrap = false
    }

    private func tabBackward(_ n: Int) {
        var x = cursorX
        for _ in 0..<n {
            if let prev = tabStops.filter({ $0 < x }).max() { x = prev } else { x = 0 }
        }
        cursorX = x
        pendingWrap = false
    }

    public func parserESC(intermediates: [UInt8], final: UInt8) {
        if intermediates.isEmpty {
            switch final {
            case 0x37: saveCursor()                                  // 7 DECSC
            case 0x38: restoreCursor()                               // 8 DECRC
            case 0x44: lineFeed(); pendingWrap = false               // D IND
            case 0x45: cursorX = 0; lineFeed(); pendingWrap = false  // E NEL
            case 0x48: tabStops.insert(cursorX)                      // H HTS
            case 0x4D: reverseIndex(); pendingWrap = false           // M RI
            case 0x4E: singleShift = 2                               // N SS2
            case 0x4F: singleShift = 3                               // O SS3
            case 0x63: hardReset()                                   // c RIS
            case 0x3D: applicationKeypad = true                      // = DECKPAM
            case 0x3E: applicationKeypad = false                     // > DECKPNM
            case 0x6E: activeCharset = 2                             // n LS2
            case 0x6F: activeCharset = 3                             // o LS3
            default: break
            }
            return
        }
        switch intermediates[0] {
        case 0x28, 0x29, 0x2A, 0x2B: // ( ) * +  designate G0..G3
            let slot = Int(intermediates[0] - 0x28)
            switch final {
            case 0x30: charsets[slot] = .decSpecial
            case 0x41: charsets[slot] = .uk
            default: charsets[slot] = .ascii
            }
        case 0x23: // #
            if final == 0x38 { // DECALN
                var c = Cell(scalar: "E")
                c.style = CellStyle()
                for y in 0..<rows { lines[y] = Line(cols: cols, fill: c) }
                cursorX = 0; cursorY = 0
                scrollTop = 0; scrollBottom = rows - 1
                pendingWrap = false
            }
        default:
            break
        }
    }

    public func parserDCS(params: [[Int]], intermediates: [UInt8], final: UInt8, data: [UInt8]) {
        // DCS $ q <name> ST  (DECRQSS) — answer "invalid" for everything we do not support.
        if intermediates == [0x24] && final == 0x71 {
            send("\u{1b}P0$r\u{1b}\\")
        }
    }

    public func parserOSC(_ string: String) {
        guard let semi = string.firstIndex(of: ";") else {
            return
        }
        let code = Int(string[string.startIndex..<semi]) ?? -1
        let arg = String(string[string.index(after: semi)...])
        switch code {
        case 0:
            title = arg; iconTitle = arg
            onTitleChange?(title)
        case 1:
            iconTitle = arg
        case 2:
            title = arg
            onTitleChange?(title)
        case 7:
            // file://host/path
            if let url = URL(string: arg), url.scheme == "file" {
                cwd = url.path.removingPercentEncoding ?? url.path
            } else if arg.hasPrefix("/") {
                cwd = arg
            }
        case 10, 11:
            if arg == "?" {
                // Report a plausible colour so colour-probing apps do not misbehave.
                let rgb = code == 10 ? "3333/ffff/5555" : "0505/1111/0808"
                send("\u{1b}]\(code);rgb:\(rgb)\u{1b}\\")
            }
        case 4:
            // 4;idx;? palette query
            let parts = arg.split(separator: ";", omittingEmptySubsequences: false)
            if parts.count >= 2, parts[1] == "?", let idx = Int(parts[0]) {
                let (r, g, b) = Palette.xterm256(idx)
                send("\u{1b}]4;\(idx);rgb:\(String(format: "%02x%02x/%02x%02x/%02x%02x", r, r, g, g, b, b))\u{1b}\\")
            }
        case 52:
            // 52;c;base64
            let parts = arg.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, parts[1] != "?", let data = Data(base64Encoded: String(parts[1])),
               let s = String(data: data, encoding: .utf8) {
                onClipboard?(s)
            }
        default:
            break
        }
    }

    public func parserCSI(params: [[Int]], intermediates: [UInt8], final: UInt8) {
        func param(_ i: Int, _ def: Int = 0) -> Int {
            guard i < params.count, let v = params[i].first else { return def }
            return v == 0 ? def : v
        }
        func rawParam(_ i: Int) -> Int {
            guard i < params.count, let v = params[i].first else { return 0 }
            return v
        }

        let priv = intermediates.first.flatMap { (0x3C...0x3F).contains($0) ? $0 : nil }
        let inter = intermediates.filter { !(0x3C...0x3F).contains($0) }

        if let priv = priv {
            switch (priv, final) {
            case (0x3F, 0x68): for p in params { setMode(p.first ?? 0, enabled: true, private: true) }   // ?h
            case (0x3F, 0x6C): for p in params { setMode(p.first ?? 0, enabled: false, private: true) }  // ?l
            case (0x3F, 0x4A): eraseInDisplay(param(0))                                                   // ?J
            case (0x3F, 0x4B): eraseInLineCmd(param(0))                                                   // ?K
            case (0x3F, 0x6E): // ?n DSR
                if param(0) == 6 {
                    let y = originMode ? cursorY - scrollTop + 1 : cursorY + 1
                    send("\u{1b}[?\(y);\(cursorX + 1)R")
                }
            case (0x3F, 0x70) where inter == [0x24]: // ? Ps $ p  DECRQM
                let mode = rawParam(0)
                send("\u{1b}[?\(mode);\(modeState(mode))$y")
            case (0x3E, 0x63): // >c  DA2
                send("\u{1b}[>1;10;0c")
            case (0x3D, 0x63): // =c  DA3
                send("\u{1b}P!|00000000\u{1b}\\")
            case (0x3F, 0x73): break // XTSAVE private modes: ignore
            case (0x3F, 0x72): break // XTRESTORE
            case (0x3E, 0x6D): break // XTMODKEYS
            case (0x3E, 0x71): // >q XTVERSION
                send("\u{1b}P>|RetroTerm 1.0\u{1b}\\")
            case (0x3F, 0x75): // ?u kitty keyboard query — report flags 0
                send("\u{1b}[?0u")
            default: break
            }
            return
        }

        if !inter.isEmpty {
            switch (inter[0], final) {
            case (0x20, 0x71): // SP q  DECSCUSR
                cursorStyle = rawParam(0)
                onCursorStyleChange?()
            case (0x21, 0x70): // ! p  DECSTR
                softReset()
            case (0x24, 0x70): // $ p DECRQM (ANSI)
                let mode = rawParam(0)
                let state: Int
                switch mode {
                case 4: state = insertMode ? 1 : 2
                case 20: state = lineFeedMode ? 1 : 2
                default: state = 0
                }
                send("\u{1b}[\(mode);\(state)$y")
            case (0x22, 0x70): break // " p DECSCL
            case (0x20, 0x74), (0x20, 0x75): break
            default: break
            }
            return
        }

        switch final {
        case 0x40: insertChars(param(0, 1))                                   // @ ICH
        case 0x41: cursorUp(param(0, 1))                                      // A CUU
        case 0x42: cursorDown(param(0, 1))                                    // B CUD
        case 0x43: cursorX = min(cols - 1, cursorX + param(0, 1)); pendingWrap = false   // C CUF
        case 0x44: cursorX = max(0, cursorX - param(0, 1)); pendingWrap = false          // D CUB
        case 0x45: cursorDown(param(0, 1)); cursorX = 0                       // E CNL
        case 0x46: cursorUp(param(0, 1)); cursorX = 0                         // F CPL
        case 0x47, 0x60: cursorX = max(0, min(cols - 1, param(0, 1) - 1)); pendingWrap = false  // G CHA, ` HPA
        case 0x48, 0x66: // H CUP, f HVP
            moveCursor(x: param(1, 1) - 1, y: effectiveTop + param(0, 1) - 1)
        case 0x49: tabForward(param(0, 1))                                    // I CHT
        case 0x4A: eraseInDisplay(param(0))                                   // J ED
        case 0x4B: eraseInLineCmd(param(0))                                   // K EL
        case 0x4C: insertLines(param(0, 1))                                   // L IL
        case 0x4D: deleteLines(param(0, 1))                                   // M DL
        case 0x50: deleteChars(param(0, 1))                                   // P DCH
        case 0x53: scrollUp(param(0, 1))                                      // S SU
        case 0x54: scrollDown(param(0, 1))                                    // T SD
        case 0x58: eraseLine(cursorY, from: cursorX, to: cursorX + param(0, 1)); pendingWrap = false  // X ECH
        case 0x5A: tabBackward(param(0, 1))                                   // Z CBT
        case 0x61: cursorX = min(cols - 1, cursorX + param(0, 1)); pendingWrap = false   // a HPR
        case 0x62: // b REP
            if let last = lastPrinted {
                for _ in 0..<min(param(0, 1), cols * rows) { printScalar(last) }
            }
        case 0x63: send("\u{1b}[?62;22c")                                     // c DA
        case 0x64: moveCursor(x: cursorX, y: effectiveTop + param(0, 1) - 1)  // d VPA
        case 0x65: cursorDown(param(0, 1))                                    // e VPR
        case 0x67: // g TBC
            switch rawParam(0) {
            case 0: tabStops.remove(cursorX)
            case 3: tabStops.removeAll()
            default: break
            }
        case 0x68: for p in params { setMode(p.first ?? 0, enabled: true, private: false) }   // h SM
        case 0x6C: for p in params { setMode(p.first ?? 0, enabled: false, private: false) }  // l RM
        case 0x6D: applySGR(params)                                           // m SGR
        case 0x6E: // n DSR
            switch rawParam(0) {
            case 5: send("\u{1b}[0n")
            case 6:
                let y = originMode ? cursorY - scrollTop + 1 : cursorY + 1
                send("\u{1b}[\(y);\(cursorX + 1)R")
            default: break
            }
        case 0x72: // r DECSTBM
            let top = param(0, 1) - 1
            let bottom = param(1, rows) - 1
            if top < bottom && bottom < rows {
                scrollTop = top
                scrollBottom = bottom
                moveCursor(x: 0, y: effectiveTop)
            }
        case 0x73: saveCursor()                                               // s SCOSC
        case 0x75: restoreCursor()                                            // u SCORC
        case 0x74: // t XTWINOPS
            switch rawParam(0) {
            case 14: send("\u{1b}[4;\(rows * 16);\(cols * 8)t")
            case 16: send("\u{1b}[6;16;8t")
            case 18: send("\u{1b}[8;\(rows);\(cols)t")
            case 19: send("\u{1b}[9;\(rows);\(cols)t")
            case 21: send("\u{1b}]l\(title)\u{1b}\\")
            case 22: titleStack.append(title); if titleStack.count > 10 { titleStack.removeFirst() }
            case 23: if let t = titleStack.popLast() { title = t; onTitleChange?(title) }
            default: break
            }
        default:
            break
        }
    }

    private var lastPrinted: Unicode.Scalar? {
        let x = pendingWrap ? cols - 1 : cursorX - 1
        guard x >= 0 else { return nil }
        let c = lines[cursorY].cells[x]
        return c.isWideSpacer ? nil : c.scalar
    }

    private func cursorUp(_ n: Int) {
        let limit = cursorY >= scrollTop ? scrollTop : 0
        cursorY = max(limit, cursorY - n)
        pendingWrap = false
    }

    private func cursorDown(_ n: Int) {
        let limit = cursorY <= scrollBottom ? scrollBottom : rows - 1
        cursorY = min(limit, cursorY + n)
        pendingWrap = false
    }

    private func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseLine(cursorY, from: cursorX, to: cols)
            for y in (cursorY + 1)..<max(cursorY + 1, rows) { lines[y] = blankLine() }
        case 1:
            eraseLine(cursorY, from: 0, to: cursorX + 1)
            for y in 0..<cursorY { lines[y] = blankLine() }
        case 2:
            for y in 0..<rows { lines[y] = blankLine() }
        case 3:
            clearScrollback()
        default:
            break
        }
        pendingWrap = false
    }

    private func eraseInLineCmd(_ mode: Int) {
        switch mode {
        case 0: eraseLine(cursorY, from: cursorX, to: cols)
        case 1: eraseLine(cursorY, from: 0, to: cursorX + 1)
        case 2: eraseLine(cursorY, from: 0, to: cols)
        default: break
        }
        pendingWrap = false
    }

    private func insertLines(_ n: Int) {
        guard cursorY >= scrollTop, cursorY <= scrollBottom else { return }
        scrollDown(n, top: cursorY, bottom: scrollBottom)
        cursorX = 0
        pendingWrap = false
    }

    private func deleteLines(_ n: Int) {
        guard cursorY >= scrollTop, cursorY <= scrollBottom else { return }
        scrollUp(n, top: cursorY, bottom: scrollBottom)
        cursorX = 0
        pendingWrap = false
    }

    private func insertChars(_ n: Int) {
        var line = lines[cursorY]
        let n = min(n, cols - cursorX)
        if line.cells[cursorX].isWideSpacer, cursorX > 0 { line.cells[cursorX - 1] = blankCell() }
        for _ in 0..<n {
            line.cells.insert(blankCell(), at: cursorX)
            line.cells.removeLast()
        }
        if line.cells[cols - 1].isWide { line.cells[cols - 1] = blankCell() }
        lines[cursorY] = line
        pendingWrap = false
    }

    private func deleteChars(_ n: Int) {
        var line = lines[cursorY]
        let n = min(n, cols - cursorX)
        if line.cells[cursorX].isWideSpacer, cursorX > 0 { line.cells[cursorX - 1] = blankCell() }
        line.cells.removeSubrange(cursorX..<(cursorX + n))
        for _ in 0..<n { line.cells.append(blankCell()) }
        if line.cells[cursorX].isWideSpacer { line.cells[cursorX] = blankCell() }
        lines[cursorY] = line
        pendingWrap = false
    }

    private func modeState(_ mode: Int) -> Int {
        switch mode {
        case 1: return applicationCursorKeys ? 1 : 2
        case 6: return originMode ? 1 : 2
        case 7: return autoWrap ? 1 : 2
        case 12: return (cursorBlinkOverride ?? true) ? 1 : 2
        case 25: return cursorVisible ? 1 : 2
        case 47, 1047, 1049: return altScreen ? 1 : 2
        case 1000: return mouseMode == .normal ? 1 : 2
        case 1002: return mouseMode == .buttonEvent ? 1 : 2
        case 1003: return mouseMode == .anyEvent ? 1 : 2
        case 1004: return focusEvents ? 1 : 2
        case 1006: return mouseEncoding == .sgr ? 1 : 2
        case 1007: return alternateScroll ? 1 : 2
        case 2004: return bracketedPaste ? 1 : 2
        default: return 0
        }
    }

    private func setMode(_ mode: Int, enabled: Bool, private isPrivate: Bool) {
        if !isPrivate {
            switch mode {
            case 4: insertMode = enabled
            case 20: lineFeedMode = enabled
            default: break
            }
            return
        }
        switch mode {
        case 1: applicationCursorKeys = enabled
        case 3: // DECCOLM: clear screen & home, keep width
            for y in 0..<rows { lines[y] = blankLine() }
            moveCursor(x: 0, y: 0)
            scrollTop = 0; scrollBottom = rows - 1
        case 5: reverseVideo = enabled
        case 6:
            originMode = enabled
            moveCursor(x: 0, y: effectiveTop)
        case 7: autoWrap = enabled
        case 12: cursorBlinkOverride = enabled; onCursorStyleChange?()
        case 25: cursorVisible = enabled
        case 47, 1047:
            if enabled { enterAltScreen() } else {
                if altScreen && mode == 1047 { for y in 0..<rows { lines[y] = blankLine() } }
                leaveAltScreen()
            }
        case 1048:
            if enabled { saveCursor() } else { restoreCursor() }
        case 1049:
            if enabled {
                saveCursor()
                enterAltScreen()
                // cursor position carries over per xterm; many apps home it anyway
            } else {
                leaveAltScreen()
                restoreCursor()
            }
        case 9: mouseMode = enabled ? .x10 : .none
        case 1000: mouseMode = enabled ? .normal : .none
        case 1002: mouseMode = enabled ? .buttonEvent : .none
        case 1003: mouseMode = enabled ? .anyEvent : .none
        case 1004: focusEvents = enabled
        case 1005: mouseEncoding = enabled ? .utf8 : .x10
        case 1006: mouseEncoding = enabled ? .sgr : .x10
        case 1015: mouseEncoding = enabled ? .urxvt : .x10
        case 1007: alternateScroll = enabled
        case 66: applicationKeypad = enabled
        case 2004: bracketedPaste = enabled
        default: break
        }
    }

    private func applySGR(_ params: [[Int]]) {
        if params.isEmpty {
            style.fg = .default; style.bg = .default
            style.attrs.subtract(.styleMask)
            return
        }
        var i = 0
        // Flatten into a stream so "38;5;n" and "38:5:n" both work.
        while i < params.count {
            let group = params[i]
            let p = group.first ?? 0
            switch p {
            case 0:
                style.fg = .default; style.bg = .default
                style.attrs.subtract(.styleMask)
            case 1: style.attrs.insert(.bold)
            case 2: style.attrs.insert(.dim)
            case 3: style.attrs.insert(.italic)
            case 4:
                if group.count > 1, group[1] == 0 { style.attrs.remove(.underline) } else { style.attrs.insert(.underline) }
            case 5, 6: style.attrs.insert(.blink)
            case 7: style.attrs.insert(.inverse)
            case 8: style.attrs.insert(.invisible)
            case 9: style.attrs.insert(.strikethrough)
            case 21: style.attrs.insert(.underline)
            case 22: style.attrs.remove([.bold, .dim])
            case 23: style.attrs.remove(.italic)
            case 24: style.attrs.remove(.underline)
            case 25: style.attrs.remove(.blink)
            case 27: style.attrs.remove(.inverse)
            case 28: style.attrs.remove(.invisible)
            case 29: style.attrs.remove(.strikethrough)
            case 30...37: style.fg = .indexed(UInt8(p - 30))
            case 39: style.fg = .default
            case 40...47: style.bg = .indexed(UInt8(p - 40))
            case 49: style.bg = .default
            case 90...97: style.fg = .indexed(UInt8(p - 90 + 8))
            case 100...107: style.bg = .indexed(UInt8(p - 100 + 8))
            case 38, 48, 58:
                var color: TermColor? = nil
                if group.count > 1 {
                    // colon form: 38:5:n or 38:2:[cs:]r:g:b
                    if group[1] == 5, group.count >= 3 {
                        color = .indexed(UInt8(clamping: group[2]))
                    } else if group[1] == 2 {
                        if group.count >= 6 {
                            color = .rgb(UInt8(clamping: group[3]), UInt8(clamping: group[4]), UInt8(clamping: group[5]))
                        } else if group.count >= 5 {
                            color = .rgb(UInt8(clamping: group[2]), UInt8(clamping: group[3]), UInt8(clamping: group[4]))
                        }
                    }
                } else if i + 1 < params.count {
                    let kind = params[i + 1].first ?? 0
                    if kind == 5, i + 2 < params.count {
                        color = .indexed(UInt8(clamping: params[i + 2].first ?? 0))
                        i += 2
                    } else if kind == 2, i + 4 < params.count {
                        color = .rgb(UInt8(clamping: params[i + 2].first ?? 0),
                                     UInt8(clamping: params[i + 3].first ?? 0),
                                     UInt8(clamping: params[i + 4].first ?? 0))
                        i += 4
                    } else {
                        i += 1
                    }
                }
                if let c = color {
                    if p == 38 { style.fg = c } else if p == 48 { style.bg = c }
                }
            case 59: break
            default: break
            }
            i += 1
        }
    }
}

// MARK: - Palette

public enum Palette {
    /// Standard xterm 16-colour palette.
    public static let ansi16: [(UInt8, UInt8, UInt8)] = [
        (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0), (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
        (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0), (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
    ]

    public static func xterm256(_ index: Int) -> (UInt8, UInt8, UInt8) {
        let i = max(0, min(255, index))
        if i < 16 { return ansi16[i] }
        if i < 232 {
            let n = i - 16
            let r = n / 36, g = (n / 6) % 6, b = n % 6
            let steps: [UInt8] = [0, 95, 135, 175, 215, 255]
            return (steps[r], steps[g], steps[b])
        }
        let v = UInt8(8 + (i - 232) * 10)
        return (v, v, v)
    }
}
