@preconcurrency import AVFoundation
import BabyphoneCore
import BabyphoneTransport
import Foundation
@preconcurrency import WebRTC

/// The WebRTC factory shared by every peer connection of the app.
final class MediaEngine: @unchecked Sendable {
    let factory: RTCPeerConnectionFactory

    init() {
        RTCInitializeSSL()
        factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
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
            // The parent's voice is only played while they hold the talk button.
            session.setIncomingAudioEnabled(false)
            session.addOutgoingMedia(
                audio: audioTrack, video: videoTrack,
                maxVideoBitrate: VideoQuality.maxBitrate, maxFramerate: VideoQuality.framesPerSecond
            )
            return session
        }
    }

    /// Starts the camera facing `position`. Returns false when that camera cannot be used.
    @discardableResult
    func startCamera(position: AVCaptureDevice.Position, lowLight: Bool) -> Bool {
        guard
            AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position }),
            let format = Self.preferredFormat(for: device)
        else { return false }
        let wanted = lowLight ? VideoQuality.lowLightFramesPerSecond : VideoQuality.framesPerSecond
        let fastestRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        capturer.startCapture(with: device, format: format, fps: min(wanted, Int(fastestRate))) { _ in
            // Where the sensor supports it, the system brightens a dim picture by itself.
            guard device.isLowLightBoostSupported, (try? device.lockForConfiguration()) != nil else { return }
            device.automaticallyEnablesLowLightBoostWhenAvailable = lowLight
            device.unlockForConfiguration()
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

/// What the baby unit sends to one parent unit, across that parent's successive connections.
final class BabyPeerMedia: @unchecked Sendable {
    private let makeSession: @Sendable () throws -> WebRTCSession
    private let lock = NSLock()
    private var latestSession: WebRTCSession?

    fileprivate init(makeSession: @escaping @Sendable () throws -> WebRTCSession) {
        self.makeSession = makeSession
    }

    var sessionFactory: PeerSessionFactory {
        { [self] in
            let session = try makeSession()
            lock.withLock { latestSession = session }
            return session
        }
    }

    /// Plays this parent's voice on the speaker, or keeps the baby unit silent.
    func setPlayingParentVoice(_ isPlaying: Bool) {
        lock.withLock { latestSession }?.setIncomingAudioEnabled(isPlaying)
    }

    /// Sends the picture to this parent, or only the sound.
    func setVideoActive(_ isActive: Bool) {
        lock.withLock { latestSession }?.setOutgoingVideoActive(isActive)
    }
}

/// Parent-side media: the incoming picture and the microphone used for talk-back.
final class ParentMedia: @unchecked Sendable {
    private let engine: MediaEngine
    private let lock = NSLock()
    private var latestSession: WebRTCSession?
    private var microphoneTrack: RTCAudioTrack?

    init(engine: MediaEngine) {
        self.engine = engine
    }

    var sessionFactory: PeerSessionFactory {
        { [self] in
            let session = try WebRTCSession(factory: engine.factory)
            lock.withLock { latestSession = session }
            return session
        }
    }

    /// The session of the connection attempt in progress, or of the live connection.
    var session: WebRTCSession? {
        lock.withLock { latestSession }
    }

    /// Sends the parent's voice to the baby unit, or stops sending it.
    /// Nothing is sent to the baby unit unless a track is attached.
    func setTalking(_ isTalking: Bool) {
        let (session, track) = lock.withLock { () -> (WebRTCSession?, RTCAudioTrack?) in
            if isTalking, microphoneTrack == nil {
                let noConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
                microphoneTrack = engine.factory.audioTrack(with: engine.factory.audioSource(with: noConstraints), trackId: "parent-voice")
            }
            microphoneTrack?.isEnabled = isTalking
            return (latestSession, isTalking ? microphoneTrack : nil)
        }
        session?.setOutgoingAudio(track)
    }
}
