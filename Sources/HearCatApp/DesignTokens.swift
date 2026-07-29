import AppKit
import CoreText
import SwiftUI

/// アプリ全体のフォント。欧文・数字はシステム(SF Pro)のまま、日本語グリフだけ
/// 同梱の Noto Sans JP に落とすカスケード指定を作る。フォントをここ以外で直接
/// 指定しない(SwiftUI 標準の .font(.caption) 等はシステムのフォールバック=
/// ヒラギノで描画されてしまうため)。
enum HCFont {
    /// SwiftPM 自動生成の `Bundle.module` は、まず `Bundle.main.bundleURL` 直下を探し、
    /// 無ければ実行ファイルに焼き込まれたビルド時の絶対パス
    /// (`.build/.../hearcat_HearCatApp.bundle`) にフォールバックする実装になっている。
    /// 前者は `Makefile` が `Contents/Resources/` に配置するため常に外れる。後者は
    /// ビルドマシン固有の一時ディレクトリで、`bootstrap.sh` 経由のインストールでは
    /// 削除済み。両方失敗すると `Bundle.module` は内部で `fatalError` してプロセスごと
    /// 落ちる(実際に起動時クラッシュの原因になった)ため、ここでは `Bundle.module` を使わず
    /// 実際の配置場所を自前で探す。
    private static var bundledResourcesURL: URL? {
        let bundleName = "hearcat_HearCatApp.bundle"
        let candidates = [
            // 配布・通常起動時: .app/Contents/Resources/hearcat_HearCatApp.bundle (Makefile が配置)
            Bundle.main.resourceURL,
            // 開発時: `swift build` 実行ファイルを .app 化せず直接叩いた場合、
            // 実行ファイルと同じディレクトリに SwiftPM がバンドルを生成する。
            Bundle.main.bundleURL,
        ]
        for base in candidates {
            guard let base else { continue }
            let url = base.appendingPathComponent(bundleName)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// 同梱フォントの登録。起動時に一度だけ呼ぶ。プロセススコープなのでシステムは汚さない。
    /// リソースバンドルが見つからなければ何もしない(カスケード先が未登録の場合、
    /// システムが従来どおりヒラギノに落とす。fatalError は絶対にしない)。
    static func registerBundledFonts() {
        guard let resourcesURL = bundledResourcesURL else { return }
        let fontsURL = resourcesURL.appendingPathComponent("Fonts")
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: fontsURL, includingPropertiesForKeys: nil)
        else { return }
        for url in urls where url.pathExtension.lowercased() == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// 可変フォントの名前付きインスタンス。ウェイトごとに日本語側も太さを揃える。
    private static func notoName(for weight: NSFont.Weight) -> String {
        switch weight {
        case .medium: "NotoSansJP-Medium"
        case .semibold: "NotoSansJP-SemiBold"
        case .bold, .heavy: "NotoSansJP-Bold"
        case .black: "NotoSansJP-Black"
        default: "NotoSansJP-Regular"
        }
    }

    private static func cascaded(_ base: NSFont, weight: NSFont.Weight) -> Font {
        let descriptor = base.fontDescriptor.addingAttributes([
            .cascadeList: [NSFontDescriptor(fontAttributes: [.name: notoName(for: weight)])]
        ])
        return Font(NSFont(descriptor: descriptor, size: base.pointSize) ?? base)
    }

    static func system(size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
        cascaded(.systemFont(ofSize: size, weight: weight), weight: weight)
    }

    /// SwiftUI の .caption 等と同じ大きさを保ったままカスケードを効かせる。
    static func style(_ textStyle: NSFont.TextStyle, weight: NSFont.Weight = .regular) -> Font {
        system(size: NSFont.preferredFont(forTextStyle: textStyle).pointSize, weight: weight)
    }

    /// 数字だけ等幅(タイムスタンプ用)。日本語はカスケードで Noto に落ちる。
    static func monospacedDigit(_ textStyle: NSFont.TextStyle) -> Font {
        let size = NSFont.preferredFont(forTextStyle: textStyle).pointSize
        return cascaded(.monospacedDigitSystemFont(ofSize: size, weight: .regular), weight: .regular)
    }

    /// 全体等幅(コマンド表記用)。
    static func monospaced(size: CGFloat) -> Font {
        cascaded(.monospacedSystemFont(ofSize: size, weight: .regular), weight: .regular)
    }

    static var body: Font { style(.body) }
    static var callout: Font { style(.callout) }
    static var subheadline: Font { style(.subheadline) }
    static var footnote: Font { style(.footnote) }
    static var caption: Font { style(.caption1) }
    static var caption2: Font { style(.caption2) }
    static var headline: Font { style(.headline, weight: .semibold) }
    static var title3: Font { style(.title3) }
}

/// ランディングページ (docs/index.html) と揃えたデザイントークン。
/// 色をここ以外に直書きしない(LP とアプリの見た目を一緒に保つため)。
enum HCColor {
    static let navy = Color(red: 12 / 255, green: 18 / 255, blue: 38 / 255)  // #0C1226
    static let navy2 = Color(red: 19 / 255, green: 27 / 255, blue: 56 / 255)  // #131B38
    static let blue = Color(red: 61 / 255, green: 123 / 255, blue: 255 / 255)  // #3D7BFF
    static let blueSoft = Color(red: 143 / 255, green: 180 / 255, blue: 255 / 255)  // #8FB4FF
    static let whiteDim = Color.white.opacity(0.62)
    static let rec = Color(red: 255 / 255, green: 92 / 255, blue: 92 / 255)  // #FF5C5C

    // --- 霧の底 + シナモンの茶(新ブランド配色) ---
    // ノルウェージャンフォレストキャットの「窓際に、静かに座る森の妖精」から引いた。
    // 底は cool gray(霧の底)、アクセントは白茶バイカラーのシナモン茶。
    // Phase A で CodeImpact overlay、Phase B 以降で他画面に横展開する共通トークン。

    /// パネル本体の背景(霧の底)。
    static let mistDark = Color(red: 0x1A / 255, green: 0x1D / 255, blue: 0x1F / 255)  // #1A1D1F
    /// 入力欄・キーキャップ等、パネルより一段明るいサーフェス。
    static let mistDarkSurface = Color(red: 0x26 / 255, green: 0x2A / 255, blue: 0x2D / 255)  // #262A2D
    /// パネル外周の細い縁。
    static let mistDarkStroke = Color(red: 0x33 / 255, green: 0x3A / 255, blue: 0x3D / 255)  // #333A3D
    /// アクセント本体(白茶バイカラーのシナモン茶)。見出し・アイコン・タグ用。
    static let cinnamon = Color(red: 0xC8 / 255, green: 0x90 / 255, blue: 0x60 / 255)  // #C89060
    /// 入力欄フォーカス時のストローク色(cinnamon より少し暗く落ち着かせる)。
    static let cinnamonStroke = Color(red: 0xB8 / 255, green: 0x84 / 255, blue: 0x5A / 255)  // #B8845A
    /// アクセントを一段落ち着かせた変化色(hover / disabled の表現に)。
    static let cinnamonDim = Color(red: 0x8F / 255, green: 0x61 / 255, blue: 0x3F / 255)  // #8F613F
    /// 主要テキスト(cool white。「白い毛」の印象)。
    static let mistWhite = Color(red: 0xE8 / 255, green: 0xEC / 255, blue: 0xEE / 255)  // #E8ECEE
    /// 本文用テキスト(mistWhite より一段落ち着かせる)。
    static let mistBody = Color(red: 0xD8 / 255, green: 0xDD / 255, blue: 0xE0 / 255)  // #D8DDE0
    /// 補助テキスト(サブヘッダー、キャプション)。
    static let mistWhiteDim = Color(red: 0x8B / 255, green: 0x94 / 255, blue: 0x97 / 255)  // #8B9497
    /// さらに一段薄い補助テキスト(「情報は出しているが目立たせない」)。
    static let mistWhiteDeeper = Color(red: 0x92 / 255, green: 0x98 / 255, blue: 0xA0 / 255)  // #9298A0
    /// 入力欄プレースホルダー・disabled のテキスト。
    static let mistPlaceholder = Color(red: 0x6C / 255, green: 0x73 / 255, blue: 0x77 / 255)  // #6C7377
    /// キーキャップの背景(パネル面から気持ちだけ浮かせる)。
    static let mistKeyCap = Color.white.opacity(0.05)
    /// キーキャップ内のテキスト。
    static let mistKeyText = Color(red: 0xB6 / 255, green: 0xBC / 255, blue: 0xC0 / 255)  // #B6BCC0
    /// 細い区切り線。
    static let mistDivider = Color.white.opacity(0.08)
    /// 一段強い区切り線(footer 上部など、視線を止めたい所に)。
    static let mistDividerStrong = Color.white.opacity(0.14)

    // 話者チップ(自分 = 青系 / 相手 = オレンジ系)
    static let meText = Color(red: 191 / 255, green: 214 / 255, blue: 255 / 255)  // #BFD6FF
    static let meBackground = blue.opacity(0.22)
    static let youText = Color(red: 255 / 255, green: 225 / 255, blue: 184 / 255)  // #FFE1B8
    static let youBackground = Color(red: 255 / 255, green: 176 / 255, blue: 74 / 255).opacity(0.16)

}

/// アプリ全体で使う落ち着いた secondary button のスタイル。
/// ダーク UI で「主張しすぎず、しかし押せることが分かる」ことを両立する。
/// - 通常: 一段明るいサーフェス塗り + 薄い縁 + 白系テキスト(mistDark 上でも読める)
/// - pressed: 縁と背景が一段濃くなる
/// - role: .destructive: 赤系の縁とテキストで、他ボタンと視覚的に差別化する
/// - compact: pill の縦余白を控えめにする(Form の LabeledContent 内で高さを揃える用途)。
struct HCSecondaryButtonStyle: ButtonStyle {
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let isDestructive = configuration.role == .destructive
        let bg = configuration.isPressed
            ? HCColor.mistDarkStroke
            : HCColor.mistDarkSurface
        let border: Color = isDestructive
            ? Color(red: 0.75, green: 0.36, blue: 0.36).opacity(0.55)
            : HCColor.mistDarkStroke
        let foreground: Color = isDestructive
            ? Color(red: 0.94, green: 0.55, blue: 0.55)
            : HCColor.mistWhite
        return configuration.label
            .font(HCFont.callout)
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 10 : 12)
            .padding(.vertical, compact ? 3 : 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(bg))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

/// 主要な操作に使う primary button のスタイル。secondary と対で使い、
/// 1つの画面に1つだけ置く(押してほしい先が2つあると、どちらも押されなくなる)。
struct HCPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HCFont.style(.callout, weight: .semibold))
            .foregroundStyle(HCColor.mistDark)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed ? HCColor.cinnamonStroke : HCColor.cinnamon))
    }
}

