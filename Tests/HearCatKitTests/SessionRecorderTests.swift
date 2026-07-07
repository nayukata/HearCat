import AVFoundation
import Foundation
import Testing

@testable import HearCatKit

/// SessionRecorder のマイク自動ゲインの検証。
/// 実測(自分の声 RMS -53〜-59dB、相手[システム音声] RMS -26dB、約30dBの差)を踏まえ、
/// マイク側だけに自動メイクアップゲインが掛かり、システム音声側には掛からないことを確認する。
struct SessionRecorderTests {
    private let sampleRate = SessionRecorder.sampleRate
    private let blockFrames = 4800

    private enum TestError: Error {
        case bufferAllocationFailed
        case noFloatData
    }

    private func sineSamples(count: Int, startIndex: Int, amplitude: Float, frequency: Double) -> [Float] {
        (0..<count).map { i in
            let t = Double(startIndex + i) / sampleRate
            return amplitude * Float(sin(2 * Double.pi * frequency * t))
        }
    }

    private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let ptr = buffer.floatChannelData![0]
        for i in 0..<samples.count { ptr[i] = samples[i] }
        return buffer
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumSquares / Float(samples.count)).squareRoot()
    }

    private func readOverallRMS(url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw TestError.bufferAllocationFailed
        }
        try file.read(into: buffer)
        let frames = Int(buffer.frameLength)
        guard let data = buffer.floatChannelData else { throw TestError.noFloatData }
        var sumSquares: Float = 0
        for i in 0..<frames { sumSquares += data[0][i] * data[0][i] }
        return (sumSquares / Float(frames)).squareRoot()
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
    }

    @Test func マイク入力に自動ゲインが掛かり相手より聞こえる音量まで底上げされる() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = SessionRecorder(url: url, includesSystemChannel: true)
        // 実測の自分の声(RMS -53〜-59dB ≈ 0.001〜0.002)相当の小さい振幅。
        let amplitude: Float = 0.002 * Float(2).squareRoot()
        var allInput: [Float] = []
        let blocks = 50 // 5秒ぶん(自動ゲインが目標へ追従し切るのに十分な長さ)
        for i in 0..<blocks {
            // system 側の最初の1回はマイクのプリロールを揃えるためのものなので先に呼ぶ。
            await recorder.appendSystem(makeBuffer([Float](repeating: 0, count: blockFrames)))
            let samples = sineSamples(count: blockFrames, startIndex: i * blockFrames, amplitude: amplitude, frequency: 220)
            allInput.append(contentsOf: samples)
            await recorder.appendMic(makeBuffer(samples))
        }
        await recorder.close()

        let inputRMS = rms(allInput)
        let outputRMS = try readOverallRMS(url: url)

        #expect(inputRMS > 0.0015 && inputRMS < 0.003, "テスト前提の入力RMSが想定範囲外: \(inputRMS)")
        #expect(outputRMS > inputRMS * 10, "自動ゲインで十分増幅されていない: input=\(inputRMS) output=\(outputRMS)")
    }

    @Test func 遅配が追いついても録音は実時間より長くならない() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = SessionRecorder(url: url, includesSystemChannel: true)
        let silence = [Float](repeating: 0, count: blockFrames)
        let tone = sineSamples(count: blockFrames, startIndex: 0, amplitude: 0.05, frequency: 220)

        // 2秒: 両音源が足並みを揃えて届く。
        for _ in 0..<20 {
            await recorder.appendSystem(makeBuffer(tone))
            await recorder.appendMic(makeBuffer(silence))
        }
        // 20秒: システム側だけ配達が止まる(認識器の重い処理でポンプが詰まる状況の再現)。
        // 閾値15秒を超えるので無音の穴埋めが発火する。
        for _ in 0..<200 {
            await recorder.appendMic(makeBuffer(silence))
        }
        // 止まっていた20秒ぶんがまとめて届く(実測で確認した追いつき)。
        // 穴埋め済みの時間帯と相殺されないと、同じ時間が二重に書かれる。
        for _ in 0..<200 {
            await recorder.appendSystem(makeBuffer(tone))
        }
        // 2秒: また足並みが揃う。
        for _ in 0..<20 {
            await recorder.appendSystem(makeBuffer(tone))
            await recorder.appendMic(makeBuffer(silence))
        }
        await recorder.close()

        let file = try AVAudioFile(forReading: url)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        // マイク基準の実時間は24秒。二重計上があると30秒以上になる。
        #expect(seconds > 22, "録音が短すぎる: \(seconds)秒")
        #expect(seconds < 26, "録音が実時間より長い(遅配の二重計上): \(seconds)秒")
    }

    @Test func システム音声には自動ゲインが掛からない() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = SessionRecorder(url: url, includesSystemChannel: true)
        // 実測の相手(システム音声、RMS -26dB ≈ 0.05)相当の振幅。
        let amplitude: Float = 0.05 * Float(2).squareRoot()
        var allInput: [Float] = []
        let blocks = 50
        for i in 0..<blocks {
            let samples = sineSamples(count: blockFrames, startIndex: i * blockFrames, amplitude: amplitude, frequency: 220)
            allInput.append(contentsOf: samples)
            await recorder.appendSystem(makeBuffer(samples))
            await recorder.appendMic(makeBuffer([Float](repeating: 0, count: blockFrames)))
        }
        await recorder.close()

        let inputRMS = rms(allInput)
        let outputRMS = try readOverallRMS(url: url)

        #expect(
            outputRMS > inputRMS * 0.5 && outputRMS < inputRMS * 2,
            "システム音声側にゲインが掛かっている: input=\(inputRMS) output=\(outputRMS)")
    }
}
