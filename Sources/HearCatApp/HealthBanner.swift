import AppKit
import SwiftUI

/// 録音・文字起こしの異常を、パネル上部のバナーとして見せる。通知センターに出さない
/// 異常(権限拒否など)も含め、次にパネルを開いた時に必ず気づけるようにする唯一の場所。
///
/// 続いている異常(マイク未許可など)は読んだだけでは消せず、畳んで1行にするまでにとどめる。
/// 消せてしまうと、自分の声が1文字も残らない状態のまま見た目だけ正常に戻るため。
/// もう終わった出来事(録音ファイルの仕上げ失敗、セッション停止後のすべて)は ✕ で消せる。
struct HealthIssueBanner: View {
    let issue: HealthIssue
    /// いま続いている異常か(AppModel.isOngoing で判定する)。
    let isOngoing: Bool
    let isCollapsed: Bool
    let onToggleCollapsed: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        Group {
            if isOngoing && isCollapsed {
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
                // 続いている異常は消させない。畳んでも印は残る、という意味を
                // 「小さくする」の側で伝える。
                if !isOngoing { closeButton }
            }
            if hasActionRow {
                HStack(spacing: 8) {
                    Spacer()
                    if let pane = issue.settingsPane {
                        Button("システム設定を開く") {
                            openSystemSettings(pane: pane)
                        }
                        .buttonStyle(.hcSecondary)
                    }
                    if isOngoing {
                        Button("小さくする", action: onToggleCollapsed)
                            .buttonStyle(.hcSecondary)
                    }
                }
            }
        }
    }

    private var hasActionRow: Bool { issue.settingsPane != nil || isOngoing }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(HCFont.caption)
                // 記号そのものは小さいので、押せる範囲を周りまで広げる。
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .foregroundStyle(HCColor.mistWhiteDim)
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
        .focusEffectDisabled()
        .help("閉じる")
    }

    private var warningIcon: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
    }
}
