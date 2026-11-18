import SwiftUI
import AppKit

struct TerminalCommands: Commands {
    @FocusedValue(\.tabManager) private var tabs
    @ObservedObject private var settings = AppSettings.shared

    private var view: TerminalNSView? { tabs?.selected?.view }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") { tabs?.newTab() }
                .keyboardShortcut("t", modifiers: .command)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") {
                if let t = tabs, t.sessions.count > 1 {
                    t.closeSelected()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Clear Screen & Scrollback") { view?.clearScrollback(nil) }
                .keyboardShortcut("k", modifiers: .command)
        }
        CommandMenu("Terminal") {
            Button("Scroll to Top") { view?.scrollToTop() }
                .keyboardShortcut(.home, modifiers: .command)
            Button("Scroll to Bottom") { view?.scrollToBottom() }
                .keyboardShortcut(.end, modifiers: .command)
            Button("Page Up") { view?.scrollPage(1) }
                .keyboardShortcut(.pageUp, modifiers: .command)
            Button("Page Down") { view?.scrollPage(-1) }
                .keyboardShortcut(.pageDown, modifiers: .command)
            Divider()
            Button("Reset Terminal") { tabs?.selected?.withTerminal { $0.hardReset() } }
        }
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Bigger Text") { settings.config.fontSize = min(48, settings.config.fontSize + 1) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Smaller Text") { settings.config.fontSize = max(6, settings.config.fontSize - 1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Default Text Size") { settings.config.fontSize = TerminalConfig().fontSize }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Toggle("CRT Effects", isOn: $settings.config.crtEnabled)
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Picker("Phosphor", selection: $settings.config.theme) {
                ForEach(PhosphorTheme.allCases) { Text($0.label).tag($0) }
            }
            Picker("Colors", selection: $settings.config.colorMode) {
                ForEach(ColorMode.allCases) { Text($0.label).tag($0) }
            }
            Picker("Window Resize", selection: $settings.config.screenFit) {
                ForEach(ScreenFit.allCases) { Text($0.label).tag($0) }
            }
            Divider()
            Button("Next Tab") { tabs?.selectNext(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { tabs?.selectNext(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            ForEach(1..<10) { i in
                Button("Tab \(i)") { tabs?.select(index: i - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i)")), modifiers: .command)
            }
        }
    }
}
