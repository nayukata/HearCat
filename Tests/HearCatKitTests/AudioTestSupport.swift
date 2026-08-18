import Foundation

/// 複数のテストファイルで共有する、決定的な音声信号の生成。
/// 乱数や現在時刻には依存しない。RMS の計測は HearCatKit 側の rmsLevel(Collection版)を
/// @testable import 経由でそのまま使い、テスト側で重複実装しない。

/// 複数周波数のサイン波を合成した信号。振幅は周波数の本数で正規化する。
func toneSignal(sampleCount: Int, frequencies: [Double], sampleRate: Double) -> [Float] {
    var signal = [Float](repeating: 0, count: sampleCount)
    for i in 0..<sampleCount {
        let t = Double(i) / sampleRate
        var value = 0.0
        for f in frequencies {
            value += sin(2 * Double.pi * f * t)
        }
        signal[i] = Float(value / Double(frequencies.count))
    }
    return signal
}

/// 参照を delaySamples 遅らせて scale 倍したものを近端の回り込みエコーとして重ねる。
func withEcho(of reference: [Float], delaySamples: Int, scale: Float) -> [Float] {
    var near = [Float](repeating: 0, count: reference.count)
    for i in delaySamples..<reference.count {
        near[i] = reference[i - delaySamples] * scale
    }
    return near
}
