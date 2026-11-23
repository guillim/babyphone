@preconcurrency import AVFoundation
import BabyphoneCore
import os
@preconcurrency import WebRTC

/// Everything the parent unit plays and records, through one audio session.
///
/// - The baby's room plays like music does: at the phone's own volume, with no
///   voice processing to soften faint sounds, and with the microphone closed,
///   so iOS shows no recording indicator.
/// - The parent's voice is recorded only while the talk button is held. For
///   that moment the session allows recording, and the baby's room, the chime
///   and the alarm are muted, so the microphone sends none of them into the room.
/// - The alert chime and the lost-link alarm go through the same session, not
///   through notifications, so they are heard with the phone on silent or in a Focus mode.
/// - A silent loop keeps the app running in the background between two connections.
///
/// WebRTC plays and records through this object instead of its own audio unit,
/// which would hold the microphone open for as long as a connection lasts.
final class ParentAudio: NSObject, RTCAudioDevice, @unchecked Sendable {
    /// The format WebRTC exchanges with this device: 16-bit mono at 48 kHz.
    private static let sampleRate = 48_000.0
    private static let ioBufferDuration = 0.01

    private let engine = AVAudioEngine()
    private let silencePlayer = AVAudioPlayerNode()
    private let alarmPlayer = AVAudioPlayerNode()
    private let chimePlayer = AVAudioPlayerNode()
    private let playout: PlayoutBridge
    private let roomNode: AVAudioSourceNode
    private let silenceBuffer = AVAudioPCMBuffer.mono(samples: [Float](repeating: 0, count: 44_100), sampleRate: 44_100)
    private let alarmBuffer = AVAudioPCMBuffer.mono(samples: ToneSynthesizer.alarm(sampleRate: 44_100), sampleRate: 44_100)
    private let chimeBuffer = AVAudioPCMBuffer.mono(samples: ToneSynthesizer.chime(sampleRate: 44_100), sampleRate: 44_100)
    /// Every use of the engines and the session goes through this queue: system
    /// notifications and WebRTC arrive on their own threads, and the engines are not safe to share.
    private let queue = DispatchQueue(label: "nuzzlecam.parent-audio")
    // Only touched on `queue`.
    private var isRunning = false
    private var isAlarmSounding = false
    private var observers: [any NSObjectProtocol] = []
    private var capture: VoiceCapture?
    // Guarded by `lock`: read by WebRTC from its own threads.
    private let lock = NSLock()
    private var webRTC: (any RTCAudioDeviceDelegate)?
    private var playoutState = (isInitialized: false, isPlaying: false)
    private var recordingState = (isInitialized: false, isRecording: false)

