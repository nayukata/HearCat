import AppKit
import CoreText
import SwiftUI

/// SwiftPM が生成するリソースバンドル(`hearcat_HearCatApp.bundle`)の base URL を探す。
/// HCFont(同梱フォント)と MermaidDiagramView(同梱 mermaid.min.js)の両方がこのバンドル配下の
/// 別ファイルを読むため、探索ロジックをここ1箇所に集約する。呼び出し側はここから
/// `Fonts` や `Mermaid/mermaid.min.js` を appendingPathComponent して使う。
///
/// SwiftPM 自動生成の `Bundle.module` は、まず `Bundle.main.bundleURL` 直下を探し、
/// 無ければ実行ファイルに焼き込まれたビルド時の絶対パス
/// (`.build/.../hearcat_HearCatApp.bundle`) にフォールバックする実装になっている。
/// 前者は `Makefile` が `Contents/Resources/` に配置するため常に外れる。後者は
/// ビルドマシン固有の一時ディレクトリで、`bootstrap.sh` 経由のインストールでは
/// 削除済み。両方失敗すると `Bundle.module` は内部で `fatalError` してプロセスごと
/// 落ちる(実際に起動時クラッシュの原因になった)ため、ここでは `Bundle.module` を使わず
/// 実際の配置場所を自前で探す。
func hcResourceBundleURL() -> URL? {
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

/// アプリ全体のフォント。欧文・数字はシステム(SF Pro)のまま、日本語グリフだけ
/// 同梱の Noto Sans JP に落とすカスケード指定を作る。フォントをここ以外で直接
/// 指定しない(SwiftUI 標準の .font(.caption) 等はシステムのフォールバック=
/// ヒラギノで描画されてしまうため)。
enum HCFont {
    /// 同梱フォントの登録。起動時に一度だけ呼ぶ。プロセススコープなのでシステムは汚さない。
    /// リソースバンドルが見つからなければ何もしない(カスケード先が未登録の場合、
    /// システムが従来どおりヒラギノに落とす。fatalError は絶対にしない)。
    static func registerBundledFonts() {
        guard let resourcesURL = hcResourceBundleURL() else { return }
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

    // MARK: - 文字のはしご
    //
    // pt ではなく役割で選ぶ。段は「実際に大きさが違うもの」だけを置く。
    // macOS の footnote / caption1 / caption2 は3つとも 10pt で、名前を変えても
    // 大きさは1ミリも変わらない(実測)。名前の数だけ段があると思って選ぶと必ず外すため、
    // 同じ大きさに複数の名前を与えない。
    //
    //   title3      15  画面の見出し
    //   headline    13  セクションの見出し(semibold)
    //   body        13  本文(文字起こし、要約、設定の項目名)
    //   callout     12  一段小さい本文(パネル内のボタン、バーのラベル)
    //   subheadline 11  ラベル、チップ、経過時間
    //   caption     10  補足説明、バッジ
    //
    // 太さを変えたい時は段を下げるのではなく style(_:weight:) で weight を渡す。

    static var title3: Font { style(.title3) }
    static var headline: Font { style(.headline, weight: .semibold) }
    static var body: Font { style(.body) }
    static var callout: Font { style(.callout) }
    static var subheadline: Font { style(.subheadline) }
    static var caption: Font { style(.caption1) }

    // MARK: - はしごから意図的に外すもの
    //
    // 下の3つだけは役割が固定で、はしごの段では表せない。ここ以外で pt を直書きしない。

    /// メニューバーのパネルに置くブランド名。ロゴマークと組にした意匠なので、
    /// 本文のはしご(13pt)には乗せず、マークの高さに合わせた大きさで固定する。
    static var brand: Font { system(size: 14, weight: .black) }
    /// 文字起こしの行頭と再生バーに出す経過時間。桁が揺れると行が踊るため数字を等幅にする。
    /// ライブ画面と履歴画面で同じ物差し・同じ見た目にするための唯一の口。
    static var timecode: Font { monospacedDigit(.caption1) }
    /// REC や「必須 / 任意」のような、短い語を詰めたバッジ。
    static var badge: Font { style(.caption1, weight: .bold) }
}

/// 角丸のはしご。面の大きさに比例させる(小さい面に大きい角丸は丸すぎ、
/// 大きい面に小さい角丸は角ばって見える)。半径はその面の高さの 1/4 を上限に選ぶ。
/// 角丸をここ以外に直書きしない。
enum HCRadius {
    /// 高さ 14pt 前後の極小の面。キーキャップなど。
    static let keycap: CGFloat = 4
    /// 高さ 20〜28pt の面。チップ、一覧の行のハイライト、細い枠。
    static let chip: CGFloat = 6
    /// 高さ 28〜36pt の面。ボタン、入力欄。
    static let control: CGFloat = 8
    /// 中の要素をまとめる面。バナー、カード、情報ブロック。
    static let card: CGFloat = 10
    /// ウィンドウ相当の外周。浮遊パネル、オーバーレイ。
    static let panel: CGFloat = 14

    /// 角丸の四角。style は必ず .continuous で揃える。既定の .circular と混ざると、
    /// 同じ半径でも角の曲がり方が違って見える。
    static func shape(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
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

    // 明るい背景向けの話者チップ。上の4色は暗い背景を前提に明るく振ってあるため、
    // ライトモードの履歴画面では地に沈んで読めない。色相は揃えたまま濃さだけ入れ替える。
    static let meTextLight = Color(red: 0x1B / 255, green: 0x4F / 255, blue: 0xB0 / 255)  // #1B4FB0
    static let meBackgroundLight = blue.opacity(0.12)
    static let youTextLight = Color(red: 0x8A / 255, green: 0x4E / 255, blue: 0x12 / 255)  // #8A4E12
    static let youBackgroundLight = Color(red: 255 / 255, green: 176 / 255, blue: 74 / 255).opacity(0.22)

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
                HCRadius.shape(HCRadius.control)
                    .fill(bg))
            .overlay(
                HCRadius.shape(HCRadius.control)
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
                HCRadius.shape(HCRadius.control)
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

/// HearCat のブランドマーク(猫の横顔)。原本は design/brand/hearcat-logo.svg。
/// 輪郭を折れ線で持つ。外形と内側の抜きが同じ配列に並ぶので、必ず even-odd で塗る。
/// 縦長(749 x 1007)なので、渡された矩形に縦横比を保って中央に収める。
struct HCLogoShape: Shape {
    private static let viewBox = CGSize(width: 749, height: 1007)

    /// [x, y, x, y, ...] を1ループとして並べたもの。
    private static let loops: [[Double]] = [
        [
            507.2, 1.1, 453.1, 54.2, 415.1, 97.2, 378.1, 144.2, 329.8, 212.9, 329.0, 211.8,
            337.0, 190.7, 336.9, 189.2, 335.4, 189.0, 305.3, 195.0, 288.2, 201.0, 271.2, 209.0,
            252.2, 221.1, 240.2, 230.1, 223.1, 246.2, 193.0, 282.2, 193.4, 284.0, 199.7, 283.0,
            219.7, 278.0, 229.2, 274.0, 228.9, 275.8, 218.9, 287.8, 201.8, 304.9, 189.8, 314.9,
            166.8, 330.0, 150.8, 338.0, 134.7, 344.0, 118.7, 348.0, 89.1, 351.0, 66.8, 349.0,
            47.3, 344.0, 44.1, 342.2, 44.1, 343.8, 62.2, 360.9, 76.2, 370.9, 85.7, 376.0,
            97.2, 381.0, 114.3, 386.0, 132.4, 389.0, 139.7, 389.0, 144.5, 390.6, 137.1, 399.2,
            120.0, 426.2, 103.0, 463.2, 89.0, 507.8, 74.0, 568.2, 67.0, 588.3, 59.0, 606.3,
            47.9, 624.8, 33.3, 641.9, 25.8, 648.9, 12.8, 657.9, 0.5, 663.4, 19.4, 668.0,
            38.1, 668.0, 58.2, 664.0, 79.3, 656.0, 102.8, 641.9, 117.8, 629.9, 133.9, 613.8,
            148.8, 596.1, 137.0, 634.8, 132.0, 657.8, 129.0, 681.9, 130.0, 717.6, 136.0, 747.2,
            146.0, 774.8, 157.1, 795.8, 177.1, 822.8, 203.2, 847.9, 223.2, 862.9, 236.2, 871.0,
            257.2, 882.0, 274.2, 889.0, 295.8, 896.0, 313.8, 899.9, 313.9, 898.7, 299.1, 880.8,
            293.0, 870.8, 282.0, 846.3, 277.0, 829.2, 274.0, 809.6, 274.0, 778.4, 278.0, 756.3,
            279.0, 752.2, 280.8, 750.5, 284.0, 761.8, 293.1, 778.8, 306.1, 795.8, 315.2, 804.9,
            331.2, 817.9, 350.2, 830.0, 388.3, 848.0, 405.8, 859.1, 424.9, 877.2, 436.0, 893.2,
            443.0, 908.2, 446.0, 917.8, 449.0, 934.9, 449.0, 951.6, 447.0, 965.2, 442.0, 980.8,
            438.0, 989.8, 426.6, 1006.8, 438.7, 1004.0, 462.3, 995.0, 488.8, 981.0, 509.8, 965.9,
            532.9, 943.8, 544.9, 928.8, 554.9, 912.8, 566.0, 888.8, 573.0, 864.7, 576.0, 842.1,
            575.0, 811.3, 570.0, 787.8, 566.0, 775.2, 555.0, 751.2, 544.9, 736.2, 529.9, 718.2,
            512.8, 702.1, 499.8, 692.1, 471.8, 674.0, 444.3, 659.0, 397.2, 636.0, 366.2, 617.9,
            350.2, 605.9, 334.1, 590.8, 321.0, 572.8, 314.0, 558.8, 309.0, 540.1, 308.0, 516.4,
            311.0, 497.3, 318.0, 477.2, 327.1, 460.2, 343.1, 439.2, 359.9, 423.7, 348.3, 426.0,
            331.7, 432.0, 296.5, 450.6, 301.0, 440.2, 312.1, 422.2, 322.1, 409.2, 349.9, 378.8,
            361.9, 363.8, 373.0, 346.8, 382.0, 327.8, 386.0, 315.7, 390.0, 297.2, 394.0, 242.9,
            402.0, 200.8, 411.0, 173.2, 427.0, 138.2, 444.1, 109.2, 461.1, 84.2, 483.1, 56.2,
            492.9, 46.2, 498.0, 144.9, 497.0, 205.8, 528.8, 216.0, 548.8, 224.0, 570.8, 235.0,
            587.8, 245.1, 604.8, 257.1, 615.8, 266.1, 632.9, 283.2, 648.0, 304.2, 657.0, 326.8,
            660.0, 347.4, 659.0, 380.6, 665.0, 397.3, 679.1, 415.8, 708.9, 447.2, 726.0, 467.3,
            724.3, 469.0, 704.0, 475.2, 716.0, 495.8, 716.0, 505.7, 711.0, 520.3, 697.9, 541.8,
            681.8, 558.9, 678.1, 561.2, 664.9, 587.8, 659.9, 594.8, 651.8, 602.9, 638.3, 612.0,
            623.2, 617.0, 607.1, 619.0, 568.4, 621.0, 554.1, 623.8, 598.8, 637.0, 610.4, 639.0,
            635.7, 638.0, 647.3, 634.0, 657.8, 627.9, 671.9, 614.8, 677.9, 606.8, 688.0, 588.3,
            694.1, 571.2, 711.9, 553.8, 722.0, 539.8, 733.0, 515.8, 749.0, 470.1, 746.0, 461.2,
            739.9, 453.2, 696.1, 404.8, 684.0, 387.8, 680.0, 375.1, 681.0, 344.9, 679.0, 325.8,
            673.0, 306.2, 664.9, 291.2, 652.9, 275.2, 634.8, 256.1, 615.8, 240.1, 596.0, 226.7,
            596.0, 219.8, 607.0, 152.6, 614.0, 89.1, 615.9, 58.2, 614.1, 58.2, 613.9, 59.8,
            592.1, 89.2, 522.9, 192.8, 521.5, 192.8, 518.0, 100.4, 509.0, 1.4, 507.2, 1.0,
        ],
        [
            447.2, 434.6, 406.4, 437.0, 400.3, 438.0, 400.2, 439.0, 423.6, 439.0, 445.6, 441.0,
            480.7, 446.0, 513.7, 453.0, 555.2, 465.0, 600.8, 481.0, 628.8, 493.0, 646.8, 502.5,
            640.8, 497.1, 606.8, 475.0, 587.8, 465.0, 558.8, 453.0, 525.7, 443.0, 494.2, 437.0,
            473.6, 435.0, 447.2, 434.5,
        ],
        [
            450.2, 487.1, 406.8, 492.0, 382.8, 497.0, 379.2, 498.0, 379.3, 499.0, 400.9, 497.0,
            453.6, 497.0, 511.7, 503.0, 571.2, 515.0, 618.7, 529.0, 640.3, 538.0, 637.8, 535.0,
            601.3, 515.0, 577.8, 505.0, 552.7, 497.0, 524.7, 491.0, 501.1, 488.0, 450.2, 487.0,
        ],
        [
            486.2, 537.1, 461.3, 540.0, 441.8, 544.0, 414.7, 552.0, 413.3, 554.0, 425.4, 551.0,
            465.4, 548.0, 513.6, 549.0, 574.2, 557.0, 616.2, 566.0, 631.3, 571.0, 629.8, 569.0,
            602.8, 556.0, 584.2, 549.0, 562.7, 543.0, 527.1, 537.0, 486.2, 537.0,
        ],
    ]

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / Self.viewBox.width, rect.height / Self.viewBox.height)
        let ox = rect.midX - Self.viewBox.width * scale / 2
        let oy = rect.midY - Self.viewBox.height * scale / 2
        var path = Path()
        for loop in Self.loops {
            var i = 0
            while i + 1 < loop.count {
                let point = CGPoint(x: ox + loop[i] * scale, y: oy + loop[i + 1] * scale)
                if i == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
                i += 2
            }
            path.closeSubpath()
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
    /// ライブ画面や共有カードは常に暗い背景だが、履歴画面はシステムの外観に従う。
    /// どちらでも読めるよう、実際に置かれた側の外観で色を選ぶ。
    @Environment(\.colorScheme) private var colorScheme

    private var isMe: Bool { speaker == "自分" }

    private var textColor: Color {
        if colorScheme == .dark { return isMe ? HCColor.meText : HCColor.youText }
        return isMe ? HCColor.meTextLight : HCColor.youTextLight
    }

    private var backgroundColor: Color {
        if colorScheme == .dark { return isMe ? HCColor.meBackground : HCColor.youBackground }
        return isMe ? HCColor.meBackgroundLight : HCColor.youBackgroundLight
    }

    var body: some View {
        Text(speaker)
            .font(HCFont.style(.subheadline, weight: .bold))
            .padding(.horizontal, 9)
            .padding(.vertical, 1)
            .foregroundStyle(textColor)
            .background(Capsule().fill(backgroundColor))
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
                .font(HCFont.badge)
                .kerning(1)
                .foregroundStyle(Color(red: 1, green: 122 / 255, blue: 122 / 255))
        }
        .onAppear { dimmed = true }
    }
}
