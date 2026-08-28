// gen_icon.swift — 生成 1024x1024 应用图标（扁平深紫底 + 白色月牙 + z z）
// 用法: swift scripts/gen_icon.swift <输出路径.png>

import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size: CGFloat = 1024

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else {
    fatalError("cannot create bitmap rep")
}
rep.size = NSSize(width: size, height: size)

NSGraphicsContext.saveGraphicsState()
guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("cannot create graphics context") }
NSGraphicsContext.current = ctx

// 背景：圆角矩形（扁平深紫，深浅色模式下图标自包含、观感一致）
let bg = NSColor(calibratedRed: 0.36, green: 0.31, blue: 0.80, alpha: 1)
let bgRect = NSRect(x: 0, y: 0, width: size, height: size)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 230, yRadius: 230)
bg.setFill()
bgPath.fill()

// 月亮：白圆上覆盖一块背景色偏移圆，形成月牙（背景为纯色，无接缝问题）
let moonCenter = NSPoint(x: 420, y: 490)
let moonR: CGFloat = 260
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: moonCenter.x - moonR, y: moonCenter.y - moonR,
                            width: moonR * 2, height: moonR * 2)).fill()

let biteCenter = NSPoint(x: moonCenter.x + 95, y: moonCenter.y + 70)
let biteR: CGFloat = 215
bg.setFill()
NSBezierPath(ovalIn: NSRect(x: biteCenter.x - biteR, y: biteCenter.y - biteR,
                            width: biteR * 2, height: biteR * 2)).fill()

// z z 文本
func drawZ(_ text: String, fontSize: CGFloat, at point: NSPoint) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: fontSize),
        .foregroundColor: NSColor.white,
    ]
    NSAttributedString(string: text, attributes: attrs).draw(at: point)
}
drawZ("z", fontSize: 190, at: NSPoint(x: 660, y: 620))
drawZ("z", fontSize: 120, at: NSPoint(x: 810, y: 800))

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("cannot encode png")
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("icon written: \(outPath)")
