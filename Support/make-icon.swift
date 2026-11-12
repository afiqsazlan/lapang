// Draws the Lapang icon ("Level": a container filled partway, with an orange dashed line
// marking the free space above) and writes AppIcon.icns plus a PNG preview.
//
//   xcrun swift Support/make-icon.swift
//
// Coordinates are on Apple's 1024-point icon grid: an 824-point rounded square, centred.

import AppKit

let bg = NSColor(red: 0x27 / 255, green: 0x27 / 255, blue: 0x2A / 255, alpha: 1)       // zinc-800
let outline = NSColor(red: 0xA1 / 255, green: 0xA1 / 255, blue: 0xAA / 255, alpha: 1)  // zinc-400
let fill = NSColor(red: 0x71 / 255, green: 0x71 / 255, blue: 0x7A / 255, alpha: 1)     // zinc-500
let accent = NSColor(red: 0xF5 / 255, green: 0x9E / 255, blue: 0x0B / 255, alpha: 1)   // amber
let arrow = NSColor(red: 0xE4 / 255, green: 0xE4 / 255, blue: 0xE7 / 255, alpha: 1)    // zinc-200

/// Below 64 px the dashes and arrow blur into noise, so small sizes get a solid line and no arrow.
func drawIcon(in ctx: CGContext, size: CGFloat) {
    let small = size < 64
    let s = size / 1024
    ctx.saveGState()
    ctx.scaleBy(x: s, y: s)
    // flip so y grows downward, like the design
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.setFillColor(bg.cgColor)
    ctx.fillPath()

    // the container
    let box = CGRect(x: 277, y: 265, width: 470, height: 506)
    ctx.addPath(CGPath(roundedRect: box, cornerWidth: 70, cornerHeight: 70, transform: nil))
    ctx.setStrokeColor(outline.cgColor)
    ctx.setLineWidth(small ? 44 : 30)
    ctx.strokePath()

    // what's used: the fill at the bottom
    let used = CGRect(x: 300, y: 536, width: 424, height: 212)
    ctx.addPath(CGPath(roundedRect: used, cornerWidth: 46, cornerHeight: 46, transform: nil))
    ctx.setFillColor(fill.cgColor)
    ctx.fillPath()

    // the line where it starts to matter
    ctx.setStrokeColor(accent.cgColor)
    ctx.setLineWidth(small ? 44 : 26)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: small ? [] : [44, 38])
    ctx.move(to: CGPoint(x: 318, y: 406))
    ctx.addLine(to: CGPoint(x: 706, y: 406))
    ctx.strokePath()

    // room to grow
    if small { ctx.restoreGState(); return }
    ctx.setLineDash(phase: 0, lengths: [])
    ctx.setStrokeColor(arrow.cgColor)
    ctx.setLineWidth(26)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 462, y: 500))
    ctx.addLine(to: CGPoint(x: 512, y: 450))
    ctx.addLine(to: CGPoint(x: 562, y: 500))
    ctx.strokePath()

    ctx.restoreGState()
}

func png(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    drawIcon(in: gc.cgContext, size: CGFloat(pixels))
    gc.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try! png(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! png(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let icns = here.appendingPathComponent("AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! p.run()
p.waitUntilExit()

let docs = here.deletingLastPathComponent().appendingPathComponent("docs")
try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
try! png(512).write(to: docs.appendingPathComponent("icon.png"))
print("✓ \(icns.path)\n✓ \(docs.appendingPathComponent("icon.png").path)")
