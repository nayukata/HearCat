// HearCat のアプリアイコン(.icns)を生成する。地は LP (web/) と同じネイビー +
// 右上の青いグロー。絵柄は design/brand/hearcat-logo.png(白 + アルファ)を
// ブランド色に着色して重ねる。実行: make icon
import AppKit
import Foundation

let tokens = (
    navy: NSColor(red: 12 / 255, green: 18 / 255, blue: 38 / 255, alpha: 1),
    navy2: NSColor(red: 19 / 255, green: 27 / 255, blue: 56 / 255, alpha: 1),
    blue: NSColor(red: 61 / 255, green: 123 / 255, blue: 255 / 255, alpha: 1),
    // ブランドのアクセント色。ネイビー地の上で猫を浮かせる。
    mark: NSColor(red: 222 / 255, green: 230 / 255, blue: 238 / 255, alpha: 1)
)

/// ロゴ画像。スクリプトの位置から辿る(実行時の作業ディレクトリに依存させない)。
let logo: CGImage = {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // scripts/
        .deletingLastPathComponent()   // リポジトリ直下
    let url = repoRoot.appendingPathComponent("design/brand/hearcat-logo.png")
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { fatalError("ロゴが読めない: \(url.path)") }
    return image
}()

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

    // 猫: 縦長のロゴを板の内側に収め、縦横比を保って中央に置く。
    let inset = plate.width * 0.15
    let box = plate.insetBy(dx: inset, dy: inset)
    let scale = min(box.width / CGFloat(logo.width), box.height / CGFloat(logo.height))
    let art = CGRect(
        x: box.midX - CGFloat(logo.width) * scale / 2,
        y: box.midY - CGFloat(logo.height) * scale / 2,
        width: CGFloat(logo.width) * scale,
        height: CGFloat(logo.height) * scale)
    // このコンテキストは呼び出し元で y 下向きに反転してある。パスはその前提で
    // 書いてあるが、CGImage は反転の影響をそのまま受けて上下が逆に出る。
    // 画像を描くあいだだけ反転を打ち消す。
    ctx.saveGState()
    ctx.translateBy(x: art.minX, y: art.maxY)
    ctx.scaleBy(x: 1, y: -1)
    let local = CGRect(x: 0, y: 0, width: art.width, height: art.height)
    // ロゴは白 + アルファ。透明レイヤ内で sourceIn 合成し、アルファを保ったまま着色する。
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.draw(logo, in: local)
    ctx.setBlendMode(.sourceIn)
    ctx.setFillColor(tokens.mark.cgColor)
    ctx.fill(local)
    ctx.setBlendMode(.normal)
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    ctx.restoreGState()
}

func renderPNG(side: Int, to url: URL) throws {
    guard let ctx = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("CGContext 作成失敗") }
    ctx.interpolationQuality = .high
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
