import AppKit
import Combine
import SwiftUI

/// Tabs of one window.
final class TabManager: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var selectedID: UUID?
    private var cancellables: [UUID: AnyCancellable] = [:]

    var selected: TerminalSession? {
        sessions.first { $0.id == selectedID }
    }

    init() {
        newTab()
    }

    deinit {
        sessions.forEach { $0.terminate() }
    }

    @discardableResult
    func newTab() -> TerminalSession {
        let cwd = selected?.currentDirectory()
        let s = TerminalSession(workingDirectory: cwd)
        s.onExit = { [weak self] session in
            self?.close(session)
        }
        cancellables[s.id] = s.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
        sessions.append(s)
        selectedID = s.id
        return s
    }

    func close(_ session: TerminalSession) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        session.terminate()
        cancellables.removeValue(forKey: session.id)
        sessions.remove(at: idx)
        if selectedID == session.id {
            selectedID = sessions[max(0, min(idx, sessions.count - 1))].id
        }
        if sessions.isEmpty {
            selectedID = nil
            DispatchQueue.main.async {
                NSApp.keyWindow?.performClose(nil)
            }
        }
    }

    func closeSelected() {
        if let s = selected { close(s) }
    }

    func select(_ session: TerminalSession) {
        selectedID = session.id
    }

    func selectNext(_ delta: Int) {
        guard let idx = sessions.firstIndex(where: { $0.id == selectedID }), !sessions.isEmpty else { return }
        let n = sessions.count
        selectedID = sessions[((idx + delta) % n + n) % n].id
    }

    func select(index: Int) {
        guard index >= 0, index < sessions.count else { return }
        selectedID = sessions[index].id
    }

    func move(_ session: TerminalSession, to index: Int) {
        guard let from = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let s = sessions.remove(at: from)
        sessions.insert(s, at: max(0, min(index, sessions.count)))
    }
}

struct TabManagerKey: FocusedValueKey {
    typealias Value = TabManager
}

extension FocusedValues {
    var tabManager: TabManager? {
        get { self[TabManagerKey.self] }
        set { self[TabManagerKey.self] = newValue }
    }
}