extension ButtonStyle where Self == HCPrimaryButtonStyle {
    /// cinnamon 塗りの primary スタイル。
    static var hcPrimary: HCPrimaryButtonStyle { HCPrimaryButtonStyle() }
}

extension ButtonStyle where Self == HCSecondaryButtonStyle {
    /// 落ち着いた secondary スタイル。ヘッダー右端のアクションボタン等に使う。
    static var hcSecondary: HCSecondaryButtonStyle { HCSecondaryButtonStyle() }
    /// Form 内の LabeledContent(ラベル + 値の 1 行構造)に収めるコンパクト版。
    /// pill 高さがラベルの高さに揃うので、行の中央整列が崩れない。
    static var hcSecondaryCompact: HCSecondaryButtonStyle { HCSecondaryButtonStyle(compact: true) }
}

/// HearCat のロゴ(猫の頭)。LP の SVG パス(viewBox 26x26)をそのまま写した形。
struct CatHeadShape: Shape {
    /// true なら目をくり抜いた塗り用パス(even-odd で塗る)、false なら輪郭のみ。
    var includesEyes = false

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 26
        let ox = rect.minX + (rect.width - 26 * s) / 2
        let oy = rect.minY + (rect.height - 26 * s) / 2
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * s, y: oy + y * s)
        }

        var path = Path()
        path.move(to: pt(3, 10))
        path.addLine(to: pt(6, 3))
        path.addLine(to: pt(10, 8))
        path.addLine(to: pt(16, 8))
        path.addLine(to: pt(20, 3))
        path.addLine(to: pt(23, 10))
        path.addLine(to: pt(23, 16))
        // あごの楕円弧: 中心(13,16)、半径(10, 7.5)。円弧を楕円に変形して描く。
        let center = pt(13, 16)
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .scaledBy(x: 10 * s, y: 7.5 * s)
        path.addArc(
            center: .zero, radius: 1,
            startAngle: .zero, endAngle: .radians(.pi), clockwise: false,
            transform: transform)
        path.closeSubpath()

        if includesEyes {
            path.addPath(Self.eyes(in: rect))
        }
        return path
    }

    /// 目(2つの円)を Shape として使うためのラッパー。輪郭スタイルの上に重ねて塗る。
    struct Eyes: Shape {
        func path(in rect: CGRect) -> Path {
            CatHeadShape.eyes(in: rect)
        }
    }

    /// 目(2つの円)。輪郭スタイルでは別途これを塗る。
    static func eyes(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 26
        let ox = rect.minX + (rect.width - 26 * s) / 2
        let oy = rect.minY + (rect.height - 26 * s) / 2
        var path = Path()
        for x in [9.5, 16.5] {
            let r = 1.6 * s
            path.addEllipse(
                in: CGRect(x: ox + x * s - r, y: oy + 14 * s - r, width: r * 2, height: r * 2))
        }
        return path
    }
}

