// Renders Resources/AppIcon.icns: a beige CRT monitor with a green phosphor screen.
// Usage: swift Scripts/make-icon.swift   (run from the repo root)
import AppKit

func draw(size px: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { return img }
    let s = px / 1024.0
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x*s, y: y*s, width: w*s, height: h*s) }

    // Monitor body (macOS icon grid: ~100px margin on 1024)
    let body = CGPath(roundedRect: r(104, 150, 816, 760), cornerWidth: 90*s, cornerHeight: 90*s, transform: nil)
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let bodyGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [NSColor(calibratedRed: 0.86, green: 0.82, blue: 0.70, alpha: 1).cgColor,
                                       NSColor(calibratedRed: 0.70, green: 0.65, blue: 0.53, alpha: 1).cgColor] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(bodyGrad, start: CGPoint(x: 0, y: px), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()
    // Body edge
    ctx.addPath(body)
    ctx.setStrokeColor(NSColor(calibratedRed: 0.45, green: 0.40, blue: 0.30, alpha: 1).cgColor)
    ctx.setLineWidth(10*s)
    ctx.strokePath()

    // Stand
    ctx.setFillColor(NSColor(calibratedRed: 0.62, green: 0.57, blue: 0.46, alpha: 1).cgColor)
    ctx.fill(r(412, 96, 200, 70))
    ctx.addPath(CGPath(roundedRect: r(300, 60, 424, 56), cornerWidth: 20*s, cornerHeight: 20*s, transform: nil))
    ctx.fillPath()

    // Bezel (dark inset)
    let bezel = CGPath(roundedRect: r(168, 260, 688, 590), cornerWidth: 60*s, cornerHeight: 60*s, transform: nil)
    ctx.addPath(bezel)
    ctx.setFillColor(NSColor(calibratedRed: 0.16, green: 0.15, blue: 0.13, alpha: 1).cgColor)
    ctx.fillPath()

    // Screen glass with curvature-like radial glow
    let screen = CGPath(roundedRect: r(200, 292, 624, 526), cornerWidth: 70*s, cornerHeight: 70*s, transform: nil)
    ctx.saveGState()
    ctx.addPath(screen); ctx.clip()
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(calibratedRed: 0.06, green: 0.22, blue: 0.09, alpha: 1).cgColor,
                                   NSColor(calibratedRed: 0.015, green: 0.07, blue: 0.03, alpha: 1).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512*s, y: 560*s), startRadius: 0,
                           endCenter: CGPoint(x: 512*s, y: 560*s), endRadius: 460*s, options: [])
    // Scanlines
    ctx.setFillColor(NSColor(white: 0, alpha: 0.28).cgColor)
    var y: CGFloat = 292
    while y < 820 { ctx.fill(r(200, y, 624, 4)); y += 8 }
    // Phosphor text: prompt + block cursor
    let green = NSColor(calibratedRed: 0.25, green: 1.0, blue: 0.4, alpha: 1)
    let font = NSFont(name: "Menlo-Bold", size: 150*s) ?? NSFont.boldSystemFont(ofSize: 150*s)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: green]
    ctx.setShadow(offset: .zero, blur: 40*s, color: green.withAlphaComponent(0.9).cgColor)
    NSAttributedString(string: ">_", attributes: attrs).draw(at: NSPoint(x: 272*s, y: 470*s))
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // Glass reflection
    ctx.setFillColor(NSColor(white: 1, alpha: 0.05).cgColor)
    ctx.addPath(CGPath(ellipseIn: r(140, 620, 560, 360), transform: nil)); ctx.fillPath()
    ctx.restoreGState()

    // Power LED
    ctx.setFillColor(NSColor(calibratedRed: 0.9, green: 0.2, blue: 0.15, alpha: 1).cgColor)
    ctx.fillEllipse(in: r(800, 200, 28, 28))
    img.unlockFocus()
    return img
}

let root = FileManager.default.currentDirectoryPath
let iconset = root + "/build/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for (name, px) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),
                   ("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] as [(String, Int)] {
    let img = draw(size: CGFloat(px))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(iconset)/icon_\(name).png"))
}
print("iconset written to \(iconset)")
