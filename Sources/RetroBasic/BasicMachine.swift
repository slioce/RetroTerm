import Foundation

/// What the machine is doing after a `step`.
public enum StepResult: Equatable {
    /// At the READY prompt, waiting for a line.
    case ready
    /// A program (or a direct-mode line) is executing; call `step` again.
    case running
    /// An INPUT statement is waiting for `supplyLine`.
    case awaitingLine
    /// SYS 64738 or EXIT: the host should leave BASIC.
    case exit
}

/// A small Commodore-64-style BASIC interpreter driven in steps by the host.
///
/// The machine never blocks: `step(budget:)` runs up to `budget` statements and returns what
/// it needs next. Output goes through `output` as plain text, "\n" for newline and the PETSCII
/// clear-screen control (U+0093) for the banner; the console translates both for the terminal.
public final class BasicMachine {
    public var output: (String) -> Void = { _ in }
    /// Width used for the PRINT "," zones.
    public var columns: Int = 40

    public static let banner = "\u{93}\n    **** RETROTERM BASIC V2 ****\n\n 64K RAM SYSTEM  38911 BASIC BYTES FREE\n\nREADY.\n"

    public private(set) var state: StepResult = .ready
    /// Number of the program line being executed; nil in direct mode.
    public private(set) var currentLine: Int?

    private struct ProgramLine {
        let number: Int
        let text: String
        var parsed: Result<[Statement], Error>?
    }

    /// Where execution is: the working copy of a line's statements and the next index.
    /// `lineIndex` is nil for a direct-mode line. IF...THEN splices its body into `statements`,
    /// so loop and subroutine returns restore the whole position, not just an index.
    private struct Position {
        var lineIndex: Int?
        var statements: [Statement]
        var stmtIndex: Int
    }

    private struct ForFrame {
        let name: String
        let limit: Double
        let step: Double
        let resume: Position
    }

    private var program: [ProgramLine] = []
    private var position = Position(lineIndex: nil, statements: [], stmtIndex: 0)
    private var forStack: [ForFrame] = []
    private var gosubStack: [Position] = []
    private let runtime: Runtime
    private var column = 0
    private var interrupted = false
    private var pendingInput: [VarRef] = []

    public init(random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        runtime = Runtime(random: random)
    }

    /// Forgets everything, clears the screen and prints the banner.
    public func powerOn() {
        program = []
        clr()
        state = .ready
        column = 0
        emit(BasicMachine.banner)
    }

    // MARK: - Host interface

    /// A line typed at READY: either a numbered program line or direct-mode statements.
    public func submitLine(_ text: String) {
        guard state == .ready else { return }
        let line = text.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty {
            guard let n = Int(digits), n <= 63999 else { report(.syntax); return }
            store(line: n, text: String(line.dropFirst(digits.count)).trimmingCharacters(in: .whitespaces))
            return
        }
        do {
            position = Position(lineIndex: nil, statements: try Parser.parseLine(line), stmtIndex: 0)
            currentLine = nil
            state = .running
        } catch {
            report(error as? BasicError ?? .syntax)
        }
    }

    /// The answer to a pending INPUT. The host has already echoed it and moved to a new line.
    public func supplyLine(_ text: String) {
        guard state == .awaitingLine else { return }
        column = 0
        let values = BasicMachine.splitInput(text)
        do {
            for (i, ref) in pendingInput.enumerated() {
                let raw = i < values.count ? values[i] : ""
                if raw.isEmpty { continue }   // nothing typed: the variable keeps its value
                if ref.isString {
                    try runtime.set(ref, .string(raw))
                } else {
                    guard let n = Runtime.parseNumber(raw) else { emit("?REDO FROM START\n? "); return }
                    try runtime.set(ref, .number(n))
                }
            }
        } catch {
            report(error as? BasicError ?? .syntax)
            return
        }
        pendingInput = []
        state = .running
    }

    /// RUN/STOP: breaks a running program, or a pending INPUT.
    public func interrupt() {
        switch state {
        case .running: interrupted = true
        case .awaitingLine: pendingInput = []; breakProgram()
        default: break
        }
    }

    /// Executes up to `budget` statements.
    @discardableResult
    public func step(budget: Int = 1) -> StepResult {
        guard state == .running else { return state }
        var n = 0
        while n < budget, state == .running {
            if interrupted {
                interrupted = false
                breakProgram()
                break
            }
            do {
                guard let stmt = try fetch() else { finish(); break }
                try execute(stmt)
            } catch {
                report(error as? BasicError ?? .syntax)
            }
            n += 1
        }
        return state
    }

    // MARK: - Program store

    private func store(line number: Int, text: String) {
        clr()
        let index = program.firstIndex { $0.number >= number }
        if text.isEmpty {
            if let i = index, program[i].number == number { program.remove(at: i) }
            return
        }
        let entry = ProgramLine(number: number, text: BasicMachine.uppercasedOutsideQuotes(text), parsed: nil)
        if let i = index {
            if program[i].number == number { program[i] = entry } else { program.insert(entry, at: i) }
        } else {
            program.append(entry)
        }
    }

    private func lineIndex(of number: Int) throws -> Int {
        guard let i = program.firstIndex(where: { $0.number == number }) else { throw BasicError.undefdStatement }
        return i
    }

    private func load(lineIndex: Int) throws {
        if program[lineIndex].parsed == nil {
            program[lineIndex].parsed = Result { try Parser.parseLine(program[lineIndex].text) }
        }
        currentLine = program[lineIndex].number
        position = Position(lineIndex: lineIndex, statements: try program[lineIndex].parsed!.get(), stmtIndex: 0)
    }

    private func restore(_ p: Position) {
        position = p
        currentLine = p.lineIndex.map { program[$0].number }
    }

