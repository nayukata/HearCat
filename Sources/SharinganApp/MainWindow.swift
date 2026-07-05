import SharinganKit
import SwiftUI

/// 履歴ウィンドウ。左にセッション一覧(進行中は先頭に固定)、右に詳細。
struct MainWindow: View {
    let model: AppModel
    @State private var selection: String?

    private static let liveID = "live"

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if model.status.active {
                    Section("進行中") {
                        Label("ライブ", systemImage: "dot.radiowaves.left.and.right")
                            .tag(Self.liveID)
                    }
                }
                Section("履歴") {
                    ForEach(pastSessions) { session in
                        SessionRow(session: session)
                            .tag(session.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if selection == Self.liveID, model.status.active {
                LiveSessionView(model: model)
            } else if let session = model.sessions.first(where: { $0.id == selection }) {
                SessionDetailView(model: model, session: session) {
                    selection = nil
                }
                // 選択が変わったらプレーヤー等の内部状態を作り直す。
                .id(session.id)
            } else {
                ContentUnavailableView(
                    "セッションを選択",
                    systemImage: "eye",
                    description: Text("左の一覧からセッションを選ぶと、文字起こしと録音をここで確認できます。"))
            }
        }
        .onAppear {
            model.refreshSessions()
            if selection == nil {
                selection = model.status.active ? Self.liveID : model.sessions.first?.id
            }
        }
    }

    /// 進行中のセッションは「ライブ」行で見せるため、履歴一覧からは除く。
    private var pastSessions: [SessionInfo] {
        model.sessions.filter { $0.id != model.status.sessionID }
    }
}

struct SessionRow: View {
    let session: SessionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.startDate.formatted(date: .abbreviated, time: .shortened))
            HStack(spacing: 6) {
                if session.transcriptURL != nil {
                    Image(systemName: "text.quote")
                }
                if session.micAudioURL != nil || session.systemAudioURL != nil {
                    Image(systemName: "waveform")
                }
                if session.summaryURL != nil {
                    Image(systemName: "list.bullet.rectangle")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
