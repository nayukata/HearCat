import Testing

@testable import HearCatApp

struct SessionGroupMenuTests {
    @Test func 今のグループを除き順序は保つ() {
        #expect(SessionGroupMenuLogic.moveTargets(folders: ["A", "B", "C"], current: "B") == ["A", "C"])
        #expect(SessionGroupMenuLogic.moveTargets(folders: ["A"], current: nil) == ["A"])
        #expect(SessionGroupMenuLogic.moveTargets(folders: [], current: nil).isEmpty)
    }

    @Test func 未分類へ戻すは所属があるときだけ() {
        #expect(SessionGroupMenuLogic.showsReturnToUnclassified(current: "A"))
        #expect(!SessionGroupMenuLogic.showsReturnToUnclassified(current: nil))
    }

    @Test func 表示名() {
        #expect(SessionGroupMenuLogic.label(for: nil) == "グループ: 未分類")
        #expect(SessionGroupMenuLogic.label(for: "案件A") == "グループ: 案件A")
    }

    @Test func 新しいグループ名の検証() {
        #expect(SessionGroupMenuLogic.validNewGroupName("") == nil)
        #expect(SessionGroupMenuLogic.validNewGroupName("  \n") == nil)
        #expect(SessionGroupMenuLogic.validNewGroupName(" X ") == "X")
    }

    @Test func 予約は登録_上書き_取り消しができる() {
        // 登録
        #expect(PendingMoveLogic.reservation(requested: "B", actual: "A") == PendingMove(folder: "B"))
        #expect(PendingMoveLogic.reservation(requested: nil, actual: "A") == PendingMove(folder: nil))
        // 上書き: 毎回新しい選択だけで決まる
        #expect(PendingMoveLogic.reservation(requested: "C", actual: "A") == PendingMove(folder: "C"))
        // 取り消し: 今のグループを選ぶ
        #expect(PendingMoveLogic.reservation(requested: "A", actual: "A") == nil)
        #expect(PendingMoveLogic.reservation(requested: nil, actual: nil) == nil)
    }

    @Test func 予約中の表示は行き先と案内を出す() {
        #expect(
            SessionGroupMenuLogic.label(for: "A", pending: PendingMove(folder: "B"))
                == "グループ: B (要約のあとに移します)")
        #expect(
            SessionGroupMenuLogic.label(for: "A", pending: PendingMove(folder: nil))
                == "グループ: 未分類 (要約のあとに移します)")
    }

    @Test func 選択の差し替えは旧IDを選んでいるときだけ() {
        #expect(PendingMoveLogic.remapSelection(["x", "y"], olds: ["x"], new: "z") == ["y", "z"])
        #expect(PendingMoveLogic.remapSelection(["y"], olds: ["x"], new: "z") == ["y"])
    }

    @Test func 続けて変わったIDは途中のIDも引き継ぐ() {
        // 改名(a→b)の直後に予約の移動(b→c)が走ると、画面は最後の変化しか受け取らない。
        let renamed = SessionIDChange.next(after: nil, old: "a", new: "b", serial: 1)
        let moved = SessionIDChange.next(after: renamed, old: "b", new: "c", serial: 2)
        #expect(moved.olds == ["a", "b"])
        #expect(PendingMoveLogic.remapSelection(["a"], olds: moved.olds, new: moved.new) == ["c"])
        // 無関係な変化からは引き継がない。
        let other = SessionIDChange.next(after: moved, old: "p", new: "q", serial: 3)
        #expect(other.olds == ["p"])
    }
}
