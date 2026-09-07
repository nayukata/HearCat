import Foundation

/// 複数チャンネルの確定セグメントを1ファイルへ直列に追記する。
/// actor にすることで、自分/相手の2系統が同時に届いても行が壊れない(書き込み競合の防止)。
/// 文字起こしに現れる話者。行の分解と表示の色分けで同じ知識を使う。
public enum Speaker: String, Sendable, CaseIterable {
    case me = "自分"
    case other = "相手"
}

/// 文字起こしファイルの1行。行頭の時刻から録音内の再生位置を割り出すために使う。
public struct TranscriptLine: Identifiable, Sendable {
    /// 行番号(表示順の安定 ID)。
    public let id: Int
    /// 行頭の時刻表示(例 "12:34:56")。時刻の無い行(ヘッダや空行)は nil。
    public let stamp: String?
    /// 時刻を除いた本文(「話者: 発言」)。時刻の無い行は行全体。
    public let body: String
    /// 行頭の話者。話者ラベルの付かない行は nil。
    public let speaker: Speaker?
    /// 話者の実名。取り込んだ会議の文字起こし(「相手(菅原啓史): 発言」)だけが持つ。
    /// 自分と相手しか登場しない録音セッションでは nil。
    public let speakerName: String?
    /// 話者ラベルを除いた発言。話者の無い行は body と同じ。
    public let text: String
    /// セッション開始からの経過秒。時刻の無い行は nil。
    public let offset: TimeInterval?
}

/// TranscriptWriter が書く「[HH:mm:ss] 話者: 発言」形式を読み戻す側。
/// 形式の知識が書き手と読み手で食い違わないよう、同じファイルに置く。
public enum TranscriptParser {
    public static func lines(from text: String, sessionStart: Date) -> [TranscriptLine] {
        return bodyLines(from: text).enumerated().map { index, line in
            guard let (stamp, body) = split(line) else {
                return TranscriptLine(
                    id: index, stamp: nil, body: line, speaker: nil, speakerName: nil,
                    text: line, offset: nil)
            }
            let (speaker, speakerName, spoken) = splitSpeaker(body)
            // 行の時刻は時分秒だけなので、日をまたいだセッションでは開始より小さく見える
            // (allowDayCrossing: true で 24 時間補正する)。
            let offset = offsetSeconds(
                forWallClock: stamp, sessionStart: sessionStart, allowDayCrossing: true)
            return TranscriptLine(
                id: index, stamp: stamp, body: body, speaker: speaker, speakerName: speakerName,
                text: spoken, offset: offset.map(TimeInterval.init))
        }
    }

