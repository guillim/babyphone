import BabyphoneCore
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

/// Baby-side media: the microphone and camera tracks sent to the parent unit.
final class BabyMedia: @unchecked Sendable {
    /// A baby monitor needs a recognisable picture, not a sharp one. A small,
    /// slow stream keeps the phone cool through the night.
    private enum VideoQuality {
        static let targetPixelCount = 640 * 480
        static let framesPerSecond = 15
        static let maxBitrate = 700_000
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

    var sessionFactory: PeerSessionFactory {
        { [self] in
            let session = try WebRTCSession(factory: engine.factory)
            session.addOutgoingMedia(audio: audioTrack, video: videoTrack, maxVideoBitrate: VideoQuality.maxBitrate, maxFramerate: VideoQuality.framesPerSecond)
            return session
        }
    }

    /// Whether video frames are sent. When false the parent unit receives audio only.
    func setVideoEnabled(_ isEnabled: Bool) {
        videoTrack.isEnabled = isEnabled
    }

    /// Starts the camera facing `position`. Returns false when that camera cannot be used.
    @discardableResult
    func startCamera(position: AVCaptureDevice.Position) -> Bool {
        guard
            AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position }),
            let format = Self.preferredFormat(for: device)
        else { return false }
        let fastestRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        capturer.startCapture(with: device, format: format, fps: min(VideoQuality.framesPerSecond, Int(fastestRate)))
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
    ///
    /// The microphone only runs while a track is attached, so nothing is
    /// recorded outside talk-back.
    func setTalking(_ isTalking: Bool) {
        let (session, track) = lock.withLock { () -> (WebRTCSession?, RTCAudioTrack?) in
            if isTalking, microphoneTrack == nil {
                let noConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
                microphoneTrack = engine.factory.audioTrack(with: engine.factory.audioSource(with: noConstraints), trackId: "parent-voice")
            }
            return (latestSession, isTalking ? microphoneTrack : nil)
        }
        session?.setOutgoingAudio(track)
    }
}
