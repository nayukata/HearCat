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
}
