import AppKit
import SwiftUI

/// メニューバーから開くパネル。開始/停止・トグル・入力メーターをここに集約する。
/// (MenuBarExtra の .window スタイルで表示するリッチ版メニュー)
struct MenuPanel: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            divider
            Group {
                if model.status.active {
                    activeSection
                } else {
                    idleSection
                }
            }
            .padding(14)
            if let error = model.lastError {
                divider
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            divider
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .frame(width: 300)
        .background(HCColor.navyGradient)
        // パネルは LP と同じネイビー基調で固定する。
        .environment(\.colorScheme, .dark)
        .tint(HCColor.blue)
        .background(WindowAccessor { window in
            model.panelWindow = window
        })
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
    }

    // MARK: - ヘッダー

    private var header: some View {
        HStack(spacing: 9) {
            Group {
                if model.status.active {
                    CatHeadShape(includesEyes: true)
                        .fill(HCColor.blueSoft, style: FillStyle(eoFill: true))
                } else {
                    CatHeadShape()
                        .stroke(
                            HCColor.whiteDim,
                            style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                        .overlay(CatHeadShape.Eyes().fill(HCColor.whiteDim))
                }
            }
            .frame(width: 17, height: 17)
            Text("HearCat")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(.white)
            Spacer()
            if model.status.active, let startedAt = model.status.startedAt {
                // 経過時間。Text(_:style: .timer) が毎秒勝手に進んでくれる。
                Text(startedAt, style: .timer)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(HCColor.whiteDim)
            } else {
                Text("待機中")
                    .font(.subheadline)
                    .foregroundStyle(HCColor.whiteDim)
            }
        }
    }

    // MARK: - 待機中

    private var idleSection: some View {
        VStack(spacing: 8) {
            Button {
                Task { await model.startSession(record: true, transcribe: true) }
            } label: {
                Label("録音 ＋ 文字起こしを開始", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                Task { await model.startSession(record: false, transcribe: true) }
            } label: {
                Label("文字起こしのみ開始", systemImage: "text.quote")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
        .disabled(model.busy)
    }

    // MARK: - セッション中

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("録音", isOn: recordingBinding)
            Toggle("文字起こし", isOn: transcribingBinding)

            VStack(alignment: .leading, spacing: 6) {
                meterRow(label: "自分", level: model.micLevel)
                if model.status.systemAudioError == nil {
                    meterRow(label: "相手", level: model.systemLevel)
                }
            }
            .padding(.top, 2)

            if model.status.systemAudioError != nil {
                Label("相手の音声: 取得できていません", systemImage: "speaker.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(model.status.systemAudioError ?? "")
            }

            Button(role: .destructive) {
                Task { await model.stopSession() }
            } label: {
                Label("セッションを停止", systemImage: "stop.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(model.busy)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private func meterRow(label: String, level: Float) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(HCColor.whiteDim)
                .frame(width: 28, alignment: .leading)
            LevelMeter(level: level)
        }
    }

    // MARK: - フッター

    private var footer: some View {
        HStack {
            Button("履歴") { model.showHistory() }
            Button("設定") { model.showSettings() }
            Spacer()
            Button("終了") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(HCColor.whiteDim)
    }

    private var recordingBinding: Binding<Bool> {
        Binding(
            get: { model.status.recording },
            set: { model.setRecording($0) })
    }

    private var transcribingBinding: Binding<Bool> {
        Binding(
            get: { model.status.transcribing },
            set: { model.setTranscribing($0) })
    }
}

/// 入力レベル(RMS)を dB に直して出す横バー。
struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(HCColor.blueSoft)
                    .frame(width: max(0, geo.size.width * normalized))
            }
        }
        .frame(height: 5)
        .animation(.linear(duration: 0.1), value: level)
    }

    /// RMS を -60dB〜0dB のレンジで 0〜1 に写す(耳の感覚に近い対数スケール)。
    private var normalized: CGFloat {
        guard level > 0 else { return 0 }
        let db = 20 * log10(level)
        return CGFloat(min(1, max(0, (db + 60) / 60)))
    }
}
