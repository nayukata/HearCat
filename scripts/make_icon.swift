// HearCat のアプリアイコン(.icns)を生成する。デザインは LP (docs/index.html) と同じ
// ネイビー地 + 青のグロー + 白い猫。実行: make icon
import AppKit
import Foundation

let tokens = (
    navy: NSColor(red: 12 / 255, green: 18 / 255, blue: 38 / 255, alpha: 1),
    navy2: NSColor(red: 19 / 255, green: 27 / 255, blue: 56 / 255, alpha: 1),
    blue: NSColor(red: 61 / 255, green: 123 / 255, blue: 255 / 255, alpha: 1)
)

/// 猫の頭(viewBox 26x26 の SVG パスと同じ形)を CGPath にする。
func catPath(in rect: CGRect) -> (head: CGPath, eyes: CGPath) {
    let s = min(rect.width, rect.height) / 26
    let ox = rect.minX + (rect.width - 26 * s) / 2
    let oy = rect.minY + (rect.height - 26 * s) / 2
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }

    let head = CGMutablePath()
    head.move(to: pt(3, 10))
    head.addLine(to: pt(6, 3))
    head.addLine(to: pt(10, 8))
    head.addLine(to: pt(16, 8))
    head.addLine(to: pt(20, 3))
    head.addLine(to: pt(23, 10))
    head.addLine(to: pt(23, 16))
    let center = pt(13, 16)
    let transform = CGAffineTransform(translationX: center.x, y: center.y)
        .scaledBy(x: 10 * s, y: 7.5 * s)
    head.addArc(
        center: .zero, radius: 1, startAngle: 0, endAngle: .pi, clockwise: false,
        transform: transform)
    head.closeSubpath()

    let eyes = CGMutablePath()
    for x in [9.5, 16.5] {
        let r = 1.6 * s
        eyes.addEllipse(in: CGRect(x: ox + x * s - r, y: oy + 14 * s - r, width: r * 2, height: r * 2))
    }
    return (head, eyes)
}

/// 指定サイズのアイコン1枚を描く(y 下向き座標)。
func drawIcon(side: CGFloat, ctx: CGContext) {
    // macOS のアイコングリッド: キャンバスの約 80% の角丸四角、余白は透過。
    let plate = CGRect(
        x: side * 0.1, y: side * 0.1, width: side * 0.8, height: side * 0.8)
    let radius = plate.width * 0.225
    let platePath = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()

    // 地: ネイビーの縦グラデーション。
    let colors = [tokens.navy.cgColor, tokens.navy2.cgColor] as CFArray
    let space = CGColorSpaceCreateDeviceRGB()
    if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.midX, y: plate.minY),
            end: CGPoint(x: plate.midX, y: plate.maxY), options: [])
    }
    // LP のヒーローと同じ、右上の青いグロー。
    let glowColors = [tokens.blue.withAlphaComponent(0.5).cgColor, tokens.blue.withAlphaComponent(0).cgColor] as CFArray
    if let glow = CGGradient(colorsSpace: space, colors: glowColors, locations: [0, 1]) {
        ctx.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: plate.maxX - plate.width * 0.22, y: plate.minY + plate.height * 0.16),
            startRadius: 0,
            endCenter: CGPoint(x: plate.maxX - plate.width * 0.22, y: plate.minY + plate.height * 0.16),
            endRadius: plate.width * 0.75, options: [])
    }

    // 猫: 白の輪郭 + 目。
    let catRect = plate.insetBy(dx: plate.width * 0.21, dy: plate.height * 0.21)
    let (head, eyes) = catPath(in: catRect)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(max(1, catRect.width / 26 * 2))
    ctx.setLineJoin(.round)
    ctx.addPath(head)
    ctx.strokePath()
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.addPath(eyes)
    ctx.fillPath()
    ctx.restoreGState()
}

func renderPNG(side: Int, to url: URL) throws {
    guard let ctx = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("CGContext 作成失敗") }
    // CGContext は y 上向きなので、描画コードの y 下向き座標に合わせて反転する。
    ctx.translateBy(x: 0, y: CGFloat(side))
    ctx.scaleBy(x: 1, y: -1)
    drawIcon(side: CGFloat(side), ctx: ctx)
    guard let image = ctx.makeImage() else { fatalError("makeImage 失敗") }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG 変換失敗") }
    try png.write(to: url)
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("HearCat.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let entries: [(name: String, side: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for entry in entries {
    try renderPNG(side: entry.side, to: iconset.appendingPathComponent(entry.name + ".png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil 失敗") }
print("生成: \(output.path)")
