import AppKit
import Foundation
import HearCatKit
import HearCatSummarize
import SwiftUI
import UniformTypeIdentifiers

/// マイクの入力デバイス選択肢。nil(システム標準)を含めて Picker で扱えるようにする。
private struct MicDeviceOption: Identifiable, Hashable {
    let uid: String?
    let name: String
    var id: String { uid ?? "" }
}

private struct AgentModelOption: Equatable {
    let value: String
    let label: String
}

private struct CodexModelsCache: Decodable {
    let models: [CodexModelEntry]
}

private struct CodexModelEntry: Decodable {
    let slug: String
    let displayName: String
    let visibility: String

    enum CodingKeys: String, CodingKey {
        case slug
        case displayName = "display_name"
        case visibility
    }
}

/// 候補から選べる一方、将来追加された完全なモデル名も直接入力できる欄。
/// SwiftUI の TextField は grouped Form 内でフォーカスを取得できない環境があるため、
/// 編集可能な AppKit 標準の NSComboBox を使う。
private struct AgentModelComboBox: NSViewRepresentable {
    @Binding var value: String
    let suggestions: [AgentModelOption]

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    func makeNSView(context: Context) -> NSComboBox {
        let comboBox = NSComboBox()
        context.coordinator.suggestions = suggestions
        comboBox.addItems(withObjectValues: suggestions.map(\.label))
        comboBox.stringValue = displayValue(for: value)
        comboBox.placeholderString = "CLI の設定を使用"
        comboBox.isEditable = true
        comboBox.completes = true
        comboBox.delegate = context.coordinator
        comboBox.target = context.coordinator
        comboBox.action = #selector(Coordinator.selectionChanged(_:))
        return comboBox
    }

    func updateNSView(_ comboBox: NSComboBox, context: Context) {
        context.coordinator.value = $value
        context.coordinator.suggestions = suggestions

        let labels = suggestions.map(\.label)
        let currentLabels = comboBox.objectValues.compactMap { $0 as? String }
        if currentLabels != labels {
            comboBox.removeAllItems()
            comboBox.addItems(withObjectValues: labels)
        }

        let displayValue = displayValue(for: value)
        if comboBox.currentEditor() == nil, comboBox.stringValue != displayValue {
            comboBox.stringValue = displayValue
        }
    }

    private func displayValue(for value: String) -> String {
        suggestions.first(where: { $0.value == value })?.label ?? value
    }

    @MainActor
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var value: Binding<String>
        var suggestions: [AgentModelOption] = []
        /// キーストロークごとに UserDefaults を書き換えないよう、最終入力から少し
        /// 待って 1 回だけ書き込むための遅延タスク。
        private var debounceTask: Task<Void, Never>?

        init(value: Binding<String>) {
            self.value = value
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else { return }
            scheduleWrite(from: comboBox.stringValue)
        }

        /// フォーカスを外した瞬間は、debounce の途中でも直ちに書き込む
        /// (「値を入れて Tab で抜けた直後」に反映されないと不自然なため)。
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else { return }
            debounceTask?.cancel()
            writeValue(from: comboBox.stringValue)
        }

        @objc func selectionChanged(_ comboBox: NSComboBox) {
            debounceTask?.cancel()
            let selectedIndex = comboBox.indexOfSelectedItem
            guard suggestions.indices.contains(selectedIndex) else {
                writeValue(from: comboBox.stringValue)
                return
            }
            let selected = suggestions[selectedIndex].value
            if value.wrappedValue != selected { value.wrappedValue = selected }
        }

        private func scheduleWrite(from input: String) {
            let resolved = suggestions.first(where: { $0.label == input })?.value ?? input
            if value.wrappedValue == resolved { return }
            debounceTask?.cancel()
            let binding = value
            debounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
                if binding.wrappedValue != resolved { binding.wrappedValue = resolved }
            }
        }

        private func writeValue(from input: String) {
            let resolved = suggestions.first(where: { $0.label == input })?.value ?? input
            if value.wrappedValue != resolved { value.wrappedValue = resolved }
        }
    }
}

/// 設定ウィンドウ。用途別のタブに分け、関連する設定を同じ場所へ集約する。
struct SettingsView: View {
    let model: AppModel
    @Bindable var settings: AppSettings

    @State private var skillInstalled = SkillInstaller.skillInstalled
    @State private var cliInstalled = SkillInstaller.cliInstalled
    @State private var skillMessage: String?
    @State private var inputDevices: [MicDeviceOption] = [MicDeviceOption(uid: nil, name: "システム標準")]
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var launchAtLoginMessage: String?
    @State private var updateCheck: UpdateCheckResult = .checking
    @State private var codexModelOptions: [AgentModelOption] = []
    /// Claude/Codex を自動要約に選ぶ際の外部送信同意確認。ダイアログでキャンセルされたら
    /// pending の選択に戻さず、元の選択を保つためにここへ待避する。
    @State private var pendingAutoSummaryEngine: SummaryEngine?
    /// 追加待ちの除外キーワード。追加した時点で空に戻す。
    @State private var newExcludedKeyword = ""
    /// 「予定から選ぶ」で出す、これから2週間ぶんの会議。押すたびに引き直す。
    @State private var upcomingMeetings: [CalendarMeeting] = []
    @State private var loadingUpcomingMeetings = false
    /// メニューを出す位置の基準にする NSView(「予定から選ぶ」ボタンの実体)。
    @State private var upcomingMenuAnchor: NSView?
    /// NSMenuItem の target。NSMenuItem は target を弱参照するため、
    /// ビューの生存期間だけ強参照を保持する必要がある。
    @State private var upcomingMenuActionHandler = MenuActionHandler()

