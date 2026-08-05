import Foundation
import Testing

@testable import HearCatKit

/// 決定事項の記録(DecisionLog)の検証。
///
/// SessionStore.rootDirectory を差し替える点で SessionPackageTests と同じ土俵を使うため、
/// 独立した @Suite にはせず SessionPackageTests の extension として定義する
/// (SessionStoreStorageTests と同じ理由。.serialized は同一 Suite 内の直列化しか保証せず、
/// 別 Suite にすると並列実行時に rootDirectory の差し替えが競合する。実際に別 Suite として
/// 書いたところ SessionPackageTests 側が毎回失敗することを確認した)。
extension SessionPackageTests {
    private var decisionTestFolder: String { "テストグループ" }
    private var decisionTestSessionStart: Date { Date(timeIntervalSince1970: 1_767_225_600) }  // 2026-01-01 00:00:00 UTC

    private func makeDecisionTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HearCatTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 保存先を一時ディレクトリへ差し替えて body を実行し、必ず元へ戻す。
    /// withTemporaryStore(SessionPackageTests 本体)と同じ役割を、可視性の都合で
    /// このファイル内に独自に持つ(SessionStoreStorageTests と同じやり方)。
    private func withTemporaryDecisionStore(_ body: () throws -> Void) throws {
        let temp = try makeDecisionTempDirectory()
        SessionStore.rootDirectory = temp
        defer {
            SessionStore.rootDirectory = SessionStore.defaultRootDirectory
            try? FileManager.default.removeItem(at: temp)
        }
        try body()
    }

    private func makeDecisionDelta(
        topicId: String? = nil, title: String = "レート制限", text: String,
        status: DecisionStatus = .confirmed, time: String? = "12:34",
        by: DecisionSpeaker? = .me, reason: String? = nil
    ) -> DecisionDelta {
        DecisionDelta(decisions: [
            DecisionDelta.Item(
                topicId: topicId, title: title, text: text, status: status, time: time, by: by,
                reason: reason)
        ])
    }

    // MARK: - merge: 新規議題・current

    @Test func 差分マージで新規議題が作られcurrentが末尾になる() throws {
        try withTemporaryDecisionStore {
            let delta = makeDecisionDelta(text: "無料プランのみ60回/分")

            let log = try DecisionLogStore.merge(
                delta: delta, folder: decisionTestFolder, sessionDirectoryName: "2026-01-01_000000",
                sessionName: "定例", sessionStartedAt: decisionTestSessionStart)

            #expect(log.topics.count == 1)
            let topic = log.topics[0]
            #expect(topic.title == "レート制限")
            #expect(topic.current?.text == "無料プランのみ60回/分")
            #expect(topic.current?.timeSeconds == 12 * 60 + 34)
            #expect(topic.current?.by == .me)
        }
    }

    // MARK: - 冪等性

    @Test func 同じセッションの差分を2回マージしても結果が同一() throws {
        try withTemporaryDecisionStore {
            let delta = makeDecisionDelta(text: "無料プランのみ60回/分")

            _ = try DecisionLogStore.merge(
                delta: delta, folder: decisionTestFolder, sessionDirectoryName: "2026-01-01_000000",
                sessionName: "定例", sessionStartedAt: decisionTestSessionStart)
            let second = try DecisionLogStore.merge(
                delta: delta, folder: decisionTestFolder, sessionDirectoryName: "2026-01-01_000000",
                sessionName: "定例", sessionStartedAt: decisionTestSessionStart)

            #expect(second.topics.count == 1)
            #expect(second.topics[0].history.count == 1)
        }
    }

    // MARK: - 再抽出による置換

    @Test func 再抽出で内容が変わると旧エントリが置換される() throws {
        try withTemporaryDecisionStore {
            let first = try DecisionLogStore.merge(
                delta: makeDecisionDelta(text: "無料プランのみ60回/分"), folder: decisionTestFolder,
                sessionDirectoryName: "2026-01-01_000000", sessionName: "定例",
                sessionStartedAt: decisionTestSessionStart)
            let topicId = first.topics[0].id

            let second = try DecisionLogStore.merge(
                delta: makeDecisionDelta(topicId: topicId, text: "無料プランのみ30回/分"),
                folder: decisionTestFolder, sessionDirectoryName: "2026-01-01_000000",
                sessionName: "定例", sessionStartedAt: decisionTestSessionStart)

            #expect(second.topics.count == 1)
            #expect(second.topics[0].history.count == 1)
            #expect(second.topics[0].current?.text == "無料プランのみ30回/分")
        }
    }

