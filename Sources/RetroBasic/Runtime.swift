import Foundation

enum Value {
    case number(Double)
    case string(String)
}

struct BasicArray {
    /// Size of each dimension (declared bound + 1).
    let sizes: [Int]
    var values: [Value]

    init(sizes: [Int], isString: Bool) {
        self.sizes = sizes
        values = Array(repeating: isString ? .string("") : .number(0), count: sizes.reduce(1, *))
    }
}

/// Variables, arrays and expression evaluation.
final class Runtime {
    private var scalars: [String: Value] = [:]
    private var arrays: [String: BasicArray] = [:]
    let random: () -> Double

    init(random: @escaping () -> Double) { self.random = random }

    func clear() {
        scalars.removeAll()
        arrays.removeAll()
    }

    // MARK: - Variables

    func get(_ ref: VarRef) throws -> Value {
        if let subs = ref.subscripts {
            let index = try arrayIndex(ref, subs, autoDim: true)
            return arrays[ref.name]!.values[index]
        }
        return scalars[ref.name] ?? (ref.isString ? .string("") : .number(0))
    }

    func set(_ ref: VarRef, _ value: Value) throws {
        switch (ref.isString, value) {
        case (true, .number), (false, .string): throw BasicError.typeMismatch
        default: break
        }
        if let subs = ref.subscripts {
            let index = try arrayIndex(ref, subs, autoDim: true)
            arrays[ref.name]!.values[index] = value
        } else {
            scalars[ref.name] = value
        }
    }

    func dim(_ ref: VarRef) throws {
        guard let subs = ref.subscripts else { throw BasicError.syntax }
        guard arrays[ref.name] == nil else { throw BasicError.redimdArray }
        var sizes: [Int] = []
        for s in subs {
            let bound = try integer(try number(try eval(s)))
            guard bound >= 0 else { throw BasicError.illegalQuantity }
            sizes.append(bound + 1)
        }
        arrays[ref.name] = BasicArray(sizes: sizes, isString: ref.isString)
    }

    private func arrayIndex(_ ref: VarRef, _ subs: [Expr], autoDim: Bool) throws -> Int {
        if arrays[ref.name] == nil {
            arrays[ref.name] = BasicArray(sizes: Array(repeating: 11, count: subs.count), isString: ref.isString)
        }
        let array = arrays[ref.name]!
        guard array.sizes.count == subs.count else { throw BasicError.badSubscript }
        var index = 0
        var stride = 1
        for (i, s) in subs.enumerated() {
            let v = try integer(try number(try eval(s)))
            guard v >= 0, v < array.sizes[i] else { throw BasicError.badSubscript }
            index += v * stride
            stride *= array.sizes[i]
        }
        return index
    }

    // MARK: - Coercions

    func number(_ v: Value) throws -> Double {
        guard case .number(let n) = v else { throw BasicError.typeMismatch }
        return n
    }

    func string(_ v: Value) throws -> String {
        guard case .string(let s) = v else { throw BasicError.typeMismatch }
        return s
    }

    /// Floors to an integer; the C64 rejects anything beyond 16 bits in that position.
    func integer(_ d: Double) throws -> Int {
        let f = d.rounded(.down)
        guard f >= -32768, f <= 32767 else { throw BasicError.illegalQuantity }
        return Int(f)
    }

    private func int16(_ v: Value) throws -> Int16 { Int16(try integer(try number(v))) }

    private func checked(_ d: Double) throws -> Value {
        guard d.isFinite, abs(d) <= 1.70141183e38 else { throw BasicError.overflow }
        return .number(d)
    }

    // MARK: - Evaluation

    func eval(_ e: Expr) throws -> Value {
        switch e {
        case .number(let n): return .number(n)
        case .string(let s): return .string(s)
        case .variable(let ref): return try get(ref)
        case .neg(let x): return try checked(-(try number(try eval(x))))
        case .not(let x): return .number(Double(~(try int16(try eval(x)))))
        case .binary(let op, let l, let r): return try binary(op, try eval(l), try eval(r))
        case .call(let name, let args): return try call(name, try args.map(eval))
        }
    }

