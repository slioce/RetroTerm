import SwiftUI
import AppKit

struct TerminalWindowView: View {
    @StateObject private var tabs = TabManager()
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            if tabs.sessions.count > 1 || settings.config.alwaysShowTabBar {
                TabBarView(tabs: tabs)
            }
            TerminalContainer(tabs: tabs)
        }
        .background(Color.black)
        .ignoresSafeArea()
        .focusedSceneValue(\.tabManager, tabs)
        .navigationTitle(tabs.selected?.title ?? "RetroTerm")
        .frame(minWidth: 400, minHeight: 240)
    }
}

/// Hosts the selected session's NSView, swapping it when the tab changes.
struct TerminalContainer: NSViewRepresentable {
    @ObservedObject var tabs: TabManager

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        return v
    }

    func updateNSView(_ container: NSView, context: Context) {
        let wanted = tabs.selected?.view
        if container.subviews.first === wanted { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        guard let v = wanted else { return }
        v.frame = container.bounds
        v.autoresizingMask = [.width, .height]
        container.addSubview(v)
        DispatchQueue.main.async {
            v.window?.makeFirstResponder(v)
        }
    }
}

struct TabBarView: View {
    @ObservedObject var tabs: TabManager
    @EnvironmentObject private var settings: AppSettings

    private var phosphor: Color { settings.config.phosphor.color }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs.sessions) { session in
                tab(session)
            }
            Button(action: { tabs.newTab() }) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(phosphor.opacity(0.7))
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .help("New Tab (⌘T)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color(white: 0.06))
        .overlay(alignment: .bottom) {
            Rectangle().fill(phosphor.opacity(0.25)).frame(height: 1)
        }
    }

    private func tab(_ session: TerminalSession) -> some View {
        let selected = tabs.selectedID == session.id
        return HStack(spacing: 6) {
            Text(session.title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: { tabs.close(session) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .opacity(selected ? 0.8 : 0.4)
        }
        .foregroundStyle(selected ? phosphor : phosphor.opacity(0.55))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(minWidth: 90, maxWidth: 220)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(selected ? phosphor.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { tabs.select(session) }
    }
}