    // MARK: - 複数セッションをまたぐ履歴の並び

    @Test func 複数セッションにまたがる履歴がrecordedAt順に並ぶ() throws {
        try withTemporaryDecisionStore {
            let later = decisionTestSessionStart.addingTimeInterval(60 * 60 * 24)

            // 後のセッションを先にマージしても、履歴は開始日時の昇順に並ぶこと。
            let afterSecond = try DecisionLogStore.merge(
                delta: makeDecisionDelta(text: "無料プランのみ30回/分"), folder: decisionTestFolder,
                sessionDirectoryName: "second", sessionName: "第2回", sessionStartedAt: later)
            let final = try DecisionLogStore.merge(
                delta: makeDecisionDelta(
                    topicId: afterSecond.topics[0].id, text: "無料プランのみ60回/分"),
                folder: decisionTestFolder, sessionDirectoryName: "first", sessionName: "第1回",
                sessionStartedAt: decisionTestSessionStart)

            let history = final.topics[0].history
            #expect(history.count == 2)
            #expect(history[0].sessionDirectoryName == "first")
            #expect(history[1].sessionDirectoryName == "second")
            #expect(final.topics[0].current?.text == "無料プランのみ30回/分")
        }
    }

    // MARK: - 議題解決(topicId / title / どちらも無し)

    @Test func topicId一致で既存議題に積まれる() throws {
        try withTemporaryDecisionStore {
            let first = try DecisionLogStore.merge(
                delta: makeDecisionDelta(title: "レート制限", text: "初期案"),
                folder: decisionTestFolder, sessionDirectoryName: "s1", sessionName: "回1",
                sessionStartedAt: decisionTestSessionStart)
            let topicId = first.topics[0].id

            // タイトルを変えても topicId が一致すれば同じ議題に積む。
            let second = try DecisionLogStore.merge(
                delta: makeDecisionDelta(topicId: topicId, title: "違うタイトル", text: "追加分"),
                folder: decisionTestFolder, sessionDirectoryName: "s2", sessionName: "回2",
                sessionStartedAt: decisionTestSessionStart.addingTimeInterval(3600))

            #expect(second.topics.count == 1)
            #expect(second.topics[0].id == topicId)
            #expect(second.topics[0].history.count == 2)
        }
    }

    @Test func topicId無しでもtitle完全一致で既存議題に積まれる() throws {
        try withTemporaryDecisionStore {
            _ = try DecisionLogStore.merge(
                delta: makeDecisionDelta(title: "レート制限", text: "初期案"),
                folder: decisionTestFolder, sessionDirectoryName: "s1", sessionName: "回1",
                sessionStartedAt: decisionTestSessionStart)

            let second = try DecisionLogStore.merge(
                delta: makeDecisionDelta(title: "レート制限", text: "追加分"),
                folder: decisionTestFolder, sessionDirectoryName: "s2", sessionName: "回2",
                sessionStartedAt: decisionTestSessionStart.addingTimeInterval(3600))

            #expect(second.topics.count == 1)
            #expect(second.topics[0].history.count == 2)
        }
    }

    @Test func topicIdもtitleも一致しなければ新規議題になる() throws {
        try withTemporaryDecisionStore {
            _ = try DecisionLogStore.merge(
                delta: makeDecisionDelta(title: "レート制限", text: "初期案"),
                folder: decisionTestFolder, sessionDirectoryName: "s1", sessionName: "回1",
                sessionStartedAt: decisionTestSessionStart)

            let second = try DecisionLogStore.merge(
                delta: makeDecisionDelta(topicId: "存在しないid", title: "別の議題", text: "別の内容"),
                folder: decisionTestFolder, sessionDirectoryName: "s2", sessionName: "回2",
                sessionStartedAt: decisionTestSessionStart.addingTimeInterval(3600))

            #expect(second.topics.count == 2)
        }
    }

    // MARK: - removeEntries

    @Test func removeEntriesで履歴が空になった議題が消える() throws {
        try withTemporaryDecisionStore {
            let first = try DecisionLogStore.merge(
                delta: makeDecisionDelta(text: "初期案"), folder: decisionTestFolder,
                sessionDirectoryName: "s1", sessionName: "回1",
                sessionStartedAt: decisionTestSessionStart)
            let topicId = first.topics[0].id

            let after = try DecisionLogStore.removeEntries(
                folder: decisionTestFolder, sessionDirectoryName: "s1", topicID: topicId)

            #expect(after.topics.isEmpty)
        }
    }

