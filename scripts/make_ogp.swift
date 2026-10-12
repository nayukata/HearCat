// OGP 画像(web/public/ogp.png, 1200x630)を生成する。地とコピーは LP のファーストビューと揃える。
// 猫は web/public/lp/clay-cat.webp、ロゴは design/brand/hearcat-logo.png(白 + アルファ)を着色して使う。
// 実行: make ogp
//
// このスクリプトを唯一の出所にする。PNG を手で作らない。
import AppKit
import CoreText
import Foundation

let W: CGFloat = 1200
let H: CGFloat = 630

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(
        red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
        blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

let ink = hex(0x3A2A20)
let inkDim = hex(0x6B5444)
let sage = hex(0x557A47)

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

/// 見出しは Zen Maru Gothic Black、本文は Medium(LP と同じ)。
/// 端末に入っていないので design/brand/fonts のファイルをこの実行の間だけ登録する。
/// 登録できなければ Hiragino Sans に落とす。
let fontsLoaded: Bool = {
    var ok = true
    for name in ["ZenMaruGothic-Black.ttf", "ZenMaruGothic-Medium.ttf"] {
        let url = root.appendingPathComponent("design/brand/fonts/\(name)")
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            FileHandle.standardError.write(Data("フォントを登録できない: \(url.path)\n".utf8))
            ok = false
        }
    }
    return ok
}()

func font(_ size: CGFloat, heavy: Bool) -> NSFont {
    if fontsLoaded, let f = NSFont(name: heavy ? "ZenMaruGothic-Black" : "ZenMaruGothic-Medium", size: size) {
        return f
    }
    return NSFont(name: heavy ? "HiraginoSans-W8" : "HiraginoSans-W5", size: size)
        ?? .systemFont(ofSize: size, weight: heavy ? .black : .medium)
}

