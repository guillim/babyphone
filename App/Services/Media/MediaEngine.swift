@preconcurrency import AVFoundation
import BabyphoneCore
import BabyphoneTransport
import Foundation
@preconcurrency import WebRTC

/// The WebRTC factory shared by every peer connection of the app.
final class MediaEngine: @unchecked Sendable {
    let factory: RTCPeerConnectionFactory

    /// `audioDevice` replaces WebRTC's own audio unit. Without one, WebRTC
    /// plays and records through voice processing, as the baby unit needs.
    init(audioDevice: (any RTCAudioDevice)? = nil) {
        RTCInitializeSSL()
        factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory(),
            audioDevice: audioDevice
        )
    }
}

/// Baby-side media: the microphone and camera tracks, shared by every parent unit.
final class BabyMedia: @unchecked Sendable {
    /// Enough detail to zoom in on a cot, at a frame rate and bitrate an old
    /// phone can hold all night for two parents.
    private enum VideoQuality {
        static let targetPixelCount = 1280 * 720
        static let framesPerSecond = 15
        /// In low light the camera may expose each frame for much longer, which a slow frame rate allows.
        static let lowLightFramesPerSecond = 5
        static let maxBitrate = 1_200_000
    }

    private let engine: MediaEngine
    private let audioTrack: RTCAudioTrack
    private let videoSource: RTCVideoSource
    private let videoTrack: RTCVideoTrack
    private let capturer: RTCCameraVideoCapturer

    init(engine: MediaEngine) {
        self.engine = engine
        let noConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        audioTrack = engine.factory.audioTrack(with: engine.factory.audioSource(with: noConstraints), trackId: "room-audio")
        videoSource = engine.factory.videoSource()
        videoTrack = engine.factory.videoTrack(with: videoSource, trackId: "room-video")
        capturer = RTCCameraVideoCapturer(delegate: videoSource)
    }

    /// The media of one parent unit's connection.
    func makePeer() -> BabyPeerMedia {
        BabyPeerMedia { [self] in
            let session = try WebRTCSession(factory: engine.factory)
            session.addOutgoingMedia(
                audio: audioTrack, video: videoTrack,
                maxVideoBitrate: VideoQuality.maxBitrate, maxFramerate: VideoQuality.framesPerSecond
            )
            return session
        }
    }

    /// Starts the camera facing `position`. Returns false when that camera cannot be used.
    /// The camera starts asynchronously: `onRunning` is called, off the main thread, once it runs.
    @discardableResult
    func startCamera(position: AVCaptureDevice.Position, lowLight: Bool, onRunning: @escaping @Sendable () -> Void) -> Bool {
        guard
            AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position }),
            let format = Self.preferredFormat(for: device)
        else { return false }
        let wanted = lowLight ? VideoQuality.lowLightFramesPerSecond : VideoQuality.framesPerSecond
        let fastestRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        capturer.startCapture(with: device, format: format, fps: min(wanted, Int(fastestRate))) { _ in
            // Where the sensor supports it, the system brightens a dim picture by itself.
            if device.isLowLightBoostSupported, (try? device.lockForConfiguration()) != nil {
                device.automaticallyEnablesLowLightBoostWhenAvailable = lowLight
                device.unlockForConfiguration()
            }
            onRunning()
        }
        return true
    }

    func stopCamera() {
        capturer.stopCapture()
    }

    private static func preferredFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        func pixelCount(_ format: AVCaptureDevice.Format) -> Int {
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return Int(size.width) * Int(size.height)
        }
        return RTCCameraVideoCapturer.supportedFormats(for: device).min {
            abs(pixelCount($0) - VideoQuality.targetPixelCount) < abs(pixelCount($1) - VideoQuality.targetPixelCount)
        }
    }
}

/// The sessions of one peer's connection attempts that are still alive.
///
/// Attempts overlap, and the one that connects is not always the last one
/// created. Settings therefore go to every live session, and each new session
/// starts with the settings in force.
private final class LiveSessions: @unchecked Sendable {
    private struct Entry {
        weak var session: WebRTCSession?
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func add(_ session: WebRTCSession) {
        lock.withLock {
            entries = entries.filter { $0.session != nil } + [Entry(session: session)]
        }
    }

    var all: [WebRTCSession] {
        lock.withLock { entries.compactMap(\.session) }
    }

    var latest: WebRTCSession? {
        all.last
    }
}

/// What the baby unit sends to one parent unit, across that parent's successive connections.
final class BabyPeerMedia: @unchecked Sendable {
    private let makeSession: @Sendable () throws -> WebRTCSession
    private let sessions = LiveSessions()
    private let lock = NSLock()
    // Guarded by `lock`.
    private var isPlayingParentVoice = false
    private var isVideoActive = true

    fileprivate init(makeSession: @escaping @Sendable () throws -> WebRTCSession) {
        self.makeSession = makeSession
    }

    var sessionFactory: PeerSessionFactory {
        { [self] in
            let session = try makeSession()
            let (isPlaying, isVideoActive) = lock.withLock { (isPlayingParentVoice, self.isVideoActive) }
            session.setIncomingAudioEnabled(isPlaying)
            session.setOutgoingVideoActive(isVideoActive)
            sessions.add(session)
            return session
        }
    }

    /// Plays this parent's voice on the speaker, or keeps the baby unit silent.
    func setPlayingParentVoice(_ isPlaying: Bool) {
        lock.withLock { isPlayingParentVoice = isPlaying }
        sessions.all.forEach { $0.setIncomingAudioEnabled(isPlaying) }
    }

    /// Sends the picture to this parent, or only the sound.
    func setVideoActive(_ isActive: Bool) {
        lock.withLock { isVideoActive = isActive }
        sessions.all.forEach { $0.setOutgoingVideoActive(isActive) }
    }
}

/// Parent-side media: the incoming picture and the microphone used for talk-back.
final class ParentMedia: @unchecked Sendable {
    private let engine: MediaEngine
    private let sessions = LiveSessions()
    private let lock = NSLock()
    // Guarded by `lock`.
    private var microphoneTrack: RTCAudioTrack?
    private var isTalking = false

    init(engine: MediaEngine) {
        self.engine = engine
    }

    var sessionFactory: PeerSessionFactory {
        { [self] in
            let session = try WebRTCSession(factory: engine.factory)
            if let track = lock.withLock({ isTalking ? microphoneTrack : nil }) {
                session.setOutgoingAudio(track)
            }
            sessions.add(session)
            return session
        }
    }

    /// The session of the connection attempt in progress, or of the live connection.
    var session: WebRTCSession? {
        sessions.latest
    }

    /// Sends the parent's voice to the baby unit, or stops sending it.
    /// Nothing is sent to the baby unit unless a track is attached.
    func setTalking(_ isTalking: Bool) {
        // Created once, outside the lock: making a track waits for WebRTC's signaling thread.
        if isTalking, lock.withLock({ microphoneTrack }) == nil {
            let noConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            let track = engine.factory.audioTrack(with: engine.factory.audioSource(with: noConstraints), trackId: "parent-voice")
            lock.withLock { if microphoneTrack == nil { microphoneTrack = track } }
        }
        let track = lock.withLock { () -> RTCAudioTrack? in
            self.isTalking = isTalking
            return isTalking ? microphoneTrack : nil
        }
        sessions.all.forEach { $0.setOutgoingAudio(track) }
    }
}