    /// ストレージの合計使用量。開くたびに計算し直す(セッションの録音・削除で変わるため)。
    @State private var storageUsage: SessionStore.StorageUsage?
    @State private var deleteOldRecordingsMenuAnchor: NSView?
    @State private var deleteOldRecordingsMenuActionHandler = MenuActionHandler()
    /// 確認ダイアログに出す「対象日数」と「対象件数・サイズ」。両方揃っている間だけダイアログを出す。
    @State private var pendingDeleteOldRecordingsDays: Int?
    @State private var pendingDeleteOldRecordingsSummary: SessionStore.OldRecordingsSummary?
    @State private var deleteOldRecordingsMessage: String?
    /// 入力レベルの確認中か。押されている間だけマイクを掴む(micTestRow を参照)。
    @State private var micTesting = false

    var body: some View {
        // 1本の長いスクロールだと下のセクションが見落とされるため、macOS の
        // 設定アプリと同じタブで分ける。各タブが一画面に収まる高さにする。
        TabView {
            Tab("一般", systemImage: "gearshape") { generalTab }
            Tab("セッション", systemImage: "record.circle") { sessionTab }
            Tab("音声", systemImage: "mic") { audioTab }
            Tab("AI", systemImage: "sparkles") { aiTab }
            Tab("ホットキー", systemImage: "keyboard") { hotkeyTab }
        }
        // タブの並びは本文ではなくタイトルバーの中に描かれる。幅が足りないと、
        // 並びは省略されずに丸ごと畳まれて何も見えなくなるため、必要な幅を必ず確保する。
        //
        // 実測(タイトルバーを画面外に描いて計測): タブ5つの帯は約 430pt、左端の信号機
        // ボタンが約 98pt で、合計 528pt が下限。520pt だと 8pt 足りずに畳まれていた。
        // 560pt はその下限に 32pt の余裕を持たせた値。タブの文言を長くする時はここも見直す。
        //
        // 幅を固定するのは、下限だけにすると折り返してほしい長い説明文の幅に
        // ウィンドウが合わせてしまい、際限なく横に伸びるため。
        .frame(width: 560, height: 480)
        // Toggle の switch トラック(on 側の色)は Window レベルの tint だけでは
        // system accent が優先されて青のまま残ることがある。SwitchToggleStyle に
        // 直接 tint を渡すことで、切替スイッチのトラック色を確実にシナモン茶へ。
        .tint(HCColor.cinnamon)
        .toggleStyle(SwitchToggleStyle(tint: HCColor.cinnamon))
        .onAppear {
            refreshInputDevices()
            refreshCodexModelOptions()
            // システム設定や CLI 側で変えられていても、開いた時点の実状態に合わせる。
            launchAtLogin = LoginItem.isEnabled
        }
    }

