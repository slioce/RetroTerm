import Foundation

public protocol VTParserDelegate: AnyObject {
    func parserPrint(_ scalar: Unicode.Scalar)
    func parserExecute(_ byte: UInt8)
    func parserCSI(params: [[Int]], intermediates: [UInt8], final: UInt8)
    func parserESC(intermediates: [UInt8], final: UInt8)
    func parserOSC(_ string: String)
    func parserDCS(params: [[Int]], intermediates: [UInt8], final: UInt8, data: [UInt8])
}

/// VT500-series escape sequence parser (state machine after Paul Williams' DEC ANSI parser)
/// with inline UTF-8 decoding.
public final class VTParser {
    enum State {
        case ground, escape, escapeIntermediate
        case csiEntry, csiParam, csiIntermediate, csiIgnore
        case dcsEntry, dcsParam, dcsIntermediate, dcsPassthrough, dcsIgnore
        case oscString, sosPmApcString
    }

    public weak var delegate: VTParserDelegate?

    private var state: State = .ground
    private var params: [[Int]] = []
    private var currentGroup: [Int] = []
    private var currentValue: Int = 0
    private var hasValue = false
    private var intermediates: [UInt8] = []
    private var oscBytes: [UInt8] = []
    private var dcsData: [UInt8] = []
    private var dcsFinal: UInt8 = 0
    private var dcsParams: [[Int]] = []
    private var dcsIntermediates: [UInt8] = []

    // UTF-8 decoding state
    private var utf8Value: UInt32 = 0
    private var utf8Needed = 0
    private var utf8Min: UInt32 = 0

    private static let maxParams = 32

    public init(delegate: VTParserDelegate? = nil) {
        self.delegate = delegate
    }

    public func feed(_ bytes: UnsafeBufferPointer<UInt8>) {
        for b in bytes { process(b) }
    }