    override init() {
        let playout = PlayoutBridge()
        self.playout = playout
        let roomFormat = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)
        roomNode = AVAudioSourceNode(format: roomFormat!) { isSilence, timestamp, frameCount, output in
            playout.render(isSilence: isSilence, timestamp: timestamp, frameCount: frameCount, output: output)
        }
        super.init()
        for (player, buffer) in [(silencePlayer, silenceBuffer), (alarmPlayer, alarmBuffer), (chimePlayer, chimeBuffer)] {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: buffer?.format)
        }
        engine.attach(roomNode)
        engine.connect(roomNode, to: engine.mainMixerNode, format: roomFormat)
    }

    func start() {
        queue.sync {
            isRunning = true
            observers = [
                NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
                ) { [weak self] _ in self?.restart() },
                NotificationCenter.default.addObserver(
                    forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
                ) { [weak self] notification in
                    // After a phone call or an alarm, iOS leaves the session inactive. Without this the app would be suspended.
                    let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                    if type == AVAudioSession.InterruptionType.ended.rawValue { self?.restart() }
                },
            ]
            configureSession(recording: false)
            run()
        }
    }

    func stop() {
        queue.sync {
            isRunning = false
            isAlarmSounding = false
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            stopCapture()
            silencePlayer.stop()
            alarmPlayer.stop()
            chimePlayer.stop()
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func setAlarmSounding(_ isSounding: Bool) {
        queue.async { [self] in
            isAlarmSounding = isSounding
            if isSounding {
                play(alarmBuffer, on: alarmPlayer)
            } else {
                alarmPlayer.stop()
            }
        }
    }

    /// Plays the alert chime once.
    func playChime() {
        queue.async { [self] in
            guard let chimeBuffer, engine.isRunning else { return }
            chimePlayer.stop()
            chimePlayer.scheduleBuffer(chimeBuffer, at: nil)
            chimePlayer.play()
        }
    }

    /// Opens the microphone for talk-back, or closes it. The microphone is never open otherwise.
    func setTalking(_ isTalking: Bool) {
        queue.async { [self] in
            guard isRunning, isTalking != (capture != nil) else { return }
            // There is no echo cancellation: what the speaker plays, the microphone would send.
            playout.setMuted(isTalking)
            alarmPlayer.volume = isTalking ? 0 : 1
            chimePlayer.volume = isTalking ? 0 : 1
            if isTalking {
                configureSession(recording: true)
                startCapture()
            } else {
                stopCapture()
                configureSession(recording: false)
            }
        }
    }

    // MARK: Session and engines

    /// Plain playback, except while the parent talks.
    private func configureSession(recording: Bool) {
        let session = AVAudioSession.sharedInstance()
        // Mixing keeps the monitor audible, and alive, while another app plays sound.
        if recording {
            try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
        } else {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        try? session.setActive(true)
    }

    private func restart() {
        queue.async { [weak self] in self?.run() }
    }

    private func run() {
        guard isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        engine.prepare()
        try? engine.start()
        // The audio thread may have changed: WebRTC must accept the next callback from a new one.
        notifyWebRTC { $0.notifyAudioOutputInterrupted() }
        // A playing node is what keeps the app alive between two connections.
        play(silenceBuffer, on: silencePlayer)
        if isAlarmSounding {
            play(alarmBuffer, on: alarmPlayer)
        }
        // A route change or an interruption stops the microphone's engine too.
        if let capture, !capture.isRunning {
            capture.stop()
            notifyWebRTC { $0.notifyAudioInputInterrupted() }
            if !capture.start() {
                Logger(subsystem: "nuzzlecam", category: "audio").error("The microphone could not restart")
            }
        }
    }

    private func play(_ buffer: AVAudioPCMBuffer?, on player: AVAudioPlayerNode) {
        guard let buffer, engine.isRunning else { return }
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
    }

    private func startCapture() {
        let capture = VoiceCapture(
            sampleRate: Self.sampleRate,
            onSamples: { [weak self] samples, timestamp in self?.deliver(samples, at: timestamp) },
            onConfigurationChange: { [weak self] in self?.restart() }
        )
        notifyWebRTC { $0.notifyAudioInputInterrupted() }
        // When the microphone cannot start, the press goes on and nothing is sent.
        if !capture.start() {
            Logger(subsystem: "nuzzlecam", category: "audio").error("The microphone could not start")
        }
        self.capture = capture
    }

    private func stopCapture() {
        capture?.close()
        capture = nil
    }

    // MARK: WebRTC

    private func deliver(_ samples: AVAudioPCMBuffer, at timestamp: AudioTimeStamp) {
        guard let webRTC = lock.withLock({ recordingState.isRecording ? webRTC : nil }) else { return }
        var flags = AudioUnitRenderActionFlags()
        var timestamp = timestamp
        _ = webRTC.deliverRecordedData(&flags, &timestamp, 1, samples.frameLength, samples.audioBufferList, nil, nil)
    }

    /// Runs `body` on WebRTC's audio thread, which its notifications require.
    private func notifyWebRTC(_ body: @escaping @Sendable (any RTCAudioDeviceDelegate) -> Void) {
        guard let webRTC = lock.withLock({ webRTC }) else { return }
        nonisolated(unsafe) let delegate = webRTC
        webRTC.dispatchAsync { body(delegate) }
    }

    var deviceInputSampleRate: Double { Self.sampleRate }
    var inputIOBufferDuration: TimeInterval { Self.ioBufferDuration }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { AVAudioSession.sharedInstance().inputLatency }
    var deviceOutputSampleRate: Double { Self.sampleRate }
    var outputIOBufferDuration: TimeInterval { Self.ioBufferDuration }
    var outputNumberOfChannels: Int { 1 }
    var outputLatency: TimeInterval { AVAudioSession.sharedInstance().outputLatency }

    var isInitialized: Bool { lock.withLock { webRTC != nil } }

    func initialize(with delegate: any RTCAudioDeviceDelegate) -> Bool {
        lock.withLock { webRTC = delegate }
        playout.setSource(delegate.getPlayoutData)
        return true
    }

    func terminateDevice() -> Bool {
        playout.setSource(nil)
        lock.withLock {
            webRTC = nil
            playoutState = (false, false)
            recordingState = (false, false)
        }
        return true
    }

    var isPlayoutInitialized: Bool { lock.withLock { playoutState.isInitialized } }
    var isPlaying: Bool { lock.withLock { playoutState.isPlaying } }

    func initializePlayout() -> Bool {
        lock.withLock { playoutState.isInitialized = true }
        return true
    }

    /// The engine already runs for the alerts: WebRTC's sound joins it.
    func startPlayout() -> Bool {
        lock.withLock { playoutState.isPlaying = true }
        return true
    }

    func stopPlayout() -> Bool {
        lock.withLock { playoutState = (false, false) }
        return true
    }

    var isRecordingInitialized: Bool { lock.withLock { recordingState.isInitialized } }
    var isRecording: Bool { lock.withLock { recordingState.isRecording } }

    func initializeRecording() -> Bool {
        lock.withLock { recordingState.isInitialized = true }
        return true
    }

    /// WebRTC wants to send: the microphone still opens only while the talk button is held.
    func startRecording() -> Bool {
        lock.withLock { recordingState.isRecording = true }
        return true
    }

    func stopRecording() -> Bool {
        lock.withLock { recordingState = (false, false) }
        return true
    }
}

/// Hands the sound received by WebRTC to the engine.
/// `render` runs on the real-time audio thread: it neither allocates nor waits.
private final class PlayoutBridge: @unchecked Sendable {
    private static let maxFrames = 8192
    private let samples = UnsafeMutablePointer<Int16>.allocate(capacity: maxFrames)
    private let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        return lock
    }()
    // Guarded by `lock`.
    private var source: RTCAudioDeviceGetPlayoutDataBlock?
    private var isMuted = false

    deinit {
        samples.deallocate()
        lock.deallocate()
    }

    func setSource(_ source: RTCAudioDeviceGetPlayoutDataBlock?) {
        os_unfair_lock_lock(lock)
        self.source = source
        os_unfair_lock_unlock(lock)
    }

    func setMuted(_ isMuted: Bool) {
        os_unfair_lock_lock(lock)
        self.isMuted = isMuted
        os_unfair_lock_unlock(lock)
    }

    func render(
        isSilence: UnsafeMutablePointer<ObjCBool>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: AVAudioFrameCount,
        output: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        os_unfair_lock_lock(lock)
        let source = source
        let isMuted = isMuted
        os_unfair_lock_unlock(lock)

        let buffers = UnsafeMutableAudioBufferListPointer(output)
        let frames = Int(frameCount)
        guard let source, frames <= Self.maxFrames else {
            return silence(buffers, isSilence: isSilence)
        }
        // WebRTC is always read, even when muted, so its buffers keep pace with time.
        var flags = AudioUnitRenderActionFlags()
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: frameCount * 2, mData: UnsafeMutableRawPointer(samples))
        )
        let status = source(&flags, timestamp, 0, frameCount, &list)
        guard status == noErr, !isMuted, !flags.contains(.unitRenderAction_OutputIsSilence) else {
            return silence(buffers, isSilence: isSilence)
        }
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for index in 0..<frames {
                data[index] = Float(samples[index]) / 32_768
            }
        }
        return noErr
    }

    private func silence(_ buffers: UnsafeMutableAudioBufferListPointer, isSilence: UnsafeMutablePointer<ObjCBool>) -> OSStatus {
        for buffer in buffers {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        isSilence.pointee = true
        return noErr
    }
}

