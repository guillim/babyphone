@preconcurrency import AVFoundation
import BabyphoneCore

/// Baby-side audio that runs whether or not a parent unit is connected:
/// measures the sound level in the room and plays the lullaby.
final class RoomAudio: @unchecked Sendable {
    enum Failure: Error {
        case microphoneUnavailable
    }

    /// Called about ten times a second with the room level in dBFS, on an audio thread.
    var onLevel: (@Sendable (Double) -> Void)?

    private let engine = AVAudioEngine()
    private let lullabyPlayer = AVAudioPlayerNode()
    private let lullabyBuffer: AVAudioPCMBuffer?
    private let lock = NSLock()
    private var isRunning = false
    private var isLullabyPlaying = false
    private var observers: [any NSObjectProtocol] = []

    init() {
        lullabyBuffer = AVAudioPCMBuffer.mono(samples: ToneSynthesizer.lullaby(sampleRate: 44_100), sampleRate: 44_100)
        engine.attach(lullabyPlayer)
        engine.connect(lullabyPlayer, to: engine.mainMixerNode, format: lullabyBuffer?.format)
        lullabyPlayer.volume = 0.6
    }

    func start() throws {
        lock.withLock { isRunning = true }
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
        try run()
    }

    func stop() {
        lock.withLock {
            isRunning = false
            isLullabyPlaying = false
        }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        lullabyPlayer.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    func setLullabyPlaying(_ isPlaying: Bool) {
        lock.withLock { isLullabyPlaying = isPlaying }
        if isPlaying {
            playLullaby()
        } else {
            lullabyPlayer.stop()
        }
    }

    private func run() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.microphoneUnavailable }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let samples = buffer.floatChannelData?[0] else { return }
            let level = SoundLevel.decibels(of: UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
            self?.onLevel?(level)
        }
        engine.prepare()
        try engine.start()
        if lock.withLock({ isLullabyPlaying }) {
            playLullaby()
        }
    }

    private func restart() {
        guard lock.withLock({ isRunning }) else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        try? run()
    }

    private func playLullaby() {
        guard let lullabyBuffer, engine.isRunning else { return }
        lullabyPlayer.stop()
        lullabyPlayer.scheduleBuffer(lullabyBuffer, at: nil, options: .loops)
        lullabyPlayer.play()
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
