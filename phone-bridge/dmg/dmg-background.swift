// Draws the DMG window background: an arrow from the app to Applications.
import AppKit
let w: CGFloat = 600, h: CGFloat = 380, scale: CGFloat = CGFloat(Int(CommandLine.arguments[2])!)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: w, height: h)
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGradient(starting: NSColor(srgbRed: 0.97, green: 0.99, blue: 0.98, alpha: 1), ending: NSColor(srgbRed: 0.88, green: 0.96, blue: 0.92, alpha: 1))!.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)
// Arrow between the two icons (icons sit at y = 190 from the top).
let y = h - 190
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 245, y: y)); arrow.line(to: NSPoint(x: 345, y: y))
arrow.lineWidth = 6; arrow.lineCapStyle = .round
NSColor(srgbRed: 0.07, green: 0.6, blue: 0.36, alpha: 0.85).setStroke(); arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 330, y: y + 16)); head.line(to: NSPoint(x: 352, y: y)); head.line(to: NSPoint(x: 330, y: y - 16))
head.lineWidth = 6; head.lineCapStyle = .round; head.lineJoinStyle = .round; head.stroke()
let style = NSMutableParagraphStyle(); style.alignment = .center
let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor(srgbRed: 0.1, green: 0.2, blue: 0.15, alpha: 1), .paragraphStyle: style]
let sub: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(srgbRed: 0.3, green: 0.4, blue: 0.35, alpha: 1), .paragraphStyle: style]
("Install PhoneBridge" as NSString).draw(in: NSRect(x: 0, y: h - 70, width: w, height: 30), withAttributes: title)
("Drag PhoneBridge to the Applications folder." as NSString).draw(in: NSRect(x: 0, y: h - 96, width: w, height: 20), withAttributes: sub)
("First launch: right-click PhoneBridge in Applications and choose Open." as NSString).draw(in: NSRect(x: 0, y: 36, width: w, height: 20), withAttributes: sub)
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