/// メニューバー用のテンプレートアイコン。RunCat と同じく、座った猫のシルエット自体が
/// 状態に応じて動く。録音=聞いてる(首かしげ+耳)、文字起こし=書いてる(しっぽ)、
/// 両方=全部、待機=静止。
enum HCIcon {
    static let menuIdle = [
        makeIcon { ctx in drawSittingCat(ctx, headTilt: 0, earFlick: 0, tailSway: 0) }
    ]
    /// セッション中だが録音・文字起こしとも一時オフ。静止で示す(待機と同じ見た目)。
    static let menuActive = menuIdle

    static let menuRecording = makeAnimationFrames { ctx, phase in
        drawSittingCat(
            ctx,
            headTilt: sin(phase * 2 * .pi) * .pi / 45,
            earFlick: sin(phase * 2 * .pi + .pi / 2) * 0.9,
            tailSway: 0)
    }
    static let menuTranscribing = makeAnimationFrames { ctx, phase in
        drawSittingCat(ctx, headTilt: 0, earFlick: 0, tailSway: sin(phase * 2 * .pi))
    }
    static let menuRecordingAndTranscribing = makeAnimationFrames { ctx, phase in
        drawSittingCat(
            ctx,
            headTilt: sin(phase * 2 * .pi) * .pi / 45,
            earFlick: sin(phase * 2 * .pi + .pi / 2) * 0.9,
            tailSway: sin(phase * 2 * .pi))
    }