func loadImage(_ path: String) -> CGImage {
    let url = root.appendingPathComponent(path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { fatalError("画像が読めない: \(url.path)") }
    return image
}

let logo = loadImage("design/brand/hearcat-logo.png")
let cat = loadImage("web/public/lp/clay-cat.webp")

/// y 下向きに反転済みのコンテキストへ、画像を正立で描く。
func drawImage(_ ctx: CGContext, _ image: CGImage, in rect: CGRect) {
    ctx.saveGState()
    ctx.translateBy(x: rect.minX, y: rect.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
    ctx.restoreGState()
}

func drawLogo(_ ctx: CGContext, x: CGFloat, top: CGFloat, height: CGFloat, color: NSColor) {
    let scale = height / CGFloat(logo.height)
    let rect = CGRect(x: x, y: top, width: CGFloat(logo.width) * scale, height: height)
    ctx.saveGState()
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

/// x はベースラインの左端。反転済みコンテキストでは draw(at:) の y が行の上端になる。
@discardableResult
func drawText(_ text: String, x: CGFloat, baseline: CGFloat, font f: NSFont, color: NSColor, kern: CGFloat = 0) -> CGFloat {
    let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color, .kern: kern]
    let s = NSAttributedString(string: text, attributes: attrs)
    s.draw(at: CGPoint(x: x, y: baseline - f.ascender))
    return x + s.size().width
}

func roundedPath(_ rect: CGRect, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

func linear(_ ctx: CGContext, _ colors: [NSColor], from: CGPoint, to: CGPoint) {
    guard let g = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map { $0.cgColor } as CFArray, locations: nil)
    else { return }
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// 粘土の面。外側の柔らかい影、上方向の白い内側ハイライト、下方向の暗い内側の影を重ねる。
func clay(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, top: NSColor = hex(0xFFFCF7), bottom: NSColor = hex(0xFFF1E2)) {
    let path = roundedPath(rect, radius)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 30, color: hex(0x8C5C38, 0.30).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(bottom.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    linear(ctx, [top, bottom], from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX * 0.9, y: rect.maxY))
    // 内側の影は、外周の反転形(穴あき)を塗って影だけを面に落とす。
    let hole = CGMutablePath()
    hole.addRect(rect.insetBy(dx: -80, dy: -80))
    hole.addPath(path)
    ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 7, color: NSColor.white.withAlphaComponent(0.95).cgColor)
    ctx.addPath(hole)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath(using: .evenOdd)
    ctx.setShadow(offset: CGSize(width: 0, height: 7), blur: 12, color: hex(0xC48C62, 0.28).cgColor)
    ctx.addPath(hole)
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
ctx.translateBy(x: 0, y: H)
ctx.scaleBy(x: 1, y: -1)
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

// 地(LP のファーストビューと同じ 165deg の淡いピーチ〜クリーム)
linear(ctx, [hex(0xFCE6D4), hex(0xFFF0E0), hex(0xFFF6EC)], from: CGPoint(x: 0, y: 0), to: CGPoint(x: W * 0.55, y: H))

// 左: ロゴ、見出し、一文
let logoH: CGFloat = 46
drawLogo(ctx, x: 72, top: 50, height: logoH, color: ink)
drawText("HearCat", x: 72 + logoWidth(height: logoH) + 12, baseline: 90, font: font(38, heavy: true), color: ink)
drawText("メモ、", x: 72, baseline: 240, font: font(76, heavy: true), color: ink)
drawText("取らなくていいよ。", x: 72, baseline: 334, font: font(76, heavy: true), color: ink)
drawText("会議の声をその場で文字に。", x: 72, baseline: 420, font: font(28, heavy: false), color: inkDim)
drawText("聞き逃したら、あとで AI に聞き返せる。", x: 72, baseline: 464, font: font(28, heavy: false), color: inkDim)
drawText("Mac 用の日本語文字起こしアプリ", x: 72, baseline: 566, font: font(22, heavy: false), color: sage)

// 右: 重ねた粘土のパネル(文字起こしの 2 行)と猫
let panel = CGRect(x: 706, y: 84, width: 430, height: 232)
clay(ctx, panel.offsetBy(dx: 0, dy: -0).insetBy(dx: 44, dy: 0).offsetBy(dx: 0, dy: -26), radius: 30, top: hex(0xFFF4E6), bottom: hex(0xFFF4E6))
clay(ctx, panel.insetBy(dx: 22, dy: 0).offsetBy(dx: 0, dy: -13), radius: 30, top: hex(0xFFF4E6), bottom: hex(0xFFF4E6))
clay(ctx, panel, radius: 32)

let tabs = CGRect(x: panel.minX + 16, y: panel.minY + 16, width: panel.width - 32, height: 52)
ctx.addPath(roundedPath(tabs, 22))
ctx.setFillColor(hex(0xF8E6D2).cgColor)
ctx.fillPath()
let tabW = (tabs.width - 12) / 3
let tabTitles = ["文字起こし", "AI に質問", "決まったこと"]
for (i, title) in tabTitles.enumerated() {
    let r = CGRect(x: tabs.minX + 6 + CGFloat(i) * tabW, y: tabs.minY + 6, width: tabW, height: tabs.height - 12)
    if i == 0 {
        ctx.addPath(roundedPath(r, 16))
        ctx.setFillColor(hex(0xD5E5C8).cgColor)
        ctx.fillPath()
    }
    let f = font(17, heavy: i == 0)
    let w = NSAttributedString(string: title, attributes: [.font: f]).size().width
    drawText(title, x: r.midX - w / 2, baseline: r.midY + 6, font: f, color: ink)
}
let rows = [("相手", "リリースは来週の金曜にずらしましょう"), ("自分", "了解です、告知も合わせて直します。")]
for (i, row) in rows.enumerated() {
    let y = panel.minY + 112 + CGFloat(i) * 62
    drawText(row.0, x: panel.minX + 30, baseline: y, font: font(17, heavy: true), color: ink)
    drawText(row.1, x: panel.minX + 88, baseline: y, font: font(18, heavy: false), color: ink)
    if i == 0 {
        ctx.setStrokeColor(hex(0x3A2A20, 0.15).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: panel.minX + 30, y: y + 22))
        ctx.addLine(to: CGPoint(x: panel.maxX - 30, y: y + 22))
        ctx.strokePath()
    }
}

let catW: CGFloat = 470
let catH = catW * CGFloat(cat.height) / CGFloat(cat.width)
drawImage(ctx, cat, in: CGRect(x: W - catW - 28, y: H - catH - 22, width: catW, height: catH))

NSGraphicsContext.current = nil
let output = URL(
    fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "web/public/ogp.png")
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG 変換失敗") }
try png.write(to: output)
print("fontsLoaded=\(fontsLoaded)")
