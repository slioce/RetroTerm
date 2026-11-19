import AppKit
import Metal
import MetalKit
import QuartzCore
import RetroTermCore

struct GridVertex {
    var pos: SIMD2<Float>
    var uv: SIMD2<Float>
    var color: SIMD4<Float>
    var kind: SIMD4<Float>
}

struct GridUniforms {
    var viewport: SIMD2<Float>
    var origin: SIMD2<Float>
    var scale: SIMD2<Float>
    var sharp: Float = 0      // 1 = bitmap glyphs: snap to texels with a one-pixel transition (sharp bilinear)
    var pad: Float = 0
}

struct BlurUniforms {
    var direction: SIMD2<Float>
    var pad: SIMD2<Float> = .zero
}

struct CRTUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var curvature: Float
    var scanline: Float
    var scanlinePeriod: Float
    var glow: Float
    var vignette: Float
    var flicker: Float
    var noise: Float
    var brightness: Float
    var chromatic: Float
    var cornerRadius: Float
    var bellFlash: Float
    var pad: SIMD2<Float> = .zero
}

/// Snapshot of what the view shows: visible lines (scrollback + screen) and cursor.
struct TerminalSnapshot {
    var lines: [Line]
    var firstAbsoluteLine: Int
    var cols: Int
    var rows: Int
    var cursorX: Int
    var cursorY: Int          // row within `lines`; may be >= rows when scrolled back
    var cursorVisible: Bool
    var cursorStyle: Int
    var cursorBlinkOverride: Bool?
    var reverseVideo: Bool
    var generation: UInt64
}

struct TextPosition: Comparable, Equatable {
    var line: Int
    var col: Int
    static func < (a: TextPosition, b: TextPosition) -> Bool {
        a.line < b.line || (a.line == b.line && a.col < b.col)
    }
}

struct Selection: Equatable {
    var start: TextPosition
    var end: TextPosition   // inclusive
    var normalized: Selection {
        start <= end ? self : Selection(start: end, end: start)
    }
    func contains(line: Int, col: Int) -> Bool {
        let n = normalized
        if line < n.start.line || line > n.end.line { return false }
        if n.start.line == n.end.line { return col >= n.start.col && col <= n.end.col }
        if line == n.start.line { return col >= n.start.col }
        if line == n.end.line { return col <= n.end.col }
        return true
    }
}

struct RenderState {
    var snapshot: TerminalSnapshot
    var selection: Selection?
    var focused: Bool
    var blinkOn: Bool
    var preedit: String
    var bellFlash: Float
}