    /// 1周のフレーム数。0.12秒間隔で回すと約1秒で1周する。
    static let frameInterval: TimeInterval = 0.12
    private static let frameCount = 8
    private static let canvas = CGSize(width: 22, height: 18)

    private static func makeAnimationFrames(
        _ draw: @escaping (CGContext, CGFloat) -> Void
    ) -> [NSImage] {
        (0..<frameCount).map { frame in
            makeIcon { ctx in draw(ctx, CGFloat(frame) / CGFloat(frameCount)) }
        }
    }

    private static func makeIcon(_ draw: @escaping (CGContext) -> Void) -> NSImage {
        let image = NSImage(size: canvas, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(.black)
            ctx.setStrokeColor(.black)
            draw(ctx)
            return true
        }
        // テンプレート画像にすると、メニューバーの明暗にシステムが自動で追従させる。
        image.isTemplate = true
        return image
    }

    /// 正面向きの座り猫(長毛)。しっぽは右側で太いプルームとして立つ。
    /// フサフサ感は「輪郭そのものを連続した波型(スカラップ)の曲線にする」ことで出す。
    /// 個別の突起や切れ込みは棘・傷に見えるため使わない。尖りは耳だけ。
    /// パーツごとに個別に塗る(まとめて塗ると winding の相殺で重なりが白抜けする)。
    /// - headTilt: 首かしげ(ラジアン)。首の付け根を中心に回す。上下には動かさない。
    /// - earFlick: 耳の傾き(-1...1)。
    /// - tailSway: しっぽの振り(-1...1)。0 で基準の J カーブ。
    private static func drawSittingCat(
        _ ctx: CGContext, headTilt: CGFloat, earFlick: CGFloat, tailSway: CGFloat
    ) {
        func triangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) {
            let path = CGMutablePath()
            path.move(to: a)
            path.addLine(to: b)
            path.addLine(to: c)
            path.closeSubpath()
            ctx.addPath(path)
            ctx.fillPath()
        }
        /// 2次ベジェ上の点。
        func quadPoint(_ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint, _ t: CGFloat) -> CGPoint {
            let u = 1 - t
            return CGPoint(
                x: u * u * p0.x + 2 * u * t * c.x + t * t * p1.x,
                y: u * u * p0.y + 2 * u * t * c.y + t * t * p1.y)
        }
        /// 毛並みの縁。元の曲線を分割し、各区間を外側に膨らむ弧で繋ぐ。
        /// 弧と弧の継ぎ目が内向きのくぼみになり、フサフサした輪郭になる。
        func furEdge(
            _ path: CGMutablePath, from p0: CGPoint, control c: CGPoint, to p1: CGPoint,
            segments: Int, bulge: CGFloat, flip: Bool
        ) {
            var prev = p0
            for i in 1...segments {
                let pt = quadPoint(p0, c, p1, CGFloat(i) / CGFloat(segments))
                let d = CGPoint(x: pt.x - prev.x, y: pt.y - prev.y)
                let len = max(0.001, (d.x * d.x + d.y * d.y).squareRoot())
                let n = flip
                    ? CGPoint(x: -d.y / len, y: d.x / len)
                    : CGPoint(x: d.y / len, y: -d.x / len)
                let mid = CGPoint(x: (prev.x + pt.x) / 2, y: (prev.y + pt.y) / 2)
                path.addQuadCurve(
                    to: pt,
                    control: CGPoint(x: mid.x + n.x * bulge * 2, y: mid.y + n.y * bulge * 2))
                prev = pt
            }
        }

