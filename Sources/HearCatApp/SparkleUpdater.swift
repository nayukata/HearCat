import Foundation
import Sparkle

/// Sparkle による自動更新のラッパー。SPUStandardUpdaterController を保持し、
/// 設定画面の「更新を確認」ボタンと自動チェックのオン/オフから使う。
///
/// 開発ビルド(`swift build` のデフォルト = debug)では更新チェックを一切起動しない。
/// `make dist` が作る release ビルドでのみ有効になる。署名が安定しない開発ビルドが
/// 誤って appcast をチェックしに行ったり、自分自身を上書きしたりするのを防ぐため。
/// Info.plist に `SUFeedURL` が無い場合も同様に静かに無効化する
/// (将来 Info.plist の設定漏れがあってもクラッシュさせない)。
@MainActor
final class SparkleUpdater {
    static let shared = SparkleUpdater()

    private let controller: SPUStandardUpdaterController?

    /// 手動チェックボタンを押せる状態か。起動直後のフィード取得前などは false になる。
    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    /// 自動チェックの有効/無効。Sparkle 自身が UserDefaults へ永続化する。
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// このビルドで自動更新が有効か(= 設定画面にセクションを出すかどうかの判定に使う)。
    var isEnabled: Bool { controller != nil }

    private init() {
        #if DEBUG
        controller = nil
        #else
        guard
            let feedURLString = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            !feedURLString.isEmpty
        else {
            controller = nil
            return
        }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        #endif
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
