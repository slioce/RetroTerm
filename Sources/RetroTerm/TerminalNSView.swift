import AppKit
import Combine
import MetalKit
import RetroTermCore

/// The Metal-backed terminal surface: keyboard, mouse, selection, scrolling and drawing.
final class TerminalNSView: MTKView, MTKViewDelegate, NSTextInputClient, NSUserInterfaceValidations {
    private(set) weak var session: TerminalSession?
    private var renderer: Renderer?
    private let settings = AppSettings.shared
    private var cancellable: AnyCancellable?

    private(set) var cols = 80
    private(set) var rows = 24
    private var viewOffset = 0 {
        didSet { if viewOffset != oldValue { needsRender = true } }
    }

    var needsRender = true
    private var lastGeneration: UInt64 = 0
    private var blinkOn = true
    private var blinkTimer: Timer?
    private var bellFlashUntil: CFTimeInterval = 0
    private var isFocused = false

    private var markedText = ""
    private var selection: Selection? {
        didSet { if selection != oldValue { needsRender = true } }
    }
    private var selectionAnchor: TextPosition?
    private var selectionMode = 0 // 1 char, 2 word, 3 line
    private var scrollAccumulator: CGFloat = 0
    private var trackingArea: NSTrackingArea?
    private var lastMouseCell: (Int, Int)? = nil

