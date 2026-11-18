import AVFoundation
import AppKit

/// Keyboard sounds. Two sources: recorded tactile-switch samples (CC0, in Resources/Sounds/Tactile) or a click
/// synthesised at startup. Everything is loaded lazily on the first keypress.
///
/// A sample pack is a folder of WAVs: `press-*.wav` for ordinary keys, `large-*.wav` for big keys (space, return,
/// backspace, tab, modifiers) and optionally `release-*.wav`, played on key up when present.
final class KeyClickPlayer {
    static let shared = KeyClickPlayer()

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var next = 0
    private let sampleRate: Double = 44_100
    private lazy var format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    private var started = false
    private let queue = DispatchQueue(label: "RetroTerm.keyclick", qos: .userInteractive)

    // Synthesised variants.
    private var synthNormal: [AVAudioPCMBuffer] = []
    private var synthHeavy: [AVAudioPCMBuffer] = []

    // Sample pack.
    private var packPress: [AVAudioPCMBuffer] = []
    private var packLarge: [AVAudioPCMBuffer] = []
    private var packRelease: [AVAudioPCMBuffer] = []
    private var packLoaded = false
    private var lastPress = -1
    private var pressedModifiers = NSEvent.ModifierFlags()

    private init() {}

    // MARK: - Events (main thread)

    func keyDown(_ event: NSEvent, config: TerminalConfig) {
        guard !event.isARepeat else { return }   // a held key stays down, no extra click
        play(keyCode: event.keyCode, release: false, config: config)
    }

    func keyUp(_ event: NSEvent, config: TerminalConfig) {
        play(keyCode: event.keyCode, release: true, config: config)
    }

    /// Modifier keys arrive as flag changes; work out whether the key went down or up.
    func flagsChanged(_ event: NSEvent, config: TerminalConfig) {
        let flag: NSEvent.ModifierFlags
        switch Int(event.keyCode) {
        case 56, 60: flag = .shift
        case 58, 61: flag = .option
        case 59, 62: flag = .control
        case 54, 55: flag = .command
        case 57: flag = .capsLock
        case 63: flag = .function
        default: return
        }
        let now = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let wasDown = pressedModifiers.contains(flag)
        let isDown = now.contains(flag)
        pressedModifiers = now
        if isDown == wasDown { return }
        play(keyCode: event.keyCode, release: !isDown, config: config)
    }

    /// Keys with a bigger keycap, which sound deeper.
    private static func isLarge(_ keyCode: UInt16) -> Bool {
        switch Int(keyCode) {
        case 36, 49, 51, 76, 48, 117,            // return, space, backspace, keypad enter, tab, forward delete
             54, 55, 56, 57, 58, 59, 60, 61, 62: // modifiers
            return true
        default:
            return false
        }
    }

    private func play(keyCode: UInt16, release: Bool, config: TerminalConfig) {
        let volume = config.keyClickVolume
        guard volume > 0 else { return }
        let source = config.keyClickSound
        let large = KeyClickPlayer.isLarge(keyCode)
        queue.async { [self] in
            start()
            guard started, !players.isEmpty else { return }
            let buffer: AVAudioPCMBuffer?
            switch source {
            case .tactile: buffer = packBuffer(large: large, release: release) ?? synthBuffer(large: large, release: release)
            case .synth: buffer = synthBuffer(large: large, release: release)
            }
            guard let buffer = buffer else { return }
            let p = players[next]
            next = (next + 1) % players.count
            p.stop()
            p.volume = Float(volume) * Float.random(in: 0.85...1.0)
            p.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            p.play()
        }
    }

    // MARK: - Engine

