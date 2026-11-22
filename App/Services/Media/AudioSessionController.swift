@preconcurrency import AVFoundation
@preconcurrency import WebRTC

/// Configures the shared audio session, the same way on both phones.
///
/// Both sides use the play-and-record category with voice processing, which is
/// the configuration WebRTC is built and tested for. On the parent phone this
/// keeps the microphone unit open while connected, so iOS shows its recording
/// indicator, but the parent's voice is only sent while the talk button is held.
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
