import Foundation

/// A BASIC runtime error. `message` is printed as "?<message>  ERROR".
struct BasicError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }

    static let syntax = BasicError("SYNTAX")
    static let typeMismatch = BasicError("TYPE MISMATCH")
    static let illegalQuantity = BasicError("ILLEGAL QUANTITY")
    static let divisionByZero = BasicError("DIVISION BY ZERO")
    static let overflow = BasicError("OVERFLOW")
    static let undefdStatement = BasicError("UNDEF'D STATEMENT")
    static let nextWithoutFor = BasicError("NEXT WITHOUT FOR")
    static let returnWithoutGosub = BasicError("RETURN WITHOUT GOSUB")
    static let badSubscript = BasicError("BAD SUBSCRIPT")
    static let redimdArray = BasicError("REDIM'D ARRAY")
    static let illegalDirect = BasicError("ILLEGAL DIRECT")
    static let deviceNotPresent = BasicError("DEVICE NOT PRESENT")
}

/// A variable reference. `name` is the normalised key: the first two characters of the
/// identifier, upper-cased, plus "$" for strings. `subscripts` is nil for scalars.
struct VarRef {
    let name: String
    let isString: Bool
    let subscripts: [Expr]?
}

indirect enum Expr {
    case number(Double)
    case string(String)
    case variable(VarRef)
    case call(String, [Expr])
    case neg(Expr)
    case not(Expr)
    case binary(String, Expr, Expr)
}

enum PrintItem {
    case expr(Expr), comma, semicolon
}

indirect enum Statement {
    case print([PrintItem])
    case input(prompt: String?, [VarRef])
    case assign(VarRef, Expr)
    case ifThen(Expr, [Statement])
    case goto(Int)
    case gosub(Int)
    case `return`
    case forLoop(VarRef, start: Expr, limit: Expr, step: Expr?)
    case next([VarRef])
    case dim([VarRef])
    case rem
    case end
    case stop
    case run(Int?)
    case list(Int?, Int?)
    case new
    case clr
    case sys(Expr)
    case exit
    case deviceNotPresent
    case empty
}

enum Token: Equatable {
    case number(Double)
    case string(String)
    case word(String)   // identifier or keyword, upper-cased, "$" suffix kept
    case op(String)
    case eol
}

enum Lexer {
    static func tokenize(_ line: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(line)
        var i = 0
        func peek(_ k: Int = 0) -> Character? { i + k < chars.count ? chars[i + k] : nil }
        while i < chars.count {
            let c = chars[i]
            if c == " " { i += 1; continue }
            if c == "\"" {
                i += 1
                var s = ""
                while i < chars.count, chars[i] != "\"" { s.append(chars[i]); i += 1 }
                if i < chars.count { i += 1 }
                tokens.append(.string(s))
                continue
            }
            if c.isASCIIDigit || (c == "." && (peek(1)?.isASCIIDigit ?? false)) {
                var s = ""
                while let d = peek(), d.isASCIIDigit || d == "." { s.append(d); i += 1 }
                if let e = peek(), e == "E" || e == "e" {
                    var j = i + 1
                    var exp = "E"
                    if j < chars.count, chars[j] == "+" || chars[j] == "-" { exp.append(chars[j]); j += 1 }
                    var digits = ""
                    while j < chars.count, chars[j].isASCIIDigit { digits.append(chars[j]); j += 1 }
                    if !digits.isEmpty { s += exp + digits; i = j }
                }
                guard let v = Double(s) else { throw BasicError.syntax }
                tokens.append(.number(v))
                continue
            }
            if c.isASCIILetter {
                var s = ""
                while let d = peek(), d.isASCIILetter || d.isASCIIDigit { s.append(d); i += 1 }
                if peek() == "$" { s.append("$"); i += 1 }
                let w = s.uppercased()
                tokens.append(.word(w))
                if w == "REM" { break }   // the rest of the line is a comment
                continue
            }
            if c == "?" { tokens.append(.word("PRINT")); i += 1; continue }
            if let n = peek(1) {
                let two = String([c, n])
                if let op = ["<=": "<=", "=<": "<=", ">=": ">=", "=>": ">=", "<>": "<>", "><": "<>"][two] {
                    tokens.append(.op(op)); i += 2; continue
                }
            }
            if "+-*/^()=<>,;:".contains(c) { tokens.append(.op(String(c))); i += 1; continue }
            throw BasicError.syntax
        }
        tokens.append(.eol)
        return tokens
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
    var isASCIILetter: Bool { ("A"..."Z").contains(self) || ("a"..."z").contains(self) }
}

struct Parser {
    static let functions: Set<String> = ["ABS", "INT", "SGN", "SQR", "SIN", "COS", "TAN", "ATN", "EXP", "LOG", "RND",
                                         "LEN", "ASC", "VAL", "STR$", "CHR$", "LEFT$", "RIGHT$", "MID$"]
    static let keywords: Set<String> = ["PRINT", "INPUT", "LET", "IF", "THEN", "GOTO", "GO", "TO", "GOSUB", "RETURN",
                                        "FOR", "STEP", "NEXT", "DIM", "REM", "END", "STOP", "RUN", "LIST", "NEW", "CLR",
                                        "SYS", "EXIT", "LOAD", "SAVE", "VERIFY", "OPEN", "CLOSE", "AND", "OR", "NOT"]

