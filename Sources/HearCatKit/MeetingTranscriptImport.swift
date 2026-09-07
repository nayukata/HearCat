import Foundation

/// Google Meet や Zoom が書き出した文字起こしを読み、HearCat のセッションとして取り込む。
///
/// 録音は伴わない(会議アプリ側の録画は手元に無い)ため、作られるセッションは文字起こしだけを
/// 持つ。再生ジャンプは効かないが、行の経過時間・話者・検索・要約・質疑応答は録音した
/// セッションと同じように使える。
///
/// 話者は実名のまま残す。会議アプリの文字起こしは3人以上が普通で、名前を落とすと
/// 「誰が言ったか」が失われ、取り込む意味がほとんど無くなるため。取り込み時に選んだ
/// 「自分」だけを自分として扱い、それ以外は相手として扱う(色分けと要約の視点のため)。
public enum MeetingTranscriptImport {
    /// 読み取れた元の形式。取り込み画面で何として読んだかを見せるために使う。
    public enum Source: String, Sendable {
        /// Google Meet の文字起こし(Google ドキュメントからの貼り付け)。
        case meet
        /// 字幕ファイル。Zoom のクラウド録画が書き出す .vtt と、その親戚の .srt。
        case caption

        public var displayName: String {
            switch self {
            case .meet: return "Google Meet の文字起こし"
            case .caption: return "字幕ファイル (Zoom など)"
            }
        }
    }

    /// 1発言。offset は会議開始からの経過秒。
    public struct Utterance: Sendable, Equatable {
        public let offset: TimeInterval
        /// 話者の実名。行から読み取れなかった場合は nil。
        public let speaker: String?
        public let text: String

        public init(offset: TimeInterval, speaker: String?, text: String) {
            self.offset = offset
            self.speaker = speaker
            self.text = text
        }
    }

    /// 読み取り結果。会議名と開始日時は「読み取れれば」の値で、取り込み画面で直せる。
    public struct Parsed: Sendable {
        public let source: Source
        /// 読み取れた会議名。読み取れなければ nil。
        public let suggestedName: String?
        /// 読み取れた開始日時。日付しか分からない形式では、その日の 0 時になる。
        public let suggestedStart: Date?
        /// suggestedStart が時刻まで分かっているか。Google Meet の文字起こしには開始時刻が
        /// 書かれておらず 0 時になるため、取り込み画面で「時刻は直したほうがよい」と
        /// 伝えるために持つ。
        public let suggestedStartHasTime: Bool
        /// 登場した話者を出てきた順に並べたもの。取り込み画面の「自分」の選択肢になる。
        public let speakers: [String]
        public let utterances: [Utterance]

        /// 最後の発言までの長さ。取り込み画面で「どれくらいの会議か」を見せるために使う。
        public var duration: TimeInterval { utterances.last?.offset ?? 0 }
    }