    @Test func removeEntriesで他セッション由来のエントリは残る() throws {
        try withTemporaryDecisionStore {
            let first = try DecisionLogStore.merge(
                delta: makeDecisionDelta(text: "初期案"), folder: decisionTestFolder,
                sessionDirectoryName: "s1", sessionName: "回1",
                sessionStartedAt: decisionTestSessionStart)
            let topicId = first.topics[0].id
            try DecisionLogStore.merge(
                delta: makeDecisionDelta(topicId: topicId, text: "追加案"),
                folder: decisionTestFolder, sessionDirectoryName: "s2", sessionName: "回2",
                sessionStartedAt: decisionTestSessionStart.addingTimeInterval(3600))

            let after = try DecisionLogStore.removeEntries(
                folder: decisionTestFolder, sessionDirectoryName: "s1", topicID: topicId)

            #expect(after.topics.count == 1)
            #expect(after.topics[0].history.count == 1)
            #expect(after.topics[0].history[0].sessionDirectoryName == "s2")
        }
    }

    // MARK: - updateEntryText

    @Test func updateEntryTextで該当エントリのtextが書き換わる() throws {
        try withTemporaryDecisionStore {
            let first = try DecisionLogStore.merge(
                delta: makeDecisionDelta(text: "誤字のある内容"), folder: decisionTestFolder,
                sessionDirectoryName: "s1", sessionName: "回1",
                sessionStartedAt: decisionTestSessionStart)
            let topicId = first.topics[0].id

            let after = try DecisionLogStore.updateEntryText(
                folder: decisionTestFolder, sessionDirectoryName: "s1", topicID: topicId,
                newText: "修正済みの内容")

            #expect(after.topics[0].current?.text == "修正済みの内容")
        }
    }

    // MARK: - setArchived

    @Test func setArchivedでarchivedAtが付き戻すとnilに戻る() throws {
        try withTemporaryDecisionStore {
            let first = try DecisionLogStore.merge(
                delta: makeDecisionDelta(text: "初期案"), folder: decisionTestFolder,
                sessionDirectoryName: "s1", sessionName: "回1",
                sessionStartedAt: decisionTestSessionStart)
            let topicId = first.topics[0].id

            let archived = try DecisionLogStore.setArchived(
                folder: decisionTestFolder, topicID: topicId, archived: true)
            #expect(archived.topics[0].archivedAt != nil)

            let restored = try DecisionLogStore.setArchived(
                folder: decisionTestFolder, topicID: topicId, archived: false)
            #expect(restored.topics[0].archivedAt == nil)
        }
    }

    // MARK: - "MM:SS" パース

    @Test func MM_SSの正常系がパースできる() {
        #expect(DecisionLogStore.parseTimeSeconds("12:34") == 12 * 60 + 34)
        #expect(DecisionLogStore.parseTimeSeconds("00:00") == 0)
        #expect(DecisionLogStore.parseTimeSeconds("90:05") == 90 * 60 + 5)
    }

    @Test func MM_SSの不正系はnilに落ちる() {
        #expect(DecisionLogStore.parseTimeSeconds("") == nil)
        #expect(DecisionLogStore.parseTimeSeconds("abc") == nil)
        #expect(DecisionLogStore.parseTimeSeconds("12:34:56") == nil)
        #expect(DecisionLogStore.parseTimeSeconds("12") == nil)
        #expect(DecisionLogStore.parseTimeSeconds("12:99") == nil)
        #expect(DecisionLogStore.parseTimeSeconds("-1:30") == nil)
    }

    // MARK: - load: 壊れたJSON

    @Test func 壊れたJSONのloadは黙って空を返さない() throws {
        try withTemporaryDecisionStore {
            let dir = SessionStore.sessionsDirectory.appendingPathComponent(
                decisionTestFolder, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{ 壊れたJSON".utf8).write(
                to: dir.appendingPathComponent("decisions.json"))

            #expect(throws: DecisionLogStore.LoadError.self) {
                try DecisionLogStore.load(folder: decisionTestFolder)
            }
        }
    }