    private let tokens: [Token]
    private var pos = 0

    private init(tokens: [Token]) { self.tokens = tokens }

    /// Parses one line of statements (without a line number).
    static func parseLine(_ line: String) throws -> [Statement] {
        var p = Parser(tokens: try Lexer.tokenize(line))
        let s = try p.statements()
        guard p.current == .eol else { throw BasicError.syntax }
        return s
    }

    private var current: Token { tokens[pos] }
    private mutating func advance() { if pos < tokens.count - 1 { pos += 1 } }
    private mutating func accept(op: String) -> Bool { if current == .op(op) { advance(); return true }; return false }
    private mutating func accept(word: String) -> Bool { if current == .word(word) { advance(); return true }; return false }
    private mutating func expect(op: String) throws { guard accept(op: op) else { throw BasicError.syntax } }
    private mutating func expect(word: String) throws { guard accept(word: word) else { throw BasicError.syntax } }
    private mutating func lineNumber() throws -> Int {
        guard case .number(let n) = current, n >= 0, n <= 63999, n == n.rounded() else { throw BasicError.syntax }
        advance()
        return Int(n)
    }
    private var atStatementEnd: Bool { current == .eol || current == .op(":") }

    private mutating func statements() throws -> [Statement] {
        var list: [Statement] = []
        while true {
            list.append(try statement())
            if accept(op: ":") { continue }
            return list
        }
    }

    private mutating func statement() throws -> Statement {
        if atStatementEnd { return .empty }
        guard case .word(let w) = current else { throw BasicError.syntax }
        switch w {
        case "PRINT":
            advance()
            var items: [PrintItem] = []
            while !atStatementEnd {
                if accept(op: ";") { items.append(.semicolon) }
                else if accept(op: ",") { items.append(.comma) }
                else { items.append(.expr(try expression())) }
            }
            return .print(items)
        case "INPUT":
            advance()
            var prompt: String? = nil
            if case .string(let s) = current { prompt = s; advance(); try expect(op: ";") }
            return .input(prompt: prompt, try variableList())
        case "LET":
            advance()
            return try assignment()
        case "IF":
            advance()
            let cond = try expression()
            if accept(word: "THEN") {
                if case .number = current { return .ifThen(cond, [.goto(try lineNumber())]) }
                return .ifThen(cond, try statements())
            }
            try expect(word: "GOTO")
            return .ifThen(cond, [.goto(try lineNumber())])
        case "GOTO":
            advance()
            return .goto(try lineNumber())
        case "GO":
            advance()
            try expect(word: "TO")
            return .goto(try lineNumber())
        case "GOSUB":
            advance()
            return .gosub(try lineNumber())
        case "RETURN": advance(); return .return
        case "FOR":
            advance()
            let v = try variable()
            guard v.subscripts == nil, !v.isString else { throw BasicError.syntax }
            try expect(op: "=")
            let start = try expression()
            try expect(word: "TO")
            let limit = try expression()
            let step = accept(word: "STEP") ? try expression() : nil
            return .forLoop(v, start: start, limit: limit, step: step)
        case "NEXT":
            advance()
            var vars: [VarRef] = []
            if case .word = current {
                vars.append(try variable())
                while accept(op: ",") { vars.append(try variable()) }
            }
            return .next(vars)
        case "DIM":
            advance()
            let vars = try variableList()
            guard vars.allSatisfy({ $0.subscripts != nil }) else { throw BasicError.syntax }
            return .dim(vars)
        case "REM": advance(); return .rem
        case "END": advance(); return .end
        case "STOP": advance(); return .stop
        case "NEW": advance(); return .new
        case "CLR": advance(); return .clr
        case "EXIT": advance(); return .exit
        case "RUN":
            advance()
            if case .number = current { return .run(try lineNumber()) }
            return .run(nil)
        case "LIST":
            advance()
            if atStatementEnd { return .list(nil, nil) }
            if accept(op: "-") { return .list(nil, try lineNumber()) }
            let a = try lineNumber()
            if accept(op: "-") {
                if atStatementEnd { return .list(a, nil) }
                return .list(a, try lineNumber())
            }
            return .list(a, a)
        case "SYS":
            advance()
            return .sys(try expression())
        case "LOAD", "SAVE", "VERIFY", "OPEN", "CLOSE":
            while !atStatementEnd { advance() }
            return .deviceNotPresent
        default:
            return try assignment()
        }
    }