    public func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { feed($0) }
    }

    public func feed(_ string: String) {
        feed(Array(string.utf8))
    }

    // MARK: - State machine

    private func clear() {
        params.removeAll(keepingCapacity: true)
        currentGroup.removeAll(keepingCapacity: true)
        currentValue = 0
        hasValue = false
        intermediates.removeAll(keepingCapacity: true)
    }

    private func finishParam() {
        if hasValue || !currentGroup.isEmpty {
            currentGroup.append(hasValue ? currentValue : 0)
        } else {
            currentGroup.append(0)
        }
        if params.count < VTParser.maxParams { params.append(currentGroup) }
        currentGroup.removeAll(keepingCapacity: true)
        currentValue = 0
        hasValue = false
    }

    private func finalizeParams() -> [[Int]] {
        if hasValue || !currentGroup.isEmpty {
            currentGroup.append(hasValue ? currentValue : 0)
            if params.count < VTParser.maxParams { params.append(currentGroup) }
            currentGroup.removeAll(keepingCapacity: true)
            currentValue = 0
            hasValue = false
        }
        return params
    }

    private func paramByte(_ b: UInt8) {
        switch b {
        case 0x30...0x39:
            if hasValue {
                currentValue = min(currentValue * 10 + Int(b - 0x30), 0xFFFF)
            } else {
                currentValue = Int(b - 0x30)
                hasValue = true
            }
        case 0x3B: // ;
            finishParam()
        case 0x3A: // : sub-parameter separator
            currentGroup.append(hasValue ? currentValue : 0)
            currentValue = 0
            hasValue = false
        default:
            break
        }
    }

    private func transition(to newState: State) {
        // exit actions
        if state == .oscString && newState != .oscString {
            dispatchOSC()
        }
        if state == .dcsPassthrough && newState != .dcsPassthrough {
            delegate?.parserDCS(params: dcsParams, intermediates: dcsIntermediates, final: dcsFinal, data: dcsData)
            dcsData.removeAll(keepingCapacity: true)
        }
        state = newState
        // entry actions
        switch newState {
        case .escape, .csiEntry, .dcsEntry:
            clear()
        case .oscString:
            oscBytes.removeAll(keepingCapacity: true)
        case .dcsPassthrough:
            dcsData.removeAll(keepingCapacity: true)
        default:
            break
        }
    }

    private func dispatchOSC() {
        let s = String(decoding: oscBytes, as: UTF8.self)
        oscBytes.removeAll(keepingCapacity: true)
        delegate?.parserOSC(s)
    }

    private func process(_ b: UInt8) {
        // UTF-8 continuation handling takes precedence while a sequence is pending.
        if utf8Needed > 0 {
            if b & 0xC0 == 0x80 {
                utf8Value = (utf8Value << 6) | UInt32(b & 0x3F)
                utf8Needed -= 1
                if utf8Needed == 0 {
                    if utf8Value < utf8Min || utf8Value > 0x10FFFF || (utf8Value >= 0xD800 && utf8Value <= 0xDFFF) {
                        emitScalar(0xFFFD)
                    } else {
                        emitScalar(utf8Value)
                    }
                }
                return
            } else {
                // invalid continuation: emit replacement and reprocess this byte
                utf8Needed = 0
                emitScalar(0xFFFD)
            }
        }

        // "anywhere" transitions
        switch b {
        case 0x18, 0x1A:
            delegate?.parserExecute(b)
            transition(to: .ground)
            return
        case 0x1B:
            transition(to: .escape)
            return
        default:
            break
        }

        switch state {
        case .ground:
            if b < 0x20 {
                delegate?.parserExecute(b)
            } else if b < 0x7F {
                delegate?.parserPrint(Unicode.Scalar(b))
            } else if b == 0x7F {
                // DEL: ignored
            } else {
                startUTF8(b)
            }

        case .escape:
            switch b {
            case 0x00...0x1F:
                delegate?.parserExecute(b)
            case 0x20...0x2F:
                intermediates.append(b)
                transition(to: .escapeIntermediate)
            case 0x5B: // [
                transition(to: .csiEntry)
            case 0x5D: // ]
                transition(to: .oscString)
            case 0x50: // P
                transition(to: .dcsEntry)
            case 0x58, 0x5E, 0x5F: // X ^ _
                transition(to: .sosPmApcString)
            case 0x30...0x4F, 0x51...0x57, 0x59, 0x5A, 0x5C, 0x60...0x7E:
                let inter = intermediates
                transition(to: .ground)
                delegate?.parserESC(intermediates: inter, final: b)
            default:
                break
            }

        case .escapeIntermediate:
            switch b {
            case 0x00...0x1F:
                delegate?.parserExecute(b)
            case 0x20...0x2F:
                intermediates.append(b)
            case 0x30...0x7E:
                let inter = intermediates
                transition(to: .ground)
                delegate?.parserESC(intermediates: inter, final: b)
            default:
                break
            }

        case .csiEntry:
            switch b {
            case 0x00...0x1F:
                delegate?.parserExecute(b)
            case 0x20...0x2F:
                intermediates.append(b)
                transition(to: .csiIntermediate)
            case 0x30...0x3B:
                paramByte(b)
                state = .csiParam
            case 0x3C...0x3F:
                intermediates.append(b)
                state = .csiParam
            case 0x40...0x7E:
                dispatchCSI(final: b)
            default:
                break
            }

        case .csiParam:
            switch b {
            case 0x00...0x1F:
                delegate?.parserExecute(b)
            case 0x30...0x3B:
                paramByte(b)
            case 0x3C...0x3F:
                state = .csiIgnore
            case 0x20...0x2F:
                intermediates.append(b)
                state = .csiIntermediate
            case 0x40...0x7E:
                dispatchCSI(final: b)
            default:
                break
            }

        case .csiIntermediate:
            switch b {
            case 0x00...0x1F:
                delegate?.parserExecute(b)
            case 0x20...0x2F:
                intermediates.append(b)
            case 0x30...0x3F:
                state = .csiIgnore
            case 0x40...0x7E:
                dispatchCSI(final: b)
            default:
                break
            }

        case .csiIgnore:
            switch b {
            case 0x00...0x1F:
                delegate?.parserExecute(b)
            case 0x40...0x7E:
                transition(to: .ground)
            default:
                break
            }

        case .dcsEntry:
            switch b {
            case 0x20...0x2F:
                intermediates.append(b)
                state = .dcsIntermediate
            case 0x30...0x3B:
                paramByte(b)
                state = .dcsParam
            case 0x3C...0x3F:
                intermediates.append(b)
                state = .dcsParam
            case 0x40...0x7E:
                startDCS(final: b)
            default:
                break
            }

        case .dcsParam:
            switch b {
            case 0x30...0x3B:
                paramByte(b)
            case 0x3C...0x3F:
                state = .dcsIgnore
            case 0x20...0x2F:
                intermediates.append(b)
                state = .dcsIntermediate
            case 0x40...0x7E:
                startDCS(final: b)
            default:
                break
            }

        case .dcsIntermediate:
            switch b {
            case 0x20...0x2F:
                intermediates.append(b)
            case 0x30...0x3F:
                state = .dcsIgnore
            case 0x40...0x7E:
                startDCS(final: b)
            default:
                break
            }

        case .dcsPassthrough:
            if b != 0x7F { dcsData.append(b) }

        case .dcsIgnore:
            break

        case .oscString:
            switch b {
            case 0x07:
                transition(to: .ground)
            case 0x00...0x06, 0x08...0x1F:
                break
            default:
                oscBytes.append(b)
            }

        case .sosPmApcString:
            break
        }
    }

    private func dispatchCSI(final: UInt8) {
        let p = finalizeParams()
        let inter = intermediates
        transition(to: .ground)
        delegate?.parserCSI(params: p, intermediates: inter, final: final)
    }

    private func startDCS(final: UInt8) {
        dcsParams = finalizeParams()
        dcsIntermediates = intermediates
        dcsFinal = final
        transition(to: .dcsPassthrough)
    }

    // MARK: - UTF-8

    private func startUTF8(_ b: UInt8) {
        if b & 0xE0 == 0xC0 {
            utf8Value = UInt32(b & 0x1F); utf8Needed = 1; utf8Min = 0x80
        } else if b & 0xF0 == 0xE0 {
            utf8Value = UInt32(b & 0x0F); utf8Needed = 2; utf8Min = 0x800
        } else if b & 0xF8 == 0xF0 {
            utf8Value = UInt32(b & 0x07); utf8Needed = 3; utf8Min = 0x10000
        } else {
            emitScalar(0xFFFD)
        }
    }

    private func emitScalar(_ v: UInt32) {
        guard let s = Unicode.Scalar(v) else {
            delegate?.parserPrint(Unicode.Scalar(0xFFFD)!)
            return
        }
        delegate?.parserPrint(s)
    }
}