final class Renderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let gridPipeline: MTLRenderPipelineState
    private let downsamplePipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private let crtPipeline: MTLRenderPipelineState
    private let nearestSampler: MTLSamplerState
    private let linearSampler: MTLSamplerState

    private(set) var atlas: GlyphAtlas?
    private var atlasSignature = ""
    private var sceneTexture: MTLTexture?
    private var bloomA: MTLTexture?
    private var bloomB: MTLTexture?

    private var vertexBuffers: [MTLBuffer] = []
    private var bufferIndex = 0
    private let inflight = DispatchSemaphore(value: 3)
    private var vertices: [GridVertex] = []
    private var vertexCount = 0

    /// Device-pixel metrics of the grid.
    private(set) var cellWidth: Int = 8
    private(set) var cellHeight: Int = 16
    private(set) var pixelScale: Int = 1
    var originX: Int = 0
    var originY: Int = 0
    /// Extra scaling applied to every cell around the origin (fixed-grid modes stretch the raster to the window).
    var cellScale = SIMD2<Float>(1, 1)
    /// How much the raster is magnified in fixed-grid modes; scanlines scale with it so they stay proportional to the text.
    var rasterMagnification: Float = 1

    private var palette: [SIMD3<Float>] = (0..<256).map { i in
        let (r, g, b) = Palette.xterm256(i)
        return SIMD3(Float(r) / 255, Float(g) / 255, Float(b) / 255)
    }

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue

        let library: MTLLibrary
        do {
            let opts = MTLCompileOptions()
            opts.fastMathEnabled = true
            library = try device.makeLibrary(source: ShaderSource.source, options: opts)
        } catch {
            NSLog("RetroTerm: shader compile failed: \(error)")
            return nil
        }

        func pipeline(vertex: String, fragment: String, blend: Bool) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            if blend {
                let a = d.colorAttachments[0]!
                a.isBlendingEnabled = true
                a.rgbBlendOperation = .add
                a.alphaBlendOperation = .add
                a.sourceRGBBlendFactor = .one
                a.sourceAlphaBlendFactor = .one
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let g = pipeline(vertex: "grid_vertex", fragment: "grid_fragment", blend: true),
              let ds = pipeline(vertex: "fs_vertex", fragment: "downsample_fragment", blend: false),
              let bl = pipeline(vertex: "fs_vertex", fragment: "blur_fragment", blend: false),
              let crt = pipeline(vertex: "fs_vertex", fragment: "crt_fragment", blend: false) else { return nil }
        gridPipeline = g
        downsamplePipeline = ds
        blurPipeline = bl
        crtPipeline = crt

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .nearest; sd.magFilter = .nearest
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        nearestSampler = device.makeSamplerState(descriptor: sd)!
        sd.minFilter = .linear; sd.magFilter = .linear
        linearSampler = device.makeSamplerState(descriptor: sd)!

        for _ in 0..<3 {
            vertexBuffers.append(device.makeBuffer(length: 1 << 20, options: .storageModeShared)!)
        }
    }

    // MARK: - Configuration

    /// Builds the glyph atlas for the configured font. `magnification` enlarges the font so fixed-grid modes
    /// rasterise glyphs at the size they are displayed instead of upscaling them.
    @discardableResult
    func configure(config: TerminalConfig, backingScale: CGFloat, magnification: CGFloat = 1) -> Bool {
        let ps = max(1, min(4, config.pixelScale))
        let fontPx = CGFloat(config.fontSize) * backingScale * magnification
        let rasterSize = (fontPx / CGFloat(ps) * 2).rounded() / 2
        let sig = "\(config.fontName)|\(rasterSize)|\(ps)|\(config.antialias)|\(config.lineSpacing)"
        if sig == atlasSignature, atlas != nil { return false }
        atlasSignature = sig
        let a = GlyphAtlas(device: device, fontName: config.fontName, pixelSize: rasterSize,
                           lineSpacing: CGFloat(config.lineSpacing), antialias: config.antialias)
        atlas = a
        pixelScale = ps
        cellWidth = a.cellWidth * ps
        cellHeight = a.cellHeight * ps
        return true
    }

    private func resetAtlas() {
        atlasSignature = ""
    }

    private func ensureTextures(width: Int, height: Int) {
        if let s = sceneTexture, s.width == width, s.height == height { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: max(1, width), height: max(1, height), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        sceneTexture = device.makeTexture(descriptor: d)
        let bw = max(1, width / 4), bh = max(1, height / 4)
        let bd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: bw, height: bh, mipmapped: false)
        bd.usage = [.renderTarget, .shaderRead]
        bd.storageMode = .private
        bloomA = device.makeTexture(descriptor: bd)
        bloomB = device.makeTexture(descriptor: bd)
    }

    // MARK: - Colour resolution

    private struct Theme {
        var phosphor: SIMD3<Float>
        var background: SIMD3<Float>
        var mode: ColorMode
    }

    private func luma(_ c: SIMD3<Float>) -> Float {
        0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
    }

    private func rgb(_ c: TermColor) -> SIMD3<Float>? {
        switch c {
        case .default: return nil
        case .indexed(let i): return palette[Int(i)]
        case .rgb(let r, let g, let b): return SIMD3(Float(r) / 255, Float(g) / 255, Float(b) / 255)
        }
    }

    private func resolveFg(_ c: TermColor, theme: Theme) -> SIMD3<Float> {
        guard let real = rgb(c) else { return theme.phosphor }
        // Dim colours fade towards the screen background, not towards black: on a near-black
        // background the two are the same, on a bright one (Commodore 64) they would vanish.
        switch theme.mode {
        case .monochrome:
            let l = luma(real)
            return simd_mix(theme.background, theme.phosphor, SIMD3(repeating: 0.38 + 0.62 * pow(l, 0.7)))
        case .tinted:
            let l = luma(real)
            return real * 0.45 + simd_mix(theme.background, theme.phosphor, SIMD3(repeating: 0.3 + 0.7 * l)) * 0.55
        case .full:
            return real
        }
    }

    private func resolveBg(_ c: TermColor, theme: Theme) -> SIMD3<Float> {
        guard let real = rgb(c) else { return theme.background }
        switch theme.mode {
        case .monochrome:
            let l = luma(real)
            return theme.background + theme.phosphor * (l * 0.85)
        case .tinted:
            let l = luma(real)
            return theme.background + (real * 0.45 + theme.phosphor * l * 0.55) * 0.9
        case .full:
            return real
        }
    }

    // MARK: - Vertex building

    private func quad(_ x: Float, _ y: Float, _ w: Float, _ h: Float, color: SIMD4<Float>,
                      uv: (Float, Float, Float, Float) = (0, 0, 0, 0), kind: Float = 0) {
        let k = SIMD4<Float>(kind, 0, 0, 0)
        let (u0, v0, u1, v1) = uv
        let a = GridVertex(pos: SIMD2(x, y), uv: SIMD2(u0, v0), color: color, kind: k)
        let b = GridVertex(pos: SIMD2(x + w, y), uv: SIMD2(u1, v0), color: color, kind: k)
        let c = GridVertex(pos: SIMD2(x, y + h), uv: SIMD2(u0, v1), color: color, kind: k)
        let d = GridVertex(pos: SIMD2(x + w, y + h), uv: SIMD2(u1, v1), color: color, kind: k)
        vertices.append(a); vertices.append(b); vertices.append(c)
        vertices.append(b); vertices.append(d); vertices.append(c)
    }

    private func buildVertices(state: RenderState, config: TerminalConfig) {
        guard let atlas = atlas else { return }
        vertices.removeAll(keepingCapacity: true)
        let snap = state.snapshot
        let theme = Theme(phosphor: config.phosphor.simd, background: config.background.simd, mode: config.colorMode)
        let cw = Float(cellWidth), ch = Float(cellHeight)
        let ox = Float(originX), oy = Float(originY)
        let ps = Float(pixelScale)
        let thickness = max(1, Float(pixelScale))

        let defaultBg = snap.reverseVideo ? theme.phosphor : theme.background
        let cursorBlinks = snap.cursorBlinkOverride ?? config.cursorBlink
        let cursorShown = snap.cursorVisible && snap.cursorY < snap.rows && (state.focused ? (!cursorBlinks || state.blinkOn) : true)
        var cursorShape = config.cursorShape
        switch snap.cursorStyle {
        case 1, 2: cursorShape = .block
        case 3, 4: cursorShape = .underline
        case 5, 6: cursorShape = .bar
        default: break
        }

        struct Resolved { var fg: SIMD3<Float>; var bg: SIMD3<Float>; var isDefaultBg: Bool }

        func resolve(_ cell: Cell, line: Int, col: Int) -> Resolved {
            let attrs = cell.style.attrs
            var fg = resolveFg(cell.style.fg, theme: theme)
            var bg = resolveBg(cell.style.bg, theme: theme)
            var isDefaultBg = cell.style.bg == .default
            if attrs.contains(.bold) {
                fg = simd_mix(fg, SIMD3<Float>(1, 1, 1), SIMD3<Float>(repeating: 0.22)) * 1.08
            }
            if attrs.contains(.dim) { fg *= 0.55 }
            if snap.reverseVideo { swap(&fg, &bg); isDefaultBg = false }
            if attrs.contains(.inverse) { swap(&fg, &bg); isDefaultBg = false }
            if let sel = state.selection, sel.contains(line: line, col: col) { swap(&fg, &bg); isDefaultBg = false }
            if attrs.contains(.invisible) { fg = bg }
            return Resolved(fg: fg, bg: bg, isDefaultBg: isDefaultBg)
        }

        // Pass 1: backgrounds (merged runs).
        for row in 0..<min(snap.rows, snap.lines.count) {
            let line = snap.lines[row]
            let absLine = snap.firstAbsoluteLine + row
            let y = oy + Float(row) * ch
            var runStart = 0
            var runColor: SIMD3<Float>? = nil
            func flush(_ end: Int) {
                if let c = runColor, end > runStart {
                    quad(ox + Float(runStart) * cw, y, Float(end - runStart) * cw, ch, color: SIMD4(c, 1))
                }
            }
            let count = min(snap.cols, line.cells.count)
            for col in 0..<snap.cols {
                let r: Resolved
                if col < count {
                    r = resolve(line.cells[col], line: absLine, col: col)
                } else {
                    r = Resolved(fg: theme.phosphor, bg: defaultBg, isDefaultBg: !snap.reverseVideo)
                }
                let c: SIMD3<Float>? = (r.isDefaultBg && r.bg == defaultBg) ? nil : r.bg
                if c != runColor {
                    flush(col)
                    runStart = col
                    runColor = c
                }
            }
            flush(snap.cols)
        }

        // Pass 2: glyphs and decorations.
        for row in 0..<min(snap.rows, snap.lines.count) {
            let line = snap.lines[row]
            let absLine = snap.firstAbsoluteLine + row
            let y = oy + Float(row) * ch
            let count = min(snap.cols, line.cells.count)
            var col = 0
            while col < count {
                let cell = line.cells[col]
                let attrs = cell.style.attrs
                if cell.isWideSpacer { col += 1; continue }
                let cells = cell.isWide ? 2 : 1
                let isCursorCell = cursorShown && row == snap.cursorY && col == snap.cursorX && cursorShape == .block && state.focused
                var r = resolve(cell, line: absLine, col: col)
                if isCursorCell { swap(&r.fg, &r.bg) }
                let x = ox + Float(col) * cw
                let w = Float(cells) * cw

                if isCursorCell {
                    quad(x, y, w, ch, color: SIMD4(r.bg, 1))
                }

                if !(cell.scalar == " " && cell.combining == nil) && !attrs.contains(.invisible) {
                    if let e = atlas.entry(for: cell.text, bold: attrs.contains(.bold), italic: attrs.contains(.italic), cells: cells) {
                        if !e.isEmpty {
                            quad(x, y, w, ch, color: SIMD4(r.fg, 1), uv: (e.u0, e.v0, e.u1, e.v1), kind: e.isColor ? 2 : 1)
                        }
                    } else {
                        resetAtlas()
                    }
                }
                if attrs.contains(.underline) {
                    let uy = y + min(ch - thickness, Float(atlas.ascent) * ps + ps)
                    quad(x, uy, w, thickness, color: SIMD4(r.fg, 1))
                }
                if attrs.contains(.strikethrough) {
                    let sy = y + (Float(atlas.ascent) * ps * 0.65).rounded()
                    quad(x, sy, w, thickness, color: SIMD4(r.fg, 1))
                }
                col += cells
            }
        }

        // Cursor (non-block shapes, unfocused outline).
        if cursorShown && snap.cursorY < snap.lines.count {
            let cx = ox + Float(snap.cursorX) * cw
            let cy = oy + Float(snap.cursorY) * ch
            let lineCells = snap.lines[snap.cursorY].cells
            let under = snap.cursorX < lineCells.count ? lineCells[snap.cursorX] : Cell.blank
            let w = under.isWide ? cw * 2 : cw
            let color = SIMD4(theme.phosphor, 1)
            let t = max(thickness, ps)
            if !state.focused {
                quad(cx, cy, w, t, color: color)
                quad(cx, cy + ch - t, w, t, color: color)
                quad(cx, cy, t, ch, color: color)
                quad(cx + w - t, cy, t, ch, color: color)
            } else {
                switch cursorShape {
                case .block:
                    if under.scalar == " " && under.combining == nil {
                        // already drawn? only when a glyph loop hit it; blank cells are skipped, so draw here
                        quad(cx, cy, w, ch, color: color)
                    }
                case .underline:
                    quad(cx, cy + ch - t * 2, w, t * 2, color: color)
                case .bar:
                    quad(cx, cy, t, ch, color: color)
                }
            }
        }

        // IME pre-edit text, drawn at the cursor with an underline.
        if !state.preedit.isEmpty && snap.cursorY < snap.rows {
            var col = snap.cursorX
            let y = oy + Float(snap.cursorY) * ch
            for ch0 in state.preedit {
                let text = String(ch0)
                let width = ch0.unicodeScalars.first.map { CharWidth.width($0) } ?? 1
                let cells = max(1, width)
                if col + cells > snap.cols { break }
                let x = ox + Float(col) * cw
                let w = Float(cells) * cw
                quad(x, y, w, ch, color: SIMD4(theme.background, 1))
                if let e = atlas.entry(for: text, bold: false, italic: false, cells: cells), !e.isEmpty {
                    quad(x, y, w, ch, color: SIMD4(theme.phosphor, 1), uv: (e.u0, e.v0, e.u1, e.v1), kind: e.isColor ? 2 : 1)
                }
                quad(x, y + ch - thickness, w, thickness, color: SIMD4(theme.phosphor, 1))
                col += cells
            }
        }

        vertexCount = vertices.count
    }

    // MARK: - Frame

    func render(state: RenderState, config: TerminalConfig, in view: MTKView, rebuild: Bool) {
        guard let drawable = view.currentDrawable, let atlas = atlas else { return }
        let width = Int(view.drawableSize.width), height = Int(view.drawableSize.height)
        guard width > 0, height > 0 else { return }
        ensureTextures(width: width, height: height)
        guard let scene = sceneTexture, let bloomA = bloomA, let bloomB = bloomB else { return }

        inflight.wait()
        if rebuild || vertexCount == 0 {
            buildVertices(state: state, config: config)
            if atlas.isFull { resetAtlas() }
        }

        // Upload vertices.
        bufferIndex = (bufferIndex + 1) % vertexBuffers.count
        let needed = max(1, vertexCount) * MemoryLayout<GridVertex>.stride
        if vertexBuffers[bufferIndex].length < needed {
            vertexBuffers[bufferIndex] = device.makeBuffer(length: needed * 2, options: .storageModeShared)!
        }
        let vb = vertexBuffers[bufferIndex]
        if vertexCount > 0 {
            vertices.withUnsafeBytes { raw in
                vb.contents().copyMemory(from: raw.baseAddress!, byteCount: needed)
            }
        }

        guard let cmd = queue.makeCommandBuffer() else { inflight.signal(); return }
        cmd.addCompletedHandler { [inflight] _ in inflight.signal() }

        let bg = config.background.simd
        let clear = MTLClearColor(red: Double(bg.x), green: Double(bg.y), blue: Double(bg.z), alpha: 1)

        // Pass 1: grid → scene
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = scene
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = clear
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
            enc.setRenderPipelineState(gridPipeline)
            let bitmap = pixelScale > 1
            var u = GridUniforms(viewport: SIMD2(Float(width), Float(height)),
                                 origin: SIMD2(Float(originX), Float(originY)), scale: cellScale, sharp: bitmap ? 1 : 0)
            enc.setVertexBuffer(vb, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<GridUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<GridUniforms>.stride, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            // Bitmap glyphs are magnified in the shader; sharp bilinear keeps their pixels square at any scale.
            enc.setFragmentSamplerState(bitmap || config.antialias ? linearSampler : nearestSampler, index: 0)
            if vertexCount > 0 {
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
            }
            enc.endEncoding()
        }

        let effects = config.crtEnabled
        let glow: Float = effects && config.glowOn ? Float(config.glowIntensity) : 0

        // Pass 2: bloom
        if glow > 0 {
            func fullscreen(_ pipeline: MTLRenderPipelineState, src: MTLTexture, dst: MTLTexture, blur: SIMD2<Float>?) {
                let d = MTLRenderPassDescriptor()
                d.colorAttachments[0].texture = dst
                d.colorAttachments[0].loadAction = .dontCare
                d.colorAttachments[0].storeAction = .store
                guard let enc = cmd.makeRenderCommandEncoder(descriptor: d) else { return }
                enc.setRenderPipelineState(pipeline)
                enc.setFragmentTexture(src, index: 0)
                if let b = blur {
                    var u = BlurUniforms(direction: b)
                    enc.setFragmentBytes(&u, length: MemoryLayout<BlurUniforms>.stride, index: 0)
                }
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
            fullscreen(downsamplePipeline, src: scene, dst: bloomA, blur: nil)
            fullscreen(blurPipeline, src: bloomA, dst: bloomB, blur: SIMD2(1, 0))
            fullscreen(blurPipeline, src: bloomB, dst: bloomA, blur: SIMD2(0, 1))
        }

        // Pass 3: CRT composite → drawable
        let scale = Float(view.window?.backingScaleFactor ?? 2)
        var u = CRTUniforms(
            resolution: SIMD2(Float(width), Float(height)),
            time: Float(CACurrentMediaTime().truncatingRemainder(dividingBy: 1000)),
            curvature: effects && config.curvatureOn ? Float(config.curvature) : 0,
            scanline: effects && config.scanlinesOn ? Float(config.scanlineIntensity) : 0,
            scanlinePeriod: max(1, Float(config.scanlinePeriod) * scale * rasterMagnification),
            glow: glow,
            vignette: effects && config.vignetteOn ? Float(config.vignetteIntensity) : 0,
            flicker: effects && config.flickerOn ? Float(config.flickerIntensity) : 0,
            noise: effects && config.noiseOn ? Float(config.noiseIntensity) : 0,
            brightness: Float(config.brightness),
            chromatic: effects && config.chromaticOn ? Float(config.chromaticIntensity) : 0,
            cornerRadius: effects ? Float(config.cornerRadius) : 0,
            bellFlash: state.bellFlash
        )
        let fp = MTLRenderPassDescriptor()
        fp.colorAttachments[0].texture = drawable.texture
        fp.colorAttachments[0].loadAction = .clear
        fp.colorAttachments[0].storeAction = .store
        fp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let enc = cmd.makeRenderCommandEncoder(descriptor: fp) {
            enc.setRenderPipelineState(crtPipeline)
            enc.setFragmentTexture(scene, index: 0)
            enc.setFragmentTexture(bloomA, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<CRTUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        cmd.present(drawable)
        cmd.commit()
    }

    /// Maps a point in the view (points, bottom-left origin) to a cell, compensating for cell scaling and CRT curvature.
    func cell(at point: CGPoint, viewSize: CGSize, config: TerminalConfig, cols: Int, rows: Int, backingScale: CGFloat) -> (col: Int, row: Int) {
        guard viewSize.width > 0, viewSize.height > 0 else { return (0, 0) }
        var u = Float(point.x / viewSize.width)
        var v = Float(1 - point.y / viewSize.height)
        if config.crtEnabled && config.curvatureOn {
            let k = Float(config.curvature)
            var cx = u * 2 - 1, cy = v * 2 - 1
            let nx = cx * (1 + cy * cy * k)
            let ny = cy * (1 + cx * cx * k)
            cx = nx; cy = ny
            u = cx * 0.5 + 0.5; v = cy * 0.5 + 0.5
        }
        let px = u * Float(viewSize.width * backingScale)
        let py = v * Float(viewSize.height * backingScale)
        let col = Int(floor((px - Float(originX)) / (Float(cellWidth) * cellScale.x)))
        let row = Int(floor((py - Float(originY)) / (Float(cellHeight) * cellScale.y)))
        return (max(0, min(cols - 1, col)), max(0, min(rows - 1, row)))
    }

    /// Rectangle of a cell in view coordinates (points, bottom-left origin), accounting for cell scaling.
    func viewRect(col: Int, row: Int, viewSize: CGSize, backingScale: CGFloat) -> CGRect {
        let w = CGFloat(cellWidth) * CGFloat(cellScale.x), h = CGFloat(cellHeight) * CGFloat(cellScale.y)
        let x = (CGFloat(originX) + CGFloat(col) * w) / backingScale
        let yTop = (CGFloat(originY) + CGFloat(row) * h) / backingScale
        return CGRect(x: x, y: viewSize.height - yTop - h / backingScale, width: w / backingScale, height: h / backingScale)
    }

    /// Height of one row as displayed, in points.
    func displayedCellHeight(backingScale: CGFloat) -> CGFloat {
        CGFloat(cellHeight) * CGFloat(cellScale.y) / backingScale
    }
}