        // 体(ベル型)。左右の脇腹を毛並みの縁にする。
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 5.6, y: 16.6))
        body.addQuadCurve(to: CGPoint(x: 3.5, y: 14.4), control: CGPoint(x: 3.9, y: 16.5))
        furEdge(
            body, from: CGPoint(x: 3.5, y: 14.4), control: CGPoint(x: 3.3, y: 11.4),
            to: CGPoint(x: 5.8, y: 9.0), segments: 3, bulge: 0.55, flip: false)
        body.addQuadCurve(to: CGPoint(x: 12.2, y: 9.0), control: CGPoint(x: 9.0, y: 7.9))
        furEdge(
            body, from: CGPoint(x: 12.2, y: 9.0), control: CGPoint(x: 14.7, y: 11.4),
            to: CGPoint(x: 14.5, y: 14.4), segments: 3, bulge: 0.55, flip: false)
        body.addQuadCurve(to: CGPoint(x: 12.4, y: 16.6), control: CGPoint(x: 14.1, y: 16.5))
        body.closeSubpath()
        ctx.addPath(body)
        ctx.fillPath()

        // 前脚(裾から少し覗く2つの丸)
        ctx.fillEllipse(in: CGRect(x: 6.9, y: 15.7, width: 2.7, height: 1.9))
        ctx.fillEllipse(in: CGRect(x: 9.6, y: 15.7, width: 2.7, height: 1.9))

        // しっぽ(右側で立つ太いプルーム)。外縁を毛並みの縁にする。
        let s = tailSway
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: 12.2, y: 16.6))
        furEdge(
            tail, from: CGPoint(x: 12.2, y: 16.6),
            control: CGPoint(x: 20.8 + s * 0.9, y: 12.2),
            to: CGPoint(x: 18.2 + s * 1.7, y: 4.6), segments: 4, bulge: 0.55, flip: true)
        tail.addQuadCurve(
            to: CGPoint(x: 15.6 + s * 1.8, y: 4.8),
            control: CGPoint(x: 16.6 + s * 1.8, y: 3.0))
        tail.addQuadCurve(
            to: CGPoint(x: 13.5, y: 13.0),
            control: CGPoint(x: 16.2 + s * 0.9, y: 8.8))
        tail.closeSubpath()
        ctx.addPath(tail)
        ctx.fillPath()

        // 頭(首の付け根を中心に headTilt で傾ける)
        ctx.saveGState()
        let neck = CGPoint(x: 9.0, y: 8.6)
        ctx.translateBy(x: neck.x, y: neck.y)
        ctx.rotate(by: headTilt)
        ctx.translateBy(x: -neck.x, y: -neck.y)

        ctx.fillEllipse(in: CGRect(x: 4.7, y: 1.6, width: 8.6, height: 7.8))
        // 頬の毛(輪郭に沿った控えめなふくらみで丸頬に)
        ctx.fillEllipse(in: CGRect(x: 3.9, y: 4.6, width: 2.4, height: 2.8))
        ctx.fillEllipse(in: CGRect(x: 11.7, y: 4.6, width: 2.4, height: 2.8))
        // 耳(earFlick で先端が揺れる)
        triangle(
            CGPoint(x: 6.2 + earFlick * 0.6, y: 0.7),
            CGPoint(x: 5.4, y: 4.2), CGPoint(x: 8.2, y: 2.9))
        triangle(
            CGPoint(x: 11.8 + earFlick * 0.6, y: 0.7),
            CGPoint(x: 9.8, y: 2.9), CGPoint(x: 12.6, y: 4.2))
        ctx.restoreGState()
    }
}

