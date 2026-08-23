import HearCatKit
import SwiftUI

/// 「ようこそ」画面の絵。スクリーンショットではなく、アプリと同じ部品・トークンで描く。
/// 中の部品はすべて操作できない(WelcomeCard が allowsHitTesting(false) をまとめて掛ける)。
/// 各絵は WelcomeView.swift の各ページから1つずつ呼ばれる。

/// 「surface 地のカード」の共通の枠。ページ1・3・4の絵に使う(ページ2は枠なし)。
private struct WelcomeCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HCRadius.shape(HCRadius.card).fill(HCColor.surface))
        .overlay(HCRadius.shape(HCRadius.card).stroke(HCColor.strokeLine, lineWidth: 1))
        .allowsHitTesting(false)
    }
}

/// 文字起こしの行1つ。時刻 + 話者チップ + 本文。ライブ画面(LiveSessionView.segmentLine)と
/// 同じ組み合わせを絵として再現する。live: true は認識中の行(本文を textDim に落とす)。
private struct WelcomeTranscriptRow: View {
    let time: String
    let speaker: String
    let text: String
    var live = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(time)
                .font(HCFont.timecode)
                .foregroundStyle(HCColor.textDim)
                .frame(width: 34, alignment: .leading)
            SpeakerChip(speaker: speaker)
            Text(text)
                .font(HCFont.callout)
                .foregroundStyle(live ? HCColor.textDim : HCColor.textBody)
        }
    }
}

// MARK: - ページ1: ようこそ

/// 「録音中 12:34」+ 文字起こし4行(最後の1行は認識中)。
struct WelcomeTranscriptIllustration: View {
    var body: some View {
        WelcomeCard {
            HStack {
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(HCColor.recText).frame(width: 6, height: 6)
                    Text("録音中 12:34")
                        .font(HCFont.badge)
                }
                .foregroundStyle(HCColor.recText)
            }
            VStack(alignment: .leading, spacing: 8) {
                WelcomeTranscriptRow(time: "10:02", speaker: "相手", text: "来週の公開、金曜でいけそうですか？")
                WelcomeTranscriptRow(time: "10:02", speaker: "自分", text: "大丈夫です。木曜に最終確認しましょう。")
                WelcomeTranscriptRow(time: "10:03", speaker: "相手", text: "では金曜で確定にします。")
                WelcomeTranscriptRow(time: "10:03", speaker: "自分", text: "了解です、議事録に残して…", live: true)
            }
        }
    }
}

// MARK: - ページ2: 始め方はこれだけ

/// メニューバーの帯 + パネルの複製。枠なし。
struct WelcomeStartIllustration: View {
    @Environment(\.colorScheme) private var colorScheme

    /// メニューバーの帯の地色。実物のメニューバーそのものの色で、HCColor の
    /// パネル系トークンとは無関係な一回限りの値のため、ここだけで colorScheme 分岐する。
    /// ライト側は実物のメニューバー(明るい地)に合わせ、HCColor.mistLightSurface 相当にする。
    private var menuBarColor: Color {
        colorScheme == .dark
            ? Color(red: 0x1C / 255, green: 0x2A / 255, blue: 0x4A / 255)
            : HCColor.mistLightSurface
    }

