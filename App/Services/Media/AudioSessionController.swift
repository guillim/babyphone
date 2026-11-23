@preconcurrency import AVFoundation
@preconcurrency import WebRTC

/// Configures the baby unit's audio session.
///
/// The baby unit uses the play-and-record category with voice processing, which
/// is the configuration WebRTC is built and tested for: its microphone is always
/// on, and echo cancellation keeps the parent's voice out of what it sends.
/// The parent unit manages its own session, in `ParentAudio`.
///
/// The app keeps the session active for as long as monitoring runs. WebRTC
/// would otherwise release it between two connections, and iOS suspends a
/// background app the moment its audio session goes quiet.
enum AudioSessionController {
    /// Configures the session and takes one activation of it.
    static func activate() throws {
        let configuration = RTCAudioSessionConfiguration.webRTC()
        configuration.category = AVAudioSession.Category.playAndRecord.rawValue
        configuration.mode = AVAudioSession.Mode.videoChat.rawValue
        // Speaker rather than earpiece. A2DP keeps the sound in the parent's earphones.
        // Mixing keeps the monitor audible, and alive, while another app plays sound.
        configuration.categoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
        // WebRTC applies its stored configuration whenever it starts audio, so both must agree.
        RTCAudioSessionConfiguration.setWebRTC(configuration)

        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        try session.setConfiguration(configuration, active: true)
    }

    /// Releases the activation taken by `activate`.
    static func deactivate() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        try? session.setActive(false)
    }
}
