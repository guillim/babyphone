@preconcurrency import AVFoundation
import BabyphoneCore

/// Baby-side audio that runs whether or not a parent unit is connected:
/// measures the sound level in the room, listens for crying, and plays the
/// lullaby and the white noise.
final class RoomAudio: @unchecked Sendable {
    enum Failure: Error {
        case microphoneUnavailable
    }

    /// Called about ten times a second with the room level in dBFS, on an audio thread.
    var onLevel: (@Sendable (Double) -> Void)?
    /// Called a few times a second with how confident the device is that it hears crying, from 0 to 1.
    var onCryConfidence: (@Sendable (Double) -> Void)? {
        get { cryClassifier.onConfidence }
        set { cryClassifier.onConfidence = newValue }
    }
    /// Whether this device can recognise crying right now.
    var isCryDetectionActive: Bool { cryClassifier.isActive }

    /// Silence from the microphone tap for this long means the engine has stalled.
    private static let stallDelay: TimeInterval = 3

    private let engine = AVAudioEngine()
    private let cryClassifier = CryClassifier()
    private let lullabyPlayer = AVAudioPlayerNode()
    private let lullabyBuffer: AVAudioPCMBuffer?
    private let whiteNoisePlayer = AVAudioPlayerNode()
    private let whiteNoiseBuffer: AVAudioPCMBuffer?
    /// Every use of the engine goes through this queue: system notifications and the
    /// watchdog arrive on their own threads, and the engine is not safe to share.
    private let queue = DispatchQueue(label: "nid.room-audio")
    private let lock = NSLock()
    private var lastMeasurement = Date()
    // Only touched on `queue`.
    private var isRunning = false
    private var isLullabyPlaying = false
    private var isWhiteNoisePlaying = false
    private var observers: [any NSObjectProtocol] = []
    private var watchdog: (any DispatchSourceTimer)?

    init() {
        lullabyBuffer = AVAudioPCMBuffer.mono(samples: ToneSynthesizer.lullaby(sampleRate: 44_100), sampleRate: 44_100)
        whiteNoiseBuffer = AVAudioPCMBuffer.mono(samples: ToneSynthesizer.whiteNoise(sampleRate: 44_100), sampleRate: 44_100)
        for (player, buffer) in [(lullabyPlayer, lullabyBuffer), (whiteNoisePlayer, whiteNoiseBuffer)] {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: buffer?.format)
        }
        lullabyPlayer.volume = 0.6
        whiteNoisePlayer.volume = 0.5
    }

    func start() throws {
        try queue.sync {
            try run()
            isRunning = true
            observers = [
                // The engine stops by itself when the audio route or format changes, for example
                // when WebRTC starts its own audio unit. It has to be rebuilt each time.
                NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
                ) { [weak self] _ in self?.restart() },
                NotificationCenter.default.addObserver(
                    forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
                ) { [weak self] notification in
                    let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                    if type == AVAudioSession.InterruptionType.ended.rawValue { self?.restart() }
                },
            ]
            // Another audio unit taking over the microphone can stop the tap without any
            // notification. A monitor that has gone deaf must not stay that way.
            let watchdog = DispatchSource.makeTimerSource(queue: queue)
            watchdog.schedule(deadline: .now() + Self.stallDelay, repeating: Self.stallDelay)
            watchdog.setEventHandler { [weak self] in
                guard let self, Date().timeIntervalSince(lock.withLock { lastMeasurement }) > Self.stallDelay else { return }
                rebuild()
            }
            watchdog.resume()
            self.watchdog = watchdog
        }
    }

    func stop() {
        queue.sync {
            isRunning = false
            isLullabyPlaying = false
            isWhiteNoisePlaying = false
            watchdog?.cancel()
            watchdog = nil
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            lullabyPlayer.stop()
            whiteNoisePlayer.stop()
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            cryClassifier.stop()
        }
    }

    func setLullabyPlaying(_ isPlaying: Bool) {
        queue.async { [self] in
            isLullabyPlaying = isPlaying
            if isPlaying {
                loop(lullabyBuffer, on: lullabyPlayer)
            } else {
                lullabyPlayer.stop()
            }
        }
    }

    func setWhiteNoisePlaying(_ isPlaying: Bool) {
        queue.async { [self] in
            isWhiteNoisePlaying = isPlaying
            if isPlaying {
                loop(whiteNoiseBuffer, on: whiteNoisePlayer)
            } else {
                whiteNoisePlayer.stop()
            }
        }
    }

    private func restart() {
        queue.async { [weak self] in self?.rebuild() }
    }

    private func rebuild() {
        guard isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        try? run()
    }

    private func run() throws {
        lock.withLock { lastMeasurement = Date() }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.microphoneUnavailable }
        input.removeTap(onBus: 0)
        cryClassifier.start(format: format)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            guard let self, let samples = buffer.floatChannelData?[0] else { return }
            let level = SoundLevel.decibels(of: UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
            lock.withLock { lastMeasurement = Date() }
            onLevel?(level)
            cryClassifier.analyze(buffer, at: time)
        }
        engine.prepare()
        try engine.start()
        if isLullabyPlaying {
            loop(lullabyBuffer, on: lullabyPlayer)
        }
        if isWhiteNoisePlaying {
            loop(whiteNoiseBuffer, on: whiteNoisePlayer)
        }
    }

    private func loop(_ buffer: AVAudioPCMBuffer?, on player: AVAudioPlayerNode) {
        guard let buffer, engine.isRunning else { return }
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
    }
}

extension AVAudioPCMBuffer {
    /// Wraps mono samples in a buffer an audio player can loop.
    static func mono(samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { return nil }
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}
