import AppKit
import SwiftUI

/// ランディングページ (docs/index.html) と揃えたデザイントークン。
/// 色をここ以外に直書きしない(LP とアプリの見た目を一緒に保つため)。
enum HCColor {
    static let navy = Color(red: 12 / 255, green: 18 / 255, blue: 38 / 255)  // #0C1226
    static let navy2 = Color(red: 19 / 255, green: 27 / 255, blue: 56 / 255)  // #131B38
    static let blue = Color(red: 61 / 255, green: 123 / 255, blue: 255 / 255)  // #3D7BFF
    static let blueSoft = Color(red: 143 / 255, green: 180 / 255, blue: 255 / 255)  // #8FB4FF
    static let whiteDim = Color.white.opacity(0.62)
    static let rec = Color(red: 255 / 255, green: 92 / 255, blue: 92 / 255)  // #FF5C5C

    // 話者チップ(自分 = 青系 / 相手 = オレンジ系)
    static let meText = Color(red: 191 / 255, green: 214 / 255, blue: 255 / 255)  // #BFD6FF
    static let meBackground = blue.opacity(0.22)
    static let youText = Color(red: 255 / 255, green: 225 / 255, blue: 184 / 255)  // #FFE1B8
    static let youBackground = Color(red: 255 / 255, green: 176 / 255, blue: 74 / 255).opacity(0.16)

    static var navyGradient: LinearGradient {
        LinearGradient(colors: [navy, navy2], startPoint: .top, endPoint: .bottom)
    }
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

/// メニューバー用のテンプレートアイコン。
/// 待機中は輪郭、セッション中は塗りつぶし(目のくり抜き)で状態を示す。
enum HCIcon {
    static let menuIdle = makeMenuIcon(filled: false)
    static let menuActive = makeMenuIcon(filled: true)

    private static func makeMenuIcon(filled: Bool) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let rect = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: 1.5, dy: 1.5)
            ctx.setFillColor(.black)
            ctx.setStrokeColor(.black)
            if filled {
                ctx.addPath(CatHeadShape(includesEyes: true).path(in: rect).cgPath)
                ctx.fillPath(using: .evenOdd)
            } else {
                ctx.addPath(CatHeadShape().path(in: rect).cgPath)
                ctx.setLineWidth(1.5)
                ctx.setLineJoin(.round)
                ctx.strokePath()
                ctx.addPath(CatHeadShape.eyes(in: rect).cgPath)
                ctx.fillPath()
            }
            return true
        }
        // テンプレート画像にすると、メニューバーの明暗にシステムが自動で追従させる。
        image.isTemplate = true
        return image
    }
}

/// 話者チップ。LP の .u .s と同じ配色(自分=青 / 相手=オレンジ)。
struct SpeakerChip: View {
    let speaker: String

    var body: some View {
        Text(speaker)
            .font(.system(size: 11, weight: .bold))
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

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(HCColor.blueSoft)
                    .frame(width: 3)
                    .scaleEffect(y: animating && active ? 1 : 0.25, anchor: .bottom)
                    .animation(
                        active
                            ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.09)
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
                .font(.system(size: 10, weight: .bold))
                .kerning(1)
                .foregroundStyle(Color(red: 1, green: 122 / 255, blue: 122 / 255))
        }
        .onAppear { dimmed = true }
    }
}
