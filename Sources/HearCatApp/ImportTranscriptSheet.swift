import AppKit
import HearCatKit
import SwiftUI
import UniformTypeIdentifiers

/// Google Meet や Zoom の文字起こしを取り込む画面。
///
/// 入口を貼り付けとファイルの両方にしているのは、書き出し方が会議アプリごとに違うため。
/// Google Meet の文字起こしは Google ドキュメントに残るのでコピーが最短で、Zoom は
/// 字幕ファイル (.vtt) を落とす形になる。
///
/// 読み取れた内容(誰が何回話したか)を見せてから保存するのは、.hearcat の取り込みと同じ
/// 考え方で、取り違えたファイルをそのまま履歴に入れないため。
struct ImportTranscriptSheet: View {
    let model: AppModel

    /// 入れ先の選び方。ImportSessionSheet と同じ語彙・同じ並びにする。
    private enum Destination: Hashable {
        case unclassified
        case existing(String)
        case new
    }

    @State private var raw = ""
    @State private var parsed: MeetingTranscriptImport.Parsed?
    @State private var parseError: String?
    /// ファイルから読んだ場合の元のファイル名。貼り付けなら nil。
    @State private var sourceName: String?
    /// ファイル名から得た手がかり。中身に会議名や日付が無い形式(Zoom の字幕ファイル)の
    /// ために持つ。本文を読み直すたびに使うので、ファイルを選んだ時点で控えておく。
    @State private var fileHints: (name: String?, start: Date?)?
    /// 読み込んだファイルの中身。貼り替えられたらファイル名の手がかりを捨てるために持つ
    /// (別の会議を貼り付けたのに、前のファイル名の日時が残ると取り違えになる)。
    @State private var fileText: String?

    @State private var name = ""
    @State private var startDate = Date()
    /// 取り込み後に「自分」として扱う話者。選ばなければ全員が相手になる。
    @State private var me: String?
    @State private var startNeedsTime = false
    /// 開始日時の暦を出しているか。
    @State private var editingStart = false
    /// 直前に当てはめた推測値。本文は読み直すたびに解析し直されるため、これと今の値を
    /// 見比べて「利用者が直したかどうか」を判断する(直した会議名や日時を、本文を
    /// 少し編集しただけで元へ戻してしまわないように)。
    @State private var appliedName: String?
    @State private var appliedStart: Date?

