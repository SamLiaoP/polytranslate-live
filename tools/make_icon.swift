// PolyTranslate Live：用 CoreGraphics 畫 App 圖示，輸出 AppIcon.iconset 與預覽 PNG。
// 風格：macOS 26 圓角方形、深橘到金黃漸層、自己畫的「A ↔ 文」兩個對話框，底下兩條字幕線。
// 不使用 SF Symbols（Apple 授權禁止用在 App 圖示）。
import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return img }
    let s = size
    let rect = CGRect(x: 0, y: 0, width: s, height: s)

    // macOS 圖示有固定留白：實際圖形約佔 80%。
    let inset = s * 0.10
    let body = rect.insetBy(dx: inset, dy: inset)
    let radius = body.width * 0.225
    let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // 陰影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(squircle)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // 背景漸層
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let colors = [
        NSColor(calibratedRed: 0.80, green: 0.22, blue: 0.06, alpha: 1).cgColor,   // 深橘紅
        NSColor(calibratedRed: 0.98, green: 0.52, blue: 0.10, alpha: 1).cgColor,   // 橘
        NSColor(calibratedRed: 1.00, green: 0.80, blue: 0.22, alpha: 1).cgColor,   // 金黃
    ] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])

    // 上緣高光
    let hl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(hl, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.midY), options: [])
    ctx.restoreGState()

    // 兩個對話框：左後「A」、右前「文」，白色帶柔和陰影
    func bubble(_ r: CGRect, tailRight: Bool) -> CGPath {
        let p = CGMutablePath()
        let rad = r.height * 0.28
        p.addRoundedRect(in: r, cornerWidth: rad, cornerHeight: rad)
        // 小尾巴
        let tailW = r.width * 0.16, tailH = r.height * 0.22
        let baseX = tailRight ? r.maxX - rad * 1.1 - tailW : r.minX + rad * 1.1
        let tipX = tailRight ? baseX + tailW * 1.15 : baseX - tailW * 0.15
        p.move(to: CGPoint(x: baseX, y: r.minY + 1))
        p.addLine(to: CGPoint(x: baseX + tailW, y: r.minY + 1))
        p.addLine(to: CGPoint(x: tipX, y: r.minY - tailH))
        p.closeSubpath()
        return p
    }
    func glyph(_ text: String, in r: CGRect, size: CGFloat, color: NSColor) {
        let font = NSFont.systemFont(ofSize: size, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let str = NSAttributedString(string: text, attributes: attrs)
        let sz = str.size()
        str.draw(at: CGPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2 + size * 0.02))
    }
    let w = body.width, h = body.height
    let back = CGRect(x: body.minX + w * 0.14, y: body.minY + h * 0.50, width: w * 0.42, height: h * 0.30)
    let front = CGRect(x: body.minX + w * 0.42, y: body.minY + h * 0.36, width: w * 0.44, height: h * 0.31)
    let orange = NSColor(calibratedRed: 0.90, green: 0.40, blue: 0.08, alpha: 1)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    ctx.addPath(bubble(back, tailRight: false))
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.88).cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    glyph("A", in: back, size: h * 0.20, color: orange)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.035, color: NSColor.black.withAlphaComponent(0.30).cgColor)
    ctx.addPath(bubble(front, tailRight: true))
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    glyph("文", in: front, size: h * 0.19, color: orange)

    // 底下兩條字幕線：一長一短，代表原文與譯文
    let barH = body.height * 0.055
    let barR = barH / 2
    let bar1 = CGRect(x: body.minX + body.width * 0.20, y: body.minY + body.height * 0.215, width: body.width * 0.60, height: barH)
    let bar2 = CGRect(x: body.minX + body.width * 0.30, y: body.minY + body.height * 0.125, width: body.width * 0.40, height: barH)
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
    ctx.addPath(CGPath(roundedRect: bar1, cornerWidth: barR, cornerHeight: barR, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.55).cgColor)
    ctx.addPath(CGPath(roundedRect: bar2, cornerWidth: barR, cornerHeight: barR, transform: nil))
    ctx.fillPath()

    img.unlockFocus()
    return img
}

func savePNG(_ img: NSImage, pixels: Int, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(pixels)).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = out + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes { savePNG(drawIcon(size: CGFloat(px)), pixels: px, to: "\(iconset)/\(name).png") }
savePNG(drawIcon(size: 512), pixels: 512, to: out + "/icon_preview.png")
print("ok")
