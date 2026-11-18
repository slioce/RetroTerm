import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        TabView {
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "textformat") }
            EffectsSettings().tabItem { Label("CRT Effects", systemImage: "tv") }
            TerminalSettings().tabItem { Label("Terminal", systemImage: "terminal") }
        }
        .frame(width: 520, height: 520)
    }
}

private struct EffectRow: View {
    let title: String
    @Binding var on: Bool
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1

    var body: some View {
        HStack {
            Toggle(title, isOn: $on)
                .frame(width: 150, alignment: .leading)
            Slider(value: $value, in: range)
                .disabled(!on)
            Text(String(format: "%.2f", value))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }
}

struct AppearanceSettings: View {
    @EnvironmentObject private var settings: AppSettings

    private var monospaceFamilies: [String] {
        let fm = NSFontManager.shared
        let names = fm.availableFontNames(with: .fixedPitchFontMask) ?? []
        var families = Set<String>()
        for n in names {
            if let f = NSFont(name: n, size: 12), let fam = f.familyName { families.insert(fam) }
        }
        return families.sorted()
    }

    var body: some View {
        Form {
            Section("Phosphor") {
                Picker("Theme", selection: $settings.config.theme) {
                    ForEach(PhosphorTheme.allCases) { Text($0.label).tag($0) }
                }
                if settings.config.theme == .custom {
                    ColorPicker("Text color", selection: Binding(
                        get: { settings.config.customPhosphor.color },
                        set: { settings.config.customPhosphor = RGB(color: $0) }), supportsOpacity: false)
                    ColorPicker("Background color", selection: Binding(
                        get: { settings.config.customBackground.color },
                        set: { settings.config.customBackground = RGB(color: $0) }), supportsOpacity: false)
                }
                Picker("ANSI colors", selection: $settings.config.colorMode) {
                    ForEach(ColorMode.allCases) { Text($0.label).tag($0) }
                }
                Slider(value: $settings.config.brightness, in: 0.5...1.6) { Text("Brightness") }
            }
            Section("Font") {
                Picker("Family", selection: $settings.config.fontName) {
                    ForEach(monospaceFamilies, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Text("Size")
                    Slider(value: $settings.config.fontSize, in: 8...32, step: 1)
                    Text("\(Int(settings.config.fontSize)) pt").frame(width: 44, alignment: .trailing)
                }
                Picker("Rendering", selection: $settings.config.pixelScale) {
                    Text("Bitmap ×2 (chunky pixels)").tag(2)
                    Text("Bitmap ×3").tag(3)
                    Text("Bitmap ×4").tag(4)
                    Text("Native resolution").tag(1)
                }
                Toggle("Antialiasing", isOn: $settings.config.antialias)
                HStack {
                    Text("Line spacing")
                    Slider(value: $settings.config.lineSpacing, in: 0.9...1.6, step: 0.05)
                    Text(String(format: "%.2f", settings.config.lineSpacing)).frame(width: 44, alignment: .trailing)
                }
            }
            Section("Cursor") {
                Picker("Shape", selection: $settings.config.cursorShape) {
                    ForEach(CursorShape.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Blink", isOn: $settings.config.cursorBlink)
            }
            Section("Window") {
                HStack {
                    Text("Screen margin")
                    Slider(value: $settings.config.contentInset, in: 0...80, step: 2)
                    Text("\(Int(settings.config.contentInset)) pt").frame(width: 44, alignment: .trailing)
                }
                Picker("Window resize", selection: $settings.config.screenFit) {
                    ForEach(ScreenFit.allCases) { Text($0.label).tag($0) }
                }
                if settings.config.screenFit != .reflow {
                    HStack {
                        Text("Fixed grid")
                        Spacer()
                        TextField("Cols", value: $settings.config.fixedCols, format: .number)
                            .labelsHidden().frame(width: 56)
                        Text("cols  ×")
                        TextField("Rows", value: $settings.config.fixedRows, format: .number)
                            .labelsHidden().frame(width: 56)
                        Text("rows")
                    }
                    Text("The grid keeps this size and the picture is scaled to the window, like the raster of a real CRT. Handy in full screen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Always show tab bar", isOn: $settings.config.alwaysShowTabBar)
                Toggle("Show boot banner in new tabs", isOn: $settings.config.showBootBanner)
                if settings.config.showBootBanner {
                    TextEditor(text: $settings.config.bootBannerText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 110)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    HStack {
                        Text("Printed in every new tab before the shell starts.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restore default text") { settings.config.bootBannerText = TerminalConfig.defaultBootBanner }
                            .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct EffectsSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Enable CRT effects", isOn: $settings.config.crtEnabled)
                    .toggleStyle(.switch)
                Text("Each effect can be switched off on its own. Everything renders on the GPU with Metal.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Effects") {
                EffectRow(title: "Screen curvature", on: $settings.config.curvatureOn, value: $settings.config.curvature, range: 0...0.03)
                EffectRow(title: "Scanlines", on: $settings.config.scanlinesOn, value: $settings.config.scanlineIntensity)
                HStack {
                    Text("Scanline period").frame(width: 150, alignment: .leading)
                    Slider(value: $settings.config.scanlinePeriod, in: 1...6, step: 0.5).disabled(!settings.config.scanlinesOn)
                    Text(String(format: "%.1f pt", settings.config.scanlinePeriod))
                        .font(.system(.caption, design: .monospaced)).frame(width: 40, alignment: .trailing).foregroundStyle(.secondary)
                }
                EffectRow(title: "Phosphor glow", on: $settings.config.glowOn, value: $settings.config.glowIntensity, range: 0...2)
                EffectRow(title: "Vignette", on: $settings.config.vignetteOn, value: $settings.config.vignetteIntensity)
                EffectRow(title: "Flicker", on: $settings.config.flickerOn, value: $settings.config.flickerIntensity)
                EffectRow(title: "Noise", on: $settings.config.noiseOn, value: $settings.config.noiseIntensity)
                EffectRow(title: "Chromatic aberration", on: $settings.config.chromaticOn, value: $settings.config.chromaticIntensity)
                HStack {
                    Text("Corner radius").frame(width: 150, alignment: .leading)
                    Slider(value: $settings.config.cornerRadius, in: 0...0.15)
                    Text(String(format: "%.2f", settings.config.cornerRadius))
                        .font(.system(.caption, design: .monospaced)).frame(width: 40, alignment: .trailing).foregroundStyle(.secondary)
                }
            }
            .disabled(!settings.config.crtEnabled)
            Section {
                Button("Restore defaults") { settings.reset() }
            }
        }
        .formStyle(.grouped)
    }
}

struct TerminalSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Shell") {
                TextField("Shell path (empty = login shell)", text: $settings.config.shellPath)
                    .font(.system(.body, design: .monospaced))
                Text("Applies to new tabs. Current login shell: \(RetroTermCoreShell.defaultShell)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Behaviour") {
                HStack {
                    Text("Scrollback lines")
                    TextField("", value: $settings.config.scrollbackLines, format: .number)
                        .frame(width: 100)
                }
                Toggle("Use Option as Meta (sends ESC prefix)", isOn: $settings.config.optionAsMeta)
                Toggle("Copy on select", isOn: $settings.config.copyOnSelect)
            }
            Section("Sound") {
                Toggle("Audible bell", isOn: $settings.config.audibleBell)
                Toggle("Visual bell (screen flash)", isOn: $settings.config.visualBell)
                Toggle("Mechanical keyboard click", isOn: $settings.config.keyClickOn)
                Picker("Keyboard", selection: $settings.config.keyClickSound) {
                    ForEach(KeyClickSound.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!settings.config.keyClickOn)
                HStack {
                    Text("Click volume")
                    Slider(value: $settings.config.keyClickVolume, in: 0...1)
                        .disabled(!settings.config.keyClickOn)
                    Text("\(Int(settings.config.keyClickVolume * 100))%").frame(width: 44, alignment: .trailing)
                }
                Text("Recorded samples are CC0 (public domain) tactile-switch keystrokes from Freesound. Held keys do not repeat.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

import RetroTermCore
enum RetroTermCoreShell {
    static let defaultShell = PseudoTerminal.defaultShell()
}