    /// セクションの補足説明。置き場所は必ずセクションの footer にする
    /// (項目の直下に地の文として置くと、インデントと行間が変わって、設定項目そのものと
    /// 見分けが付かなくなる)。複数の項目に説明が要るセクションでは、項目の順に1行ずつ並べる。
    private func settingsFooter(_ lines: String...) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
            }
        }
        .font(HCFont.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 1回の記録の始まり方・名前の付き方・終わり方をまとめるタブ。
    /// タブ名を「会議」にしないのは、通話でも独り言の口述でも使えるアプリで、
    /// 用途を会議に狭めて見せてしまうため。アプリが画面で使っている呼び名(セッション)に揃える。
    private var sessionTab: some View {
        Form {
            Section {
                Toggle("カレンダーの予定名を自動で付ける", isOn: $settings.calendarNaming)
            } header: {
                Text("セッション名")
            } footer: {
                settingsFooter("セッション開始時、今の時刻に重なる予定 (5分後までに始まる予定も含む) のタイトルをセッション名にします。macOS のカレンダーに追加したアカウント (Google など) の予定も対象です。初回はカレンダーへのアクセス許可を求めます。")
            }

            Section {
                Toggle("会議の時間になったら自動で録音を開始", isOn: $settings.meetingAutoStart)
                if settings.meetingAutoStart {
                    excludedMeetingRows
                }
            } header: {
                Text("自動開始")
            } footer: {
                settingsFooter("会議サービスの URL が入っている予定だけが対象です。開始 30 秒前に画面右上へ予告が出るので、録りたくない回はそこで取り消せます。終日の予定と、辞退した予定は対象外です。")
            }

            Section {
                Toggle("無音が5分続いたら停止するか確認", isOn: $settings.confirmStopOnSilence)
            } header: {
                Text("無音の確認")
            } footer: {
                settingsFooter("マイクとシステム音声の両方が5分間無音のとき、画面右上で停止するかを尋ねます。返事があるまで録音は続くので、会議が再開しても記録は途切れません。")
            }
        }
        .formStyle(.grouped)
    }

    private var generalTab: some View {
        Form {
            Section {
                Toggle("ログイン時に HearCat を起動", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            try LoginItem.setEnabled(newValue)
                            launchAtLoginMessage = nil
                        } catch {
                            // 失敗したら実状態へ戻す(戻す代入で onChange が再発火しても
                            // setEnabled は現状一致なら何もしない)。
                            launchAtLogin = LoginItem.isEnabled
                            launchAtLoginMessage = error.localizedDescription
                        }
                    }
                if let launchAtLoginMessage {
                    Text(launchAtLoginMessage)
                        .font(HCFont.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("起動")
            } footer: {
                settingsFooter("Mac にログインしたとき、メニューバーに自動で常駐します。システム設定 > 一般 > ログイン項目からも変更できます。")
            }

            Section {
                LabeledContent("バージョン") {
                    HStack(spacing: 8) {
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                        updateStatus
                    }
                }
                HStack(spacing: 8) {
                    Text(UpdateCheck.command)
                        .font(HCFont.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    CopyButton { UpdateCheck.command }
                }
                Toggle("毎日 11 時に確認", isOn: $settings.autoUpdateCheck)
            } header: {
                Text("アップデート")
            } footer: {
                settingsFooter("このコマンドをターミナルで実行すると、最新版に入れ替わります。実行中は HearCat がいったん終了するので、録音していないときに行ってください。確認するのは公開されているバージョン番号だけで、こちらからは何も送りません。")
            }
            .onAppear { checkForUpdate() }

            storageSection

            Section {
                // ボタンの言葉は、開く画面の名前(ようこそ)ではなく、そこで何ができるかにする。
                // 内部の呼び名をそのまま出しても、押した先に何があるか伝わらない。
                Button("使い方と権限を確認") {
                    model.openWindowAction?("welcome")
                }
                .controlSize(.small)
            } header: {
                Text("サポート")
            } footer: {
                settingsFooter("HearCat にできることの紹介と、マイク・音声認識・カレンダーの許可の状態を見直せます。")
            }

        }
        .formStyle(.grouped)
        .onAppear { refreshStorageUsage() }
    }

    /// 録音・文字起こしなどの合計使用量と、古い録音の削除。
    /// 自動削除はしない方針で、常にユーザーが日数を選んでから確認画面を挟む。
    private var storageSection: some View {
        Section {
            LabeledContent("使用量") {
                Text(storageUsageText)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("古い録音を削除…") {
                    showDeleteOldRecordingsMenu()
                }
                .controlSize(.small)
                .background(MenuAnchorView(anchor: $deleteOldRecordingsMenuAnchor))
                if let deleteOldRecordingsMessage {
                    Text(deleteOldRecordingsMessage)
                        .font(HCFont.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("ストレージ")
        } footer: {
            settingsFooter("選んだ日数より前のセッションから、録音ファイルだけを削除します。文字起こしと要約は残ります。")
        }
        .confirmationDialog(
            deleteOldRecordingsTitle,
            isPresented: Binding(
                get: { pendingDeleteOldRecordingsSummary != nil },
                set: { if !$0 { clearPendingDeleteOldRecordings() } }
            ),
            titleVisibility: .visible
        ) {
            Button("削除する", role: .destructive) { performDeleteOldRecordings() }
            Button("キャンセル", role: .cancel) { clearPendingDeleteOldRecordings() }
        } message: {
            Text(deleteOldRecordingsDialogMessage(for: pendingDeleteOldRecordingsSummary))
        }
    }

    /// 自動録音の対象から外す指定。
    ///
    /// 2つの入り口を並べる。予告パネルの「今後録らない」で外した予定と、予定名に
    /// 含まれる言葉での除外。前者は正確だが予告を見ていないと押せないため、
    /// 後者を後から止める手段として置く。
    @ViewBuilder
    private var excludedMeetingRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("録らない予定")
                .font(HCFont.caption)
                .foregroundStyle(.secondary)
            if !settings.excludedMeetings.isEmpty || !settings.excludedMeetingKeywords.isEmpty {
                // 1件が1つのタグ。解除はタグの中の × で完結させる(行の右端まで視線を
                // 往復させない)。件数が増えても折り返して収まる。
                FlowLayout(spacing: 6) {
                    // 予定名は変わることがあるので、外した時点の名前をそのまま出す。
                    ForEach(
                        settings.excludedMeetings.sorted(by: { $0.value < $1.value }), id: \.key
                    ) { id, title in
                        ExcludedChip(
                            icon: "calendar", label: title.isEmpty ? "名前のない予定" : title,
                            tinted: true
                        ) {
                            settings.excludedMeetings.removeValue(forKey: id)
                        }
                    }
                    ForEach(settings.excludedMeetingKeywords, id: \.self) { keyword in
                        ExcludedChip(icon: "magnifyingglass", label: keyword, tinted: false) {
                            settings.excludedMeetingKeywords.removeAll { $0 == keyword }
                        }
                    }
                }
                Text("カレンダーの印は予定そのもの、虫めがねは予定名に含まれる言葉です。")
                    .font(HCFont.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                // grouped Form では TextField の第1引数は左側のラベルとして描かれる。
                // 説明を欄の中に置きたいので、ラベルは空にして prompt に入れる。
                TextField(
                    "", text: $newExcludedKeyword,
                    prompt: Text("予定名に含まれる言葉 (例: リマインダー)"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit { addExcludedKeyword() }
                Button("追加") { addExcludedKeyword() }
                    .disabled(
                        newExcludedKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            // 予告を見逃した予定にも、あとから辿り着けるようにする。
            Button {
                loadUpcomingMeetings()
            } label: {
                if loadingUpcomingMeetings {
                    ProgressView().controlSize(.small)
                } else {
                    Text("予定から選ぶ…")
                }
            }
            .controlSize(.small)
            .disabled(loadingUpcomingMeetings)
            .background(MenuAnchorView(anchor: $upcomingMenuAnchor))
        }
    }

    /// これから2週間の会議から、録らないものを選ばせる。既に外したものは出さない
    /// (タグとして上に並んでいるため)。
    ///
    /// 自前のポップオーバーではなく NSMenu にしている。メニューは上下キーでの移動・
    /// Return での決定・Escape での取り消しを最初から持っていて、macOS の
    /// 「キーボードナビゲーション」が切られている環境(既定)でもキーボードだけで
    /// 選べるため。自前の一覧では、その環境で Tab がボタンにもリストにも止まらず、
    /// マウス専用の画面になってしまう。
    private func showUpcomingMeetingMenu() {
        guard let anchor = upcomingMenuAnchor else { return }
        let menu = makeHCMenu()
        let selectable = upcomingMeetings.filter {
            settings.excludedMeetings[$0.seriesID] == nil
        }
        if selectable.isEmpty {
            let item = NSMenuItem(
                title: "これから2週間に、自動で録音される予定はありません", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for meeting in selectable {
                let item = upcomingMenuActionHandler.makeItem(displayName(of: meeting)) {
                    exclude(meeting)
                }
                // 同じ名前の予定が並ぶことがあるため、日時を添えて見分けられるようにする。
                item.subtitle = meeting.startDate.formatted(
                    date: .abbreviated, time: .shortened)
                menu.addItem(item)
            }
        }
        popUpMenu(menu, below: anchor)
    }

    private func displayName(of meeting: CalendarMeeting) -> String {
        meeting.title.isEmpty ? "名前のない予定" : meeting.title
    }

    private func exclude(_ meeting: CalendarMeeting) {
        settings.excludedMeetings[meeting.seriesID] = displayName(of: meeting)
    }

    private func loadUpcomingMeetings() {
        loadingUpcomingMeetings = true
        Task {
            upcomingMeetings = await CalendarMeetings.upcomingMeetings(
                within: 14 * 24 * 60 * 60)
            loadingUpcomingMeetings = false
            showUpcomingMeetingMenu()
        }
    }

    private func addExcludedKeyword() {
        let keyword = newExcludedKeyword.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty, !settings.excludedMeetingKeywords.contains(keyword) else {
            newExcludedKeyword = ""
            return
        }
        settings.excludedMeetingKeywords.append(keyword)
        newExcludedKeyword = ""
    }

    // MARK: - ストレージ

    private func refreshStorageUsage() {
        Task {
            let usage = await Task.detached(priority: .userInitiated) {
                SessionStore.storageUsage()
            }.value
            storageUsage = usage
        }
    }

    private var storageUsageText: String {
        guard let storageUsage else { return "計算中…" }
        guard storageUsage.totalBytes > 0 else { return "録音・記録はまだありません" }
        return "合計 \(formattedBytes(storageUsage.totalBytes))"
            + " (録音 \(formattedBytes(storageUsage.audioBytes))"
            + "・その他 \(formattedBytes(storageUsage.otherBytes)))"
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// 「古い録音を削除…」で出す日数の選択肢。ボタン直下に NSMenu を出す
    /// (この環境は Tab キーがボタンに止まらない設定のため、自前の一覧ではなく NSMenu を使う)。
    private func showDeleteOldRecordingsMenu() {
        guard let anchor = deleteOldRecordingsMenuAnchor else { return }
        let menu = makeHCMenu()
        for days in [30, 90, 180] {
            let item = deleteOldRecordingsMenuActionHandler.makeItem("\(days) 日より前") {
                confirmDeleteOldRecordings(olderThanDays: days)
            }
            menu.addItem(item)
        }
        popUpMenu(menu, below: anchor)
    }

    /// 選んだ日数の対象を数え、0件ならその場で結果だけ伝えて確認ダイアログを出さない
    /// (削除しようがないものの確認を挟むと、押すだけ無駄な手順になる)。
    private func confirmDeleteOldRecordings(olderThanDays days: Int) {
        deleteOldRecordingsMessage = nil
        Task {
            let summary = await Task.detached(priority: .userInitiated) {
                SessionStore.oldRecordingsSummary(olderThanDays: days)
            }.value
            guard summary.sessionCount > 0 else {
                deleteOldRecordingsMessage = "\(days) 日より前の録音はありませんでした"
                return
            }
            pendingDeleteOldRecordingsDays = days
            pendingDeleteOldRecordingsSummary = summary
        }
    }

    private func clearPendingDeleteOldRecordings() {
        pendingDeleteOldRecordingsDays = nil
        pendingDeleteOldRecordingsSummary = nil
    }

    private var deleteOldRecordingsTitle: String {
        guard let days = pendingDeleteOldRecordingsDays else { return "" }
        return "\(days) 日より前の録音を削除しますか？"
    }

    private func deleteOldRecordingsDialogMessage(for summary: SessionStore.OldRecordingsSummary?) -> String {
        guard let summary else { return "" }
        return "\(summary.sessionCount) 件、\(formattedBytes(summary.bytes)) の録音を削除します。"
            + "文字起こしと要約は残ります。この操作は取り消せません。"
    }

    private func performDeleteOldRecordings() {
        guard let days = pendingDeleteOldRecordingsDays else { return }
        clearPendingDeleteOldRecordings()
        // 削除は保存先を全部走査して数十 MB のファイルを消す。メインスレッドで回すと
        // その間ずっと設定ウィンドウが固まるため、対象件数の集計と同じく裏へ逃がす。
        Task {
            let freed = await Task.detached(priority: .userInitiated) {
                SessionStore.deleteOldRecordings(olderThanDays: days)
            }.value
            deleteOldRecordingsMessage = "\(formattedBytes(freed)) の空き容量を確保しました"
            refreshStorageUsage()
        }
    }

    /// 入力レベルの確認。押した間だけマイクを掴む。
    ///
    /// タブを開いただけで掴まないのは、Bluetooth のイヤホンだと、マイクを掴んだ時点で
    /// 機器が通話用の経路へ切り替わり、聞こえている音の大きさまで変わってしまうため。
    /// (実測: AirPods Pro で、マイクを掴むと出力音量が 0.390 → 0.330 に変わり、
    /// マイクを離しても元に戻らなかった。設定を見に来ただけで音が変わるのは事故に近い。)
    ///
    /// メーターの表示/非表示を伝えるだけで、実際にプローブを動かすかどうかの判定
    /// (セッション中でないか等)は AppModel.updateMicProbe に集約している。
    /// デバイス変更時の作り直しも settings.micDeviceChanged 経由で同じ場所に集約される。
    private var micTestRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(micTesting ? "マイクの確認を止める" : "マイクを試す") {
                micTesting.toggle()
                model.setMicMeterVisible(micTesting)
            }
            .controlSize(.small)
            if micTesting {
                micLevelMeter
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 感度の自動調整に戻した時、タブを離れた時、ウィンドウを閉じた時のいずれでも
        // マイクを離す。掴んだままにすると、設定を閉じたあとも音の経路が戻らない。
        .onDisappear {
            micTesting = false
            model.setMicMeterVisible(false)
        }
    }

    private var audioTab: some View {
        Form {
            Section {
                Picker("入力デバイス", selection: $settings.micDeviceUID) {
                    ForEach(inputDevices) { option in
                        Text(option.name).tag(option.uid)
                    }
                }
                Toggle("エコー除去", isOn: $settings.echoRemoval)
                Toggle("入力感度を自動調整", isOn: $settings.micSensitivityAuto)
                if !settings.micSensitivityAuto {
                    micSensitivitySlider
                    micTestRow
                }
            } header: {
                Text("マイク")
            } footer: {
                settingsFooter(
                    "入力デバイスの変更は次のセッションから有効です。",
                    "エコー除去は、スピーカーから出た相手の声が自分の発言として文字起こしされるのを防ぎます。",
                    "入力感度は、マイクの音量がこの値を下回る間は文字起こしに流しません。低すぎると回り込みを拾い、高すぎると小さな声を取りこぼします。",
                    "「マイクを試す」の間だけマイクを使います。Bluetooth のイヤホンでは、マイクを使うと機器が通話用に切り替わり、聞こえる音の大きさが変わることがあります。")
            }

            Section {
                gainSlider(label: "自分 (マイク)", value: $settings.micGain)
                gainSlider(label: "相手 (システム音声)", value: $settings.systemGain)
            } header: {
                Text("録音の音量")
            } footer: {
                settingsFooter("録音ファイルに書く音量です。100% が原音。セッション中の変更もすぐに反映されます。文字起こしの精度には影響しません。")
            }
        }
        .formStyle(.grouped)
    }

    private var aiTab: some View {
        Form {
            Section {
                autoSummaryEnginePicker
                // 選択中のエンジンが Claude/Codex の時だけ、そのモデル入力欄を出す
                // (Apple Intelligence を選んでいるユーザーに無関係な行を見せない)。
                if let cli = selectedAutoSummaryCLI {
                    agentModelField(
                        for: cli,
                        binding: Binding(
                            get: { settings.summaryAgentModels[cli] ?? "" },
                            set: { settings.summaryAgentModels[cli] = $0 }))
                }
            } header: {
                Text("自動要約")
            } footer: {
                settingsFooter("セッション停止直後に自動で走る要約に使います。Apple Intelligence はオンデバイスで完結します。Claude / Codex は文字起こしを外部の AI サービスへ送信するため、初回だけ確認します。空欄なら各 CLI の設定を使います。")
            }

            Section {
                Picker("使う AI", selection: $settings.codeImpactAgent) {
                    ForEach(AgentCLI.allCases, id: \.self) { cli in
                        Text(cli.displayName).tag(cli)
                    }
                }
                agentModelField(
                    for: settings.codeImpactAgent,
                    binding: Binding(
                        get: { settings.codeImpactAgentModels[settings.codeImpactAgent] ?? "" },
                        set: { settings.codeImpactAgentModels[settings.codeImpactAgent] = $0 }))
            } header: {
                Text("関連資料との照合")
            } footer: {
                settingsFooter("会議中にホットキーを押すと、AI がここまでの文字起こしと、あらかじめ紐付けた資料フォルダの中身を見比べ、話の背景や食い違いがないかを確認します。資料は読み取るだけで書き換えません。ホットキーを押した時だけ動きます。空欄なら Claude や Codex 側の設定を使います。")
            }

            Section {
                installEntry(
                    title: "Skill", path: "~/.agents/skills/",
                    installed: skillInstalled)
                installEntry(
                    title: "CLI", path: "~/.local/bin/hearcat",
                    installed: cliInstalled)
                if !(skillInstalled && cliInstalled) {
                    Button("導入する") {
                        installSkill()
                    }
                }
                if let skillMessage {
                    Text(skillMessage)
                        .font(HCFont.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("AI エージェント連携")
            } footer: {
                settingsFooter(
                    "AI エージェント (Claude Code / Codex / Copilot など) が「文字起こしを始めて」などの指示でこのアプリを操作できるようになります。",
                    "各エージェントの設定フォルダ (~/.claude/skills/ など) に、この機能を使うためのファイルを配置します。アプリを起動するたびに自動で最新の内容に更新されるので、入れ直しは不要です。")
            }
        }
        .formStyle(.grouped)
    }

    private var hotkeyTab: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    LabeledContent(action.label) {
                        HotkeyRecorderField(action: action, settings: settings)
                    }
                }
            } header: {
                Text("ホットキー")
            } footer: {
                settingsFooter("他のアプリを使っている時でも効きます。⌘ ⌥ ⌃ のいずれかを含むキー、または F1〜F12 を登録できます。録音/文字起こしのキーは、セッション外で押すとその機能だけオンでセッションを開始します。")
            }

            Section {
                Toggle("ホットキーで開始する前に保存先グループを確認", isOn: $settings.hotkeyGroupPicker)
            } footer: {
                settingsFooter("オンのときは、ホットキーでセッションを始めるたびに、どのグループに入れるかを選ぶ画面を挟みます。オフのときは前回選んだグループでそのまま始まります。")
            }
        }
        .formStyle(.grouped)
    }

    /// 自動要約に使うエンジンを選ぶピッカー。
    /// Apple Intelligence が使えない Mac、検出できていない CLI は選択肢自体から外す
    /// (選べる=動くという期待を裏切らないため)。
    /// Claude/Codex を初めて選ぶ時は、外部送信の同意を確認するダイアログを挟み、
    /// キャンセルなら選択を戻す。
    private var autoSummaryEnginePicker: some View {
        // Optional<SummaryEngine> をそのままタグにすると SwiftUI の Picker で
        // タグの型合わせがめんどうなので、String rawValue に寄せる("off" = nil)。
        let binding = Binding<String>(
            get: { settings.autoSummaryEngine?.rawValue ?? "off" },
            set: { raw in
                let next: SummaryEngine? = raw == "off" ? nil : SummaryEngine(rawValue: raw)
                if let next, next != .appleIntelligence, !settings.agentSummaryConsented {
                    // 同意ダイアログが出るまでは選択を反映しない(バインディングも更新しない)。
                    pendingAutoSummaryEngine = next
                } else {
                    settings.autoSummaryEngine = next
                }
            })
        let onDeviceAvailable = OnDeviceModel.unavailableReason() == nil
        let detectedCLIs = AgentCLIDetector.shared.availableCLIs
        return Picker("自動要約に使う AI", selection: binding) {
            Text("使わない").tag("off")
            if onDeviceAvailable {
                Text(SummaryEngine.appleIntelligence.displayName)
                    .tag(SummaryEngine.appleIntelligence.rawValue)
            }
            ForEach(detectedCLIs, id: \.self) { cli in
                Text(cli.displayName).tag(cli.summaryEngine.rawValue)
            }
        }
        .onAppear {
            // 前回選んだエンジンが今の環境で使えない(Apple Intelligence が無効化された、
            // CLI をアンインストールした)なら、選ばれっぱなしにせず「使わない」に戻す。
            //
            // ただし CLI 検出は起動直後に zsh -lc を回すため 200〜500ms 遅れる。
            // 検出前に「detectedCLIs が空 = 未検出」と早合点して選択を消すと、
            // ユーザーが Claude/Codex を選んでいるだけで起動直後に設定画面を開いた瞬間、
            // 保存済みの選択が黙って消えてしまう。検出が終わっていない間は判定しない。
            if let current = settings.autoSummaryEngine {
                switch current {
                case .appleIntelligence where !onDeviceAvailable:
                    settings.autoSummaryEngine = nil
                case .claude, .codex:
                    guard !detectedCLIs.isEmpty else { break }
                    if let cli = AgentCLI(summaryEngine: current), !detectedCLIs.contains(cli) {
                        settings.autoSummaryEngine = nil
                    }
                default:
                    break
                }
            }
        }
        .confirmationDialog(
            "自動要約で文字起こしを外部の AI サービスへ送信します。続けますか？",
            isPresented: Binding(
                get: { pendingAutoSummaryEngine != nil },
                set: { if !$0 { pendingAutoSummaryEngine = nil } }),
            presenting: pendingAutoSummaryEngine
        ) { engine in
            Button("続ける") {
                settings.agentSummaryConsented = true
                settings.autoSummaryEngine = engine
                pendingAutoSummaryEngine = nil
            }
            Button("キャンセル", role: .cancel) {
                pendingAutoSummaryEngine = nil
            }
        }
    }

    /// 自動要約に Claude/Codex を選んでいる時だけ、そのエンジンを返す。
    /// Apple Intelligence や「使わない」を選んでいる時は nil。
    private var selectedAutoSummaryCLI: AgentCLI? {
        guard let engine = settings.autoSummaryEngine else { return nil }
        return AgentCLI(summaryEngine: engine)
    }

    /// モデル入力欄。用途ごとに保存先が違う(要約用と照合用)ため、
    /// ラベルと保存先の Binding を呼び出し側で決める。
    private func agentModelField(for cli: AgentCLI, binding: Binding<String>) -> some View {
        let options = modelOptions(for: cli)
        return LabeledContent("\(cli.displayName) のモデル") {
            AgentModelComboBox(value: binding, suggestions: options)
                .frame(width: Self.agentModelFieldWidth(for: options))
        }
    }

    /// モデル欄の幅。中身に合わせて決める。
    ///
    /// 一律 260pt にしていたときは、「Sonnet 5」のような短い候補しか無い場面でも
    /// 行の右半分を占め、すぐ上の「使う AI」の Picker(中身に合わせて縮む)と不揃いに見えた。
    ///
    /// 下限は、何も選んでいない時に出るプレースホルダ「CLI の設定を使用」(実測 96pt)が
    /// 切れない幅。上限は、`claude-sonnet-4-5-20250929` のような長い名前を直接入力した時に
    /// 行を独占しないための歯止め(入り切らない分は欄の中でスクロールする)。
    private static func agentModelFieldWidth(for options: [AgentModelOption]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let widest = options
            .map { ($0.label as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        // 文字の左右の余白と、右端の展開ボタンのぶん。
        return min(240, max(150, widest + 46))
    }

    private func modelOptions(for cli: AgentCLI) -> [AgentModelOption] {
        switch cli {
        case .claude:
            [
                AgentModelOption(value: "sonnet", label: "Sonnet 5"),
                AgentModelOption(value: "opus", label: "Opus 4.8"),
                AgentModelOption(value: "fable", label: "Fable 5"),
            ]
        case .codex:
            codexModelOptions
        }
    }

    private func refreshCodexModelOptions() {
        let cacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/models_cache.json")
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(CodexModelsCache.self, from: data)
        else {
            codexModelOptions = []
            return
        }

        codexModelOptions = cache.models
            .filter { $0.visibility == "list" }
            .map { AgentModelOption(value: $0.slug, label: $0.displayName) }
    }

    /// 入力デバイスの一覧を取得し直す。動的な抜き差し監視はスコープ外なので、
    /// 設定画面を開いた時点のスナップショットでよい。
    private func refreshInputDevices() {
        let available = MicSource.availableInputDevices()
        var options = [MicDeviceOption(uid: nil, name: "システム標準")]
        options += available.map { MicDeviceOption(uid: $0.uid, name: $0.name) }
        // 保存済みのデバイスが今は繋がっていなくても選択肢に残し、Picker の選択状態を壊さない。
        if let savedUID = settings.micDeviceUID, !available.contains(where: { $0.uid == savedUID }) {
            options.append(MicDeviceOption(uid: savedUID, name: "(未接続) \(savedUID)"))
        }
        inputDevices = options
    }

    private func gainSlider(label: String, value: Binding<Double>) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Slider(value: value, in: 0...2)
                    .frame(width: 180)
                Text("\(Int(value.wrappedValue * 100))%")
                    .font(HCFont.timecode)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
                Button("戻す") { value.wrappedValue = 1.0 }
                    .controlSize(.small)
                    .disabled(value.wrappedValue == 1.0)
            }
        }
    }

    /// 入力感度の下限/上限(RMS)。回り込み(≈0.001)と発話(≈0.01)の間を、
    /// スライダーの分解能に余裕を持たせて挟む範囲。
    private static let micSensitivityMin: Double = 0.0002
    private static let micSensitivityMax: Double = 0.02

    /// RMS(0.0002〜0.02)を対数マッピングで UI 値(0〜1)へ変換する。
    /// RMS は低域(0.001前後)の違いが重要なため、線形マッピングだと低い側が
    /// スライダーの端に張り付いてしまう。
    private func rmsToUI(_ rms: Double) -> Double {
        let clamped = max(Self.micSensitivityMin, min(Self.micSensitivityMax, rms))
        return log(clamped / Self.micSensitivityMin) / log(Self.micSensitivityMax / Self.micSensitivityMin)
    }

    private func uiToRMS(_ ui: Double) -> Double {
        Self.micSensitivityMin * pow(Self.micSensitivityMax / Self.micSensitivityMin, ui)
    }

    private var micSensitivitySlider: some View {
        LabeledContent("入力感度") {
            HStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { rmsToUI(settings.micSensitivity) },
                        set: { settings.micSensitivity = uiToRMS($0) }
                    ),
                    in: 0...1
                )
                .frame(width: 180)
                // RMS の生値(例: 0.0012)はユーザーに意味が伝わらないため、スライダーの
                // 位置をパーセントで見せる(rmsToUI で変換するだけで、内部の保存値は変えない)。
                Text("\(Int((rmsToUI(settings.micSensitivity) * 100).rounded()))%")
                    .font(HCFont.timecode)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }

    /// マイク音量のレベルメーター。しきい値の位置を縦線マーカーで重ねて表示する
    /// (Discord の入力感度 UI のイメージ)。バーもしきい値と同じ対数マッピングで描く。
    private var micLevelMeter: some View {
        VStack(alignment: .trailing, spacing: 4) {
            GeometryReader { geometry in
                let levelFraction = rmsToUI(Double(model.micLevel))
                let thresholdFraction = rmsToUI(settings.micSensitivity)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(.tint)
                        .frame(width: geometry.size.width * levelFraction)
                    Rectangle()
                        .fill(.secondary)
                        .frame(width: 2)
                        .offset(x: geometry.size.width * thresholdFraction - 1)
                }
            }
            .frame(height: 8)
        }
    }

    private func statusLabel(installed: Bool) -> some View {
        Label(
            installed ? "導入済み" : "未導入",
            systemImage: installed ? "checkmark.circle.fill" : "circle.dashed"
        )
        .foregroundStyle(installed ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
    }

    /// 導入項目の1行。ラベル+設置先パスと導入状態を横一列に並べる。
    /// タイトル列の幅を固定して、行を跨いでパスの左端が揃うようにする。
    private func installEntry(title: String, path: String, installed: Bool) -> some View {
        LabeledContent {
            statusLabel(installed: installed)
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .frame(width: 44, alignment: .leading)
                Text(path)
                    .font(HCFont.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    /// バージョンの右に出す更新の有無。取得に失敗したときだけ、その場でやり直せるようにする。
    @ViewBuilder
    private var updateStatus: some View {
        switch updateCheck {
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .upToDate:
            Text("最新です")
                .font(HCFont.caption)
                .foregroundStyle(.secondary)
        case .available(let latest):
            Text("新しい \(latest) があります")
                .font(HCFont.caption)
                .foregroundStyle(HCColor.cinnamonDim)
        case .failed:
            HStack(spacing: 6) {
                Text("確認できませんでした")
                    .font(HCFont.caption)
                    .foregroundStyle(.secondary)
                Button("再確認") { checkForUpdate() }
                    .controlSize(.small)
            }
        }
    }

    private func checkForUpdate() {
        updateCheck = .checking
        let current = appVersion
        Task { updateCheck = await UpdateCheck.run(currentVersion: current) }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }

    private func installSkill() {
        do {
            try SkillInstaller.install()
            skillMessage = "配置しました"
        } catch {
            skillMessage = error.localizedDescription
        }
        skillInstalled = SkillInstaller.skillInstalled
        cliInstalled = SkillInstaller.cliInstalled
    }
}

/// キー割り当ての録画フィールド。クリックすると次のキー入力を捕まえて登録する。
struct HotkeyRecorderField: View {
    let action: HotkeyAction
    @Bindable var settings: AppSettings

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 10) {
            Button {
                recording ? endRecording() : beginRecording()
            } label: {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    labelContent
                        .frame(minWidth: 96, alignment: .trailing)
                }
            }
            // Button の外側で pill を組まず、label 側で各キーを独立したキーキャップに
            // 分ける(macOS システム設定 / Discord / Raycast の同種 UI と同じ形)。
            // これで「⌥ + Q」の各キーが独立した箱で読める。ButtonStyle は透明 wrapper で、
            // focus ring と click ハンドリングだけ system に任せる。
            .buttonStyle(HCKeyCapButtonStyle())
            // 割り当て済みのキーだけ消せるように、xmark は別ボタンで出す。
            // 場所は常に確保し、未設定時は透明にする(行ごとにボタンの位置がずれないように)。
            Button {
                settings.hotkeys[action] = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("割り当てを削除")
            .opacity(clearable ? 1 : 0)
            .disabled(!clearable)
        }
        .onDisappear { endRecording() }
    }

    /// 状態に応じた label 中身。
    /// - 録画中: cinnamon 実線の pill(入力待ちのアクティブ状態)
    /// - 割り当て済み: 各キーを個別のキーキャップに分けて並べる
    /// - 未設定: 灰系の破線 pill(空スロット)
    /// 3 状態とも同じ pill 幅にすることで、行の右端が揃って落ち着いて見える。
    @ViewBuilder
    private var labelContent: some View {
        if recording {
            recordingSlot
        } else if let hotkey = settings.hotkeys[action] {
            HStack(spacing: 4) {
                ForEach(Array(hotkey.display.enumerated()), id: \.offset) { _, char in
                    keyCap(String(char))
                }
            }
        } else {
            emptySlot
        }
    }

    /// 録画中(キー入力待ち)のプレースホルダー。emptySlot と同じ形状で、
    /// 縁を cinnamon の実線にしてアクティブ状態を示す。テキストも cinnamon で
    /// 「今この pill が入力を受け付けている」ことを明示する。
    private var recordingSlot: some View {
        Text("キーを入力…")
            .font(HCFont.monospaced(size: 12))
            .foregroundStyle(HCColor.cinnamon)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .frame(minWidth: 96)
            .background(
                HCRadius.shape(HCRadius.chip)
                    .fill(HCColor.mistDarkSurface.opacity(0.4)))
            .overlay(
                HCRadius.shape(HCRadius.chip)
                    .strokeBorder(HCColor.cinnamon.opacity(0.65), lineWidth: 1.2))
    }

    /// 未設定時のクリック可能なプレースホルダー。破線の枠で「押して割り当てる空きスロット」
    /// であることを暗示する(macOS の空スロット UI の慣用表現)。
    /// 枠が無い薄いテキストだけだと、そもそも押せる要素に見えず設定できるアフォーダンスを失う。
    /// 割り当て済みのキーキャップ 1〜3 個より少し横長にして、「まだ何も入っていない」余白の
    /// 印象を出す。
    private var emptySlot: some View {
        Text("未設定")
            .font(HCFont.monospaced(size: 12))
            .foregroundStyle(HCColor.mistWhiteDim)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .frame(minWidth: 96)
            .background(
                HCRadius.shape(HCRadius.chip)
                    .fill(HCColor.mistDarkSurface.opacity(0.4)))
            .overlay(
                // 破線は「空スロット」の中立的表現。cinnamon で描くと「割り当てるべき箇所」
                // というアクションを催促する印象が強すぎて違和感が出る。灰系で目立たせつつ
                // 意味を持たせない: white opacity 0.3 で mistDark 上でもちゃんと視認できる。
                HCRadius.shape(HCRadius.chip)
                    .strokeBorder(
                        Color.white.opacity(0.3),
                        style: StrokeStyle(lineWidth: 1.2, dash: [4, 4])))
    }

    /// 1 個ぶんのキーキャップ。⌥/⌘/⌃/⇧/英字ともに同じ大きさの箱で表示する。
    /// 記号と英字で描画幅が違っても、box の minWidth が均等なので並びが崩れない。
    private func keyCap(_ text: String) -> some View {
        Text(text)
            .font(HCFont.monospaced(size: 12))
            .foregroundStyle(HCColor.mistWhite)
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, 4)
            .background(
                HCRadius.shape(HCRadius.chip)
                    .fill(HCColor.mistDarkSurface))
            .overlay(
                HCRadius.shape(HCRadius.chip)
                    .stroke(HCColor.mistDarkStroke, lineWidth: 1))
    }

    private var clearable: Bool {
        settings.hotkeys[action] != nil && !recording
    }

    private var buttonTitle: String {
        if recording { return "キーを入力…" }
        return settings.hotkeys[action]?.display ?? "未設定"
    }

    private func beginRecording() {
        recording = true
        // 録画中に既存のホットキーが発火すると誤操作になるため一時停止する。
        HotkeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                handle(event: event)
            }
            return nil  // 入力はここで消費し、ビープや他の反応をさせない。
        }
    }

    private func handle(event: NSEvent) {
        defer { endRecording() }
        switch event.keyCode {
        case 53:  // Escape はキャンセル
            return
        case 51:  // Delete は割り当て解除
            settings.hotkeys[action] = nil
            return
        default:
            if let hotkey = Hotkey.from(event: event) {
                settings.hotkeys[action] = hotkey
            }
        }
    }

    private func endRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        recording = false
        // suspend で外したホットキーを現在の設定で登録し直す。
        HotkeyCenter.shared.apply(settings.hotkeys)
    }
}

/// HotkeyRecorderField 専用の透明 ButtonStyle。
/// label 側で各キーキャップを既に描いているので、ここでは背景・縁を持たず、
/// click(pressed 時にわずかに opacity を落とす)と focus ring(system 提供)だけ扱う。
private struct HCKeyCapButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

/// 自動録音から外した1件。解除はタグの中の × で完結する。
private struct ExcludedChip: View {
    let icon: String
    let label: String
    /// 予定そのものを外したものは色を付けて、言葉での除外と見分けられるようにする。
    let tinted: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text(label)
                .font(HCFont.caption)
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    // 記号そのものは小さいので、押せる範囲を周りまで広げる。
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("解除")
            // 記号だけでは何のボタンか読み上げられないので、名前を持たせる。
            .accessibilityLabel("「\(label)」の除外を解除")
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(
                tinted ? HCColor.cinnamon.opacity(0.18) : Color.primary.opacity(0.06)))
        .overlay(
            Capsule().stroke(Color.primary.opacity(tinted ? 0 : 0.12), lineWidth: 0.5))
    }
}

/// タグを左から詰めて、入りきらなくなったら折り返す並べ方。
/// SwiftUI に折り返し用の標準レイアウトが無いため用意する。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

