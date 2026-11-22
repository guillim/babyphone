@preconcurrency import AVFoundation
import BabyphoneCore
@preconcurrency import WebRTC

/// Configures the shared audio session for each role.
///
/// The app keeps the session active for as long as monitoring runs. WebRTC
/// would otherwise release it between two connections, and iOS suspends a
/// background app the moment its audio session goes quiet.
enum AudioSessionController {
    enum Mode {
        /// Baby unit: microphone always on, speaker for talk-back and the lullaby.
        case room
        /// Parent unit: playback only. The microphone stays off, so iOS shows no recording indicator.
        case listening
        /// Parent unit while the talk button is held.
        case talking
    }

    /// Applies `mode` and takes one activation of the audio session.
    static func activate(_ mode: Mode) throws {
        try apply(mode, activating: true)
    }

    /// Switches between listening and talking without touching the activation.
    static func switchTo(_ mode: Mode) {
        try? apply(mode, activating: false)
    }

    /// Releases the activation taken by `activate`.
    static func deactivate() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        try? session.setActive(false)
    }

    private static func apply(_ mode: Mode, activating: Bool) throws {
        let configuration = RTCAudioSessionConfiguration.webRTC()
        switch mode {
        case .room:
            configuration.category = AVAudioSession.Category.playAndRecord.rawValue
            configuration.mode = AVAudioSession.Mode.videoChat.rawValue
            configuration.categoryOptions = [.defaultToSpeaker, .mixWithOthers]
        case .listening:
            configuration.category = AVAudioSession.Category.playback.rawValue
            configuration.mode = AVAudioSession.Mode.default.rawValue
            // Mixing keeps the monitor audible, and alive, while another app plays sound.
            configuration.categoryOptions = [.mixWithOthers]
        case .talking:
            configuration.category = AVAudioSession.Category.playAndRecord.rawValue
            configuration.mode = AVAudioSession.Mode.voiceChat.rawValue
            configuration.categoryOptions = [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
        }
        // WebRTC applies its stored configuration whenever it starts audio, so both must agree.
        RTCAudioSessionConfiguration.setWebRTC(configuration)

        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        if activating {
            try session.setConfiguration(configuration, active: true)
        } else {
            try session.setConfiguration(configuration)
        }
    }
}
