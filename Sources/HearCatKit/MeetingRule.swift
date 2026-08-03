import Foundation

/// カレンダーの予定を「会議」とみなすかどうかの判定のうち、EventKit に依存しない部分。
///
/// 根拠は会議サービスの URL があることだけに限る。参加者の有無は根拠にしない。
/// 参加者が並んでいても、もくもく会や勉強会のように録る必要のない集まりがあり、
/// 人数からは会議かどうかを判別できないため。
public enum MeetingRule {
    /// 会議の待ち合わせ場所として使われるサービス。
    /// 招待リンク(discord.gg など)は待ち合わせ場所とは限らないので入れない。
    public static let hosts: [String] = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "webex.com", "whereby.com", "meet.jit.si", "chime.aws", "bluejeans.com",
        "gather.town", "around.co", "slack.com",
    ]

    /// 渡した欄のどれかに会議サービスのホスト名が現れるか。
    ///
    /// カレンダーの種類によって URL の入り先が違う(Google は URL 欄、手貼りは
    /// 場所や説明欄)ため、3か所を同じ基準で見る。URL 欄だけをホスト名の確認
    /// なしに通すと、資料やチケットのリンクを入れただけの予定が会議になる。
    public static func mentionsMeetingHost(_ fields: [String?]) -> Bool {
        let text = fields.compactMap { $0 }.joined(separator: "\n")
        guard !text.isEmpty else { return false }
        return hosts.contains { text.localizedCaseInsensitiveContains($0) }
    }

    /// ユーザーが「この予定は録らない」と決めたものか。
    ///
    /// 会議サービスの URL があるかどうかだけでは、録る必要のない予定を弾けない。
    /// 例えば Google カレンダーの「すべての予定に会議を追加」を有効にしていると、
    /// 個人的なリマインダーにも会議リンクが付く。ここは「ルールでは会議に見えるが、
    /// 本人は録りたくない」を受け止める場所。
    ///
    /// 除外の根拠は2つ。予定を指す ID と、予定名に含まれる言葉(予告を見逃した後でも
    /// 設定画面から止められる)。
    ///
    /// ID を複数受けるのは、繰り返しの予定を1つの ID で表せないカレンダーがあるため。
    /// Google の繰り返しは回ごとに `..._R20260617T020000@google.com` のような別々の
    /// eventIdentifier を持つので、それを鍵に外しても次の回にはまた予告が出て、
    /// 押すたびに「録らない予定」が増えていく。回をまたいで共通の ID
    /// (calendarItemExternalIdentifier)を第一の鍵にしつつ、以前のバージョンが
    /// eventIdentifier で保存した分も外れたままになるよう、どれか1つでも一致したら除外する。
    public static func isExcluded(
        eventIDs: [String], title: String, excludedIDs: Set<String>, keywords: [String]
    ) -> Bool {
        if eventIDs.contains(where: excludedIDs.contains) { return true }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return false }
        return keywords.contains { keyword in
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            return trimmedTitle.localizedCaseInsensitiveContains(trimmed)
        }
    }
}
