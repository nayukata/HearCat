@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os

/// Mac から出る音声(通話相手など)を Core Audio プロセスタップで取得する。
/// 画面録画許可は不要だが、バイナリが署名されていないと無音で失敗する点に注意。
///
/// タップは muteBehavior = .unmuted で作るため、取得に失敗していても相手の声は普通に
/// 聞こえ続ける。つまり「耳に届いている」ことは「録れている」ことの証拠にならない。
/// 集約デバイスは作った時点の既定の出力デバイスに固定されるので、セッション中に出力先を
/// 切り替えられたらタップを載せ替える(載せ替えないと、耳には届いたまま録音と文字起こしにだけ
/// 何も入らなくなり、しかもエラーも出ない)。
public final class SystemAudioSource: @unchecked Sendable {
    public let buffers: AsyncStream<SendableBuffer>
    private let continuation: AsyncStream<SendableBuffer>.Continuation
    private let queue = DispatchQueue(label: "hearcat.systemaudio", qos: .userInitiated)
    /// タップと集約デバイスの作り直しを直列化するキュー。出力先の変更は Core Audio 側の
    /// スレッドから届くため、start/stop と同時に走らないようここに寄せる。
    private let controlQueue = DispatchQueue(label: "hearcat.systemaudio.control")

    // 以下の4つは controlQueue の上でだけ読み書きする。
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    /// いまタップを載せている出力デバイスの UID。載せ替えの要否の判定に使う。
    private var capturingOutputUID: String?

    /// 出力先の変更を受け取るブロック。解除に同じブロックが要るため保持する。
    /// start/stop からだけ触る(どちらも呼び出し側で直列化されている)。
    private var deviceListener: AudioObjectPropertyListenerBlock?
    /// 開始後に取得が止まった時の通知先。呼ばれるのは controlQueue の上。
    private let failureHandler =
        OSAllocatedUnfairLock<(@Sendable (String) -> Void)?>(initialState: nil)

    public init() {
        let (stream, continuation) = AsyncStream<SendableBuffer>.makeStream()
        self.buffers = stream
        self.continuation = continuation
    }

    /// stop() を呼ばずに解放された場合の保険。出力先変更の監視ブロックが controlQueue 上で
    /// 同じ資源を付け替えている最中と重なり得るため、stop() と同じく controlQueue で直列化する。
    deinit {
        controlQueue.sync {
            removeDefaultOutputDeviceListener()
            stopCapture()
        }
    }

    /// 開始したあとに取得が止まった場合の通知先を差し込む。start() より前に呼ぶこと。
    /// 開始時の失敗は start() が throw するので、こちらは開始後の失敗だけを運ぶ。
    public func setOnFailure(_ handler: @escaping @Sendable (String) -> Void) {
        failureHandler.withLock { $0 = handler }
    }

    public func start() throws {
        try controlQueue.sync { try startCapture() }
        addDefaultOutputDeviceListener()
    }

    public func stop() {
        removeDefaultOutputDeviceListener()
        controlQueue.sync { stopCapture() }
        continuation.finish()
    }

    // MARK: - タップの生成と破棄

    /// タップと集約デバイスを作って取得を始める。buffers のストリームには触らない
    /// (載せ替えの間もストリームは生かしたままにするため)。
    /// 途中の段階で失敗したら、そこまでに作った分だけ stopCapture() で片付けてから投げ直す。
    private func startCapture() throws {
        do {
            try attemptStartCapture()
        } catch {
            stopCapture()
            throw error
        }
    }

    private func attemptStartCapture() throws {
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
            kAudioAggregateDeviceNameKey: "hearcat-tap",
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
        var callbackCount = 0
        let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, _, _ in
            guard let wrapped = AVAudioPCMBuffer(pcmFormat: format,
                                                 bufferListNoCopy: inInputData,
                                                 deallocator: nil),
                  let copy = wrapped.deepCopy() else { return }
            if hearcatDebug {
                callbackCount += 1
                if callbackCount <= 30 || callbackCount % 100 == 0 {
                    let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
                    let sizes = abl.map { "\($0.mDataByteSize)B ch=\($0.mNumberChannels)" }.joined(separator: ",")
                    debugLog("systemtap cb#\(callbackCount) abl=[\(sizes)] frames=\(copy.frameLength) rms=\(rmsLevel(copy))")
                }
            }
            continuation.yield(SendableBuffer(buffer: copy))
        }
        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue, ioBlock)
        guard err == noErr, let proc else { throw SystemAudioError.ioProcFailed(err) }
        procID = proc

        err = AudioDeviceStart(aggregate, proc)
        guard err == noErr else { throw SystemAudioError.startFailed(err) }
        capturingOutputUID = outputUID
    }

    /// タップと集約デバイスを畳む。buffers のストリームは終わらせない。
    private func stopCapture() {
        if aggregateID != 0, let proc = procID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = 0
        tapID = 0
        capturingOutputUID = nil
    }

    // MARK: - 出力先の変更への追従

    private static var defaultOutputDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private func addDefaultOutputDeviceListener() {
        var address = Self.defaultOutputDeviceAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.reattachToDefaultOutputDevice()
        }
        let err = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, block)
        guard err == noErr else {
            // 監視できなくても取得自体は動いているので、ここでは止めない。
            // 載せ替えが効かなくなるだけで、その場合は無音として気づける側に倒す。
            errorLog("既定の出力デバイスの監視を開始できません: \(err)")
            return
        }
        deviceListener = block
    }

    private func removeDefaultOutputDeviceListener() {
        guard let deviceListener else { return }
        var address = Self.defaultOutputDeviceAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, deviceListener)
        self.deviceListener = nil
    }

    /// 新しい出力デバイスへタップを載せ替える(controlQueue の上で走る)。
    /// 出力先の切り替えでは同じ通知が続けて届くことがあるため、実際に別のデバイスを
    /// 指した時だけ作り直す。
    private func reattachToDefaultOutputDevice() {
        guard let uid = try? Self.defaultOutputDeviceUID(), uid != capturingOutputUID else {
            return
        }
        debugLog("出力先が変わったためタップを載せ替える: \(capturingOutputUID ?? "なし") -> \(uid)")
        stopCapture()
        do {
            try startCapture()
        } catch {
            let reason = "出力先の変更後に取得できなくなりました: \(error)"
            errorLog(reason)
            failureHandler.withLock { $0 }?(reason)
        }
    }

    // MARK: - Core Audio プロパティ読み出し

    private static func defaultOutputDeviceUID() throws -> String {
        var address = defaultOutputDeviceAddress
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