    /// "HH:mm:ss" または "HH:mm" の壁時計表記(AI が本文中に引用する場合など秒無しもある)を、
    /// sessionStart を基準にした経過秒に変換する。時 0-23、分秒 0-59 の範囲外、または
    /// パースできない場合は nil。
    ///
    /// allowDayCrossing が true の場合、経過が負(壁時計だけでは分からない日またぎで、
    /// stamp が sessionStart より小さく見える場合)は 24 時間を足して補正する
    /// (lines(from:sessionStart:) が文字起こしファイルの全行を必ずどれかの offset へ
    /// 解決する必要があるため)。false の場合は経過が負なら nil を返す
    /// (CodeImpactResultView.elapsedTimeString が使う、チップ表示のためのベストエフォートな
    /// 変換で、自信が持てない時は壁時計表記のまま出す方が安全なため、日またぎ補正はしない)。
    public static func offsetSeconds(
        forWallClock stamp: String, sessionStart: Date, allowDayCrossing: Bool
    ) -> Int? {
        let parts = stamp.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 || parts.count == 3,
            (0..<24).contains(parts[0]), (0..<60).contains(parts[1]),
            parts.count < 3 || (0..<60).contains(parts[2])
        else { return nil }
        let stampSeconds = parts[0] * 3600 + parts[1] * 60 + (parts.count == 3 ? parts[2] : 0)

        let comps = Calendar.current.dateComponents(
            [.hour, .minute, .second], from: sessionStart)
        let startSeconds = (comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60 + (comps.second ?? 0)

        var offset = stampSeconds - startSeconds
        if offset < 0 {
            guard allowDayCrossing else { return nil }
            offset += 24 * 3600
        }
        return offset
    }

    /// 「話者: 発言」を話者・実名・発言に分ける。既知の話者ラベルで始まる行だけを対象にする
    /// (発言の中のコロンを話者の区切りと取り違えないため)。
    ///
    /// 取り込んだ会議の文字起こしは「相手(菅原啓史): 発言」の形で実名を伴う。名前の終わりを
    /// 最初の ")" で見分けられるのは、書き出し側(TranscriptWriter.line(time:speaker:name:text:))が
    /// 名前から丸括弧を落としているため。
    private static func splitSpeaker(_ body: String) -> (Speaker?, String?, String) {
        for speaker in Speaker.allCases {
            guard body.hasPrefix(speaker.rawValue) else { continue }
            let rest = body.dropFirst(speaker.rawValue.count)
            if rest.hasPrefix(":") {
                return (speaker, nil, rest.dropFirst().trimmingCharacters(in: .whitespaces))
            }
            guard rest.hasPrefix("(") else { continue }
            let nameStart = rest.index(after: rest.startIndex)
            guard let close = rest[nameStart...].firstIndex(of: ")"),
                close > nameStart,
                rest[rest.index(after: close)...].hasPrefix(":")
            else { continue }
            let spoken = rest[rest.index(close, offsetBy: 2)...]
            return (
                speaker, String(rest[nameStart..<close]),
                spoken.trimmingCharacters(in: .whitespaces)
            )
        }
        return (nil, nil, body)
    }

    /// コピー機能など、TranscriptLine への変換を経ずに整形済みの本文だけが必要な場面向け。
    public static func bodyText(from text: String) -> String {
        bodyLines(from: text).joined(separator: "\n")
    }

    /// 最初の発言。履歴一覧の行に「何の話だったか」の手がかりを1行添えるために使う。
    /// 時刻は落とし、「話者: 発言」の形だけを返す(一覧では再生位置に対応づかないため)。
    /// 発言が1つも無ければ nil。
    public static func firstUtterance(from text: String) -> String? {
        for line in bodyLines(from: text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let body = split(trimmed).map(\.body) ?? trimmed
            guard !body.isEmpty else { continue }
            return body
        }
        return nil
    }

    /// 旧バージョンが書いていたヘッダー行(廃止済み)と、それに続く空行を取り除く。
    /// ヘッダーの無い新形式のファイルでは何も落とさない。
    private static func bodyLines(from text: String) -> [String] {
        Array(text.components(separatedBy: "\n")
            .drop(while: { $0.isEmpty || $0.hasPrefix("# 文字起こし") }))
    }

    /// 「[HH:mm:ss] 本文」を (時刻, 本文) に分ける。形式に合わない行は nil。
    private static func split(_ line: String) -> (stamp: String, body: String)? {
        guard line.hasPrefix("["), line.count >= 11 else { return nil }
        let stamp = String(line.dropFirst().prefix(8))
        let rest = line.dropFirst(10)
        let parts = stamp.split(separator: ":")
        guard parts.count == 3, parts.allSatisfy({ $0.count == 2 && Int($0) != nil }),
              line[line.index(line.startIndex, offsetBy: 9)] == "]"
        else { return nil }
        return (stamp, String(rest).trimmingCharacters(in: .whitespaces))
    }
}

public actor TranscriptWriter {
    private let fileURL: URL
    private let handle: FileHandle
    /// これまで書いたセグメント。順序が入れ替わって届いた時にファイルを
    /// 並べ直して書き戻すために持つ。
    private var segments: [TranscriptSegment] = []

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: fileURL)
    }

    public func append(_ segment: TranscriptSegment) {
        // タイムスタンプは発話開始時刻で、確定までの遅延はチャンネルごとに違うため、
        // 発話順と届く順が入れ替わることがある。ファイルは発話時刻順を保つ。
        // 通常(順序どおり)は追記だけで済ませ、入れ替わった時だけ全体を書き直す
        // (1セッション高々数百行なので書き直しは十分軽い)。
        if let last = segments.last, last.timestamp > segment.timestamp {
            let index = segments.lastIndex(where: { $0.timestamp <= segment.timestamp }).map { $0 + 1 } ?? 0
            segments.insert(segment, at: index)
            rewrite()
        } else {
            segments.append(segment)
            write(Self.line(for: segment) + "\n")
        }
    }

    private func rewrite() {
        let content = segments.map { Self.line(for: $0) + "\n" }.joined()
        do {
            try handle.truncate(atOffset: 0)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Data(content.utf8))
            try handle.synchronize()
        } catch {
            // ディスク満杯やボリューム取り外しなどで失敗しても、後続の書き込みで
            // 復帰する可能性があるためクラッシュさせず継続する。
            errorLog("文字起こしの書き直しに失敗しました: \(error)")
        }
    }

    public func close() {
        try? handle.close()
    }

    private func write(_ line: String) {
        do {
            try handle.write(contentsOf: Data(line.utf8))
            // 追記のたびに flush して、録音中でも AI(Claude Code)が最新を読めるようにする。
            try handle.synchronize()
        } catch {
            // 上と同じ理由でクラッシュさせず継続する。
            errorLog("文字起こしの書き込みに失敗しました: \(error)")
        }
    }

    /// ファイルに書く行の書式。ライブ画面のコピー機能が、まだファイルに書かれていない
    /// 確定分を同じ形式で複製するためにも参照する(書式の知識を1箇所にまとめる)。
    public static func line(for segment: TranscriptSegment) -> String {
        "[\(timeString(from: segment.timestamp))] \(segment.speaker): \(segment.text)"
    }

    /// 実名を伴う1行。取り込んだ会議の文字起こし(MeetingTranscriptImport)が書く形式の正本で、
    /// 読み戻しは TranscriptParser が受け持つ。名前が空、または名前を落とした結果空になる
    /// 場合は、実名の無い通常の行と同じ形にする。
    public static func line(time: Date, speaker: Speaker, name: String?, text: String) -> String {
        let cleaned = name.map(sanitizedSpeakerName) ?? ""
        let label = cleaned.isEmpty ? speaker.rawValue : "\(speaker.rawValue)(\(cleaned))"
        return "[\(timeString(from: time))] \(label): \(text)"
    }

    /// 実名を、行の書式を壊さない形に整える。TranscriptParser は名前の終わりを最初の ")" で
    /// 見分けるため、半角の丸括弧が名前に残ると発言の頭が名前側へ食い込む。落とすと
    /// 「山田太郎 (Host)」のような表示名が「山田太郎 Host」になってしまうので、
    /// 取り違えの元にならない全角へ寄せて中身を残す。コロンと改行は落とす。
    public static func sanitizedSpeakerName(_ raw: String) -> String {
        String(
            raw.map { character in
                switch character {
                case "(": return "（"
                case ")": return "）"
                default: return character
                }
            })
            .filter { !":：\n\r\t".contains($0) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "HH:mm:ss"(en_US_POSIX)で時刻を文字列化する。line(for:) が書く時刻表記と同じ書式にする
    /// ことで、他画面(LiveSessionView など)がファイル内の時刻表記とそのまま文字列比較できる
    /// ようにする。actor(TranscriptWriter)をまたいで呼ばれるため、DateFormatter は共有せず
    /// 呼び出しごとに作る。
    public static func timeString(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
