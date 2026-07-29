import Foundation
import HearCatKit

/// 更新確認の結果。設定画面の表示に必要な状態だけを持つ。
enum UpdateCheckResult: Equatable {
    case checking
    case upToDate
    case available(String)
    case failed
}

/// main の Info.plist にあるバージョンと手元のバージョンを比べて、更新の有無だけを出す。
///
/// 配布は署名済みバイナリではなくソース一式(bootstrap.sh)で、署名はビルドした本人の
/// 証明書に紐づく。そのためアプリが自分自身を置き換えることはせず、「新しいのが出ている」
/// ことだけを伝える。実際の更新は設定画面が案内するコマンドの再実行で行う。
enum UpdateCheck {
    /// main の Info.plist。raw は CDN 配信なので、GitHub API のレート制限(未認証で
    /// 1時間60回)に掛からない。
    private static let manifestURL = URL(
        string: "https://raw.githubusercontent.com/nayukata/HearCat/main/Sources/HearCatApp/Info.plist"
    )!

    /// 更新のために実行してもらうコマンド。導入と同じもので、LP の「更新するには」
    /// (web/src/components/Install.astro) と同じ文面。
    static let command =
        "curl -fsSL https://raw.githubusercontent.com/nayukata/HearCat/main/bootstrap.sh | bash"

    /// 手元のバージョン。取れなければ nil を返し、比較そのものを行わない。
    static var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    static func run(currentVersion: String) async -> UpdateCheckResult {
        guard let latest = await latestVersion() else { return .failed }
        return AppVersion.isNewer(latest, than: currentVersion) ? .available(latest) : .upToDate
    }

    private static func latestVersion() async -> String? {
        var request = URLRequest(url: manifestURL)
        // 最新かどうかを見に行くので、手元に残った古い応答を使わせない。
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10

        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse,
            http.statusCode == 200,
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let version = (plist as? [String: Any])?["CFBundleShortVersionString"] as? String,
            !version.isEmpty
        else { return nil }

        return version
    }
}

/// 1日1回、決まった時刻に更新を確認する見張り役。
///
/// 知らせるかどうかの判断はここで行わない。確認して結果を渡すところまでを担い、
/// 画面に何を出すかはアプリ側(AppModel)に任せる。
@MainActor
final class UpdateCheckScheduler {
    /// 基準時刻をまたいだかを見に行く間隔。スリープ中は発火しないので、
    /// 復帰後の最初の tick で追いつく。
    private static let pollInterval: TimeInterval = 300
    private static let lastCheckedKey = "lastUpdateCheckAt"

    /// 更新が見つかった。同じバージョンについて何度も呼ばれることはある
    /// (日をまたいで確認し直したとき)。
    var onUpdateFound: ((String) -> Void)?

    private var timer: Timer?
    private var enabled = false
    private var checking = false
    private var lastCheckedAt: Date?

    init() {
        lastCheckedAt = UserDefaults.standard.object(forKey: Self.lastCheckedKey) as? Date
    }

    func setEnabled(_ on: Bool) {
        guard enabled != on else { return }
        enabled = on
        timer?.invalidate()
        timer = nil
        guard on else { return }
        // 有効にした直後にも一度見る(基準時刻を過ぎてから起動した場合に追いつくため)。
        Task { await tick() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in await self?.tick() }
        }
    }

    private func tick() async {
        guard enabled, !checking else { return }
        guard UpdateCheckSchedule.isDue(now: Date(), lastCheckedAt: lastCheckedAt) else { return }
        guard let current = UpdateCheck.currentVersion else { return }

        checking = true
        defer { checking = false }
        let result = await UpdateCheck.run(currentVersion: current)
        // 通信に失敗した日は記録を進めない。次の tick でやり直す
        // (記録を進めると、その日はもう確認しなくなってしまう)。
        guard result != .failed else { return }
        markChecked()
        if case .available(let latest) = result { onUpdateFound?(latest) }
    }

    private func markChecked() {
        let now = Date()
        lastCheckedAt = now
        UserDefaults.standard.set(now, forKey: Self.lastCheckedKey)
    }
}
