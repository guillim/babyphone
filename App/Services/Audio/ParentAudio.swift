@preconcurrency import AVFoundation
import BabyphoneCore

/// Parent-side audio that does not depend on the connection: keeps the app
/// running in the background and sounds the alarm when the link is lost.
final class ParentAudio: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let silencePlayer = AVAudioPlayerNode()
    private let alarmPlayer = AVAudioPlayerNode()
    private let silenceBuffer = AVAudioPCMBuffer.mono(samples: [Float](repeating: 0, count: 44_100), sampleRate: 44_100)
    private let alarmBuffer = AVAudioPCMBuffer.mono(samples: ToneSynthesizer.alarm(sampleRate: 44_100), sampleRate: 44_100)
    private let lock = NSLock()
    private var isRunning = false
    private var isAlarmSounding = false
    private var observers: [any NSObjectProtocol] = []

    init() {
        for (player, buffer) in [(silencePlayer, silenceBuffer), (alarmPlayer, alarmBuffer)] {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: buffer?.format)
        }
    }

    func start() {
        lock.withLock { isRunning = true }
        observers = [
            NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in self?.run() },
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
            ) { [weak self] notification in
                // After a phone call or an alarm, iOS leaves the session inactive. Without this the app would be suspended.
                let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                if type == AVAudioSession.InterruptionType.ended.rawValue { self?.run() }
            },
        ]
        run()
    }

    func stop() {
        lock.withLock {
            isRunning = false
            isAlarmSounding = false
        }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        silencePlayer.stop()
        alarmPlayer.stop()
        engine.stop()
    }

    func setAlarmSounding(_ isSounding: Bool) {
        lock.withLock { isAlarmSounding = isSounding }
        if isSounding {
            play(alarmBuffer, on: alarmPlayer)
        } else {
            alarmPlayer.stop()
        }
    }

    private func run() {
        guard lock.withLock({ isRunning }) else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        engine.prepare()
        try? engine.start()
        // A playing node is what keeps the app alive between two connections.
        play(silenceBuffer, on: silencePlayer)
        if lock.withLock({ isAlarmSounding }) {
            play(alarmBuffer, on: alarmPlayer)
        }
    }

    private func play(_ buffer: AVAudioPCMBuffer?, on player: AVAudioPlayerNode) {
        guard let buffer, engine.isRunning else { return }
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
    }
}
