import SwiftUI
import Combine

enum PhosphorTheme: String, Codable, CaseIterable, Identifiable {
    case green, amber, white, c64, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .green: return "Green phosphor (P1)"
        case .amber: return "Amber phosphor (P3)"
        case .white: return "White phosphor (P4)"
        case .c64: return "C64"
        case .custom: return "Custom"
        }
    }
}

enum ColorMode: String, Codable, CaseIterable, Identifiable {
    case monochrome, tinted, full
    var id: String { rawValue }
    var label: String {
        switch self {
        case .monochrome: return "Monochrome (authentic)"
        case .tinted: return "Tinted ANSI colors"
        case .full: return "Full ANSI colors"
        }
    }
}

/// What happens to the terminal grid when the window changes size.
enum ScreenFit: String, Codable, CaseIterable, Identifiable {
    case reflow, stretch, fit
    var id: String { rawValue }
    var label: String {
        switch self {
        case .reflow: return "Reflow text (add columns and rows)"
        case .stretch: return "Fixed grid, stretch to fill the window"
        case .fit: return "Fixed grid, keep aspect ratio"
        }
    }
}

/// Where the keyboard click comes from.
enum KeyClickSound: String, Codable, CaseIterable, Identifiable {
    case tactile, synth
    var id: String { rawValue }
    var label: String {
        switch self {
        case .tactile: return "Tactile switches (recorded samples)"
        case .synth: return "Synthesised click"
        }
    }
}

enum CursorShape: String, Codable, CaseIterable, Identifiable {
    case block, underline, bar
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct RGB: Codable, Equatable {
    var r: Double, g: Double, b: Double
    var simd: SIMD3<Float> { SIMD3(Float(r), Float(g), Float(b)) }
    var color: Color { Color(red: r, green: g, blue: b) }
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        r = Double(ns.redComponent); g = Double(ns.greenComponent); b = Double(ns.blueComponent)
    }
}

struct TerminalConfig: Codable, Equatable {
    // Appearance
    var theme: PhosphorTheme = .green
    var customPhosphor = RGB(0.2, 1.0, 0.35)
    var customBackground = RGB(0.02, 0.07, 0.03)
    var colorMode: ColorMode = .monochrome
    var fontName = "Menlo"
    var fontSize: Double = 15
    var pixelScale: Int = 2          // bitmap look: raster at size/pixelScale, upscale with nearest filtering
    var antialias = false
    var lineSpacing: Double = 1.1
    var cursorShape: CursorShape = .block
    var cursorBlink = true
    var contentInset: Double = 28
    var showBootBanner = true
    var bootBannerText = TerminalConfig.defaultBootBanner
    var alwaysShowTabBar = false
    var screenFit: ScreenFit = .stretch
    var fixedCols: Int = 80
    var fixedRows: Int = 24

    // CRT effects
    var crtEnabled = true
    var curvatureOn = true
    var curvature: Double = 0.008
    var scanlinesOn = true
    var scanlineIntensity: Double = 0.35
    var scanlinePeriod: Double = 2.0      // in points
    var glowOn = true
    var glowIntensity: Double = 0.9
    var vignetteOn = true
    var vignetteIntensity: Double = 0.55
    var flickerOn = false
    var flickerIntensity: Double = 0.5
    var noiseOn = false
    var noiseIntensity: Double = 0.4
    var chromaticOn = false
    var chromaticIntensity: Double = 0.5
    var cornerRadius: Double = 0.05
    var brightness: Double = 1.0

    // Terminal
    var shellPath = ""                 // empty = login shell
    var scrollbackLines: Int = 10_000
    var optionAsMeta = true
    var audibleBell = true
    var visualBell = true
    var copyOnSelect = false
    var keyClickOn = true
    var keyClickVolume: Double = 0.5
    var keyClickSound: KeyClickSound = .tactile

    var phosphor: RGB {
        switch theme {
        case .green: return RGB(0.20, 1.0, 0.35)
        case .amber: return RGB(1.0, 0.69, 0.0)
        case .white: return RGB(0.90, 0.92, 0.95)
        case .c64: return RGB(0.55, 0.50, 0.92)
        case .custom: return customPhosphor
        }
    }
    var background: RGB {
        switch theme {
        case .green: return RGB(0.015, 0.06, 0.025)
        case .amber: return RGB(0.07, 0.04, 0.0)
        case .white: return RGB(0.04, 0.04, 0.05)
        case .c64: return RGB(0.17, 0.13, 0.45)
        case .custom: return customBackground
        }
    }

    /// Text fed to a new tab before the shell starts. Plain newlines; the session turns them into CR LF.
    static let defaultBootBanner = """

      *** RETROTERM v1.1.1 ***

      (C) 1984 Alessandro Lioce Systems

    """

    init() {}

    // Tolerant decoding: missing keys keep their defaults so old preferences survive upgrades.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ key: CodingKeys, _ v: inout T) { if let x = try? c.decodeIfPresent(T.self, forKey: key) { v = x } }
        d(.theme, &theme); d(.customPhosphor, &customPhosphor); d(.customBackground, &customBackground)
        d(.colorMode, &colorMode); d(.fontName, &fontName); d(.fontSize, &fontSize); d(.pixelScale, &pixelScale)
        d(.antialias, &antialias); d(.lineSpacing, &lineSpacing); d(.cursorShape, &cursorShape); d(.cursorBlink, &cursorBlink)
        d(.contentInset, &contentInset); d(.showBootBanner, &showBootBanner); d(.bootBannerText, &bootBannerText); d(.alwaysShowTabBar, &alwaysShowTabBar)
        d(.screenFit, &screenFit); d(.fixedCols, &fixedCols); d(.fixedRows, &fixedRows)
        d(.crtEnabled, &crtEnabled); d(.curvatureOn, &curvatureOn); d(.curvature, &curvature)
        d(.scanlinesOn, &scanlinesOn); d(.scanlineIntensity, &scanlineIntensity); d(.scanlinePeriod, &scanlinePeriod)
        d(.glowOn, &glowOn); d(.glowIntensity, &glowIntensity); d(.vignetteOn, &vignetteOn); d(.vignetteIntensity, &vignetteIntensity)
        d(.flickerOn, &flickerOn); d(.flickerIntensity, &flickerIntensity); d(.noiseOn, &noiseOn); d(.noiseIntensity, &noiseIntensity)
        d(.chromaticOn, &chromaticOn); d(.chromaticIntensity, &chromaticIntensity); d(.cornerRadius, &cornerRadius); d(.brightness, &brightness)
        d(.shellPath, &shellPath); d(.scrollbackLines, &scrollbackLines); d(.optionAsMeta, &optionAsMeta)
        d(.audibleBell, &audibleBell); d(.visualBell, &visualBell); d(.copyOnSelect, &copyOnSelect)
        d(.keyClickOn, &keyClickOn); d(.keyClickVolume, &keyClickVolume); d(.keyClickSound, &keyClickSound)
        // Migration: earlier builds used a 0...0.25 scale whose defaults (0.07, 0.03) visibly bent text lines.
        // Anything at or above the new slider maximum comes from that scale; reset it to the new default.
        if curvature >= 0.03 { curvature = TerminalConfig().curvature }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private static let key = "RetroTerm.config"

    @Published var config: TerminalConfig {
        didSet { save() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: AppSettings.key),
           let cfg = try? JSONDecoder().decode(TerminalConfig.self, from: data) {
            config = cfg
        } else {
            config = TerminalConfig()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: AppSettings.key)
        }
    }

    func reset() { config = TerminalConfig() }
}