    private func binary(_ op: String, _ l: Value, _ r: Value) throws -> Value {
        switch (l, r) {
        case (.string(let a), .string(let b)):
            switch op {
            case "+": return .string(a + b)
            case "=": return .number(a == b ? -1 : 0)
            case "<>": return .number(a != b ? -1 : 0)
            case "<": return .number(a < b ? -1 : 0)
            case ">": return .number(a > b ? -1 : 0)
            case "<=": return .number(a <= b ? -1 : 0)
            case ">=": return .number(a >= b ? -1 : 0)
            default: throw BasicError.typeMismatch
            }
        case (.number(let a), .number(let b)):
            switch op {
            case "+": return try checked(a + b)
            case "-": return try checked(a - b)
            case "*": return try checked(a * b)
            case "/":
                guard b != 0 else { throw BasicError.divisionByZero }
                return try checked(a / b)
            case "^":
                if a == 0, b < 0 { throw BasicError.divisionByZero }
                return try checked(pow(a, b))
            case "=": return .number(a == b ? -1 : 0)
            case "<>": return .number(a != b ? -1 : 0)
            case "<": return .number(a < b ? -1 : 0)
            case ">": return .number(a > b ? -1 : 0)
            case "<=": return .number(a <= b ? -1 : 0)
            case ">=": return .number(a >= b ? -1 : 0)
            case "AND": return .number(Double(try int16(l) & (try int16(r))))
            case "OR": return .number(Double(try int16(l) | (try int16(r))))
            default: throw BasicError.syntax
            }
        default:
            throw BasicError.typeMismatch
        }
    }

    private func call(_ name: String, _ args: [Value]) throws -> Value {
        func one() throws -> Value { guard args.count == 1 else { throw BasicError.syntax }; return args[0] }
        func num() throws -> Double { try number(try one()) }
        func str() throws -> String { try string(try one()) }
        switch name {
        case "ABS": return .number(abs(try num()))
        case "INT": return .number((try num()).rounded(.down))
        case "SGN": let n = try num(); return .number(n > 0 ? 1 : (n < 0 ? -1 : 0))
        case "SQR":
            let n = try num()
            guard n >= 0 else { throw BasicError.illegalQuantity }
            return .number(n.squareRoot())
        case "SIN": return .number(sin(try num()))
        case "COS": return .number(cos(try num()))
        case "TAN": return try checked(tan(try num()))
        case "ATN": return .number(atan(try num()))
        case "EXP": return try checked(exp(try num()))
        case "LOG":
            let n = try num()
            guard n > 0 else { throw BasicError.illegalQuantity }
            return .number(log(n))
        case "RND": _ = try num(); return .number(random())
        case "LEN": return .number(Double((try str()).count))
        case "ASC":
            guard let c = (try str()).unicodeScalars.first else { throw BasicError.illegalQuantity }
            return .number(Double(c.value))
        case "VAL": return .number(Runtime.parseNumber(try str()) ?? 0)
        case "STR$": return .string(Runtime.format(try num()))
        case "CHR$":
            let n = try integer(try num())
            guard n >= 0, n <= 255, let scalar = Unicode.Scalar(n) else { throw BasicError.illegalQuantity }
            return .string(String(Character(scalar)))
        case "LEFT$", "RIGHT$":
            guard args.count == 2 else { throw BasicError.syntax }
            let s = try string(args[0])
            let n = try integer(try number(args[1]))
            guard n >= 0, n <= 255 else { throw BasicError.illegalQuantity }
            return .string(name == "LEFT$" ? String(s.prefix(n)) : String(s.suffix(n)))
        case "MID$":
            guard args.count == 2 || args.count == 3 else { throw BasicError.syntax }
            let s = try string(args[0])
            let start = try integer(try number(args[1]))
            guard start >= 1, start <= 255 else { throw BasicError.illegalQuantity }
            let rest = String(s.dropFirst(start - 1))
            if args.count == 3 {
                let n = try integer(try number(args[2]))
                guard n >= 0, n <= 255 else { throw BasicError.illegalQuantity }
                return .string(String(rest.prefix(n)))
            }
            return .string(rest)
        default:
            throw BasicError.syntax
        }
    }

    // MARK: - Numbers as text

    /// Formats a number the way PRINT and STR$ do: a leading space for positives, no trailing
    /// zeros, no leading zero before the point, up to nine significant digits.
    static func format(_ d: Double) -> String {
        var s: String
        if d == d.rounded(), abs(d) < 1e15 {
            s = String(Int64(d))
        } else {
            s = String(format: "%.9g", d)
            if s.contains("e") {
                s = s.uppercased()
            } else if s.hasPrefix("0.") {
                s.removeFirst()
            } else if s.hasPrefix("-0.") {
                s = "-" + s.dropFirst(2)
            }
        }
        return d < 0 ? s : " " + s
    }

    /// Reads the leading number of a string the way VAL and INPUT do; nil when there is none.
    static func parseNumber(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return 0 }
        var end = t.startIndex
        var seenDigit = false, seenDot = false, seenExp = false
        var i = t.startIndex
        while i < t.endIndex {
            let c = t[i]
            if c.isNumber && c.isASCII { seenDigit = true; end = t.index(after: i) }
            else if c == "." && !seenDot && !seenExp { seenDot = true }
            else if (c == "E" || c == "e") && seenDigit && !seenExp { seenExp = true }
            else if (c == "+" || c == "-") && (i == t.startIndex || t[t.index(before: i)] == "E" || t[t.index(before: i)] == "e") {}
            else { break }
            i = t.index(after: i)
        }
        guard seenDigit else { return nil }
        return Double(String(t[t.startIndex..<end]))
    }
}
