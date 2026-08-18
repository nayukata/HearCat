import Foundation
import Testing

@testable import HearCatKit

/// 決定的な信号(複数周波数のサイン波合成)で EchoCanceller の性質を検証する。
/// 乱数や現在時刻には依存しない。
struct EchoCancellerTests {
    private let sampleRate = 48000.0

    /// 声のフォルマント構造を模した基本周波数+倍音の信号にビブラート(周波数変調)を掛けたもの。
    /// 静的な単一トーンだと preprocess の denoise(既定でオン)に定常ノイズとして誤検出され
    /// 大きく減衰してしまうため、自分の声を表すテストではこちらを使う。
    private func harmonicVoice(
        sampleCount: Int, fundamental: Double, harmonics: Int, depthRatio: Double, rate: Double, amp: Float
    ) -> [Float] {
        var signal = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            let t = Double(i) / sampleRate
            let vibrato = sin(2 * Double.pi * rate * t)
            var value = 0.0
            for h in 1...harmonics {
                let f = fundamental * Double(h) * (1 + depthRatio * vibrato)
                value += sin(2 * Double.pi * f * t) / Double(h)
            }
            signal[i] = Float(value) * amp
        }
        return signal
    }

    /// harmonicVoice の各倍音がビブラートで動く範囲をカバーする周波数一覧(帯域エネルギー測定用)。
    private func harmonicVoiceFrequencies(fundamental: Double, harmonics: Int, depthRatio: Double) -> [Double] {
        var frequencies: [Double] = []
        for h in 1...harmonics {
            let base = fundamental * Double(h)
            let spread = max(8.0, base * depthRatio)
            for offset in stride(from: -spread, through: spread, by: max(8.0, spread / 2)) {
                frequencies.append(base + offset)
            }
        }
        return frequencies
    }

    private func suppressionDb(output: ArraySlice<Float>, near: ArraySlice<Float>) -> Double? {
        let nearRms = rmsLevel(near)
        guard nearRms > 0 else { return nil }
        let outRms = rmsLevel(output)
        return 20 * log10(Double(outRms) / Double(nearRms))
    }

    /// windowSize(フレーム長相当)ごとに区切った Goertzel でエネルギーを足し上げる。
    /// ビブラートで周波数が動く信号でも、短い窓の中ではほぼ定常とみなせるため追従できる。
    private func slidingBandEnergy(_ signal: [Float], windowSize: Int, frequencies: [Double]) -> Double {
        var total = 0.0
        var offset = 0
        while offset + windowSize <= signal.count {
            total += goertzelPower(signal[offset..<(offset + windowSize)], frequencies: frequencies, windowSize: windowSize)
            offset += windowSize
        }
        return total
    }

    private func goertzelPower(_ signal: ArraySlice<Float>, frequencies: [Double], windowSize: Int) -> Double {
        var total = 0.0
        for f in frequencies {
            let omega = 2 * Double.pi * f / sampleRate
            let coeff = 2 * cos(omega)
            var s1 = 0.0
            var s2 = 0.0
            for x in signal {
                let s0 = Double(x) + coeff * s1 - s2
                s2 = s1
                s1 = s0
            }
            let real = s1 - s2 * cos(omega)
            let imag = s2 * sin(omega)
            total += (real * real + imag * imag) / Double(windowSize * windowSize)
        }
        return total
    }

    /// 配列を size ごとに分割する(最後だけ端数になりうる)。
    private func chunks(_ array: [Float], size: Int) -> [[Float]] {
        stride(from: 0, to: array.count, by: size).map {
            Array(array[$0..<min($0 + size, array.count)])
        }
    }

    @Test func 参照を遅延させ混入させたエコーを収束後に10dB以上抑える() {
        guard let canceller = EchoCanceller(sampleRate: sampleRate) else {
            Issue.record("EchoCanceller の初期化に失敗した")
            return
        }

        let totalSamples = Int(sampleRate * 6.0)
        let reference = toneSignal(sampleCount: totalSamples, frequencies: [220, 440, 880], sampleRate: sampleRate)
        let near = withEcho(of: reference, delaySamples: Int(sampleRate * 0.05), scale: 0.3)

        let chunkSize = 4096
        let refChunks = chunks(reference, size: chunkSize)
        let nearChunks = chunks(near, size: chunkSize)

        var output: [Float] = []
        output.reserveCapacity(totalSamples)
        for (refChunk, nearChunk) in zip(refChunks, nearChunks) {
            canceller.pushReference(refChunk)
            output.append(contentsOf: canceller.process(nearChunk))
        }

        #expect(output.count == near.count)
        #expect(canceller.reAnchorCount == 0, "参照が途切れていないのに再アンカーが発生した")

        // フィルタが収束したはずの終盤区間で、抑圧量を確認する。
        let tailStart = totalSamples - Int(sampleRate * 2.0)
        guard let ratioDb = suppressionDb(output: output[tailStart...], near: near[tailStart...]) else {
            Issue.record("近端のRMSが0だった")
            return
        }
        #expect(ratioDb <= -10, "抑圧量が不足: \(ratioDb) dB")
    }

    @Test func 参照が無音でもアンカー後は近端の声がほぼそのまま残る() {
        guard let canceller = EchoCanceller(sampleRate: sampleRate) else {
            Issue.record("EchoCanceller の初期化に失敗した")
            return
        }

        let totalSamples = Int(sampleRate * 3.0)
        let near = harmonicVoice(sampleCount: totalSamples, fundamental: 130, harmonics: 5, depthRatio: 0.03, rate: 4, amp: 0.4)

        var output: [Float] = []
        output.reserveCapacity(totalSamples)
        for chunk in chunks(near, size: 4096) {
            // 参照は常に無音だが、アンカーは張る(実処理経路を通す)。
            canceller.pushReference([Float](repeating: 0, count: chunk.count))
            output.append(contentsOf: canceller.process(chunk))
        }

        #expect(output.count == near.count)

        let tailStart = totalSamples - Int(sampleRate * 1.5)
        guard let ratioDb = suppressionDb(output: output[tailStart...], near: near[tailStart...]) else {
            Issue.record("近端のRMSが0だった")
            return
        }
        // denoise が既定でオンのため、エコーが無くても声らしい信号がいくらか減衰する
        // (実測は -5.2dB程度)。denoise 追加前の基準だった ±3dB は現実的でないため広げる。
        #expect(abs(ratioDb) <= 6, "参照無音時に近端が変化しすぎ: \(ratioDb) dB")
    }

    @Test func 端数を挟んでも出力長の合計は入力長の合計と一致する() {
        guard let canceller = EchoCanceller(sampleRate: sampleRate) else {
            Issue.record("EchoCanceller の初期化に失敗した")
            return
        }

        // フレーム長(960)にもチャンク長(4096)にも揃わない半端な総サンプル数にする。
        let totalSamples = Int(sampleRate * 3.0) + 777
        let near = toneSignal(sampleCount: totalSamples, frequencies: [300], sampleRate: sampleRate)

        var totalOutput = 0
        for chunk in chunks(near, size: 4096) {
            canceller.pushReference([Float](repeating: 0, count: chunk.count))
            totalOutput += canceller.process(chunk).count
        }

        #expect(totalOutput == totalSamples)
    }

    @Test func 参照より先に近端だけが流れても参照開始後に抑圧が効く() {
        guard let canceller = EchoCanceller(sampleRate: sampleRate) else {
            Issue.record("EchoCanceller の初期化に失敗した")
            return
        }

        let preAnchorSeconds = 2.0
        let postAnchorSeconds = 5.0
        let totalSamples = Int(sampleRate * (preAnchorSeconds + postAnchorSeconds))
        let reference = toneSignal(sampleCount: totalSamples, frequencies: [220, 440, 880], sampleRate: sampleRate)
        let near = withEcho(of: reference, delaySamples: Int(sampleRate * 0.05), scale: 0.3)

        let chunkSize = 4096
        let nearChunks = chunks(near, size: chunkSize)
        let refChunks = chunks(reference, size: chunkSize)
        // 参照はこのチャンクから初めて届く(=マイクだけ2秒先行して動き出した状況を模す)。
        let anchorChunkIndex = Int(sampleRate * preAnchorSeconds) / chunkSize

        var output: [Float] = []
        output.reserveCapacity(totalSamples)
        for (index, nearChunk) in nearChunks.enumerated() {
            if index >= anchorChunkIndex {
                canceller.pushReference(refChunks[index])
            }
            output.append(contentsOf: canceller.process(nearChunk))
        }

        #expect(output.count == near.count)

        // アンカー前(参照が一切届いていない間)は素通しのはず。
        let preAnchorEnd = anchorChunkIndex * chunkSize
        #expect(Array(output[0..<preAnchorEnd]) == Array(near[0..<preAnchorEnd]), "アンカー前は素通しであるべき")

        // アンカー後、収束したはずの終盤区間で抑圧を確認する。
        let tailStart = totalSamples - Int(sampleRate * 2.0)
        guard let ratioDb = suppressionDb(output: output[tailStart...], near: near[tailStart...]) else {
            Issue.record("近端のRMSが0だった")
            return
        }
        #expect(ratioDb <= -10, "アンカー後の抑圧量が不足: \(ratioDb) dB")
    }

    @Test func 参照供給に穴が空いても再アンカー後に抑圧が回復する() {
        guard let canceller = EchoCanceller(sampleRate: sampleRate) else {
            Issue.record("EchoCanceller の初期化に失敗した")
            return
        }

        let phase1Seconds = 4.0 // 初回アンカーして収束させる
        let gapSeconds = 1.0 // 参照が届かない穴(100ms超のゼロ埋めを起こして自己修復させる)
        let phase3Seconds = 5.0 // 再アンカー後の収束
        let totalSamples = Int(sampleRate * (phase1Seconds + gapSeconds + phase3Seconds))

        let reference = toneSignal(sampleCount: totalSamples, frequencies: [220, 440, 880], sampleRate: sampleRate)
        let near = withEcho(of: reference, delaySamples: Int(sampleRate * 0.05), scale: 0.3)

        let chunkSize = 4096
        let nearChunks = chunks(near, size: chunkSize)
        let refChunks = chunks(reference, size: chunkSize)

        let gapStartSample = Int(sampleRate * phase1Seconds)
        let gapEndSample = Int(sampleRate * (phase1Seconds + gapSeconds))

        var output: [Float] = []
        output.reserveCapacity(totalSamples)
        var offset = 0
        for (nearChunk, refChunk) in zip(nearChunks, refChunks) {
            let inGap = offset >= gapStartSample && offset < gapEndSample
            if !inGap {
                canceller.pushReference(refChunk)
            }
            output.append(contentsOf: canceller.process(nearChunk))
            offset += nearChunk.count
        }

        #expect(output.count == near.count)
        #expect(canceller.reAnchorCount >= 1, "参照の穴を検知して再アンカーしているはず")

        // 再アンカー後、十分収束したはずの終盤区間で抑圧を確認する。
        let tailStart = totalSamples - Int(sampleRate * 2.0)
        guard let ratioDb = suppressionDb(output: output[tailStart...], near: near[tailStart...]) else {
            Issue.record("近端のRMSが0だった")
            return
        }
        #expect(ratioDb <= -10, "再アンカー後の抑圧回復が不足: \(ratioDb) dB")
    }

    @Test func 二重発話でも自分の声の帯域が過度に削られない() {
        guard let canceller = EchoCanceller(sampleRate: sampleRate) else {
            Issue.record("EchoCanceller の初期化に失敗した")
            return
        }

        let totalSamples = Int(sampleRate * 6.0)
        let reference = toneSignal(sampleCount: totalSamples, frequencies: [220, 440, 880], sampleRate: sampleRate)
        let echo = withEcho(of: reference, delaySamples: Int(sampleRate * 0.05), scale: 0.3)
        // エコー帯域(220/440/880Hz)から離した、声のフォルマント構造を模す自分の声。
        let fundamental = 130.0
        let harmonics = 5
        let depthRatio = 0.03
        let ownVoice = harmonicVoice(
            sampleCount: totalSamples, fundamental: fundamental, harmonics: harmonics, depthRatio: depthRatio, rate: 4, amp: 0.6)

        var near = [Float](repeating: 0, count: totalSamples)
        for i in 0..<totalSamples {
            near[i] = echo[i] + ownVoice[i]
        }

        let chunkSize = 4096
        let refChunks = chunks(reference, size: chunkSize)
        let nearChunks = chunks(near, size: chunkSize)

        var output: [Float] = []
        output.reserveCapacity(totalSamples)
        for (refChunk, nearChunk) in zip(refChunks, nearChunks) {
            canceller.pushReference(refChunk)
            output.append(contentsOf: canceller.process(nearChunk))
        }

        #expect(output.count == near.count)

        let tailStart = totalSamples - Int(sampleRate * 2.0)
        let windowSize = 960 // フレーム長と揃える(ビブラートでも窓内はほぼ定常とみなせる)

        // 本題: 自分の声の帯域は、エコー除去/残渣抑制が効いていても過度に削られていないはず。
        let ownFrequencies = harmonicVoiceFrequencies(fundamental: fundamental, harmonics: harmonics, depthRatio: depthRatio)
        let ownEnergyBefore = slidingBandEnergy(Array(ownVoice[tailStart...]), windowSize: windowSize, frequencies: ownFrequencies)
        let ownEnergyAfter = slidingBandEnergy(Array(output[tailStart...]), windowSize: windowSize, frequencies: ownFrequencies)
        let ownRatioDb = 10 * log10(ownEnergyAfter / ownEnergyBefore)
        #expect(ownRatioDb >= -6, "二重発話で自分の声が削られすぎ: \(ownRatioDb) dB")

        // 参考: エコー帯域は(単独エコーほど強くはなくても)いくらかは抑圧されているはず。
        let echoFrequencies = [220.0, 440.0, 880.0]
        let echoEnergyBefore = slidingBandEnergy(Array(echo[tailStart...]), windowSize: windowSize, frequencies: echoFrequencies)
        let echoEnergyAfter = slidingBandEnergy(Array(output[tailStart...]), windowSize: windowSize, frequencies: echoFrequencies)
        let echoRatioDb = 10 * log10(echoEnergyAfter / echoEnergyBefore)
        #expect(echoRatioDb <= -3, "二重発話中でもエコーがほぼ無抑圧: \(echoRatioDb) dB")
    }
}
