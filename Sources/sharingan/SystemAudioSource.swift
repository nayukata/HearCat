@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Mac から出る音声(通話相手など)を Core Audio プロセスタップで取得する。
/// 画面録画許可は不要だが、バイナリが署名されていないと無音で失敗する点に注意。
final class SystemAudioSource {
    let buffers: AsyncStream<SendableBuffer>
    private let continuation: AsyncStream<SendableBuffer>.Continuation
    private let queue = DispatchQueue(label: "sharingan.systemaudio", qos: .userInitiated)

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?

    init() {
        let (stream, continuation) = AsyncStream<SendableBuffer>.makeStream()
        self.buffers = stream
        self.continuation = continuation
    }

    func start() throws {
        // 1. システム全体を対象にしたタップを作る。muteBehavior=.unmuted なので相手の声は普通に聞こえる。
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted

        var tap: AudioObjectID = 0
        var err = AudioHardwareCreateProcessTap(tapDescription, &tap)
        guard err == noErr else { throw SystemAudioError.tapCreateFailed(err) }
        tapID = tap

        // 2. 既定の出力デバイスを親にした private な集約デバイスを作り、その中にタップを載せる。
        let outputUID = try Self.defaultOutputDeviceUID()
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "sharingan-tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
            ]],
        ]
        var aggregate: AudioObjectID = 0
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard err == noErr else { throw SystemAudioError.aggregateCreateFailed(err) }
        aggregateID = aggregate

        // 3. タップのストリームフォーマットから AVAudioFormat を作る。
        var asbd = try Self.tapStreamFormat(tapID: tap)
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw SystemAudioError.formatFailed
        }
        debugLog("system capture format sr=\(format.sampleRate) ch=\(format.channelCount)")

        // 4. IO コールバックで届く AudioBufferList を AVAudioPCMBuffer にして流す。
        //    no-copy ラップは callback 内でしか有効でないため、必ず deepCopy してから yield する。
        let continuation = self.continuation
        let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, _, _ in
            guard let wrapped = AVAudioPCMBuffer(pcmFormat: format,
                                                 bufferListNoCopy: inInputData,
                                                 deallocator: nil),
                  let copy = wrapped.deepCopy() else { return }
            continuation.yield(SendableBuffer(buffer: copy))
        }
        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue, ioBlock)
        guard err == noErr, let proc else { throw SystemAudioError.ioProcFailed(err) }
        procID = proc

        err = AudioDeviceStart(aggregate, proc)
        guard err == noErr else { throw SystemAudioError.startFailed(err) }
    }

    func stop() {
        if aggregateID != 0, let proc = procID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
        continuation.finish()
    }

    // MARK: - Core Audio プロパティ読み出し

    private static func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard err == noErr else { throw SystemAudioError.propertyFailed(err) }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        err = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, pointer)
        }
        guard err == noErr else { throw SystemAudioError.propertyFailed(err) }
        return uid as String
    }

    private static func tapStreamFormat(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let err = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard err == noErr else { throw SystemAudioError.propertyFailed(err) }
        return asbd
    }
}
