import Foundation
import Testing

@testable import HearCatKit

struct AppVersionTests {
    @Test func 数値として比べるので桁上がりを取り違えない() {
        #expect(AppVersion.isNewer("0.10.0", than: "0.9.0"))
        #expect(!AppVersion.isNewer("0.9.0", than: "0.10.0"))
    }

    @Test func 同じバージョンは更新なし() {
        #expect(!AppVersion.isNewer("0.3.0", than: "0.3.0"))
    }

    @Test func 古いバージョンは更新なし() {
        #expect(!AppVersion.isNewer("0.2.0", than: "0.3.0"))
        #expect(AppVersion.isNewer("1.0.0", than: "0.3.0"))
    }

    @Test func 桁数が違っても足りない側を0として比べる() {
        #expect(!AppVersion.isNewer("0.3", than: "0.3.0"))
        #expect(AppVersion.isNewer("0.3.1", than: "0.3"))
    }

    /// 取得先が壊れていたときに「更新があります」と誤って出さないための保険。
    @Test func 解釈できない形式は更新なしに倒す() {
        #expect(!AppVersion.isNewer("0.3.0-beta", than: "0.2.0"))
        #expect(!AppVersion.isNewer("", than: "0.2.0"))
        #expect(!AppVersion.isNewer("<!DOCTYPE html>", than: "0.2.0"))
        #expect(!AppVersion.isNewer("0.3.0", than: "不明"))
    }
}
