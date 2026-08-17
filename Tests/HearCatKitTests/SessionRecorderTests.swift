import AVFoundation
import Foundation
import Testing

@testable import HearCatKit

/// SessionRecorder のミックス音量の検証。
/// マイク・システム音声のどちらも自動では増幅されず、設定ゲイン(既定値 1)倍の
/// 素の振幅のまま録音されることを確認する。
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

    @Test func マイク入力は増幅せずそのままの音量で録る() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = SessionRecorder(url: url, includesSystemChannel: true)
        // 実測の自分の声(RMS -53〜-59dB ≈ 0.001〜0.002)相当の小さい振幅。
        let amplitude: Float = 0.002 * Float(2).squareRoot()
        var allInput: [Float] = []
        let blocks = 50 // 5秒ぶん
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
        #expect(
            outputRMS > inputRMS * 0.5 && outputRMS < inputRMS * 1.5,
            "マイク入力が無加工のまま録れていない(AACエンコード誤差の範囲を超える差): input=\(inputRMS) output=\(outputRMS)")
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

    /// 相手だけの録音は、混ぜたものと同じ時間軸で書かれている必要がある。
    /// ずれると、文字起こしからのジャンプと再生バーが音を選んだ瞬間に食い違う。
    @Test func 相手だけの録音は混ぜたものと同じ尺で書かれる() async throws {
        let url = tempURL()
        let otherURL = tempURL()
        defer { for u in [url, otherURL] { try? FileManager.default.removeItem(at: u) } }

        let recorder = SessionRecorder(url: url, otherURL: otherURL, includesSystemChannel: true)
        let tone = sineSamples(count: blockFrames, startIndex: 0, amplitude: 0.05, frequency: 220)
        let silence = [Float](repeating: 0, count: blockFrames)
        for _ in 0..<20 {
            await recorder.appendSystem(makeBuffer(tone))
            await recorder.appendMic(makeBuffer(silence))
        }
        await recorder.close()

        let mixed = try AVAudioFile(forReading: url).length
        #expect(try AVAudioFile(forReading: otherURL).length == mixed)
    }

    /// 「相手だけ」で聞く目的は、会議アプリでマイクを切っていた場面で自分の声が
    /// 混ざっているのを避けること。相手側のファイルに自分の音が残っていては意味がない。
    @Test func 相手だけの録音に自分の声は入らない() async throws {
        let url = tempURL()
        let otherURL = tempURL()
        defer { for u in [url, otherURL] { try? FileManager.default.removeItem(at: u) } }

        let recorder = SessionRecorder(url: url, otherURL: otherURL, includesSystemChannel: true)
        let tone = sineSamples(count: blockFrames, startIndex: 0, amplitude: 0.05, frequency: 220)
        let silence = [Float](repeating: 0, count: blockFrames)
        for _ in 0..<20 {
            await recorder.appendSystem(makeBuffer(silence))
            await recorder.appendMic(makeBuffer(tone))
        }
        await recorder.close()

        #expect(try readOverallRMS(url: otherURL) < 0.001)
        // 混ぜたものには自分の声が入っている。
        #expect(try readOverallRMS(url: url) > 0.01)
    }

    /// 相手の音を録らないセッション(マイクだけ)では、分けても中身が同じになるだけ。
    /// 無駄なファイルを増やさないことの確認。
    @Test func 相手の音を録らないセッションでは相手だけの録音を作らない() async throws {
        let url = tempURL()
        let otherURL = tempURL()
        defer { for u in [url, otherURL] { try? FileManager.default.removeItem(at: u) } }

        let recorder = SessionRecorder(url: url, otherURL: otherURL, includesSystemChannel: false)
        let tone = sineSamples(count: blockFrames, startIndex: 0, amplitude: 0.05, frequency: 220)
        for _ in 0..<20 {
            await recorder.appendMic(makeBuffer(tone))
        }
        await recorder.close()

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: url.path))
        #expect(!fm.fileExists(atPath: otherURL.path))
    }

    /// stop() の正常経路では、最終形式(.m4a)が残り、録音中に書いていた生ファイル(.aac)は
    /// 消えている必要がある(両方残ると容量が倍になり、後者だけ残ると再生できない)。
    @Test func 停止後は最終形式が残り生ファイルは消えている() async throws {
        let url = tempURL()
        let stagingURL = SessionRecorder.stagingURL(for: url)
        defer { for u in [url, stagingURL] { try? FileManager.default.removeItem(at: u) } }

        let recorder = SessionRecorder(url: url, includesSystemChannel: false)
        let tone = sineSamples(count: blockFrames, startIndex: 0, amplitude: 0.05, frequency: 220)
        for _ in 0..<20 { await recorder.appendMic(makeBuffer(tone)) }
        let converted = await recorder.close()

        #expect(converted)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
        // 変換はパススルー(再エンコードなし)なので、音の中身は保たれているはず。
        #expect(try readOverallRMS(url: url) > 0.01)
    }

    /// close() を呼ばない(強制終了相当)状態でも、録音中に書いていた生ファイルは
    /// 読める必要がある。これが .caf ではなく .aac(ADTS の AAC 生ストリーム)を選んだ理由そのもの
    /// (SessionRecorder の型 doc comment を参照)。
    @Test func stopを呼ばなくても書きかけの生ファイルは読める() async throws {
        let url = tempURL()
        let stagingURL = SessionRecorder.stagingURL(for: url)
        defer { for u in [url, stagingURL] { try? FileManager.default.removeItem(at: u) } }

        let recorder = SessionRecorder(url: url, includesSystemChannel: false)
        let tone = sineSamples(count: blockFrames, startIndex: 0, amplitude: 0.05, frequency: 220)
        // close() を呼ばずに、writeBlock が実際にディスクへ書く量(blockFrames の倍数)だけ送る。
        for _ in 0..<10 { await recorder.appendMic(makeBuffer(tone)) }

        #expect(FileManager.default.fileExists(atPath: stagingURL.path))
        let staged = try AVAudioFile(forReading: stagingURL)
        #expect(staged.length > 0)
        // close() を呼んでいないので、最終形式(.m4a)への変換はまだ走っていない。
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func システム音声は増幅せずそのままの音量で録る() async throws {
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
