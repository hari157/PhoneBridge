// Draws the PhoneBridge app icon (version 2) as a 1024 x 1024 PNG.
// Usage: swift draw-icon.swift <output.png> [small]
// "small" leaves out the drop shadow, which turns into a gray box at 16 and 32 pixels.
// "layer-bridge" and "layer-handset" draw one white element on a clear, full-bleed canvas,
// for the Icon Composer icon (AppIcon.icon) that macOS 26 and later use.

import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let options = CommandLine.arguments.dropFirst(2)
let small = options.contains("small")
let layer = options.first { $0.hasPrefix("layer-") }

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    .retagging(with: .sRGB)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let cg = NSGraphicsContext.current!.cgContext

// Work in top-left coordinates.
cg.translateBy(x: 0, y: size)
cg.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// A rounded square with continuous (squircle-like) corners, as on macOS icons.
func squircle(_ r: CGRect, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let k: CGFloat = 1.28  // how far the corner curve starts from the corner, relative to the radius
    let c = radius * k
    p.move(to: CGPoint(x: r.minX + c, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
    p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + c), control1: CGPoint(x: r.maxX - c * 0.35, y: r.minY), control2: CGPoint(x: r.maxX, y: r.minY + c * 0.35))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
    p.addCurve(to: CGPoint(x: r.maxX - c, y: r.maxY), control1: CGPoint(x: r.maxX, y: r.maxY - c * 0.35), control2: CGPoint(x: r.maxX - c * 0.35, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
    p.addCurve(to: CGPoint(x: r.minX, y: r.maxY - c), control1: CGPoint(x: r.minX + c * 0.35, y: r.maxY), control2: CGPoint(x: r.minX, y: r.maxY - c * 0.35))
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
    p.addCurve(to: CGPoint(x: r.minX + c, y: r.minY), control1: CGPoint(x: r.minX, y: r.minY + c * 0.35), control2: CGPoint(x: r.minX + c * 0.35, y: r.minY))
    p.closeSubpath()
    return p
}

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = squircle(tile, radius: 145)
let space = CGColorSpace(name: CGColorSpace.sRGB)!


// The bridge: an arch from the phone (left dot) to the Mac (right dot).
func drawBridge(dotCentres: Bool) {
let left = CGPoint(x: 236, y: 560), right = CGPoint(x: 788, y: 560)
let arch = CGMutablePath()
arch.move(to: left)
arch.addCurve(to: right, control1: CGPoint(x: 262, y: 170), control2: CGPoint(x: 762, y: 170))
cg.saveGState()
cg.addPath(arch)
cg.setLineWidth(40)
cg.setLineCap(.round)
cg.setStrokeColor(rgb(0xFFFFFF, dotCentres ? 0.5 : 0.9))  // the glass layer adds its own translucency
cg.strokePath()
cg.restoreGState()
for p in [left, right] {
    cg.setFillColor(rgb(0xFFFFFF))
    cg.fillEllipse(in: CGRect(x: p.x - 44, y: p.y - 44, width: 88, height: 88))
    if dotCentres {
        cg.setFillColor(rgb(0x14AE63))
        cg.fillEllipse(in: CGRect(x: p.x - 18, y: p.y - 18, width: 36, height: 36))
    } else {
        cg.setBlendMode(.clear)
        cg.fillEllipse(in: CGRect(x: p.x - 18, y: p.y - 18, width: 36, height: 36))
        cg.setBlendMode(.normal)
    }
}
}

// The handset: the Material Design "call" glyph (Apache License 2.0), on a 24 x 24 grid.
let callGlyph = "M6.62 10.79c1.44 2.83 3.76 5.14 6.59 6.59l2.2-2.2c.27-.27.67-.36 1.02-.24 1.12.37 2.33.57 3.57.57.55 0 1 .45 1 1V20c0 .55-.45 1-1 1-9.39 0-17-7.61-17-17 0-.55.45-1 1-1h3.5c.55 0 1 .45 1 1 0 1.25.2 2.45.57 3.57.11.35.03.74-.25 1.02l-2.2 2.2z"

/// Reads the SVG path commands this glyph uses: M, c, l, V, h, z.
func svgPath(_ d: String) -> CGPath {
    var tokens: [String] = []
    var cur = ""
    for ch in d {
        if ch.isLetter { if !cur.isEmpty { tokens.append(cur) }; tokens.append(String(ch)); cur = "" }
        else if ch == " " || ch == "," { if !cur.isEmpty { tokens.append(cur) }; cur = "" }
        else if ch == "-" { if !cur.isEmpty { tokens.append(cur) }; cur = "-" }
        else if ch == "." && cur.contains(".") { tokens.append(cur); cur = "." }
        else { cur.append(ch) }
    }
    if !cur.isEmpty { tokens.append(cur) }
    let p = CGMutablePath()
    var pt = CGPoint.zero, i = 0, cmd = ""
    func num() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i])!) }
    while i < tokens.count {
        if tokens[i].first!.isLetter { cmd = tokens[i]; i += 1 }
        switch cmd {
        case "M": pt = CGPoint(x: num(), y: num()); p.move(to: pt)
        case "c":
            let c1 = CGPoint(x: pt.x + num(), y: pt.y + num()), c2 = CGPoint(x: pt.x + num(), y: pt.y + num())
            pt = CGPoint(x: pt.x + num(), y: pt.y + num()); p.addCurve(to: pt, control1: c1, control2: c2)
        case "l": pt = CGPoint(x: pt.x + num(), y: pt.y + num()); p.addLine(to: pt)
        case "V": pt = CGPoint(x: pt.x, y: num()); p.addLine(to: pt)
        case "h": pt = CGPoint(x: pt.x + num(), y: pt.y); p.addLine(to: pt)
        case "z": p.closeSubpath()
        default: fatalError("unsupported path command \(cmd)")
        }
    }
    return p
}