/// 話者チップ。LP の .u .s と同じ配色(自分=青 / 相手=オレンジ)。
struct SpeakerChip: View {
    let speaker: String

    var body: some View {
        Text(speaker)
            .font(HCFont.system(size: 11, weight: .bold))
            .padding(.horizontal, 9)
            .padding(.vertical, 1)
            .foregroundStyle(speaker == "自分" ? HCColor.meText : HCColor.youText)
            .background(
                Capsule().fill(speaker == "自分" ? HCColor.meBackground : HCColor.youBackground))
    }
}

/// LP の .eq と同じ、揺れるイコライザーバー(装飾)。
struct EQBars: View {
    var active = true
    @State private var animating = false

    /// LP の .eq の delay と同じ値。線形でなくランダム風に位相をずらして自然な揺れに見せる。
    private static let delays: [Double] = [0, 0.18, 0.36, 0.1, 0.28]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(HCColor.cinnamon)
                    .frame(width: 3)
                    .scaleEffect(y: animating && active ? 1 : 0.25, anchor: .bottom)
                    .animation(
                        active
                            ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                                .delay(Self.delays[i])
                            : .default,
                        value: animating && active)
            }
        }
        .frame(height: 16)
        .onAppear { animating = true }
    }
}

/// LP の .rec と同じ、点滅する REC バッジ。
struct RecBadge: View {
    @State private var dimmed = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(HCColor.rec)
                .frame(width: 8, height: 8)
                .opacity(dimmed ? 0.15 : 1)
                .animation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true), value: dimmed)
            Text("REC")
                .font(HCFont.system(size: 10, weight: .bold))
                .kerning(1)
                .foregroundStyle(Color(red: 1, green: 122 / 255, blue: 122 / 255))
        }
        .onAppear { dimmed = true }
    }
}