    /// 帯の上のアイコン。実物のメニューバーはライトで黒、ダークで白のアイコンになる。
    private var menuBarIconFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.28) : Color.black.opacity(0.35)
    }

    private var menuBarLogoBoxFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.06)
    }

    private var menuBarCatFill: Color {
        colorScheme == .dark ? Color.white : Color.black.opacity(0.8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            menuBar
            HStack {
                Spacer()
                panel
                    .frame(width: 290)
            }
        }
        .allowsHitTesting(false)
    }

    private var menuBar: some View {
        HStack(spacing: 14) {
            Spacer()
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(menuBarIconFill)
                    .frame(width: 14, height: 14)
            }
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(menuBarLogoBoxFill)
                .frame(width: 26, height: 20)
                .overlay(
                    HCLogoShape()
                        .fill(menuBarCatFill, style: FillStyle(eoFill: true))
                        .frame(width: 15, height: 15))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(HCColor.accent, lineWidth: 2)
                        .padding(-2))
            Color.clear.frame(width: 60, height: 1)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 6, bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                topTrailingRadius: 6, style: .continuous
            )
            .fill(menuBarColor))
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelHeader
            startRow
            destRow
            footerRow
        }
        .padding(12)
        .background(HCRadius.shape(HCRadius.panel).fill(HCColor.panel))
        .overlay(HCRadius.shape(HCRadius.panel).stroke(HCColor.strokeLine, lineWidth: 1))
    }

    private var panelHeader: some View {
        HStack(spacing: 8) {
            HCLogoShape()
                .fill(HCColor.textDim, style: FillStyle(eoFill: true))
                .frame(width: 14, height: 18)
            Text("HearCat")
                .font(HCFont.brand)
                .foregroundStyle(HCColor.textPrimary)
            Spacer()
            Text("待機中")
                .font(HCFont.subheadline)
                .foregroundStyle(HCColor.textDim)
        }
    }

    /// 開始ボタンの外側に textPrimary 2pt の枠(角丸はボタンに合わせ 3pt 外側)で強調する。
    /// 負のパディングで枠だけを外側にはみ出させ、周りのレイアウトは動かさない。
    private var startRow: some View {
        HStack(spacing: 6) {
            Button {
            } label: {
                Label(
                    SessionStartMode.recordAndTranscribe.buttonLabel,
                    systemImage: SessionStartMode.recordAndTranscribe.systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.hcPrimary)
            .overlay(
                RoundedRectangle(cornerRadius: HCRadius.control + 3, style: .continuous)
                    .stroke(HCColor.textPrimary, lineWidth: 2)
                    .padding(-3))

            Button {
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.hcSecondary)
        }
    }

    private var destRow: some View {
        HStack(spacing: 4) {
            Text("保存先: ")
                .foregroundStyle(HCColor.textDim)
            HStack(spacing: 2) {
                Text("未分類")
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(HCColor.textBody)
            Text("・")
                .foregroundStyle(HCColor.textDim)
            Text("資料フォルダを紐付ける")
                .underline(pattern: .dot)
                .foregroundStyle(HCColor.textDim)
        }
        .font(HCFont.caption)
    }

    private var footerRow: some View {
        HStack(spacing: 8) {
            Button {
            } label: {
                Label("履歴", systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity)
            }
            Button {
            } label: {
                Label("設定", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            Button {
            } label: {
                Image(systemName: "ellipsis")
            }
        }
        .buttonStyle(.hcSecondary)
    }
}

// MARK: - ページ3: 会議中にできること

/// 文字起こし3行(最後は認識中) + 「AI に質問」ボタン + Q/A。
struct WelcomeDuringIllustration: View {
    var body: some View {
        WelcomeCard {
            VStack(alignment: .leading, spacing: 8) {
                WelcomeTranscriptRow(time: "10:02", speaker: "相手", text: "来週の公開、金曜でいけそうですか？")
                WelcomeTranscriptRow(time: "10:02", speaker: "自分", text: "大丈夫です。木曜に最終確認しましょう。")
                WelcomeTranscriptRow(time: "10:03", speaker: "相手", text: "では金曜で…", live: true)
            }
            Rectangle().fill(HCColor.strokeLine).frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                askButton
                questionRow
                answerRow
            }
        }
    }

    /// 実物(MenuPanel.swift の「会話について AI に質問」ボタン)と同じ組み立て。
    private var askButton: some View {
        Button {
        } label: {
            Label("会話について AI に質問", systemImage: "text.magnifyingglass")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.hcSecondary)
    }

    private var questionRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("Q")
                .font(HCFont.style(.callout, weight: .heavy))
                .foregroundStyle(HCColor.accentText)
            Text("さっき決まった公開日は？")
                .font(HCFont.callout)
                .foregroundStyle(HCColor.textPrimary)
        }
    }

    private var answerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("金曜です。木曜に最終確認をする話でした。")
                .font(HCFont.callout)
                .foregroundStyle(HCColor.textBody)
            Text("10:02")
                .font(HCFont.timecode)
                .foregroundStyle(HCColor.accentText)
                .padding(.horizontal, 4)
                .overlay(HCRadius.shape(HCRadius.keycap).stroke(HCColor.accentStroke, lineWidth: 1))
        }
        .padding(.leading, 14)
    }
}

// MARK: - ページ4: 終わったあとは、AI が要約を作る

/// 履歴の1画面(議題名 + 決まったこと + 要約 + 文字起こし)をそのままの並びで。
struct WelcomeAfterIllustration: View {
    /// history は recordedAt 昇順(DecisionTimelineView の約束どおり)。
    /// 会話由来(origin なし)のセッション名は「定例」で統一。
    private static let history: [DecisionEntry] = [
        DecisionEntry(
            text: "来週中に公開", status: .tentative,
            sessionDirectoryName: "welcome-illustration-1", sessionName: "定例",
            recordedAt: date(2026, 8, 14, 14, 10), timeSeconds: 850),
        DecisionEntry(
            text: "金曜に公開", status: .confirmed,
            sessionDirectoryName: "welcome-illustration-2", sessionName: "定例",
            recordedAt: date(2026, 8, 21, 10, 3), timeSeconds: 603),
    ]

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components) ?? Date()
    }

    var body: some View {
        WelcomeCard {
            Text("8/21 定例 — 公開日の調整")
                .font(HCFont.style(.body, weight: .semibold))
                .foregroundStyle(HCColor.textPrimary)
            decisionsSection
            summarySection
            transcriptSection
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(HCFont.style(.caption1, weight: .bold))
            .foregroundStyle(HCColor.textDim)
    }

    private var decisionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("決まったこと")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "chevron.down")
                    .font(HCFont.caption)
                    .foregroundStyle(HCColor.textDim)
                DecisionStatusChip(status: .confirmed)
                Text("公開日")
                    .font(HCFont.style(.body, weight: .semibold))
                    .foregroundStyle(HCColor.textPrimary)
            }
            DecisionTimelineView(
                history: Self.history,
                currentTextColor: .primary, pastTextColor: .secondary
            ) { entry in
                entryMetaRow(entry)
            }
            .padding(.leading, 20)
        }
    }

    /// DecisionBlock.swift の entryMetaRow と同じ並び。ジャンプボタンはただの文字にする
    /// (絵の中は操作できないため)。
    private func entryMetaRow(_ entry: DecisionEntry) -> some View {
        HStack(spacing: 4) {
            DecisionStatusChip(status: entry.status)
            Text(HCDate.list.string(from: entry.recordedAt))
                .font(HCFont.monospacedDigit(.caption1))
            Text(entry.sourceLabel)
            if let timeSeconds = entry.timeSeconds {
                Text("·")
                Text(formatPlaybackTime(TimeInterval(timeSeconds)))
                    .font(HCFont.timecode)
                    .foregroundStyle(HCColor.accentText)
            }
        }
        .font(HCFont.caption)
        .foregroundStyle(.secondary)
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("要約")
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(HCColor.lift(0.10))
                .frame(height: 7)
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(HCColor.lift(0.10))
                    .frame(width: proxy.size.width * 0.7, height: 7)
            }
            .frame(height: 7)
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("文字起こし")
            WelcomeTranscriptRow(time: "10:03", speaker: "相手", text: "では金曜で確定にします。")
        }
    }
}
