import Foundation
import Testing

@testable import HearCatKit

/// 要約の 4 セクション形式(概要 / 話題ごとのまとめ / 決定事項 / TODO・宿題)を
/// SummaryParser が構造化できること、想定外の形式では nil(原文表示への
/// フォールバック)になることの検証。
struct SummaryParserTests {
    @Test func 標準の4セクションを分解する() {
        let text = """
            ## 概要

            週次の進捗共有ミーティング。

            ## 話題ごとのまとめ

            ### 進捗報告
            - 同意画面まわりを実装した
            - 今週は TODO リストから対応する

            ### 検診ラベルの英語対応
            - 英語ラベルをバックエンドに追加する方針で合意

            ## 決定事項

            - PR は develop ブランチへマージする

            ## TODO・宿題

            - デバイス連携の仕様決定 (担当: 小倉さん)
            - 送信テスト各パターン(担当: 上村さん)
            """
        let summary = SummaryParser.parse(text)

        #expect(summary?.overview == "週次の進捗共有ミーティング。")
        #expect(summary?.topics.count == 2)
        #expect(summary?.topics[0].title == "進捗報告")
        #expect(summary?.topics[0].blocks.map(\.text) == ["同意画面まわりを実装した", "今週は TODO リストから対応する"])
        #expect(summary?.topics[0].blocks.allSatisfy(\.isBullet) == true)
        #expect(summary?.decisions == ["PR は develop ブランチへマージする"])
        #expect(summary?.todos.count == 2)
        #expect(summary?.todos[0].text == "デバイス連携の仕様決定")
        #expect(summary?.todos[0].assignee == "小倉さん")
        // 括弧の前に空白が無い形(オンデバイス要約の出力)も担当を分離できる。
        #expect(summary?.todos[1].text == "送信テスト各パターン")
        #expect(summary?.todos[1].assignee == "上村さん")
    }

    @Test func 全角括弧の担当も分離する() {
        let text = """
            ## 概要
            テスト。
            ## TODO・宿題
            - 資料の共有（担当：前田さん）
            """
        let summary = SummaryParser.parse(text)

        #expect(summary?.todos[0].text == "資料の共有")
        #expect(summary?.todos[0].assignee == "前田さん")
    }

    @Test func 担当の無いTODOはそのまま保持する() {
        let text = """
            ## 概要
            テスト。
            ## TODO・宿題
            - 次回までに各自レビュー
            """
        let summary = SummaryParser.parse(text)

        #expect(summary?.todos[0].text == "次回までに各自レビュー")
        #expect(summary?.todos[0].assignee == nil)
    }

    /// 空セクションのプレースホルダ「なし」は項目として扱わない(空表示に落とす)。
    @Test func なしだけのセクションは空になる() {
        let text = """
            ## 概要
            雑談のみの通話。
            ## 決定事項
            - なし
            ## TODO・宿題
            - なし
            """
        let summary = SummaryParser.parse(text)

        #expect(summary?.decisions.isEmpty == true)
        #expect(summary?.todos.isEmpty == true)
    }

    /// 未知のセクションを含む文書を中途半端に構造化すると、その部分が静かに
    /// 欠落する。欠落させないため全体をフォールバック(nil)にする。
    @Test func 未知のセクションがあればnil() {
        let text = """
            ## 概要
            テスト。
            ## 所感
            - よかった
            """
        #expect(SummaryParser.parse(text) == nil)
    }

    @Test func 見出しより前に前置きがあればnil() {
        let text = """
            以下に要約を示します。
            ## 概要
            テスト。
            """
        #expect(SummaryParser.parse(text) == nil)
    }

    @Test func 見出しの無い文書はnil() {
        #expect(SummaryParser.parse("ただのメモ書き") == nil)
        #expect(SummaryParser.parse("") == nil)
    }

    /// 「### より前に置かれた本文」も欠落させず、見出しなしの話題として保持する。
    @Test func 話題見出しの無い本文も保持する() {
        let text = """
            ## 概要
            テスト。
            ## 話題ごとのまとめ
            全体を通して短い雑談だった。
            """
        let summary = SummaryParser.parse(text)

        #expect(summary?.topics.count == 1)
        #expect(summary?.topics[0].title == "")
        #expect(summary?.topics[0].blocks.map(\.text) == ["全体を通して短い雑談だった。"])
    }

    /// エージェント要約の自然文スタイル。箇条書きでない本文は段落ブロックになり、
    /// 空行を挟まない連続行は1つの段落にまとまる。
    @Test func 話題の自然文は段落ブロックになる() {
        let text = """
            ## 概要
            テスト。
            ## 話題ごとのまとめ
            ### チャットボット開発進捗確認
            ベースリポジトリは公開可能な状態であり、回答精度を向上させた。
            出典の明示についてはファイル名での識別で運用を開始する。

            承認フローの構築を検討することに決定した。
            """
        let summary = SummaryParser.parse(text)

        let blocks = summary?.topics[0].blocks
        #expect(blocks?.count == 2)
        #expect(blocks?[0].isBullet == false)
        #expect(
            blocks?[0].text
                == "ベースリポジトリは公開可能な状態であり、回答精度を向上させた。\n出典の明示についてはファイル名での識別で運用を開始する。")
        #expect(blocks?[1].text == "承認フローの構築を検討することに決定した。")
    }

    /// 段落と箇条書きが混在する話題では、箇条書き行が段落に吸収されない。
    @Test func 段落と箇条書きの混在を区別する() {
        let text = """
            ## 概要
            テスト。
            ## 話題ごとのまとめ
            ### 運用と承認プロセス
            全体方針を確認した。
            - 承認フローを作る
            - 停滞タスクはクローズする
            """
        let summary = SummaryParser.parse(text)

        let blocks = summary?.topics[0].blocks
        #expect(blocks?.map(\.isBullet) == [false, true, true])
        #expect(blocks?.map(\.text) == ["全体方針を確認した。", "承認フローを作る", "停滞タスクはクローズする"])
    }
}