// The glyph spans 3...21 on its grid; centre it under the arch.
let glyphScale: CGFloat = 19.5
var place = CGAffineTransform(translationX: 512 - 12 * glyphScale, y: 640 - 12 * glyphScale).scaledBy(x: glyphScale, y: glyphScale)
let phone = svgPath(callGlyph).copy(using: &place)!

func drawHandset(shadow: Bool) {
    cg.saveGState()
    if shadow { cg.setShadow(offset: CGSize(width: 0, height: 14), blur: 26, color: rgb(0x00492A, 0.35)) }
    cg.addPath(phone)
    cg.setFillColor(rgb(0xFFFFFF))
    cg.fillPath(using: .winding)
    cg.restoreGState()
}

func save() {
    NSGraphicsContext.current = nil
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print("wrote \(out)")
}

if let layer {
    // macOS masks the layers to the icon shape itself, so map the 824-point tile onto the whole canvas.
    let k = size / 824
    cg.translateBy(x: 512, y: 512); cg.scaleBy(x: k, y: k); cg.translateBy(x: -512, y: -512)
    if layer == "layer-bridge" { drawBridge(dotCentres: false) } else { drawHandset(shadow: false) }
    save()
    exit(0)
}

// Drop shadow under the tile.
cg.saveGState()
if !small { cg.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: rgb(0x000000, 0.35)) }
cg.addPath(tilePath)
cg.setFillColor(rgb(0x18B866))
cg.fillPath()
cg.restoreGState()

// Tile background: green gradient, lighter at the top left.
cg.saveGState()
cg.addPath(tilePath)
cg.clip()
let bg = CGGradient(colorsSpace: space, colors: [rgb(0x5BEA9B), rgb(0x1CC46E), rgb(0x0B8A57)] as CFArray, locations: [0, 0.5, 1])!
cg.drawLinearGradient(bg, start: CGPoint(x: 180, y: 100), end: CGPoint(x: 844, y: 924), options: [])
// Soft light from above.
let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
cg.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 60), startRadius: 0, endCenter: CGPoint(x: 512, y: 60), endRadius: 620, options: [])
cg.restoreGState()

drawBridge(dotCentres: true)
drawHandset(shadow: true)

// A thin light edge on the tile.
cg.addPath(tilePath)
cg.setLineWidth(3)
cg.setStrokeColor(rgb(0xFFFFFF, 0.18))
cg.strokePath()

save()