/// The microphone, open for one press of the talk button. Its own engine, so the
/// playback engine never has an input and never opens the microphone.
private final class VoiceCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let outputFormat: AVAudioFormat?
    private let onSamples: @Sendable (AVAudioPCMBuffer, AudioTimeStamp) -> Void
    private var observer: (any NSObjectProtocol)?

    /// `onConfigurationChange` is called when the system stops this engine, for a new route or format.
    init(
        sampleRate: Double,
        onSamples: @escaping @Sendable (AVAudioPCMBuffer, AudioTimeStamp) -> Void,
        onConfigurationChange: @escaping @Sendable () -> Void
    ) {
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)
        self.onSamples = onSamples
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in onConfigurationChange() }
    }

    func start() -> Bool {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard
            inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
            let outputFormat, let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { return false }
        converter.downmix = true
        let onSamples = onSamples
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, time in
            let ratio = outputFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            nonisolated(unsafe) var isConsumed = false
            nonisolated(unsafe) let source = buffer
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if isConsumed {
                    status.pointee = .noDataNow
                    return nil
                }
                isConsumed = true
                status.pointee = .haveData
                return source
            }
            guard error == nil, converted.frameLength > 0 else { return }
            onSamples(converted, time.audioTimeStamp)
        }
        engine.prepare()
        do {
            try engine.start()
            return true
        } catch {
            input.removeTap(onBus: 0)
            return false
        }
    }

    var isRunning: Bool {
        engine.isRunning
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Stops for good.
    func close() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        stop()
    }
}
