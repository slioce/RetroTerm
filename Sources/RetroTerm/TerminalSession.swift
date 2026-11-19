import AppKit
import Combine
import RetroTermCore
import CPTY

/// One shell + emulator + view. Lives as long as its tab.
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title: String = "Terminal"
    @Published var isAlive = true

    let terminal: Terminal
    let lock = NSLock()
    private(set) var pty: PseudoTerminal?
    private let readQueue = DispatchQueue(label: "RetroTerm.session.read", qos: .userInteractive)
    private(set) lazy var view: TerminalNSView = TerminalNSView(session: self)
    var onExit: ((TerminalSession) -> Void)?
    private let defaultTitle: String

    // Boot banner typed out character by character; shell output arriving meanwhile is held back.
    // Both fields are guarded by `lock`.
    private var bannerTyping = false
    private var heldOutput: [UInt8] = []
    private static let heldOutputCap = 1 << 20

    // The BASIC easter egg: typing "basic" at the prompt in the C64 theme. `basicActive` is
    // guarded by `lock` (read on the PTY queue); `basic` and `typedLine` are main-thread only.
    private var basicActive = false
    private(set) var basic: BasicHost?
    private var typedLine: [UInt8] = []
    /// Roughly 400 baud (40 characters per second): the pace of a serial terminal booting. 1200 baud felt rushed.
    private static let bannerCharDelay: TimeInterval = 1.0 / 40

    init(workingDirectory: String?) {
        let config = AppSettings.shared.config
        terminal = Terminal(cols: 80, rows: 24)
        terminal.maxScrollback = max(100, config.scrollbackLines)

        let shell = config.shellPath.isEmpty ? PseudoTerminal.defaultShell() : config.shellPath
        defaultTitle = (shell as NSString).lastPathComponent
        title = defaultTitle

        terminal.output = { [weak self] bytes in self?.pty?.write(bytes) }
        terminal.onTitleChange = { [weak self] t in
            DispatchQueue.main.async { self?.title = t.isEmpty ? (self?.defaultTitle ?? "Terminal") : t }
        }
        terminal.onBell = { [weak self] in
            DispatchQueue.main.async { self?.view.ringBell() }
        }
        terminal.onClipboard = { s in
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s, forType: .string)
            }
        }
        terminal.onCursorStyleChange = { [weak self] in
            DispatchQueue.main.async { self?.view.needsRender = true }
        }

        if config.showBootBanner, !config.bootBannerText.isEmpty {
            typeBanner(config.bootBannerText)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cwd = workingDirectory ?? home
        let argv0 = "-" + (shell as NSString).lastPathComponent  // login shell convention
        do {
            pty = try PseudoTerminal(executable: shell, arguments: [argv0], environment: PseudoTerminal.shellEnvironment(),
                                     workingDirectory: cwd, cols: 80, rows: 24)
        } catch {
            terminal.feed("\r\n  Failed to start \(shell): \(error)\r\n")
            isAlive = false
            return
        }

        pty?.startReading(queue: readQueue, onData: { [weak self] buf in
            guard let self = self else { return }
            self.lock.lock()
            if self.bannerTyping || self.basicActive {
                // The shell waits for the banner to finish, or for BASIC to exit.
                self.heldOutput.append(contentsOf: buf)
                if self.heldOutput.count > TerminalSession.heldOutputCap {
                    self.heldOutput.removeFirst(self.heldOutput.count - TerminalSession.heldOutputCap)
                }
            } else {
                self.terminal.feed(buf)
            }
            self.lock.unlock()
        }, onExit: { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isAlive = false
                self.basic?.stop()
                self.basic = nil
                self.lock.lock()
                self.basicActive = false
                self.terminal.feed("\r\n\u{1b}[0m[process exited" + (status.map { " with status \($0 >> 8)" } ?? "") + "]\r\n")
                self.lock.unlock()
                self.onExit?(self)
            }
        })
    }

    deinit {
        pty?.terminate()
    }

    // MARK: - Boot banner

    /// Feeds the banner one character at a time on the read queue, pausing a little longer at line ends like a
    /// carriage return would. PTY output is queued until the last character is on screen.
    private func typeBanner(_ text: String) {
        var tokens: [String] = []
        for ch in text.replacingOccurrences(of: "\r\n", with: "\n") {
            tokens.append(ch == "\n" ? "\r\n" : String(ch))
        }
        tokens.append("\r\n")
        lock.lock(); bannerTyping = true; lock.unlock()

        func step(_ i: Int) {
            lock.lock()
            if i < tokens.count {
                terminal.feed(tokens[i])
                lock.unlock()
                let pause = tokens[i] == "\r\n" ? 6.0 : 1.0
                readQueue.asyncAfter(deadline: .now() + TerminalSession.bannerCharDelay * pause) { step(i + 1) }
            } else {
                bannerTyping = false
                if !heldOutput.isEmpty, !basicActive { terminal.feed(heldOutput); heldOutput.removeAll() }
                lock.unlock()
            }
        }
        readQueue.async { step(0) }
    }

    func terminate() {
        basic?.stop()
        pty?.terminate()
    }

    // MARK: - I/O

    /// Everything the user types or pastes funnels through here (main thread).
    func send(_ bytes: [UInt8]) {
        if let basic = basic { basic.send(bytes); return }
        for (i, byte) in bytes.enumerated() where trackTyped(byte) {
            pty?.write(Array(bytes[..<i]))
            pty?.write([0x15])   // Ctrl-U: the shell forgets the "basic" it was given
            enterBasic()
            basic?.send(Array(bytes[(i + 1)...]))
            return
        }
        pty?.write(bytes)
    }

    func send(_ string: String) {
        send(Array(string.utf8))
    }

    func paste(_ text: String) {
        if let basic = basic { basic.paste(text); return }
        var t = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        lock.lock()
        let bracketed = terminal.bracketedPaste
        lock.unlock()
        if bracketed {
            t = t.replacingOccurrences(of: "\u{1b}[201~", with: "")
            t = "\u{1b}[200~" + t + "\u{1b}[201~"
        }
        send(t)
    }

    func resize(cols: Int, rows: Int) {
        lock.lock()
        terminal.resize(cols: cols, rows: rows)
        lock.unlock()
        pty?.resize(cols: cols, rows: rows)
        basic?.setColumns(cols)
    }

    // MARK: - BASIC easter egg

    /// Follows the line being typed at the shell. Returns true when Return completes "basic".
    private func trackTyped(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x20...0x7E:
            if typedLine.count < 16 { typedLine.append(byte) }
        case 0x7F, 0x08:
            _ = typedLine.popLast()
        case 0x0D:
            let hit = shouldEnterBasic()
            typedLine = []
            return hit
        default:
            typedLine = []
        }
        return false
    }

    /// "basic" was typed; also require the C64 theme and the word to sit on screen right before
    /// the cursor (so an editor or a command with arguments never triggers it).
    private func shouldEnterBasic() -> Bool {
        guard AppSettings.shared.config.theme == .c64,
              String(decoding: typedLine, as: UTF8.self).trimmingCharacters(in: .whitespaces).lowercased() == "basic"
        else { return false }
        return withTerminal { t in
            guard !t.altScreen, t.mouseMode == .none, t.cursorX >= 5, t.cursorY < t.lines.count else { return false }
            let line = t.lines[t.cursorY]
            guard t.cursorX <= line.cells.count,
                  line.text(from: t.cursorX - 5, to: t.cursorX, trimTrailing: false).lowercased() == "basic"
            else { return false }
            return t.cursorX == 5 || line.cells[t.cursorX - 6].isTextBlank
        }
    }

    private func enterBasic() {
        lock.lock(); basicActive = true; lock.unlock()
        let host = BasicHost(session: self)
        host.onExit = { [weak self] in self?.exitBasic() }
        basic = host
        host.start()
    }

    private func exitBasic() {
        basic = nil
        lock.lock()
        basicActive = false
        // The shell's reaction to Ctrl-U was held back; let it in, then wipe the BASIC screen.
        if !heldOutput.isEmpty { terminal.feed(heldOutput); heldOutput.removeAll() }
        terminal.feed("\u{1b}[0m\u{1b}[H\u{1b}[2J")
        lock.unlock()
        pty?.write([0x0C])   // Ctrl-L: redraw the prompt
    }

    var generation: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return terminal.generation
    }

    func withTerminal<T>(_ body: (Terminal) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(terminal)
    }

    /// Visible lines given a scrollback offset (0 = bottom).
    func snapshot(viewOffset: Int) -> TerminalSnapshot {
        lock.lock(); defer { lock.unlock() }
        let t = terminal
        let sb = t.scrollback.count
        let offset = max(0, min(viewOffset, sb))
        var lines: [Line] = []
        lines.reserveCapacity(t.rows)
        if offset > 0 {
            lines.append(contentsOf: t.scrollback[(sb - offset)...])
        }
        let screenRows = max(0, t.rows - offset)
        lines.append(contentsOf: t.lines[0..<min(screenRows, t.lines.count)])
        return TerminalSnapshot(
            lines: lines,
            firstAbsoluteLine: t.scrollbackBase + sb - offset,
            cols: t.cols, rows: t.rows,
            cursorX: t.cursorX, cursorY: t.cursorY + offset,
            cursorVisible: t.cursorVisible,
            cursorStyle: t.cursorStyle,
            cursorBlinkOverride: t.cursorBlinkOverride,
            reverseVideo: t.reverseVideo,
            generation: t.generation
        )
    }

    /// Line by absolute index (scrollback + screen), or nil when scrolled out.
    func line(absolute index: Int) -> Line? {
        lock.lock(); defer { lock.unlock() }
        let t = terminal
        let i = index - t.scrollbackBase
        if i < 0 { return nil }
        if i < t.scrollback.count { return t.scrollback[i] }
        let s = i - t.scrollback.count
        if s < t.lines.count { return t.lines[s] }
        return nil
    }

    func text(in selection: Selection) -> String {
        let sel = selection.normalized
        var out: [String] = []
        var pending = ""
        for l in sel.start.line...sel.end.line {
            guard let line = line(absolute: l) else { continue }
            let from = l == sel.start.line ? sel.start.col : 0
            let to = l == sel.end.line ? sel.end.col + 1 : line.cells.count
            let t = line.text(from: from, to: to, trimTrailing: !(l == sel.end.line && to < line.cells.count) )
            pending += t
            if !line.wrapped || l == sel.end.line {
                out.append(pending)
                pending = ""
            }
        }
        if !pending.isEmpty { out.append(pending) }
        return out.joined(separator: "\n")
    }

    /// Current directory of the shell (OSC 7 if reported, otherwise from the kernel).
    func currentDirectory() -> String? {
        let fromOSC: String? = withTerminal { $0.cwd }
        if let c = fromOSC { return c }
        guard let pid = pty?.pid else { return nil }
        var buf = [CChar](repeating: 0, count: 4096)
        if cpty_cwd(pid, &buf, 4096) == 0 {
            let s = String(cString: buf)
            return s.isEmpty ? nil : s
        }
        return nil
    }
}
