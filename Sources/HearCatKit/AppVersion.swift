import Foundation

/// 更新確認を「1日1回、決まった時刻に」回すための判定。
///
/// Mac が寝ていたり、アプリが起動していなかったりして、その時刻をまたげないことがある。
/// 時刻ちょうどでしか確認しない作りにすると、日中しか Mac を開かない使い方で
/// 一度も確認が走らなくなる。そのため「今日の基準時刻を過ぎていて、それ以降まだ
/// 確認していない」を条件にし、過ぎてから起動した場合はその場で追いつく。
public enum UpdateCheckSchedule {
    /// 確認を始める時刻(時)。
    public static let hour = 11

    /// now の時点で確認すべきか。lastCheckedAt が nil なら、今日の基準時刻を
    /// 過ぎていれば確認する。
    public static func isDue(
        now: Date,
        lastCheckedAt: Date?,
        hour: Int = UpdateCheckSchedule.hour,
        calendar: Calendar = .current
    ) -> Bool {
        guard let due = calendar.date(
            bySettingHour: hour, minute: 0, second: 0, of: now, matchingPolicy: .nextTime)
        else { return false }
        // 夏時間の切り替え日など、その日にその時刻が存在しない場合は翌日以降に回る。
        guard calendar.isDate(due, inSameDayAs: now) else { return false }
        guard now >= due else { return false }
        guard let lastCheckedAt else { return true }
        return lastCheckedAt < due
    }
}

/// `CFBundleShortVersionString`("0.3.0" 形式)の比較。
/// 更新の有無は、手元のバージョンと main の Info.plist にあるバージョンを比べて判定する。
public enum AppVersion {
    /// candidate が current より新しければ true。
    ///
    /// 桁数が違う場合("0.3" と "0.3.0" など)は足りない側を 0 として比べる。
    /// 数字以外が混ざるなど解釈できない形式は false を返す。判断できないときに
    /// 「更新があります」と誤って伝えないため、不明は「更新なし」側へ倒す。
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard
            let candidateNumbers = numbers(of: candidate),
            let currentNumbers = numbers(of: current)
        else { return false }

        for index in 0..<max(candidateNumbers.count, currentNumbers.count) {
            let left = index < candidateNumbers.count ? candidateNumbers[index] : 0
            let right = index < currentNumbers.count ? currentNumbers[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func numbers(of version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var numbers: [Int] = []
        for part in parts {
            // Int("+1") や Int("１") を通さないよう、10 進数字だけで構成されていることを先に見る。
            guard part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber), let number = Int(part) else {
                return nil
            }
            numbers.append(number)
        }
        return numbers
    }
}