    @Test func ファイルが無ければ空の記録を返す() throws {
        try withTemporaryDecisionStore {
            let log = try DecisionLogStore.load(folder: decisionTestFolder)
            #expect(log.topics.isEmpty)
            #expect(log.version == DecisionLog.currentVersion)
        }
    }

    // MARK: - loadOrEmpty

    @Test func loadOrEmptyは壊れたJSONでも例外を投げず空を返す() throws {
        try withTemporaryDecisionStore {
            let dir = SessionStore.sessionsDirectory.appendingPathComponent(
                decisionTestFolder, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{ 壊れたJSON".utf8).write(
                to: dir.appendingPathComponent("decisions.json"))

            let log = DecisionLogStore.loadOrEmpty(folder: decisionTestFolder)
            #expect(log.topics.isEmpty)
        }
    }

    @Test func loadOrEmptyはファイルが無ければ空を返す() throws {
        try withTemporaryDecisionStore {
            let log = DecisionLogStore.loadOrEmpty(folder: decisionTestFolder)
            #expect(log.topics.isEmpty)
            #expect(log.version == DecisionLog.currentVersion)
        }
    }

    // MARK: - filterTopics

    @Test func filterTopicsで検索語がtitleとtextの両方にマッチする() {
        let log = DecisionLog(topics: [
            DecisionTopic(
                id: "t1", title: "レート制限",
                history: [
                    DecisionEntry(
                        text: "60回/分にする", status: .confirmed, sessionDirectoryName: "s1",
                        sessionName: "回1", recordedAt: decisionTestSessionStart)
                ]),
            DecisionTopic(
                id: "t2", title: "開発体制",
                history: [
                    DecisionEntry(
                        text: "無関係な内容", status: .confirmed, sessionDirectoryName: "s1",
                        sessionName: "回1", recordedAt: decisionTestSessionStart)
                ]),
        ])

        let byTitle = log.filterTopics(query: "レート", status: nil, showArchived: false)
        #expect(byTitle.filtered.map(\.id) == ["t1"])

        let byText = log.filterTopics(query: "60回", status: nil, showArchived: false)
        #expect(byText.filtered.map(\.id) == ["t1"])
    }

    @Test func filterTopicsでstatusフィルタが母集団の件数を変えずに絞り込む() {
        let log = DecisionLog(topics: [
            DecisionTopic(
                id: "t1", title: "議題A",
                history: [
                    DecisionEntry(
                        text: "内容A", status: .confirmed, sessionDirectoryName: "s1",
                        sessionName: "回1", recordedAt: decisionTestSessionStart)
                ]),
            DecisionTopic(
                id: "t2", title: "議題B",
                history: [
                    DecisionEntry(
                        text: "内容B", status: .pending, sessionDirectoryName: "s1",
                        sessionName: "回1", recordedAt: decisionTestSessionStart)
                ]),
        ])

        let result = log.filterTopics(query: "", status: .confirmed, showArchived: false)
        #expect(result.filtered.map(\.id) == ["t1"])
        // フィルタチップの件数は絞り込み前の母集団の内訳を示すため、statusFilter に関わらず
        // 両方のステータスの件数が入っている。
        #expect(result.statusCounts[.confirmed] == 1)
        #expect(result.statusCounts[.pending] == 1)
        #expect(result.visibleCount == 2)
    }

    @Test func filterTopicsでshowArchivedがアーカイブ済みだけを返す() {
        let log = DecisionLog(topics: [
            DecisionTopic(
                id: "t1", title: "現役議題", archivedAt: nil,
                history: [
                    DecisionEntry(
                        text: "内容", status: .confirmed, sessionDirectoryName: "s1",
                        sessionName: "回1", recordedAt: decisionTestSessionStart)
                ]),
            DecisionTopic(
                id: "t2", title: "アーカイブ済み議題", archivedAt: Date(),
                history: [
                    DecisionEntry(
                        text: "内容", status: .confirmed, sessionDirectoryName: "s1",
                        sessionName: "回1", recordedAt: decisionTestSessionStart)
                ]),
        ])

        let active = log.filterTopics(query: "", status: nil, showArchived: false)
        #expect(active.filtered.map(\.id) == ["t1"])

        let archived = log.filterTopics(query: "", status: nil, showArchived: true)
        #expect(archived.filtered.map(\.id) == ["t2"])
    }

    // MARK: - DecisionDelta の寛容デコード

    @Test func 未知のstatusはpendingに落ちる() throws {
        let json = """
            {"decisions": [{"title": "議題", "text": "内容", "status": "unknown-status"}]}
            """
        let delta = try JSONDecoder().decode(DecisionDelta.self, from: Data(json.utf8))
        #expect(delta.decisions[0].status == .pending)
    }

    @Test func nullフィールドはnilにデコードされる() throws {
        let json = """
            {"decisions": [
                {"topicId": null, "title": "議題", "text": "内容", "status": "confirmed",
                 "time": null, "by": null, "reason": null}
            ]}
            """
        let delta = try JSONDecoder().decode(DecisionDelta.self, from: Data(json.utf8))
        let item = delta.decisions[0]
        #expect(item.topicId == nil)
        #expect(item.time == nil)
        #expect(item.by == nil)
        #expect(item.reason == nil)
    }

    @Test func decisionsキーが欠落していれば空差分になる() throws {
        let delta = try JSONDecoder().decode(DecisionDelta.self, from: Data("{}".utf8))
        #expect(delta.decisions.isEmpty)
    }

    @Test func 必須項目のみで足りる() throws {
        let json = """
            {"decisions": [{"title": "議題", "text": "内容", "status": "tentative"}]}
            """
        let delta = try JSONDecoder().decode(DecisionDelta.self, from: Data(json.utf8))
        #expect(delta.decisions.count == 1)
        #expect(delta.decisions[0].status == .tentative)
    }

    // MARK: - extractedSessionDirectories

    @Test func 旧形式JSONにフィールドが無くても空配列でデコードできる() throws {
        let json = """
            {"version": 1, "topics": []}
            """
        let log = try JSONDecoder().decode(DecisionLog.self, from: Data(json.utf8))
        #expect(log.extractedSessionDirectories.isEmpty)
    }

    @Test func mergeでセッションディレクトリ名がextractedSessionDirectoriesに積まれる() throws {
        try withTemporaryDecisionStore {
            let log = try DecisionLogStore.merge(
                delta: makeDecisionDelta(text: "無料プランのみ60回/分"), folder: decisionTestFolder,
                sessionDirectoryName: "2026-01-01_000000", sessionName: "定例",
                sessionStartedAt: decisionTestSessionStart)

            #expect(log.extractedSessionDirectories == ["2026-01-01_000000"])
        }
    }

    @Test func 決定が1つも無い空差分のmergeでもextractedSessionDirectoriesに積まれる() throws {
        try withTemporaryDecisionStore {
            let log = try DecisionLogStore.merge(
                delta: DecisionDelta(decisions: []), folder: decisionTestFolder,
                sessionDirectoryName: "2026-01-01_000000", sessionName: "定例",
                sessionStartedAt: decisionTestSessionStart)

            #expect(log.extractedSessionDirectories == ["2026-01-01_000000"])
            #expect(log.topics.isEmpty)
        }
    }

    @Test func 同じセッションを2回mergeしてもextractedSessionDirectoriesが重複しない() throws {
        try withTemporaryDecisionStore {
            _ = try DecisionLogStore.merge(
                delta: makeDecisionDelta(text: "初期案"), folder: decisionTestFolder,
                sessionDirectoryName: "2026-01-01_000000", sessionName: "定例",
                sessionStartedAt: decisionTestSessionStart)
            let second = try DecisionLogStore.merge(
                delta: makeDecisionDelta(text: "改訂案"), folder: decisionTestFolder,
                sessionDirectoryName: "2026-01-01_000000", sessionName: "定例",
                sessionStartedAt: decisionTestSessionStart)

            #expect(second.extractedSessionDirectories == ["2026-01-01_000000"])
        }
    }

    // MARK: - 同一会議内の複数決定の束ね

    @Test func 同一delta内で同じtitleのitem2件が1エントリに束なる() throws {
        try withTemporaryDecisionStore {
            let delta = DecisionDelta(decisions: [
                DecisionDelta.Item(
                    topicId: nil, title: "開発体制の見直し", text: "フロントは2名体制にする",
                    status: .tentative, time: "05:00", by: .them, reason: nil),
                DecisionDelta.Item(
                    topicId: nil, title: "開発体制の見直し", text: "バックエンドは1名のまま",
                    status: .confirmed, time: "10:00", by: .me, reason: "レビュー負荷を考慮"),
            ])

            let log = try DecisionLogStore.merge(
                delta: delta, folder: decisionTestFolder, sessionDirectoryName: "2026-01-01_000000",
                sessionName: "個別MTG", sessionStartedAt: decisionTestSessionStart)

            #expect(log.topics.count == 1)
            let history = log.topics[0].history
            #expect(history.count == 1)
            #expect(history[0].text == "フロントは2名体制にする\nバックエンドは1名のまま")
            #expect(history[0].timeSeconds == 5 * 60)
            #expect(history[0].status == .confirmed)
            #expect(history[0].by == .them)
            #expect(history[0].reason == "レビュー負荷を考慮")
        }
    }

    @Test func topicIdとtitleで同じ議題に解決される2件も束なる() throws {
        try withTemporaryDecisionStore {
            let first = try DecisionLogStore.merge(
                delta: makeDecisionDelta(title: "レート制限", text: "初期案"),
                folder: decisionTestFolder, sessionDirectoryName: "s1", sessionName: "回1",
                sessionStartedAt: decisionTestSessionStart)
            let topicId = first.topics[0].id

            // topicId で参照する item と、title 一致で同じ議題に解決される item が
            // 同じ delta 内に混在していても、1件に束ねる。
            let delta = DecisionDelta(decisions: [
                DecisionDelta.Item(
                    topicId: topicId, title: "違うタイトルその1", text: "追加分A",
                    status: .pending, time: "01:00", by: nil, reason: nil),
                DecisionDelta.Item(
                    topicId: nil, title: "レート制限", text: "追加分B",
                    status: .confirmed, time: "02:00", by: nil, reason: nil),
            ])
            let second = try DecisionLogStore.merge(
                delta: delta, folder: decisionTestFolder, sessionDirectoryName: "s2",
                sessionName: "回2", sessionStartedAt: decisionTestSessionStart.addingTimeInterval(3600))

            #expect(second.topics.count == 1)
            let history = second.topics[0].history
            #expect(history.count == 2)  // s1 由来 + s2 由来(束ねられて1件)
            let s2Entry = history.first { $0.sessionDirectoryName == "s2" }
            #expect(s2Entry?.text == "追加分A\n追加分B")
            #expect(s2Entry?.status == .confirmed)
        }
    }

    // MARK: - compactIndex

    @Test func compactIndexの各行が議題idを角括弧で含む() throws {
        try withTemporaryDecisionStore {
            let log = try DecisionLogStore.merge(
                delta: makeDecisionDelta(text: "無料プランのみ60回/分"), folder: decisionTestFolder,
                sessionDirectoryName: "2026-01-01_000000", sessionName: "定例",
                sessionStartedAt: decisionTestSessionStart)
            let topicId = log.topics[0].id

            let index = DecisionLogStore.compactIndex(log)

            #expect(index.contains("[\(topicId)]"))
            #expect(index.contains("レート制限: 無料プランのみ60回/分"))
        }
    }

    @Test func compactIndexはアーカイブ済み議題を含まない() throws {
        try withTemporaryDecisionStore {
            let first = try DecisionLogStore.merge(
                delta: makeDecisionDelta(text: "初期案"), folder: decisionTestFolder,
                sessionDirectoryName: "s1", sessionName: "回1",
                sessionStartedAt: decisionTestSessionStart)
            let topicId = first.topics[0].id
            let archived = try DecisionLogStore.setArchived(
                folder: decisionTestFolder, topicID: topicId, archived: true)

            let index = DecisionLogStore.compactIndex(archived)

            #expect(index.isEmpty)
        }
    }

    @Test func 別議題は束ねない() throws {
        try withTemporaryDecisionStore {
            let delta = DecisionDelta(decisions: [
                DecisionDelta.Item(
                    topicId: nil, title: "議題A", text: "Aの内容", status: .confirmed, time: nil,
                    by: nil, reason: nil),
                DecisionDelta.Item(
                    topicId: nil, title: "議題B", text: "Bの内容", status: .confirmed, time: nil,
                    by: nil, reason: nil),
            ])

            let log = try DecisionLogStore.merge(
                delta: delta, folder: decisionTestFolder, sessionDirectoryName: "s1",
                sessionName: "回1", sessionStartedAt: decisionTestSessionStart)

            #expect(log.topics.count == 2)
            #expect(log.topics[0].history.count == 1)
            #expect(log.topics[1].history.count == 1)
        }
    }
}
