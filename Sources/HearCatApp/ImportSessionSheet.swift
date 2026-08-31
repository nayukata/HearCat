import HearCatKit
import SwiftUI

/// 受け取った .hearcat を取り込む前の確認画面。
/// 中身(録音が入っているかどうかを含む)を見せてから、入れ先のグループを選ばせる。
/// 他人の会話の音声が入り得るファイルなので、開いた瞬間に保存先へ書き込むことはしない。
struct ImportSessionSheet: View {
    let model: AppModel
    let pending: AppModel.PendingImport

    /// 入れ先の選び方。Picker の選択値として使うため Hashable にする。
    private enum Destination: Hashable {
        case unclassified
        case existing(String)
        case new
    }

    @State private var destination: Destination
    @State private var newFolderName: String
    /// manifest 由来で変わらない値。body の再評価(グループ名の入力中など)のたびに
    /// 整形し直さないよう、ここで1度だけ作る。
    private let startDateText: String

    init(model: AppModel, pending: AppModel.PendingImport) {
        self.model = model
        self.pending = pending
        self.startDateText = pending.opened.manifest.startDate
            .formatted(date: .long, time: .shortened)
        // 入れ先は既定で未分類にする。送り主のグループ名と同じ名前のグループが手元に
        // あっても、それが同じものとは限らない(相手の「定例」と自分の「定例」は別)。
        // 自動で選ぶと、受け取った他人の会議が自分のプロジェクトの記録に気づかず混ざる。
        // 送り主のグループ名は画面に出し、選択肢にも並ぶので、そこへ入れたい場合は選べる。
        _destination = State(initialValue: .unclassified)
        _newFolderName = State(initialValue: pending.opened.manifest.folder ?? "")
    }

    private var manifest: SessionPackage.Manifest { pending.opened.manifest }
    /// 展開済みのセッション。保存済みのセッションと同じ API で中身を見る。
    private var session: SessionInfo { pending.opened.session }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            contentCard
            destinationField
            Divider()
            buttons
        }
        .padding(22)
        .frame(width: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("セッションを取り込む")
                .font(HCFont.headline)
            Text(pending.sourceName)
                .font(HCFont.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 受け取ったセッションの中身。「何が入っているか」が取り込むかどうかの判断材料
    /// (特に録音の有無)なので、1行に詰めず、履歴一覧と同じアイコンで縦に並べる。
    private var contentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 名前があれば名前が主役、無ければ日時が主役。履歴一覧(SessionRow)と同じ規則に
            // 揃える(同じセッションが、取り込む前と後で違う見え方をしないように)。
            VStack(alignment: .leading, spacing: 2) {
                Text(manifest.sessionName.isEmpty ? startDateText : manifest.sessionName)
                    .font(HCFont.style(.body, weight: .semibold))
                if !manifest.sessionName.isEmpty {
                    Text(startDateText)
                        .font(HCFont.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                // アイコンは履歴一覧(SessionRow)と同じものを使う。
                contentRow(
                    icon: "text.quote", title: "文字起こし",
                    detail: pending.opened.transcriptCharacterCount > 0
                        ? "\(pending.opened.transcriptCharacterCount) 文字" : nil)
                contentRow(icon: "waveform", title: "録音", detail: audioDetail)
                contentRow(
                    icon: "list.bullet.rectangle", title: "要約",
                    detail: session.summaryURL != nil ? "あり" : nil)
                // 下の選択肢に同じ名前が並ぶ理由が分かるように、出所を明示する
                // (既定では選ばないが、そこへ入れたい場合の手がかりになる)。
                if let origin = manifest.folder, !origin.isEmpty {
                    contentRow(icon: "folder", title: "送り主のグループ", detail: origin)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            HCRadius.shape(HCRadius.card)
                .fill(.quaternary.opacity(0.5)))
    }

    /// 入っているものは通常の濃さ、入っていないものは薄く「なし」。
    /// 並びを固定することで、録音が入っていないことも一目で分かるようにする。
    private func contentRow(icon: String, title: String, detail: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(HCFont.caption)
                .frame(width: 16)
            Text(title)
            Spacer(minLength: 12)
            Text(detail ?? "なし")
                .foregroundStyle(detail == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
        }
        .font(HCFont.callout)
        .foregroundStyle(detail == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
    }

    /// 録音の長さ。1分未満は「45 秒」、それ以上は「12 分」。入っていなければ nil。
    /// 入っているかどうかは manifest ではなく実体で判定する。
    private var audioDetail: String? {
        guard session.audioURL != nil else { return nil }
        // 長さを読めない録音でも、入っていること自体は伝える。
        guard let duration = pending.opened.audioDuration else { return "あり" }
        return duration < 60
            ? "\(Int(duration.rounded())) 秒"
            : "\(Int((duration / 60).rounded())) 分"
    }

    /// 取り込み先のグループ。ラベルは操作の上に置き、他の項目と同じ「見出しが上」の並びに
    /// 揃える。呼び方も履歴側の語彙(グループへ移動 / 新しいグループ / 未分類)に合わせる。
    private var destinationField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("グループ")
                .font(HCFont.style(.subheadline, weight: .semibold))
                .foregroundStyle(.secondary)
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

    private var buttons: some View {
        HStack {
            Spacer()
            Button("キャンセル", role: .cancel) {
                model.cancelImport(pending)
            }
            .keyboardShortcut(.cancelAction)
            .pointingHandOnHover()
            Button("取り込む") {
                model.confirmImport(pending, intoFolder: resolvedFolder)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(destination == .new && trimmedNewFolderName.isEmpty)
            .pointingHandOnHover(disabled: destination == .new && trimmedNewFolderName.isEmpty)
        }
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
}

/// 取り込みの確認シートとエラー表示。MainWindow.body をこれ以上太らせないため
/// (既に型推論のタイムアウトに達した経緯がある)、修飾子として切り出す。
struct SessionImportPresentation: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content
            .sheet(
                item: Binding(
                    get: { model.pendingImport },
                    // Esc やシート外の操作で閉じられた場合も、展開済みの一時ファイルを
                    // 片付けるためキャンセル扱いにする。確認/取りやめを通って既に
                    // nil になっている場合は何もしない。
                    set: { newValue in
                        guard newValue == nil, let current = model.pendingImport else { return }
                        model.cancelImport(current)
                    })
            ) { pending in
                ImportSessionSheet(model: model, pending: pending)
            }
            .alert(
                "取り込めませんでした",
                isPresented: presented(
                    Binding(get: { model.importError }, set: { model.importError = $0 }))
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.importError ?? "")
            }
    }
}
