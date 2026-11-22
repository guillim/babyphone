@preconcurrency import AVFoundation
import BabyphoneCore

/// Parent-side audio that does not depend on the connection: keeps the app
/// running in the background, chimes on alerts and sounds the alarm when the link is lost.
///
/// These sounds go through the app's own audio session, not through
/// notifications, so they are heard with the phone on silent or in a Focus mode.
final class ParentAudio: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let silencePlayer = AVAudioPlayerNode()
    private let alarmPlayer = AVAudioPlayerNode()
    private let chimePlayer = AVAudioPlayerNode()
    private let silenceBuffer = AVAudioPCMBuffer.mono(samples: [Float](repeating: 0, count: 44_100), sampleRate: 44_100)
    private let alarmBuffer = AVAudioPCMBuffer.mono(samples: ToneSynthesizer.alarm(sampleRate: 44_100), sampleRate: 44_100)
    private let chimeBuffer = AVAudioPCMBuffer.mono(samples: ToneSynthesizer.chime(sampleRate: 44_100), sampleRate: 44_100)
    /// Every use of the engine goes through this queue: system notifications arrive
    /// on their own threads, and the engine is not safe to share.
    private let queue = DispatchQueue(label: "nuzzlecam.parent-audio")
    // Only touched on `queue`.
    private var isRunning = false
    private var isAlarmSounding = false
    private var observers: [any NSObjectProtocol] = []

    init() {
        for (player, buffer) in [(silencePlayer, silenceBuffer), (alarmPlayer, alarmBuffer), (chimePlayer, chimeBuffer)] {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: buffer?.format)
        }
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
            run()
        }
    }

    func stop() {
        queue.sync {
            isRunning = false
            isAlarmSounding = false
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            silencePlayer.stop()
            alarmPlayer.stop()
            chimePlayer.stop()
            engine.stop()
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

    /// Sets how loud the alarm and the chime play, on top of the device's own volume.
    func setVolume(_ volume: AlarmVolume) {
        queue.async { [self] in
            alarmPlayer.volume = volume.gain
            chimePlayer.volume = volume.gain
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

    private func restart() {
        queue.async { [weak self] in self?.run() }
    }

    private func run() {
        guard isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        engine.prepare()
        try? engine.start()
        // A playing node is what keeps the app alive between two connections.
        play(silenceBuffer, on: silencePlayer)
        if isAlarmSounding {
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
