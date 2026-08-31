import AppKit
import SwiftUI

/// 録音・文字起こしの異常を、パネル上部のバナーとして見せる。通知センターに出さない
/// 異常(権限拒否など)も含め、次にパネルを開いた時に必ず気づけるようにする唯一の場所。
///
/// 続いている異常(マイク未許可など)は読んだだけでは消せず、畳んで1行にするまでにとどめる。
/// 消せてしまうと、自分の声が1文字も残らない状態のまま見た目だけ正常に戻るため。
/// もう終わった出来事(録音ファイルの仕上げ失敗)だけ「了解」で消せる。
struct HealthIssueBanner: View {
    let issue: HealthIssue
    let isCollapsed: Bool
    let onToggleCollapsed: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        Group {
            if issue.isOngoing && isCollapsed {
                collapsedBody
            } else {
                expandedBody
            }
        }
        .padding(10)
        .background(
            HCRadius.shape(HCRadius.card)
                .fill(Color.orange.opacity(0.12)))
        .overlay(
            HCRadius.shape(HCRadius.card)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1))
    }

    /// 畳んだ状態。何が起きているかの一言だけ残し、行のどこを押しても開き直せる。
    private var collapsedBody: some View {
        HStack(spacing: 8) {
            warningIcon
            Text(issue.title)
                .font(HCFont.caption)
                .foregroundStyle(HCColor.mistWhite)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(HCFont.caption)
                .foregroundStyle(HCColor.mistWhiteDim)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleCollapsed)
        .pointingHandOnHover()
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                warningIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.title)
                        .font(HCFont.style(.callout, weight: .semibold))
                        .foregroundStyle(HCColor.mistWhite)
                    Text(issue.detail)
                        .font(HCFont.caption)
                        .foregroundStyle(HCColor.mistWhiteDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer()
                if let pane = issue.settingsPane {
                    Button("システム設定を開く") {
                        openSystemSettings(pane: pane)
                    }
                    .buttonStyle(.hcSecondary)
                }
                // 続いている異常は「了解」で消させない。畳んでも印は残る、という意味を
                // ボタンの言葉でも伝える。
                if issue.isOngoing {
                    Button("小さくする", action: onToggleCollapsed)
                        .buttonStyle(.hcSecondary)
                } else {
                    Button("了解", action: onDismiss)
                        .buttonStyle(.hcSecondary)
                }
            }
        }
    }

    private var warningIcon: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
    }
}
