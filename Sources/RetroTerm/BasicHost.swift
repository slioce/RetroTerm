import Foundation
import RetroBasic

/// Runs the BASIC console of one session on a private serial queue.
///
/// Keys arrive through `send`/`paste`; a running program is advanced in small slices so the
/// queue never blocks and Ctrl-C can get in between. Every screen access goes through the
/// session's lock inside `TerminalScreen`.
final class BasicHost {
    private let queue = DispatchQueue(label: "RetroTerm.basic", qos: .userInitiated)
    private let console: BasicConsole
    private var cancelled = false   // queue-confined
    /// Called on the main thread when BASIC exits (SYS 64738 or EXIT).
    var onExit: (() -> Void)?

    /// Statements per slice and the pause between slices: a few percent of one core for a busy loop.
    private static let sliceBudget = 32
    private static let slicePause = DispatchTimeInterval.milliseconds(1)

    init(session: TerminalSession) {
        let screen = TerminalScreen(terminal: session.terminal, lock: session.lock)
        console = BasicConsole(machine: BasicMachine(), screen: screen)
    }

    func start() {
        queue.async { [self] in
            console.start()
            after(console.drive(budget: BasicHost.sliceBudget))
        }
    }

    func send(_ bytes: [UInt8]) {
        queue.async { [self] in
            guard !cancelled else { return }
            after(console.handleInput(bytes))
        }
    }

    func paste(_ text: String) {
        queue.async { [self] in
            guard !cancelled else { return }
            after(console.paste(text))
        }
    }

    func setColumns(_ n: Int) {
        queue.async { [self] in console.setColumns(n) }
    }

    func stop() {
        queue.async { [self] in cancelled = true }
    }

    private func after(_ result: DriveResult) {
        switch result {
        case .idle:
            break
        case .moreWork:
            queue.asyncAfter(deadline: .now() + BasicHost.slicePause) { [weak self] in
                guard let self = self, !self.cancelled else { return }
                self.after(self.console.drive(budget: BasicHost.sliceBudget))
            }
        case .exited:
            cancelled = true
            DispatchQueue.main.async { [self] in onExit?() }
        }
    }
}
