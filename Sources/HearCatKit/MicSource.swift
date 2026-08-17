@preconcurrency import AVFoundation
import AudioToolbox
import AudioUnit
import CoreAudio
import Foundation

/// 自分のマイク入力を AVAudioEngine で取得し、コピー済みバッファを stream に流す。
public final class MicSource {
    public let buffers: AsyncStream<SendableBuffer>
    private let continuation: AsyncStream<SendableBuffer>.Continuation
    private let engine = AVAudioEngine()
    /// 使う入力デバイスの UID。nil はシステム標準(既定の入力デバイス)。
    private let deviceUID: String?

    public init(deviceUID: String? = nil) {
        let (stream, continuation) = AsyncStream<SendableBuffer>.makeStream()
        self.buffers = stream
        self.continuation = continuation
        self.deviceUID = deviceUID
    }

    public func start() throws {
        let input = engine.inputNode
        if let deviceUID {
            applyInputDevice(uid: deviceUID, to: input)
        }
        let format = input.outputFormat(forBus: 0)
        if let deviceName = Self.currentInputDeviceName(audioUnit: input.audioUnit) {
            debugLog("mic capture format sr=\(format.sampleRate) ch=\(format.channelCount) device=\(deviceName)")
        } else {
            debugLog("mic capture format sr=\(format.sampleRate) ch=\(format.channelCount)")
        }
        let continuation = self.continuation
        // tap のコールバックは音声スレッド。ここでは深いコピーだけ取って即 yield し、
        // 変換や解析といった重い処理は消費側(別スレッド)に任せる。
        // callbackCount はクロージャに参照キャプチャされ、このタップ専用に音声スレッド上でだけ増える。
        var callbackCount = 0
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let copy = buffer.deepCopy() else { return }
            if hearcatDebug {
                callbackCount += 1
                if callbackCount % 100 == 0 {
                    let rms = Self.perChannelRMS(buffer)
                    let formatted = rms.enumerated().map { "ch\($0.offset)=\($0.element)" }.joined(separator: " ")
                    debugLog("mictap cb#\(callbackCount) rms=[\(formatted)]")
                }
            }
            continuation.yield(SendableBuffer(buffer: copy))
        }
        engine.prepare()
        try engine.start()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation.finish()
    }

    /// 保存された入力デバイスを適用する。デバイスが見つからない、または設定に失敗した場合は
    /// システム標準のまま続行する(保存済みデバイスが抜かれているのは正常系でエラーにしない)。
    private func applyInputDevice(uid: String, to input: AVAudioInputNode) {
        guard let deviceID = Self.resolveDeviceID(uid: uid) else {
            debugLog("mic device uid=\(uid) が見つからないためシステム標準を使用します")
            return
        }
        guard let audioUnit = input.audioUnit else {
            debugLog("mic device uid=\(uid) の適用に失敗(audioUnit未取得)。システム標準を使用します")
            return
        }
        var mutableDeviceID = deviceID
        let err = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        if err != noErr {
            debugLog("mic device uid=\(uid) の適用に失敗(err=\(err))。システム標準を使用します")
        }
    }

    // MARK: - 診断ログ

    /// 実際に使われている入力デバイス名。audioUnit にまだ現在のデバイスが反映されていない場合は
    /// 既定の入力デバイスにフォールバックする。取得できなければ nil(呼び出し側でログから省く)。
    private static func currentInputDeviceName(audioUnit: AudioUnit?) -> String? {
        if let audioUnit, let deviceID = currentDevice(of: audioUnit) {
            return stringProperty(deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
        }
        guard let deviceID = defaultInputDeviceID() else { return nil }
        return stringProperty(deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
    }

    private static func currentDevice(of audioUnit: AudioUnit) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioUnitGetProperty(
            audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, &size)
        guard err == noErr else { return nil }
        return deviceID
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard err == noErr else { return nil }
        return deviceID
    }

    /// チャンネルごとの RMS。片チャンネルにしか声が入っていない疑いの切り分けに使う。
    /// マイクの tap は Float32 でしか来ないため(Int16 は非対応)、該当しなければ空を返す。
    private static func perChannelRMS(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0, let data = buffer.floatChannelData else { return [] }
        var result = [Float](repeating: 0, count: channels)
        if buffer.format.isInterleaved {
            let p = data[0]
            for c in 0..<channels {
                var sum: Float = 0
                for i in 0..<frames {
                    let v = p[i * channels + c]
                    sum += v * v
                }
                result[c] = (sum / Float(frames)).squareRoot()
            }
        } else {
            for c in 0..<channels {
                let p = data[c]
                var sum: Float = 0
                for i in 0..<frames { sum += p[i] * p[i] }
                result[c] = (sum / Float(frames)).squareRoot()
            }
        }
        return result
    }

    // MARK: - デバイス列挙(Core Audio)

    /// 入力可能なデバイスの一覧。設定画面のデバイス選択に使う。
    /// 選択の保存は UID で行う(AudioDeviceID は抜き差しや再起動で変わるため)。
    public static func availableInputDevices() -> [(uid: String, name: String)] {
        allDeviceIDs().compactMap { deviceID in
            guard hasInputStreams(deviceID),
                let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                let name = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
            else { return nil }
            return (uid: uid, name: name)
        }
    }

    private static func resolveDeviceID(uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { stringProperty($0, selector: kAudioDevicePropertyDeviceUID) == uid }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard err == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs)
        guard err == noErr else { return [] }
        return deviceIDs
    }

    /// 入力(録音)側にストリームを持つデバイスだけを対象にする(出力専用デバイスを除外)。
    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufferListPointer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferListPointer) == noErr else {
            return false
        }
        return UnsafeMutableAudioBufferListPointer(bufferListPointer).contains { $0.mNumberChannels > 0 }
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let err = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard err == noErr else { return nil }
        return value as String
    }
}