    init(session: TerminalSession) {
        self.session = session
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        if let d = device { renderer = Renderer(device: d) }
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        preferredFramesPerSecond = 60
        isPaused = false
        enableSetNeedsDisplay = false
        autoResizeDrawable = true
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        delegate = self
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        cancellable = settings.$config
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateGrid()
                self?.needsRender = true
            }
        startBlinkTimer()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        blinkTimer?.invalidate()
    }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    private var config: TerminalConfig { settings.config }
    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    // MARK: - Layout

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateGrid()
        if window != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.window?.makeFirstResponder(self)
            }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateGrid()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGrid()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsRender = true
    }

    private func updateGrid() {
        guard let renderer = renderer, let session = session, bounds.width > 0, bounds.height > 0 else { return }
        let scale = backingScale
        renderer.configure(config: config, backingScale: scale)
        let inset = CGFloat(config.contentInset) * scale
        let pw = bounds.width * scale, ph = bounds.height * scale
        let newCols: Int, newRows: Int
        switch config.screenFit {
        case .reflow:
            // Grid follows the window: as many cells as fit, centred.
            let availW = max(renderer.cellWidth * 2, Int(pw - inset * 2))
            let availH = max(renderer.cellHeight, Int(ph - inset * 2))
            newCols = max(2, availW / renderer.cellWidth)
            newRows = max(1, availH / renderer.cellHeight)
            renderer.cellScale = SIMD2(1, 1)
            renderer.rasterMagnification = 1
            renderer.originX = Int((pw - CGFloat(newCols * renderer.cellWidth)) / 2)
            renderer.originY = Int((ph - CGFloat(newRows * renderer.cellHeight)) / 2)
        case .stretch, .fit:
            // Fixed grid filling the window like a CRT raster: the normal rendering (font, bitmap pixels, scanlines)
            // magnified to the window height. Any remaining (mostly horizontal) stretch is a per-cell scale in the shader.
            newCols = max(2, min(500, config.fixedCols))
            newRows = max(1, min(200, config.fixedRows))
            let ratio = CGFloat(renderer.cellWidth) / CGFloat(renderer.cellHeight)   // glyph aspect at the configured size
            let nativeCellH = CGFloat(renderer.cellHeight)
            var cellW = max(1, pw - inset * 2) / CGFloat(newCols)
            var cellH = max(1, ph - inset * 2) / CGFloat(newRows)
            if config.screenFit == .fit {
                let s = min(cellW / ratio, cellH)
                cellH = s; cellW = s * ratio
            }
            let magnification = cellH / nativeCellH
            renderer.configure(config: config, backingScale: scale, magnification: magnification)
            renderer.rasterMagnification = Float(magnification)
            renderer.cellScale = SIMD2(Float(cellW / CGFloat(renderer.cellWidth)), Float(cellH / CGFloat(renderer.cellHeight)))
            renderer.originX = Int((pw - cellW * CGFloat(newCols)) / 2)
            renderer.originY = Int((ph - cellH * CGFloat(newRows)) / 2)
        }
        if newCols != cols || newRows != rows {
            cols = newCols
            rows = newRows
            session.resize(cols: cols, rows: rows)
        }
        needsRender = true
    }

    // MARK: - Drawing

    func draw(in view: MTKView) {
        guard let renderer = renderer, let session = session else { return }
        let cfg = config
        let now = CACurrentMediaTime()
        let bell = bellFlashUntil > now
        let animated = cfg.crtEnabled && ((cfg.flickerOn && cfg.flickerIntensity > 0) || (cfg.noiseOn && cfg.noiseIntensity > 0))
        let gen = session.generation
        let changed = gen != lastGeneration || needsRender
        if !changed && !animated && !bell { return }

        if changed {
            if viewOffset > 0 {
                let sb = session.withTerminal { $0.scrollback.count }
                if viewOffset > sb { viewOffset = sb }
            }
        }
        let snap = session.snapshot(viewOffset: viewOffset)
        lastGeneration = snap.generation
        needsRender = false

        let flash: Float = bell && cfg.visualBell ? Float((bellFlashUntil - now) / 0.12) : 0
        let state = RenderState(snapshot: snap, selection: selection, focused: isFocused,
                                blinkOn: blinkOn, preedit: markedText, bellFlash: flash)
        renderer.render(state: state, config: cfg, in: view, rebuild: true)
    }

    private func startBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.blinkOn.toggle()
            if self.isFocused && self.config.cursorBlink { self.needsRender = true }
        }
    }

    private func resetBlink() {
        blinkOn = true
        startBlinkTimer()
    }

    func ringBell() {
        if config.audibleBell { NSSound.beep() }
        if config.visualBell {
            bellFlashUntil = CACurrentMediaTime() + 0.12
            needsRender = true
        }
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        isFocused = true
        needsRender = true
        if session?.withTerminal({ $0.focusEvents }) == true { session?.send("\u{1b}[I") }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        isFocused = false
        needsRender = true
        if session?.withTerminal({ $0.focusEvents }) == true { session?.send("\u{1b}[O") }
        return super.resignFirstResponder()
    }

    // MARK: - Keyboard

    private func modifiers(from flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var m: KeyModifiers = []
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.command) { m.insert(.command) }
        return m
    }

    override func keyUp(with event: NSEvent) {
        if config.keyClickOn { KeyClickPlayer.shared.keyUp(event, config: config) }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        if config.keyClickOn { KeyClickPlayer.shared.flagsChanged(event, config: config) }
        super.flagsChanged(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let session = session else { return }
        resetBlink()
        if config.keyClickOn { KeyClickPlayer.shared.keyDown(event, config: config) }
        if hasMarkedText() {
            interpretKeyEvents([event])
            return
        }
        var opts = KeyEncoder.Options()
        session.withTerminal { t in
            opts.applicationCursorKeys = t.applicationCursorKeys
            opts.applicationKeypad = t.applicationKeypad
            opts.lineFeedMode = t.lineFeedMode
        }
        opts.optionAsMeta = config.optionAsMeta
        if let bytes = KeyEncoder.encode(keyCode: event.keyCode,
                                         characters: event.characters ?? "",
                                         charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                                         modifiers: modifiers(from: event.modifierFlags),
                                         options: opts) {
            sendInput(bytes)
            return
        }
        interpretKeyEvents([event])
    }

    private func sendInput(_ bytes: [UInt8]) {
        session?.send(bytes)
        if viewOffset != 0 { viewOffset = 0 }
        selection = nil
    }

    override func doCommand(by selector: Selector) {
        // Everything meaningful is handled in keyDown; swallow the rest to avoid beeps.
        switch selector {
        case #selector(insertNewline(_:)): sendInput([0x0D])
        case #selector(insertTab(_:)): sendInput([0x09])
        case #selector(deleteBackward(_:)): sendInput([0x7F])
        case #selector(cancelOperation(_:)): sendInput([0x1B])
        default: break
        }
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let s: String
        if let str = string as? String { s = str }
        else if let a = string as? NSAttributedString { s = a.string }
        else { return }
        markedText = ""
        needsRender = true
        guard !s.isEmpty else { return }
        sendInput(Array(s.utf8))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let str = string as? String { markedText = str }
        else if let a = string as? NSAttributedString { markedText = a.string }
        needsRender = true
    }

    func unmarkText() {
        markedText = ""
        needsRender = true
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.utf16.count)
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let renderer = renderer, let session = session, let window = window else { return .zero }
        let (cx, cy) = session.withTerminal { ($0.cursorX, $0.cursorY) }
        let rect = renderer.viewRect(col: cx, row: cy, viewSize: bounds.size, backingScale: backingScale)
        return window.convertToScreen(convert(rect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    // MARK: - Copy / paste

    @objc func copy(_ sender: Any?) {
        guard let sel = selection, let session = session else { return }
        let text = session.text(in: sel)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let s = NSPasteboard.general.string(forType: .string) else { return }
        session?.paste(s)
        viewOffset = 0
    }

    @objc override func selectAll(_ sender: Any?) {
        guard let session = session else { return }
        session.withTerminal { t in
            let first = t.scrollbackBase
            let last = t.scrollbackBase + t.scrollback.count + t.rows - 1
            selection = Selection(start: TextPosition(line: first, col: 0), end: TextPosition(line: last, col: t.cols - 1))
        }
    }

    @objc func clearScrollback(_ sender: Any?) {
        session?.withTerminal { $0.clearAll() }
        viewOffset = 0
        needsRender = true
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selection != nil }
        if item.action == #selector(paste(_:)) { return NSPasteboard.general.string(forType: .string) != nil }
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Clear Screen & Scrollback", action: #selector(clearScrollback(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: - Mouse

    private func cell(for event: NSEvent) -> (col: Int, row: Int) {
        guard let renderer = renderer else { return (0, 0) }
        let p = convert(event.locationInWindow, from: nil)
        return renderer.cell(at: p, viewSize: bounds.size, config: config, cols: cols, rows: rows, backingScale: backingScale)
    }

    private func absolutePosition(col: Int, row: Int) -> TextPosition {
        guard let session = session else { return TextPosition(line: 0, col: col) }
        let base = session.withTerminal { $0.scrollbackBase + $0.scrollback.count }
        return TextPosition(line: base - viewOffset + row, col: col)
    }

    private func mouseReportingActive(_ event: NSEvent) -> Bool {
        guard let session = session else { return false }
        if event.modifierFlags.contains(.shift) { return false }
        return session.withTerminal { $0.mouseMode != .none }
    }

    private func reportMouse(_ event: NSEvent, button: MouseEncoder.Button, pressed: Bool, motion: Bool) {
        guard let session = session else { return }
        let (mode, enc) = session.withTerminal { ($0.mouseMode, $0.mouseEncoding) }
        if mode == .none { return }
        if mode == .x10 && (!pressed || motion) { return }
        if motion {
            if mode == .normal { return }
            if mode == .buttonEvent && button == .none { return }
        }
        let (c, r) = cell(for: event)
        if motion, let last = lastMouseCell, last.0 == c, last.1 == r { return }
        lastMouseCell = (c, r)
        let bytes = MouseEncoder.encode(button: button, pressed: pressed, motion: motion, x: c, y: r,
                                        modifiers: modifiers(from: event.modifierFlags), encoding: enc)
        session.send(bytes)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if mouseReportingActive(event) {
            reportMouse(event, button: .left, pressed: true, motion: false)
            return
        }
        let (c, r) = cell(for: event)
        let pos = absolutePosition(col: c, row: r)
        selectionMode = min(3, max(1, event.clickCount))
        selectionAnchor = pos
        switch selectionMode {
        case 2: selection = wordSelection(at: pos)
        case 3: selection = lineSelection(at: pos)
        default: selection = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if mouseReportingActive(event) {
            reportMouse(event, button: .left, pressed: true, motion: true)
            return
        }
        guard let anchor = selectionAnchor else { return }
        let (c, r) = cell(for: event)
        let pos = absolutePosition(col: c, row: r)
        switch selectionMode {
        case 2:
            let a = wordSelection(at: anchor), b = wordSelection(at: pos)
            selection = Selection(start: min(a.start, b.start), end: max(a.end, b.end))
        case 3:
            let a = lineSelection(at: anchor), b = lineSelection(at: pos)
            selection = Selection(start: min(a.start, b.start), end: max(a.end, b.end))
        default:
            if pos == anchor { selection = nil }
            else if pos < anchor {
                selection = Selection(start: pos, end: TextPosition(line: anchor.line, col: anchor.col - 1 >= 0 ? anchor.col - 1 : 0))
                if anchor.col == 0 { selection = Selection(start: pos, end: TextPosition(line: anchor.line - 1, col: cols - 1)) }
            } else {
                selection = Selection(start: anchor, end: TextPosition(line: pos.line, col: pos.col - 1 >= 0 ? pos.col - 1 : 0))
                if pos.col == 0 { selection = Selection(start: anchor, end: TextPosition(line: pos.line - 1, col: cols - 1)) }
            }
        }
        // Autoscroll when dragging above/below the view.
        let p = convert(event.locationInWindow, from: nil)
        if p.y > bounds.height { scrollBy(lines: 1) } else if p.y < 0 { scrollBy(lines: -1) }
    }

    override func mouseUp(with event: NSEvent) {
        if mouseReportingActive(event) {
            reportMouse(event, button: .left, pressed: false, motion: false)
            return
        }
        selectionAnchor = nil
        if config.copyOnSelect, selection != nil { copy(nil) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if mouseReportingActive(event) {
            reportMouse(event, button: .right, pressed: true, motion: false)
            return
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        if mouseReportingActive(event) {
            reportMouse(event, button: .right, pressed: false, motion: false)
            return
        }
        super.rightMouseUp(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        if mouseReportingActive(event) {
            reportMouse(event, button: .middle, pressed: true, motion: false)
            return
        }
        if event.buttonNumber == 2 { paste(nil) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if mouseReportingActive(event) {
            reportMouse(event, button: .middle, pressed: false, motion: false)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if mouseReportingActive(event) {
            reportMouse(event, button: .none, pressed: true, motion: true)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let session = session else { return }
        let (mouse, alt, altScroll) = session.withTerminal { ($0.mouseMode, $0.altScreen, $0.alternateScroll) }
        let shift = event.modifierFlags.contains(.shift)

        var lines: Int
        if event.hasPreciseScrollingDeltas {
            let cellPt = max(1, renderer?.displayedCellHeight(backingScale: backingScale) ?? 16)
            scrollAccumulator += event.scrollingDeltaY
            lines = Int(scrollAccumulator / cellPt)
            scrollAccumulator -= CGFloat(lines) * cellPt
        } else {
            lines = Int(event.scrollingDeltaY.rounded(.towardZero))
            if lines == 0 && event.scrollingDeltaY != 0 { lines = event.scrollingDeltaY > 0 ? 1 : -1 }
            lines *= 3
        }
        guard lines != 0 else { return }

        if mouse != .none && !shift {
            let (c, r) = cell(for: event)
            let enc = session.withTerminal { $0.mouseEncoding }
            let button: MouseEncoder.Button = lines > 0 ? .wheelUp : .wheelDown
            for _ in 0..<min(abs(lines), 10) {
                session.send(MouseEncoder.encode(button: button, pressed: true, motion: false, x: c, y: r,
                                                 modifiers: modifiers(from: event.modifierFlags), encoding: enc))
            }
            return
        }
        if alt && altScroll {
            let app = session.withTerminal { $0.applicationCursorKeys }
            let seq = lines > 0 ? (app ? "\u{1b}OA" : "\u{1b}[A") : (app ? "\u{1b}OB" : "\u{1b}[B")
            session.send(String(repeating: seq, count: min(abs(lines), 20)))
            return
        }
        scrollBy(lines: lines)
    }

    private func scrollBy(lines: Int) {
        guard let session = session else { return }
        let sb = session.withTerminal { $0.scrollback.count }
        viewOffset = max(0, min(sb, viewOffset + lines))
    }

    func scrollToBottom() { viewOffset = 0 }
    func scrollToTop() {
        guard let session = session else { return }
        viewOffset = session.withTerminal { $0.scrollback.count }
    }
    func scrollPage(_ direction: Int) { scrollBy(lines: direction * max(1, rows - 1)) }

    // MARK: - Word / line selection

    private func isWordChar(_ c: Cell) -> Bool {
        if c.isTextBlank { return false }
        let s = c.scalar
        if s.properties.isAlphabetic || s.properties.numericType != nil { return true }
        return "_-./~:@+".unicodeScalars.contains(s)
    }

    private func wordSelection(at pos: TextPosition) -> Selection {
        guard let session = session, let line = session.line(absolute: pos.line), pos.col < line.cells.count else {
            return Selection(start: pos, end: pos)
        }
        let cells = line.cells
        var a = pos.col, b = pos.col
        if isWordChar(cells[pos.col]) {
            while a > 0, isWordChar(cells[a - 1]) { a -= 1 }
            while b + 1 < cells.count, isWordChar(cells[b + 1]) { b += 1 }
        } else if cells[pos.col].isTextBlank {
            while a > 0, cells[a - 1].isTextBlank { a -= 1 }
            while b + 1 < cells.count, cells[b + 1].isTextBlank { b += 1 }
        }
        return Selection(start: TextPosition(line: pos.line, col: a), end: TextPosition(line: pos.line, col: b))
    }

    private func lineSelection(at pos: TextPosition) -> Selection {
        guard let session = session else { return Selection(start: pos, end: pos) }
        var first = pos.line, last = pos.line
        while let prev = session.line(absolute: first - 1), prev.wrapped { first -= 1 }
        while let cur = session.line(absolute: last), cur.wrapped, session.line(absolute: last + 1) != nil { last += 1 }
        let lastCols = session.line(absolute: last)?.cells.count ?? cols
        return Selection(start: TextPosition(line: first, col: 0), end: TextPosition(line: last, col: max(0, lastCols - 1)))
    }
}