    private func fetch() throws -> Statement? {
        while true {
            if position.stmtIndex < position.statements.count {
                let s = position.statements[position.stmtIndex]
                position.stmtIndex += 1
                return s
            }
            guard let li = position.lineIndex, li + 1 < program.count else { return nil }
            try load(lineIndex: li + 1)
        }
    }

    // MARK: - Execution

    private func execute(_ stmt: Statement) throws {
        switch stmt {
        case .empty, .rem:
            break
        case .print(let items):
            try print(items)
        case .assign(let ref, let e):
            try runtime.set(ref, try runtime.eval(e))
        case .ifThen(let cond, let body):
            if try runtime.number(try runtime.eval(cond)) != 0 {
                position.statements.insert(contentsOf: body, at: position.stmtIndex)
            }
        case .goto(let n):
            try load(lineIndex: try lineIndex(of: n))
        case .gosub(let n):
            gosubStack.append(position)
            try load(lineIndex: try lineIndex(of: n))
        case .return:
            guard let p = gosubStack.popLast() else { throw BasicError.returnWithoutGosub }
            restore(p)
        case .forLoop(let v, let start, let limit, let step):
            let s = try runtime.number(try runtime.eval(start))
            let lim = try runtime.number(try runtime.eval(limit))
            let st = try step.map { try runtime.number(try runtime.eval($0)) } ?? 1
            try runtime.set(v, .number(s))
            if let i = forStack.lastIndex(where: { $0.name == v.name }) { forStack.removeSubrange(i...) }
            forStack.append(ForFrame(name: v.name, limit: lim, step: st, resume: position))
        case .next(let vars):
            if vars.isEmpty {
                _ = try next(nil)
            } else {
                for v in vars where try next(v.name) { break }
            }
        case .dim(let vars):
            for v in vars { try runtime.dim(v) }
        case .end:
            finish()
        case .stop:
            breakProgram()
        case .run(let n):
            clr()
            if program.isEmpty { finish(); return }
            try load(lineIndex: try n.map(lineIndex(of:)) ?? 0)
        case .list(let from, let to):
            for line in program where (from.map { line.number >= $0 } ?? true) && (to.map { line.number <= $0 } ?? true) {
                emit("\(line.number) \(line.text)\n")
            }
        case .new:
            program = []
            clr()
            finish()
        case .clr:
            clr()
        case .sys(let e):
            let address = try runtime.number(try runtime.eval(e)).rounded(.down)
            guard address >= 0, address <= 65535 else { throw BasicError.illegalQuantity }
            if address == 64738 { state = .exit }
        case .exit:
            state = .exit
        case .deviceNotPresent:
            throw BasicError.deviceNotPresent
        case .input(let prompt, let vars):
            guard position.lineIndex != nil else { throw BasicError.illegalDirect }
            emit((prompt ?? "") + "? ")
            pendingInput = vars
            state = .awaitingLine
        }
    }

    /// Advances one FOR loop. Returns true when the loop continues (execution jumped back).
    private func next(_ name: String?) throws -> Bool {
        let index: Int?
        if let name = name { index = forStack.lastIndex { $0.name == name } } else { index = forStack.indices.last }
        guard let i = index else { throw BasicError.nextWithoutFor }
        forStack.removeSubrange((i + 1)...)   // inner loops left open are abandoned
        let frame = forStack[i]
        let ref = VarRef(name: frame.name, isString: false, subscripts: nil)
        let value = try runtime.number(try runtime.get(ref)) + frame.step
        try runtime.set(ref, .number(value))
        let done = frame.step >= 0 ? value > frame.limit : value < frame.limit
        if done {
            forStack.remove(at: i)
            return false
        }
        restore(frame.resume)
        return true
    }

    private func print(_ items: [PrintItem]) throws {
        var newline = true
        for item in items {
            switch item {
            case .semicolon:
                newline = false
            case .comma:
                newline = false
                let zone = (column / 10 + 1) * 10
                if zone >= columns { emit("\n") } else { emit(String(repeating: " ", count: zone - column)) }
            case .expr(let e):
                newline = true
                switch try runtime.eval(e) {
                case .number(let n): emit(Runtime.format(n) + " ")
                case .string(let s): emit(s)
                }
            }
        }
        if newline { emit("\n") }
    }

    private func clr() {
        runtime.clear()
        forStack = []
        gosubStack = []
        pendingInput = []
        interrupted = false
    }

    private func finish() {
        state = .ready
        currentLine = nil
        emit("\nREADY.\n")
    }

    private func report(_ error: BasicError) {
        emit("\n?\(error.message)  ERROR" + (currentLine.map { " IN \($0)" } ?? ""))
        finish()
    }

    private func breakProgram() {
        emit("\nBREAK" + (currentLine.map { " IN \($0)" } ?? ""))
        finish()
    }

    private func emit(_ text: String) {
        output(text)
        for ch in text {
            if ch == "\n" || ch == "\u{93}" {
                column = 0
            } else {
                if column >= columns { column = 0 }
                column += 1
            }
        }
    }

    // MARK: - Text helpers

    static func uppercasedOutsideQuotes(_ text: String) -> String {
        var result = ""
        var inQuotes = false
        for ch in text {
            if ch == "\"" { inQuotes.toggle() }
            result.append(inQuotes ? ch : Character(ch.uppercased()))
        }
        return result
    }

    /// Splits an INPUT answer on commas, honouring quoted items.
    static func splitInput(_ text: String) -> [String] {
        var items: [String] = []
        var current = ""
        var inQuotes = false
        for ch in text {
            if ch == "\"" { inQuotes.toggle(); continue }
            if ch == ",", !inQuotes { items.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(ch)
        }
        items.append(current.trimmingCharacters(in: .whitespaces))
        return items
    }
}
