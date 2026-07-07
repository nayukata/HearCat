import Foundation

/// ライブ表示の行並びを管理する。方針は「一度画面に出た行はその場から動かさない」。
///
/// 確定の遅延はチャンネルごとに違う(実測5分間で、マイクは中央値20秒・
/// システム音声は14秒)。確定行を発話開始時刻でソートすると、遅れて届いた
/// 確定が既存行の上へ割り込み続け(実測で新規行の31%が割り込み)、画面の
/// 順番がシャッフルされて見える。そこで表示は「認識中の行が現れた位置」を
/// 席として固定し、確定文はその席へ流し込む。厳密な時系列はファイル
/// (transcript)側が保証し、ライブ表示は並びの安定を優先する。
public struct LiveTimeline: Equatable, Sendable {
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: String
        /// 発話開始の実時刻。認識中の行では表示に使わない(揺れるため)。
        public let time: Date
        public let speaker: String
        public let text: String
        public let volatile: Bool
    }

    public private(set) var rows: [Row] = []
    /// 確定行の ID 採番。行の識別を安定させるためだけの連番。
    private var finalCount = 0

    public init() {}

    /// 認識中(暫定)テキストの更新。行は話者ごとに1つで、既にあれば同じ席で
    /// 文面だけ差し替える。空文字は「暫定行を消せ」の合図(確定がエコーとして
    /// 破棄され、確定による通常の消去が起きない時に届く)。
    public mutating func setVolatile(speaker: String, text: String, startedAt: Date) {
        let id = volatileID(speaker)
        let index = rows.firstIndex { $0.id == id }
        if text.isEmpty {
            if let index { rows.remove(at: index) }
            return
        }
        let row = Row(id: id, time: startedAt, speaker: speaker, text: text, volatile: true)
        if let index {
            rows[index] = row
        } else {
            rows.append(row)
        }
    }

    /// 確定した発話。同じ話者の認識中の行があればその席へ流し込む。
    /// なければ(エコー破棄の直後や、暫定が一度も届かず確定した時)末尾に足す。
    public mutating func finalize(_ segment: TranscriptSegment) {
        finalCount += 1
        let row = Row(
            id: "final-\(finalCount)", time: segment.timestamp,
            speaker: segment.speaker, text: segment.text, volatile: false)
        if let index = rows.firstIndex(where: { $0.id == volatileID(segment.speaker) }) {
            rows[index] = row
        } else {
            rows.append(row)
        }
    }

    /// 認識中の行をすべて消す(文字起こしオフ・セッション停止時)。
    public mutating func clearVolatiles() {
        rows.removeAll(where: \.volatile)
    }

    public mutating func removeAll() {
        rows = []
        finalCount = 0
    }

    /// 認識中の行の ID。話者で固定し、認識中→確定の入れ替わりでビューの
    /// 状態(ストリーム表示の進み)が別の行へ引き継がれないようにする。
    private func volatileID(_ speaker: String) -> String {
        "volatile-\(speaker)"
    }
}
