import HearCatKit
import SwiftUI

/// 検品ブロック(「この会議で決まった・変わったこと」)の表示行1件ぶん。
/// decisions.json 上のデータそのものではなく、SessionDetailView がそこから
/// 「このセッション由来のぶんだけ」を抜き出して整形した View 用の中間形。
struct DecisionRow: Identifiable, Equatable {
    let topicID: String
    let title: String
    /// このセッションより前の履歴の内容。無ければ新規決定。
    let previousText: String?
    let currentText: String
    let status: DecisionStatus
    let timeSeconds: Int?
    /// この議題の全履歴。展開時に DecisionTimelineView で描く。カード本文(previousText/
    /// currentText)の抽出規則とは別に、経緯を辿りたいときのためだけに保持する。
    let history: [DecisionEntry]

    var id: String { topicID }

    /// decisions.json 全体から、指定セッション由来のエントリを持つ議題だけを抜き出す。
    /// 同じ議題内に同セッション由来のエントリが複数あれば最後(=最新)を「現在」とし、
    /// その1つ前の履歴(セッションを問わない)を「旧内容」として突き合わせる。
    /// この「最後を現在とみなす」規則は DecisionLogStore.updateEntryText/removeEntries が
    /// 検品操作の対象を選ぶ規則と揃えている(表示している行と、実際に書き換わる行を一致させる)。
    static func rows(from log: DecisionLog, sessionDirectoryName: String) -> [DecisionRow] {
        log.topics.compactMap { topic in
            guard
                let index = topic.history.lastIndex(where: {
                    $0.sessionDirectoryName == sessionDirectoryName
                })
            else { return nil }
            let current = topic.history[index]
            let previous = index > 0 ? topic.history[index - 1] : nil
            return DecisionRow(
                topicID: topic.id, title: topic.title,
                previousText: previous?.text, currentText: current.text,
                status: current.status, timeSeconds: current.timeSeconds,
                history: topic.history)
        }
    }
}

/// 検品ブロックの本体。行の並びと区切り線だけを持ち、ジャンプ・修正・削除は
/// 呼び出し元(SessionDetailView)にクロージャで委ねる(decisions.json の読み書きは
/// このファイルに持たせず、セッションとの紐付けを知っている側に置く)。
struct DecisionBlockView: View {
    let rows: [DecisionRow]
    let onJump: (Int) -> Void
    let onEdit: (DecisionRow) -> Void
    let onRemove: (DecisionRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows) { row in
                DecisionRowContent(
                    row: row,
                    onJump: onJump,
                    onEdit: { onEdit(row) },
                    onRemove: { onRemove(row) })
                if row.id != rows.last?.id {
                    Divider()
                }
            }
        }
        .padding(8)
    }
}

/// 1議題ぶんの行。左に議題名と内容(変更があれば旧→新を縦に並べる)、右にステータス・
/// 時刻・「⋯」の操作メニュー。
private struct DecisionRowContent: View {
    let row: DecisionRow
    let onJump: (Int) -> Void
    let onEdit: () -> Void
    let onRemove: () -> Void

