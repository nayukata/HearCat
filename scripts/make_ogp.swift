// OGP 画像(web/public/ogp.png, 1200x630)を生成する。地とコピーは LP と揃える。
// 猫は design/brand/hearcat-logo.png(白 + アルファ)を着色して重ねる。実行: make ogp
//
// 以前は web/scripts/ogp.svg を手で書き出していたが、SVG のままだと
// ブランド変更のたびに書き出しが必要で、実物とズレる。ここを唯一の出所にする。
import AppKit
import Foundation

let W: CGFloat = 1200
let H: CGFloat = 630

let navy = NSColor(red: 0x0C / 255, green: 0x12 / 255, blue: 0x26 / 255, alpha: 1)
let navy2 = NSColor(red: 0x13 / 255, green: 0x1B / 255, blue: 0x38 / 255, alpha: 1)
let blue = NSColor(red: 0x3D / 255, green: 0x7B / 255, blue: 0xFF / 255, alpha: 1)
let blueSoft = NSColor(red: 0x8F / 255, green: 0xB4 / 255, blue: 0xFF / 255, alpha: 1)

/// 見出しは W9、本文は W5。LP は Zen Kaku Gothic New だが端末に無いため、
/// 元の ogp.svg と同じく Hiragino を先に使う。
func font(_ size: CGFloat, heavy: Bool) -> NSFont {
    NSFont(name: heavy ? "HiraginoSans-W9" : "HiraginoSans-W5", size: size)
        ?? .systemFont(ofSize: size, weight: heavy ? .black : .medium)
}

let logo: CGImage = {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent("design/brand/hearcat-logo.png")
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { fatalError("ロゴが読めない: \(url.path)") }
    return image
}()

/// 楕円状のグロー。SVG の radialGradient(objectBoundingBox)に合わせて縦横別の半径を持つ。
func glow(_ ctx: CGContext, center: CGPoint, rx: CGFloat, ry: CGFloat, alpha: CGFloat) {
    let colors = [blue.withAlphaComponent(alpha).cgColor, blue.withAlphaComponent(0).cgColor] as CFArray
    guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])
    else { return }
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.scaleBy(x: 1, y: ry / rx)
    ctx.drawRadialGradient(
        g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: rx, options: [])
    ctx.restoreGState()
}

/// 縦横比を保ったままロゴを高さ指定で描く。left は左端、baselineTop は上端。
func drawLogo(_ ctx: CGContext, x: CGFloat, top: CGFloat, height: CGFloat, color: NSColor) {
    let scale = height / CGFloat(logo.height)
    let rect = CGRect(x: x, y: top, width: CGFloat(logo.width) * scale, height: height)
    ctx.saveGState()
    // 呼び出し元で y 下向きに反転しているため、画像を描く間だけ戻す。
    ctx.translateBy(x: rect.minX, y: rect.maxY)
    ctx.scaleBy(x: 1, y: -1)
    let local = CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.draw(logo, in: local)
    ctx.setBlendMode(.sourceIn)
    ctx.setFillColor(color.cgColor)
    ctx.fill(local)
    ctx.setBlendMode(.normal)
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func logoWidth(height: CGFloat) -> CGFloat {
    height / CGFloat(logo.height) * CGFloat(logo.width)
}

/// 色の違う文言を1行に並べる。x はベースラインの左端。
@discardableResult
func drawRuns(_ runs: [(String, NSColor)], x: CGFloat, baseline: CGFloat, font f: NSFont, kern: CGFloat) -> CGFloat {
    var cursor = x
    for (text, color) in runs {
        let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color, .kern: kern]
        let s = NSAttributedString(string: text, attributes: attrs)
        // 反転済みコンテキストでは draw(at:) の y は行の上端。ベースラインから戻す。
        s.draw(at: CGPoint(x: cursor, y: baseline - f.ascender))
        cursor += s.size().width
    }
    return cursor
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let base = NSGraphicsContext(bitmapImageRep: rep)!
let ctx = base.cgContext
ctx.translateBy(x: 0, y: H)
ctx.scaleBy(x: 1, y: -1)
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

// 地
if let g = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [navy.cgColor, navy2.cgColor] as CFArray, locations: [0, 1])
{
    ctx.drawLinearGradient(
        g, start: CGPoint(x: W / 2, y: 0), end: CGPoint(x: W / 2, y: H), options: [])
}
glow(ctx, center: CGPoint(x: W * 0.8, y: H * 0.1), rx: W * 0.7, ry: H * 0.7, alpha: 0.22)
glow(ctx, center: CGPoint(x: W * 0.1, y: H * 0.95), rx: W * 0.55, ry: H * 0.55, alpha: 0.14)

// 右側の同心円と、その中の猫
let ringCenter = CGPoint(x: 940, y: 100)
ctx.setLineWidth(1.2)
for (radius, alpha) in [(60.0, 0.35), (100.0, 0.2), (140.0, 0.1)] {
    ctx.setStrokeColor(blueSoft.withAlphaComponent(alpha).cgColor)
    ctx.strokeEllipse(
        in: CGRect(x: ringCenter.x - radius, y: ringCenter.y - radius, width: radius * 2, height: radius * 2))
}
ctx.setFillColor(blue.withAlphaComponent(0.18).cgColor)
ctx.fillEllipse(in: CGRect(x: ringCenter.x - 26, y: ringCenter.y - 26, width: 52, height: 52))
let ringLogoH: CGFloat = 64
drawLogo(
    ctx, x: ringCenter.x - logoWidth(height: ringLogoH) / 2, top: ringCenter.y - ringLogoH / 2,
    height: ringLogoH, color: blueSoft)

// 左上のロゴとサービス名
let headLogoH: CGFloat = 52
drawLogo(ctx, x: 80, top: 108 - headLogoH / 2 - 4, height: headLogoH, color: .white)
drawRuns([("HearCat", .white)], x: 140, baseline: 108, font: font(30, heavy: true), kern: 0)

// 見出し
drawRuns([("秘密は、外に出さない。", .white)], x: 80, baseline: 300, font: font(76, heavy: true), kern: 1)
drawRuns(
    [("必要なのは、", .white), ("Mac だけ", blueSoft), ("。", .white)],
    x: 80, baseline: 400, font: font(76, heavy: true), kern: 1)

// 説明
drawRuns(
    [("Mac の中だけで動く、議事録 AI。", NSColor.white.withAlphaComponent(0.62))],
    x: 80, baseline: 500, font: font(26, heavy: false), kern: 0.5)

// 脚注
drawRuns([("macOS 26 / Apple Silicon", blueSoft)], x: 80, baseline: 560, font: font(20, heavy: false), kern: 0.5)
ctx.setStrokeColor(blueSoft.withAlphaComponent(0.4).cgColor)
ctx.setLineWidth(1)
ctx.move(to: CGPoint(x: 430, y: 546))
ctx.addLine(to: CGPoint(x: 430, y: 566))
ctx.strokePath()
drawRuns(
    [("録音・文字起こし・要約 すべて端末内", blueSoft.withAlphaComponent(0.75))],
    x: 450, baseline: 560, font: font(20, heavy: false), kern: 0.5)

NSGraphicsContext.current = nil
let output = URL(
    fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "web/public/ogp.png")
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG 変換失敗") }
try png.write(to: output)
print("生成: \(output.path)")