    @State private var destination: Destination = .unclassified
    @State private var newFolderName = ""
    /// このシート自身のウィンドウ。ファイル選択をここへ貼り付けるために持つ。
    /// 履歴ウィンドウへ貼ろうとすると、既にこのシートが載っているため macOS が
    /// 2枚目のシートを待たせ、パネルが出ないまま押しても何も起きない状態になる。
    @State private var sheetWindow: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            input
            if let parsed {
                resultCard(parsed)
                fields(parsed)
            } else if let parseError {
                Text(parseError)
                    .font(HCFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            buttons
        }
        .padding(22)
        .frame(width: 500)
        .background(WindowAccessor { sheetWindow = $0 })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("文字起こしを取り込む")
                .font(HCFont.headline)
            Text(sourceName ?? "Google Meet や Zoom の文字起こしから、セッションを作ります")
                .font(HCFont.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 入力

    private var input: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $raw)
                    .font(HCFont.callout)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 120)
                    .background(
                        HCRadius.shape(HCRadius.card).fill(.quaternary.opacity(0.5)))
                if raw.isEmpty {
                    // 本文の起点に重ねる。TextEditor に付けた余白(6)に加えて、
                    // 中の NSTextView が持つ行の余白(左 5・上 1)ぶんずらす
                    // (これを見ないと、カーソルと案内文が縦横ともにずれる)。
                    Text("ここに文字起こしを貼り付ける")
                        .font(HCFont.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 11)
                        .padding(.top, 7)
                        .allowsHitTesting(false)
                }
            }
            HStack {
                Button("ファイルを選ぶ…") { chooseFile() }
                    .pointingHandOnHover()
                Spacer()
                if parsed != nil || !raw.isEmpty {
                    Button("消す") { reset() }
                        .buttonStyle(.plain)
                        .font(HCFont.caption)
                        .foregroundStyle(.secondary)
                        .pointingHandOnHover()
                }
            }
        }
        .onChange(of: raw) { _, _ in reparse() }
    }

    /// 読み取れた中身。取り違えたファイルをそのまま履歴へ入れないための確認材料なので、
    /// 「何人が何回話したか」まで見せる。
    private func resultCard(_ parsed: MeetingTranscriptImport.Parsed) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "text.quote")
                    .font(HCFont.caption)
                    .frame(width: 16)
                Text(parsed.source.displayName)
                Spacer(minLength: 12)
                Text("\(parsed.utterances.count) 発言 / \(durationText(parsed.duration))")
                    .foregroundStyle(.secondary)
            }
            .font(HCFont.callout)

            if parsed.speakers.isEmpty {
                Text("話者の名前は入っていません。全員が「相手」になります。")
                    .font(HCFont.caption)
                    .foregroundStyle(.secondary)
            } else {
                // 発言数の多い順ではなく出てきた順。元の文字起こしと見比べやすくする。
                FlowRow(spacing: 6) {
                    ForEach(parsed.speakers, id: \.self) { speaker in
                        HCTextChip(text: "\(speaker) (\(count(of: speaker, in: parsed)))")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(HCRadius.shape(HCRadius.card).fill(.quaternary.opacity(0.5)))
    }

    // MARK: - 取り込みの設定

    @ViewBuilder
    private func fields(_ parsed: MeetingTranscriptImport.Parsed) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            field("会議名") {
                TextField("例: マーケ定例", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            field("開始日時") {
                VStack(alignment: .leading, spacing: 4) {
                    // 日時の欄を数字の升目(macOS の既定)で出すと、桁が右揃えになって
                    // 「2026/ 9/ 3」のように隙間が空き、他の画面での日時の書き方とも
                    // 食い違う。表示はアプリ内と同じ書き方に揃え、押したときだけ
                    // 暦を出して直せるようにする。
                    Button {
                        editingStart = true
                    } label: {
                        Text(startDate.formatted(date: .long, time: .shortened))
                            .font(HCFont.callout)
                    }
                    .pointingHandOnHover()
                    .popover(isPresented: $editingStart, arrowEdge: .bottom) {
                        DatePicker(
                            "", selection: $startDate,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding(14)
                    }
                    if startNeedsTime {
                        Text("元の文字起こしに開始時刻がありません。")
                            .font(HCFont.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !parsed.speakers.isEmpty {
                field("自分") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("", selection: $me) {
                            Text("選ばない").tag(String?.none)
                            ForEach(parsed.speakers, id: \.self) { speaker in
                                Text(speaker).tag(String?.some(speaker))
                            }
                        }
                        .labelsHidden()
                        .pointingHandOnHover()
                        preview(parsed)
                    }
                }
            }
            field("グループ") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: $destination) {
                        Text("未分類").tag(Destination.unclassified)
                        ForEach(model.folders, id: \.self) { folder in
                            Text(folder).tag(Destination.existing(folder))
                        }
                        Divider()
                        Text("新しいグループ…").tag(Destination.new)
                    }
                    .labelsHidden()
                    .pointingHandOnHover()
                    if destination == .new {
                        TextField("グループ名 (例: プロジェクトA)", text: $newFolderName)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
    }

    /// 取り込んだ後どう並ぶかの見本。話者ごとの最初の発言を、履歴画面と同じ話者チップで出す。
    /// 「名前が残るのか、自分と相手に畳まれるのか」は、文章で説明するより見せたほうが早い
    /// (選び直すとその場で色が入れ替わる)。
    private func preview(_ parsed: MeetingTranscriptImport.Parsed) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(previewRows(parsed), id: \.speaker) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(elapsed(row.offset))
                        .font(HCFont.timecode)
                        .foregroundStyle(.secondary)
                    SpeakerChip(
                        speaker: row.speaker == me ? "自分" : "相手", name: row.speaker)
                    Text(row.text)
                        .font(HCFont.callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 見本に出す発言。話者ごとの最初の1つを、出てきた順に最大3人ぶん。
    private func previewRows(
        _ parsed: MeetingTranscriptImport.Parsed
    ) -> [(speaker: String, offset: TimeInterval, text: String)] {
        parsed.speakers.prefix(3).compactMap { speaker in
            guard let first = parsed.utterances.first(where: { $0.speaker == speaker })
            else { return nil }
            return (speaker, first.offset, first.text)
        }
    }

    /// 経過時間。文字起こしの行頭と同じ「分:秒」で出す。
    private func elapsed(_ offset: TimeInterval) -> String {
        let total = Int(offset.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 見出しを左に置いた1項目。項目名の幅を揃えて、値の左端を縦に通す。
    private func field<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(HCFont.style(.subheadline, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            content()
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("キャンセル", role: .cancel) {
                model.dismissTranscriptImport()
            }
            .keyboardShortcut(.cancelAction)
            .pointingHandOnHover()
            Button("取り込む") {
                guard let parsed else { return }
                model.confirmTranscriptImport(
                    parsed, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    startDate: startDate, me: me, intoFolder: resolvedFolder)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canImport)
            .pointingHandOnHover(disabled: !canImport)
        }
    }

    // MARK: - 状態

    private var canImport: Bool {
        parsed != nil && !(destination == .new && trimmedNewFolderName.isEmpty)
    }

    private var trimmedNewFolderName: String {
        newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resolvedFolder: String? {
        switch destination {
        case .unclassified: return nil
        case .existing(let folder): return folder
        case .new: return trimmedNewFolderName.isEmpty ? nil : trimmedNewFolderName
        }
    }

    private func count(of speaker: String, in parsed: MeetingTranscriptImport.Parsed) -> Int {
        parsed.utterances.count { $0.speaker == speaker }
    }

    /// 会議の長さ。最後の発言の位置なので、1分未満は「1 分未満」に丸める。
    private func durationText(_ duration: TimeInterval) -> String {
        duration < 60 ? "1 分未満" : "約 \(Int(duration / 60)) 分"
    }

    // MARK: - 読み取り

    private func reparse() {
        let text = raw
        // 読み込んだファイルと中身が変わったら、そのファイル名から得た手がかりは捨てる。
        if let loaded = fileText, loaded != text {
            fileHints = nil
            sourceName = nil
            fileText = nil
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            parsed = nil
            parseError = nil
            return
        }
        do {
            apply(try MeetingTranscriptImport.parse(text))
        } catch {
            parsed = nil
            parseError = error.localizedDescription
        }
    }

    /// 読み取れた内容を各項目の初期値にする。会議名と開始日時は、ここで入れたあと
    /// ユーザーが直せる(会議アプリの文字起こしは、どちらも欠けていることがある)。
    /// 中身から読めた値をファイル名の手がかりより優先する。
    private func apply(_ result: MeetingTranscriptImport.Parsed) {
        let first = parsed == nil
        parsed = result
        parseError = nil

        let suggestedName = result.suggestedName ?? fileHints?.name ?? ""
        if first || name == appliedName { name = suggestedName }
        // 覚えるのは「当てはめた値そのもの」。候補が無くて既定値を入れた場合に候補側
        // (nil や空)を覚えると、利用者が触っていないのに触った扱いになり、後から
        // 正しい会議名や日時が読めても二度と反映されなくなる。
        appliedName = name

        let fromFileName = fileHints?.start
        let suggestedStart = fromFileName ?? result.suggestedStart
        if first || startDate == appliedStart {
            startDate = suggestedStart ?? (first ? Date() : startDate)
        }
        appliedStart = startDate

        // ファイル名から読めた日時は時刻まで分かっている。断りが要るのは、
        // 中身の日付行しか手がかりが無い場合だけ。
        startNeedsTime =
            fromFileName == nil && result.suggestedStart != nil && !result.suggestedStartHasTime
        // 別の文字起こしに差し替えられて、選んでいた人が居なくなった場合だけ選び直させる。
        // 本文を少し直しただけで選択が消えると、そのまま取り込んで全員が相手になる。
        if let current = me, !result.speakers.contains(current) { me = nil }
    }

    private func reset() {
        raw = ""
        parsed = nil
        parseError = nil
        sourceName = nil
        fileHints = nil
        fileText = nil
        appliedName = nil
        appliedStart = nil
        me = nil
    }

    private func chooseFile() {
        Task {
            guard let url = await TranscriptFilePicker.chooseFile(from: sheetWindow) else {
                return
            }
            sourceName = url.lastPathComponent
            fileHints = MeetingTranscriptImport.hints(forFileNamed: url.lastPathComponent)
            do {
                // 貼り付け欄に中身を出し、読み取りはそこからの1経路に揃える
                // (取り込む前に中身を目で確かめられるようにするためでもある)。
                let text = try MeetingTranscriptImport.readText(at: url)
                fileText = text
                if text == raw {
                    // 同じ内容を選び直した場合は onChange が来ないので、ここで読み直す。
                    reparse()
                } else {
                    raw = text
                }
            } catch {
                // 読めなかったファイルの名前を手がかりとして残さない。
                fileHints = nil
                fileText = nil
                parsed = nil
                parseError = error.localizedDescription
            }
        }
    }
}

/// 会議アプリの文字起こしファイルの選択パネル。
enum TranscriptFilePicker {
    @MainActor
    static func chooseFile(from window: NSWindow?) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "文字起こしを取り込む"
        panel.message = "Zoom の字幕ファイル (.vtt) や、書き出した文字起こし (.txt) を選んでください。"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // .vtt は宣言している型が環境によって無いことがあるため、拡張子からも受ける。
        panel.allowedContentTypes = [
            UTType(filenameExtension: "vtt"), UTType(filenameExtension: "srt"),
            .plainText, .text,
        ].compactMap { $0 }
        return await FilePanel.present(panel, from: window) == .OK ? panel.url : nil
    }
}

/// 幅に収まらなくなったら折り返す横並び。話者チップのように、数も長さも中身次第で
/// 変わるものを並べるために使う。
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