    /// 「⋯」メニューをボタン直下にポップアップするための土台。NSMenu を自前で使う理由は
    /// MenuSupport.swift のコメント参照。
    @State private var menuAnchor: NSView?
    @State private var menuActionHandler = MenuActionHandler()
    /// 全履歴タイムラインの展開状態。GroupDetailView.TopicRow と同じく行単位で持つ
    /// (複数カードを同時に開けてよく、他の行の開閉に連動する理由が無いため)。
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .font(HCFont.caption)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title)
                        .font(HCFont.style(.body, weight: .semibold))
                    // 展開中はタイムライン先頭(いまここ)と同じ内容が2回並んで見えるため隠す。
                    if !isExpanded {
                        content
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    DecisionStatusChip(status: row.status)
                    if let timeSeconds = row.timeSeconds {
                        Button(formatPlaybackTime(TimeInterval(timeSeconds))) {
                            onJump(timeSeconds)
                        }
                        .buttonStyle(.plain)
                        .font(HCFont.timecode)
                        .foregroundStyle(.tint)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .pointingHandOnHover()
                        .help("この位置から文字起こしへ移動")
                    }
                    moreButton
                }
            }
            .contentShape(Rectangle())
            // 行全体をタップ対象にしても、秒数ボタン・「⋯」ボタンは Button 自身のヒットテストが
            // 外側の onTapGesture より優先されるため奪われない(GroupDetailView.TopicRow と同じ理屈)。
            .onTapGesture { isExpanded.toggle() }

            if isExpanded {
                historySection
            }
        }
    }

    /// 全履歴タイムライン。カード本文(previousText/currentText、このセッション由来の抜粋)とは
    /// 別に、議題の変遷をまるごと辿るための導線。描画は GroupDetailView.TopicRow.historySection
    /// と同じ DecisionTimelineView を使うが、メタ行の組み立ては呼び出し元ごとに違うためここでも
    /// 個別に持つ(TopicRow 側との無理な共通化はしない)。
    private var historySection: some View {
        DecisionTimelineView(
            history: row.history,
            currentTextColor: .primary, pastTextColor: .secondary
        ) { entry in
            entryMetaRow(entry)
        }
        .padding(.leading, 20)
        .padding(.top, 6)
    }

    private func entryMetaRow(_ entry: DecisionEntry) -> some View {
        HStack(spacing: 4) {
            DecisionStatusChip(status: entry.status)
            Text(HCDate.list.string(from: entry.recordedAt))
                .font(HCFont.monospacedDigit(.caption1))
            Text(entry.sourceLabel)
            if let timeSeconds = entry.timeSeconds {
                Text("·")
                Button(formatPlaybackTime(TimeInterval(timeSeconds))) { onJump(timeSeconds) }
                    .buttonStyle(.plain)
                    .font(HCFont.timecode)
                    .foregroundStyle(.tint)
                    .pointingHandOnHover()
                    .help("この位置から文字起こしへ移動")
            }
            if !entry.isManual, let reason = entry.reason, !reason.isEmpty {
                Text("— \(reason)")
            }
        }
        .font(HCFont.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var content: some View {
        if let previousText = row.previousText {
            Text(previousText)
                .font(HCFont.caption)
                .foregroundStyle(.secondary)
            Text(row.currentText)
                .font(HCFont.callout)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.currentText)
                    .font(HCFont.callout)
                HCTextChip(text: "新規")
            }
        }
    }

    /// グリフの実寸は変えず、.frame + .contentShape でクリック判定だけ 24x24pt 相当まで広げる
    /// (GroupDetailView.TopicRow.archiveButton と同じ作り)。MenuAnchorView は label の背後に
    /// 敷いているため、広げたフレームがそのままアンカーの大きさになり、popUpMenu はこの枠の
    /// 下端から出る(位置関係は保たれる。以前より少し下から出るだけ)。
    private var moreButton: some View {
        Button {
            presentActionMenu()
        } label: {
            Image(systemName: "ellipsis")
                .imageScale(.small)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .pointingHandOnHover()
        .background(MenuAnchorView(anchor: $menuAnchor))
    }

    private func presentActionMenu() {
        guard let anchor = menuAnchor else { return }
        let menu = makeHCMenu()
        menu.addItem(menuActionHandler.makeItem("内容を修正…") { onEdit() })
        menu.addItem(menuActionHandler.makeItem("記録に残さない") { onRemove() })
        popUpMenu(menu, below: anchor)
    }
}

/// 検品ブロックの状態チップ。話者チップ(SpeakerChip)と同じ「暗い背景で明るく、明るい
/// 背景で濃く」の切り替えに倣う。「仮」は話者チップの「相手」と同じ色相を流用する
/// (DesignTokens.swift の HCColor.confirmedText 付近のコメント参照)。
/// グループ画面(GroupDetailView)の議題一覧でも同じ見た目にするため internal で共有する。
struct DecisionStatusChip: View {
    let status: DecisionStatus
    @Environment(\.colorScheme) private var colorScheme

    private var colors: (text: Color, background: Color) {
        switch status {
        case .confirmed:
            return colorScheme == .dark
                ? (HCColor.confirmedText, HCColor.confirmedBackground)
                : (HCColor.confirmedTextLight, HCColor.confirmedBackgroundLight)
        case .tentative:
            return colorScheme == .dark
                ? (HCColor.youText, HCColor.youBackground)
                : (HCColor.youTextLight, HCColor.youBackgroundLight)
        case .pending:
            // グレー系。ブランド色を割り当てるほどの主張は要らないので、明暗どちらでも
            // 読める標準の secondary をそのまま使う。
            return (.secondary, Color.primary.opacity(0.08))
        }
    }

    var body: some View {
        Text(status.displayName)
            .font(HCFont.style(.subheadline, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(colors.text)
            .background(HCRadius.shape(HCRadius.chip).fill(colors.background))
    }
}

/// 「内容を修正…」のシート。ImportSessionSheet と同じ「見出し + 入力 + 右下ボタン列」の
/// 構成に倣う。保存の実際の書き込み(DecisionLogStore.updateEntryText)は呼び出し元に委ねる。
struct DecisionEditSheet: View {
    let row: DecisionRow
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(row: DecisionRow, onSave: @escaping (String) -> Void) {
        self.row = row
        self.onSave = onSave
        _text = State(initialValue: row.currentText)
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(row.title)
                .font(HCFont.headline)
            TextField("内容", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .buttonStyle(.hcSecondary)
                Button("保存") {
                    onSave(trimmedText)
                    dismiss()
                }
                .buttonStyle(.hcPrimary)
                .disabled(trimmedText.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}