    public enum ImportError: LocalizedError, Equatable {
        case empty
        case tooLarge
        case unrecognized

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "文字起こしが空です。"
            case .tooLarge:
                return "ファイルが大きすぎます (上限 5MB)。"
            case .unrecognized:
                return
                    "発言を読み取れませんでした。Google Meet の文字起こし、または Zoom の字幕ファイル (.vtt) を渡してください。"
            }
        }
    }

    /// 受け取りうる最大の大きさ。丸1日の会議でも 2MB に届かないため、これを超えるものは
    /// 文字起こしではないと判断して読み込みごと断る(巨大なファイルで固まらせないため)。
    static let byteLimit = 5 * 1024 * 1024

    // MARK: - 入口

    /// ファイルを文字列として読む。読み取り自体は parse(_:) が受け持つ
    /// (取り込み画面は貼り付けた文字列とファイルを同じ経路で扱い、読み込んだ中身を
    /// そのまま画面に出して目で確かめられるようにしている)。
    public static func readText(at url: URL) throws -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= byteLimit else { throw ImportError.tooLarge }
        let data = try Data(contentsOf: url)
        // 大きさは読む前にも見ているが、そちらは問い合わせに失敗すると 0 として通る。
        // 実体を読んだ後にもう一度確かめる。
        guard data.count <= byteLimit else { throw ImportError.tooLarge }
        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS)
        else { throw ImportError.unrecognized }
        return raw
    }

    /// ファイル名から得られる手がかり。中身に会議名や日付が書かれていない形式
    /// (Zoom の字幕ファイル)のために使う。中身から読めた値のほうを優先すること。
    public static func hints(forFileNamed fileName: String) -> (name: String?, start: Date?) {
        (cleanedFileName(fileName), startDate(fromFileName: fileName))
    }

    /// 貼り付けられた文字列から読む。形式は中身で見分ける。
    public static func parse(_ raw: String) throws -> Parsed {
        guard raw.utf8.count <= byteLimit else { throw ImportError.tooLarge }
        // 先頭のバイト順マーク(書き出したファイルに付いていることがある)を落とす。
        // 残すと1行目が日付にも見出しにも一致せず、会議名と日付を取りこぼす。
        let lines = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw ImportError.empty
        }

        let parsed = isCaption(lines) ? parseCaption(lines) : parseMeet(lines)
        guard !parsed.utterances.isEmpty else { throw ImportError.unrecognized }
        // 文字起こしファイルは行頭に時分秒しか持たないため、開始から24時間以上先の位置は
        // 読み戻すときに1日ぶん巻き戻って別の時刻になる。壊れた字幕でしか起きないが、
        // 黙って違う経過時間を出すより落としたほうがよい。
        let within = parsed.utterances.filter { $0.offset < 24 * 3600 }
        guard !within.isEmpty else { throw ImportError.unrecognized }
        guard within.count != parsed.utterances.count else { return parsed }
        return Parsed(
            source: parsed.source, suggestedName: parsed.suggestedName,
            suggestedStart: parsed.suggestedStart,
            suggestedStartHasTime: parsed.suggestedStartHasTime,
            speakers: parsed.speakers.filter { name in within.contains { $0.speaker == name } },
            utterances: within)
    }

    /// 字幕ファイルか。時間範囲として実際に読める行(「00:00:03.780 --> 00:00:06.290」)を
    /// 持つかどうかで見る。WEBVTT の見出しはヘッダを削って渡される場合があるため、
    /// 見出しだけには頼らない。
    ///
    /// 「-->」を含むかどうかだけで見てはいけない。会議で「A --> B」と口にした一言が
    /// 文字起こしに残っているだけで、Google Meet の文字起こし全体が字幕として読まれ、
    /// 発言を1件も拾えずに取り込みごと失敗する。
    private static func isCaption(_ lines: [String]) -> Bool {
        lines.contains { captionStart($0) != nil }
    }

    // MARK: - 字幕ファイル (Zoom の .vtt / .srt)

    /// 「番号 / 時間範囲 / 本文」の塊の繰り返しとして読む。本文の話者は
    /// 「名前: 発言」(Zoom)と「<v 名前>発言</v>」(WebVTT の話者タグ)の両方を受ける。
    private static func parseCaption(_ lines: [String]) -> Parsed {
        var utterances: [Utterance] = []
        var speakers: [String] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            index += 1
            guard let start = captionStart(line) else { continue }

            // 次の空行までが1つの字幕。改行は表示の折り返しなので、つなげて1発言にする。
            var payload: [String] = []
            while index < lines.count {
                let next = lines[index]
                if next.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if captionStart(next) != nil { break }
                // 空行の無い書き出しでは、次の字幕の番号行がそのまま続く。番号だけの行の
                // 後ろに時間範囲が来ていれば、それは発言ではなく次の字幕の頭。
                if isCueNumber(next), index + 1 < lines.count, captionStart(lines[index + 1]) != nil {
                    break
                }
                payload.append(next)
                index += 1
            }

            let joined = payload.joined(separator: " ")
            let body = strippingTags(joined).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }

            let voice = voiceTagSpeaker(joined)
            let split = voice == nil ? splitNamedSpeaker(body) : nil
            let speaker = voice ?? split?.name
            let text = split?.text ?? body
            guard !text.isEmpty else { continue }

            if let speaker, !speakers.contains(speaker) { speakers.append(speaker) }
            utterances.append(Utterance(offset: start, speaker: speaker, text: text))
        }

        return Parsed(
            source: .caption, suggestedName: nil, suggestedStart: nil,
            suggestedStartHasTime: false, speakers: speakers, utterances: utterances)
    }

    /// 字幕の通し番号だけの行か。
    private static func isCueNumber(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.allSatisfy(\.isNumber)
    }

    /// 「00:00:03.780 --> 00:00:06.290」の開始側を経過秒にする。時間範囲でない行は nil。
    /// .srt がコンマを使うため、小数点はどちらも受ける。
    private static func captionStart(_ line: String) -> TimeInterval? {
        guard let range = line.range(of: "-->") else { return nil }
        let head = line[line.startIndex..<range.lowerBound]
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        return seconds(fromClock: head)
    }

    /// WebVTT の話者タグ「<v 名前>」から名前を取り出す。無ければ nil。
    private static func voiceTagSpeaker(_ line: String) -> String? {
        guard let open = line.range(of: "<v "),
            let close = line[open.upperBound...].firstIndex(of: ">")
        else { return nil }
        // 「<v.loud 名前>」のように装飾が付く場合があるため、末尾の名前だけを取る。
        let raw = String(line[open.upperBound..<close]).trimmingCharacters(in: .whitespaces)
        // 名前として扱う長さは「名前: 発言」の判定と揃える(長すぎるものは名前ではなく、
        // 取り込み画面の話者チップが横にはみ出す)。
        return raw.isEmpty || raw.count > nameLengthLimit ? nil : raw
    }

    /// 山括弧のタグ(<v ...> <i> など)を落とす。閉じない "<" は発言の中の不等号として
    /// そのまま残す(落とすと、その後ろの発言がまるごと消える)。
    private static func strippingTags(_ line: String) -> String {
        var out = ""
        var rest = Substring(line)
        while let open = rest.firstIndex(of: "<") {
            guard let close = rest[open...].firstIndex(of: ">") else { break }
            out += rest[rest.startIndex..<open]
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    // MARK: - Google Meet の文字起こし

    /// Google ドキュメントの文字起こしを貼り付けた形。
    /// 「00:02:18」だけの行が経過時間の見出しで、その後の「名前：発言」がその時間帯の発言。
    /// 発言の時刻は見出しの時刻をそのまま使う(行ごとの時刻は元から書かれていないため、
    /// 均等割りのような推定はしない)。
    private static func parseMeet(_ lines: [String]) -> Parsed {
        var utterances: [Utterance] = []
        var speakers: [String] = []
        var offset: TimeInterval = 0
        var name: String?
        var date: Date?
        var started = false

        // 直前の行が発言だったか。空行を挟むと切れる。折り返された発言の続きと、
        // 空行の後に来る断り書きを見分けるために持つ。
        var continuing = false

        // 発言を始めた行そのもの。話者ではなかったと後から分かったとき、行を丸ごと
        // 前の発言へ戻すために控える。
        var openingLines: [String] = []

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                continuing = false
                continue
            }

            if let heading = seconds(fromClock: line) {
                offset = heading
                started = true
                continuing = false
                continue
            }
            if let (speaker, text) = splitNamedSpeaker(line) {
                started = true
                continuing = true
                utterances.append(Utterance(offset: offset, speaker: speaker, text: text))
                openingLines.append(line)
                continue
            }
            // 発言の直後に続く行は、折り返された同じ発言の続きとして足す。
            if continuing, let last = utterances.popLast() {
                utterances.append(
                    Utterance(offset: last.offset, speaker: last.speaker, text: last.text + line))
                continue
            }
            // 発言が始まる前の数行だけが見出し。始まった後に空行を挟んで現れる地の文
            // (「この編集可能な文字起こしは…」などの断り書き)は発言ではないので捨てる。
            guard !started else { continue }
            if name == nil, let title = meetTitle(line) { name = title }
            if date == nil { date = meetDate(line) }
        }

        (utterances, speakers) = resolvingSpeakers(utterances, openingLines: openingLines)

        // 日付行に時刻は含まれない(その日の 0 時になる)。
        return Parsed(
            source: .meet, suggestedName: name, suggestedStart: date,
            suggestedStartHasTime: false, speakers: speakers, utterances: utterances)
    }

    /// 1度しか出てこない名前を話者から外す。
    ///
    /// 「名前: 発言」の見分けは行頭の短い語とコロンで決めるため、「結論: 大丈夫です」の
    /// ような言い回しを新しい話者として切り出してしまう。会議の話者は何度も出てくるので、
    /// 繰り返し出てくる名前が1つでもあれば、1度きりの名前は話者ではないとみなし、その行を
    /// 丸ごと直前の発言へ戻す(戻す先が無い先頭の行は、話者なしの発言として残す)。
    ///
    /// 発言が少ないうちは回数で見分けられないため、4件に満たない文字起こしでは何もしない。
    private static func resolvingSpeakers(
        _ utterances: [Utterance], openingLines: [String]
    ) -> ([Utterance], [String]) {
        var counts: [String: Int] = [:]
        for utterance in utterances {
            guard let speaker = utterance.speaker else { continue }
            counts[speaker, default: 0] += 1
        }
        let recurring = Set(counts.filter { $0.value >= 2 }.keys)

        var resolved: [Utterance] = []
        var openingIndex = 0
        for utterance in utterances {
            let opening = openingIndex < openingLines.count ? openingLines[openingIndex] : nil
            openingIndex += 1
            guard let speaker = utterance.speaker else {
                resolved.append(utterance)
                continue
            }
            let isSpeaker =
                recurring.contains(speaker) || recurring.isEmpty || utterances.count < 4
            if isSpeaker {
                resolved.append(utterance)
                continue
            }
            let line = opening ?? utterance.text
            if let last = resolved.popLast() {
                resolved.append(
                    Utterance(offset: last.offset, speaker: last.speaker, text: last.text + line))
            } else {
                resolved.append(Utterance(offset: utterance.offset, speaker: nil, text: line))
            }
        }

        var speakers: [String] = []
        for utterance in resolved {
            guard let speaker = utterance.speaker, !speakers.contains(speaker) else { continue }
            speakers.append(speaker)
        }
        return (resolved, speakers)
    }

    /// 「マーケ定例 - 文字起こし」から会議名を取り出す。見出しでなければ nil。
    private static func meetTitle(_ line: String) -> String? {
        for suffix in [" - 文字起こし", " - Transcript", "‐文字起こし", " -文字起こし"] {
            guard line.hasSuffix(suffix) else { continue }
            let title = String(line.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        return nil
    }

    /// 見出しの日付行(「9月 3, 2026」「September 3, 2026」など)を日付にする。
    /// 時刻は書かれていないため、その日の 0 時になる。
    private static func meetDate(_ line: String) -> Date? {
        let candidates: [(String, String)] = [
            ("M月 d, yyyy", "ja_JP"), ("yyyy年M月d日", "ja_JP"),
            ("MMMM d, yyyy", "en_US"), ("MMM d, yyyy", "en_US"),
            ("d MMMM yyyy", "en_US"),
            ("yyyy/M/d", "en_US_POSIX"), ("yyyy-MM-dd", "en_US_POSIX"),
        ]
        for (format, locale) in candidates {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: locale)
            formatter.dateFormat = format
            if let date = formatter.date(from: line) { return date }
        }
        return nil
    }

    // MARK: - 共通の読み取り

    /// 行頭の「名前: 発言」を切り出す。発言中のコロンを話者の区切りと取り違えないよう、
    /// 名前として自然な長さと文字だけを認める(会議アプリの話者は表示名で、句読点や
    /// 括弧を含まない)。全角コロン(Google Meet)と半角コロン(Zoom)の両方を受ける。
    static func splitNamedSpeaker(_ line: String) -> (name: String, text: String)? {
        guard let index = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
        let name = String(line[line.startIndex..<index]).trimmingCharacters(in: .whitespaces)
        let text = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !text.isEmpty, name.count <= nameLengthLimit else { return nil }
        // 「https://…」を「https さんの発言」と取り違えない。会議で共有された URL が
        // そのまま文字起こしに残ることがある。
        guard !text.hasPrefix("//") else { return nil }
        // 丸括弧と中黒は弾かない。「山田太郎（営業）」「ジョン・スミス」のような表示名は
        // 珍しくなく、弾くとその人の発言がまるごと落ちる。
        let forbidden = CharacterSet(charactersIn: "。、．，,!?！？「」『』[]【】…/\\\t|<>")
        guard name.rangeOfCharacter(from: forbidden) == nil else { return nil }
        // 数字だけの断片(「00」など)は名前ではない。
        guard name.contains(where: { !$0.isNumber && $0 != "." && $0 != " " }) else { return nil }
        return (name, text)
    }

    /// 話者名として認める長さ。会議アプリの表示名はこれより短い。
    static let nameLengthLimit = 32

    /// 「HH:MM:SS.mmm」「MM:SS」などの経過時間を秒にする。時間表記でなければ nil。
    static func seconds(fromClock raw: String) -> TimeInterval? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var total: TimeInterval = 0
        for (index, part) in parts.enumerated() {
            // 小数(字幕のミリ秒)を許すのは末尾だけ。時と分は整数。
            let isLast = index == parts.count - 1
            guard !part.isEmpty,
                part.allSatisfy({ $0.isNumber || (isLast && $0 == ".") }),
                let value = Double(part)
            else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// Zoom の書き出しファイル名(「GMT20260903-100000_Recording.transcript.vtt」)から開始日時を読む。
    /// GMT と書かれている通り協定世界時なので、手元の時間帯へ直して返す。
    static func startDate(fromFileName fileName: String) -> Date? {
        guard let range = fileName.range(of: "GMT") else { return nil }
        let rest = fileName[range.upperBound...]
        let digits = rest.prefix(while: { $0.isNumber || $0 == "-" })
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.date(from: String(digits))
    }

    /// ファイル名から会議名の当たりを付ける。拡張子と、Zoom が足す決まり文句を落とす。
    private static func cleanedFileName(_ fileName: String) -> String? {
        var name = fileName
        for suffix in [".vtt", ".srt", ".txt", ".transcript", ".cc", "_Recording"] {
            if name.lowercased().hasSuffix(suffix.lowercased()) {
                name = String(name.dropLast(suffix.count))
            }
        }
        // Zoom の書き出しは名前が日時そのもの(「GMT20260903-010000」)になることがある。
        // それは会議名ではないので、開始日時として読んだうえで名前からは落とす。
        if name.hasPrefix("GMT"), startDate(fromFileName: name) != nil {
            name = String(name.dropFirst(3).drop(while: { $0.isNumber || $0 == "-" }))
        }
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: " _-"))
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - 取り込み

    /// 読み取り結果を文字起こしファイルの中身にする。me に渡した話者だけを「自分」とし、
    /// それ以外(名前を読み取れなかった発言を含む)を「相手」にする。
    public static func transcript(from parsed: Parsed, me: String?, startDate: Date) -> String {
        parsed.utterances.map { utterance in
            let isMe = me != nil && utterance.speaker == me
            return TranscriptWriter.line(
                time: startDate.addingTimeInterval(utterance.offset),
                speaker: isMe ? .me : .other,
                name: utterance.speaker,
                text: utterance.text)
        }
        .joined(separator: "\n") + "\n"
    }

    /// セッションとして保存する。既存のセッションと日時・名前がぶつかっても上書きはしない
    /// (.hearcat の取り込みと同じく、別名の新しいセッションとして並ぶ)。
    @discardableResult
    public static func install(
        _ parsed: Parsed, name: String, startDate: Date, me: String?, intoFolder folder: String?
    ) throws -> SessionInfo {
        let created = try SessionStore.createUniqueSessionDirectory(
            startDate: startDate, name: name, folder: folder)
        do {
            let fileName = SessionInfo.Artifact.transcript.fileName(
                inDirectoryNamed: created.directory.lastPathComponent)
            try Data(transcript(from: parsed, me: me, startDate: startDate).utf8)
                .write(to: created.directory.appendingPathComponent(fileName), options: .atomic)
        } catch {
            // 書き込みに失敗したら、中身の無いセッションを履歴に残さない。
            try? FileManager.default.removeItem(at: created.directory)
            throw error
        }
        return SessionInfo(
            id: SessionStore.relativeID(for: created.directory),
            directory: created.directory,
            startDate: startDate,
            name: created.name,
            folder: created.folder)
    }
}