    private func start() {
        guard !started else { return }
        started = true
        for _ in 0..<10 {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: format)
            players.append(p)
        }
        do {
            try engine.start()
        } catch {
            started = false
        }
    }

    // MARK: - Sample pack

    /// Folder holding the pack: the app bundle, or the source tree when run from `swift run`.
    private static func packDirectory(named name: String) -> URL? {
        let fm = FileManager.default
        if let r = Bundle.main.resourceURL?.appendingPathComponent("Sounds/\(name)"), fm.fileExists(atPath: r.path) {
            return r
        }
        var dir = Bundle.main.bundleURL
        for _ in 0..<6 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent("Resources/Sounds/\(name)")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func loadPackIfNeeded() {
        guard !packLoaded else { return }
        packLoaded = true
        guard let dir = KeyClickPlayer.packDirectory(named: "Tactile"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "wav" {
            guard let b = KeyClickPlayer.load(url, as: format) else { continue }
            let name = url.lastPathComponent
            if name.hasPrefix("press-") { packPress.append(b) }
            else if name.hasPrefix("large-") { packLarge.append(b) }
            else if name.hasPrefix("release-") { packRelease.append(b) }
        }
    }

    /// Reads a WAV into a buffer of the engine format, resampling if needed.
    private static func load(_ url: URL, as format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let src = file.processingFormat
        guard let raw = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: raw)) != nil else { return nil }
        if src.sampleRate == format.sampleRate && src.channelCount == format.channelCount { return raw }
        guard let conv = AVAudioConverter(from: src, to: format) else { return nil }
        let frames = AVAudioFrameCount(Double(raw.frameLength) * format.sampleRate / src.sampleRate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        var consumed = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return raw
        }
        return error == nil ? out : nil
    }

    private func packBuffer(large: Bool, release: Bool) -> AVAudioPCMBuffer? {
        loadPackIfNeeded()
        if release { return packRelease.randomElement() }   // nil when the pack has no release sounds
        if large, let b = packLarge.randomElement() { return b }
        guard !packPress.isEmpty else { return nil }
        // Avoid playing the same sample twice in a row; it is what makes a loop sound fake.
        var i = Int.random(in: 0..<packPress.count)
        if packPress.count > 1 && i == lastPress { i = (i + 1) % packPress.count }
        lastPress = i
        return packPress[i]
    }

    // MARK: - Synthesised fallback

    private func synthBuffer(large: Bool, release: Bool) -> AVAudioPCMBuffer? {
        if synthNormal.isEmpty {
            synthNormal = (0..<4).map { i in render(pitch: 1.0 + Double(i) * 0.06 - 0.09, heavy: false) }
            synthHeavy = (0..<2).map { i in render(pitch: 0.9 + Double(i) * 0.08, heavy: true) }
        }
        if release { return nil }   // the synthesised keyboard only clicks on the way down
        return large ? synthHeavy.randomElement() : synthNormal.randomElement()
    }

    private func render(pitch: Double, heavy: Bool) -> AVAudioPCMBuffer {
        let duration = heavy ? 0.09 : 0.06
        let n = Int(sampleRate * duration)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        let out = buf.floatChannelData![0]

        var rng = SystemRandomNumberGenerator()
        var prevNoise = 0.0
        var hp = 0.0
        let thockHz = (heavy ? 140.0 : 190.0) * pitch
        let ringHz = (heavy ? 900.0 : 1400.0) * pitch
        let bottomAt = Int(sampleRate * (heavy ? 0.022 : 0.016))
        var peak = 0.0
        var samples = [Double](repeating: 0, count: n)

        for i in 0..<n {
            let t = Double(i) / sampleRate
            let noise = Double.random(in: -1...1, using: &rng)
            hp = 0.85 * (hp + noise - prevNoise)
            prevNoise = noise
            var s = hp * exp(-t / 0.0022)
            if i >= bottomAt {
                let t2 = Double(i - bottomAt) / sampleRate
                s += hp * exp(-t2 / 0.0015) * 0.55
            }
            s += sin(2 * .pi * thockHz * t) * exp(-t / (heavy ? 0.020 : 0.012)) * (heavy ? 0.9 : 0.5)
            s += sin(2 * .pi * ringHz * t) * exp(-t / 0.003) * 0.35
            samples[i] = s
            peak = max(peak, abs(s))
        }
        let gain = peak > 0 ? 0.8 / peak : 1
        for i in 0..<n {
            let fade = min(1.0, Double(n - i) / (sampleRate * 0.004))
            out[i] = Float(samples[i] * gain * fade)
        }
        return buf
    }
}