    private mutating func assignment() throws -> Statement {
        let v = try variable()
        try expect(op: "=")
        return .assign(v, try expression())
    }

    private mutating func variableList() throws -> [VarRef] {
        var vars = [try variable()]
        while accept(op: ",") { vars.append(try variable()) }
        return vars
    }

    private mutating func variable() throws -> VarRef {
        guard case .word(let w) = current, !Parser.keywords.contains(w), !Parser.functions.contains(w) else {
            throw BasicError.syntax
        }
        advance()
        let isString = w.hasSuffix("$")
        let ident = isString ? String(w.dropLast()) : w
        let name = String(ident.prefix(2)) + (isString ? "$" : "")
        var subscripts: [Expr]? = nil
        if accept(op: "(") {
            var subs = [try expression()]
            while accept(op: ",") { subs.append(try expression()) }
            try expect(op: ")")
            subscripts = subs
        }
        return VarRef(name: name, isString: isString, subscripts: subscripts)
    }

    // MARK: - Expressions, lowest precedence first

    private mutating func expression() throws -> Expr { try orExpr() }

    private mutating func orExpr() throws -> Expr {
        var e = try andExpr()
        while accept(word: "OR") { e = .binary("OR", e, try andExpr()) }
        return e
    }

    private mutating func andExpr() throws -> Expr {
        var e = try notExpr()
        while accept(word: "AND") { e = .binary("AND", e, try notExpr()) }
        return e
    }

    private mutating func notExpr() throws -> Expr {
        if accept(word: "NOT") { return .not(try notExpr()) }
        return try relExpr()
    }

    private mutating func relExpr() throws -> Expr {
        let e = try addExpr()
        for op in ["=", "<>", "<=", ">=", "<", ">"] {
            if accept(op: op) { return .binary(op, e, try addExpr()) }
        }
        return e
    }

    private mutating func addExpr() throws -> Expr {
        var e = try mulExpr()
        while true {
            if accept(op: "+") { e = .binary("+", e, try mulExpr()) }
            else if accept(op: "-") { e = .binary("-", e, try mulExpr()) }
            else { return e }
        }
    }

    private mutating func mulExpr() throws -> Expr {
        var e = try unary()
        while true {
            if accept(op: "*") { e = .binary("*", e, try unary()) }
            else if accept(op: "/") { e = .binary("/", e, try unary()) }
            else { return e }
        }
    }

    /// Unary minus binds looser than "^": -2^2 is -(2^2).
    private mutating func unary() throws -> Expr {
        if accept(op: "-") { return .neg(try unary()) }
        return try power()
    }

    private mutating func power() throws -> Expr {
        var e = try primary()
        while accept(op: "^") {
            let rhs: Expr = accept(op: "-") ? .neg(try primary()) : try primary()
            e = .binary("^", e, rhs)
        }
        return e
    }

    private mutating func primary() throws -> Expr {
        switch current {
        case .number(let n): advance(); return .number(n)
        case .string(let s): advance(); return .string(s)
        case .op("("):
            advance()
            let e = try expression()
            try expect(op: ")")
            return e
        case .word(let w) where Parser.functions.contains(w):
            advance()
            try expect(op: "(")
            var args = [try expression()]
            while accept(op: ",") { args.append(try expression()) }
            try expect(op: ")")
            return .call(w, args)
        case .word:
            return .variable(try variable())
        default:
            throw BasicError.syntax
        }
    }
}
