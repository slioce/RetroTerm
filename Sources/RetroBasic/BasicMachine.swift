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
/// clear-screen control (U+0093) for CLR/HOME; the console translates both for the terminal.
public final class BasicMachine {
    public var output: (String) -> Void = { _ in }
    /// Width used for the PRINT "," zones.
    public var columns: Int = 40

    public static let banner = "\u{93}\n    **** RETROTERM BASIC V2 ****\n\n 64K RAM SYSTEM  38911 BASIC BYTES FREE\n\nREADY.\n"

    public private(set) var state: StepResult = .ready

    public init() {}

    /// Clears the screen and prints the banner.
    public func powerOn() {
        state = .ready
        output(BasicMachine.banner)
    }
}
