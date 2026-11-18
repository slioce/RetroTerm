import AppKit
import CoreText
import Metal

/// Rasterises glyphs with CoreText into a single Metal texture, one slot per (text, bold, italic).
final class GlyphAtlas {
    struct Key: Hashable {
        let text: String
        let bold: Bool
        let italic: Bool
    }

    struct Entry {
        let u0: Float, v0: Float, u1: Float, v1: Float
        let isColor: Bool
        let isEmpty: Bool
    }

    let device: MTLDevice
    private(set) var texture: MTLTexture
    let atlasSize = 2048

    /// Cell metrics in raster pixels (before any pixel upscaling).
    let cellWidth: Int
    let cellHeight: Int
    let ascent: CGFloat
    let descent: CGFloat
    let antialias: Bool
    let fontDisplayName: String

    private let regular: CTFont
    private let bold: CTFont
    private let italic: CTFont
    private let boldItalic: CTFont

    private var entries: [Key: Entry] = [:]
    private var shelfX = 1
    private var shelfY = 1
    private var shelfHeight = 0
    private(set) var isFull = false

    init(device: MTLDevice, fontName: String, pixelSize: CGFloat, lineSpacing: CGFloat, antialias: Bool) {
        self.device = device
        self.antialias = antialias

        let size = max(4, pixelSize)
        let base: NSFont = NSFont(name: fontName, size: size) ?? NSFont.userFixedPitchFont(ofSize: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let fm = NSFontManager.shared
        let b = fm.convert(base, toHaveTrait: .boldFontMask)
        let i = fm.convert(base, toHaveTrait: .italicFontMask)
        let bi = fm.convert(b, toHaveTrait: .italicFontMask)
        regular = base as CTFont
        bold = b as CTFont
        italic = i as CTFont
        boldItalic = bi as CTFont
        fontDisplayName = base.displayName ?? fontName

        let asc = CTFontGetAscent(regular)
        let desc = CTFontGetDescent(regular)
        let leading = CTFontGetLeading(regular)
        var glyph = CGGlyph(0)
        var ch = UniChar(0x4D) // "M"
        CTFontGetGlyphsForCharacters(regular, &ch, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(regular, .horizontal, &glyph, &advance, 1)
        cellWidth = max(1, Int(ceil(advance.width)))
        let natural = asc + desc + leading
        cellHeight = max(1, Int(ceil(natural * lineSpacing)))
        let extra = CGFloat(cellHeight) - (asc + desc)
        ascent = asc + max(0, extra / 2)
        descent = CGFloat(cellHeight) - ascent

        let desc2 = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: atlasSize, height: atlasSize, mipmapped: false)
        desc2.usage = .shaderRead
        desc2.storageMode = .managed
        texture = device.makeTexture(descriptor: desc2)!
    }

    func entry(for text: String, bold isBold: Bool, italic isItalic: Bool, cells: Int) -> Entry? {
        let key = Key(text: text, bold: isBold, italic: isItalic)
        if let e = entries[key] { return e }
        guard let e = rasterise(text: text, bold: isBold, italic: isItalic, cells: cells) else { return nil }
        entries[key] = e
        return e
    }

    private func rasterise(text: String, bold isBold: Bool, italic isItalic: Bool, cells: Int) -> Entry? {
        let w = cellWidth * max(1, cells)
        let h = cellHeight
        // Allocate a slot.
        if shelfX + w + 1 > atlasSize {
            shelfX = 1
            shelfY += shelfHeight + 1
            shelfHeight = 0
        }
        if shelfY + h + 1 > atlasSize {
            isFull = true
            return nil
        }
        let slotX = shelfX, slotY = shelfY
        shelfX += w + 1
        shelfHeight = max(shelfHeight, h)

        let font: CTFont
        switch (isBold, isItalic) {
        case (false, false): font = regular
        case (true, false): font = bold
        case (false, true): font = italic
        case (true, true): font = boldItalic
        }

        let bytesPerRow = w * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * h)
        var isColor = false
        var isEmpty = true

        data.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            ctx.setAllowsAntialiasing(antialias)
            ctx.setShouldAntialias(antialias)
            ctx.setShouldSmoothFonts(false)
            ctx.setAllowsFontSmoothing(false)
            ctx.setShouldSubpixelPositionFonts(false)
            ctx.setAllowsFontSubpixelPositioning(false)
            ctx.setShouldSubpixelQuantizeFonts(true)
            ctx.setAllowsFontSubpixelQuantization(true)

            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white,
                .ligature: 0,
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            let line = CTLineCreateWithAttributedString(str)
            if let runs = CTLineGetGlyphRuns(line) as? [CTRun] {
                for run in runs {
                    let ra = CTRunGetAttributes(run) as NSDictionary
                    if let f = ra[kCTFontAttributeName as String] {
                        let rf = f as! CTFont
                        if CTFontGetSymbolicTraits(rf).contains(.traitColorGlyphs) { isColor = true }
                    }
                }
            }
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            var x: CGFloat = 0
            if width < CGFloat(w) && width > 0 { x = ((CGFloat(w) - width) / 2).rounded(.down) }
            if cells == 1 { x = 0 }
            ctx.textPosition = CGPoint(x: x, y: descent)
            CTLineDraw(line, ctx)
        }

        // Check emptiness (alpha channel).
        var idx = 3
        while idx < data.count {
            if data[idx] != 0 { isEmpty = false; break }
            idx += 4
        }

        if !isEmpty {
            texture.replace(region: MTLRegionMake2D(slotX, slotY, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: bytesPerRow)
        }
        let s = Float(atlasSize)
        return Entry(u0: Float(slotX) / s, v0: Float(slotY) / s,
                     u1: Float(slotX + w) / s, v1: Float(slotY + h) / s,
                     isColor: isColor, isEmpty: isEmpty)
    }
}
