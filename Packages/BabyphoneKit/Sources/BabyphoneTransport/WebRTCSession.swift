import BabyphoneCore
import Foundation
@preconcurrency import WebRTC

/// One direct WebRTC connection between the two phones.
///
/// The connection uses host candidates only: the ICE server list is empty, so
/// there is no STUN lookup and no TURN relay. Each side's description already
/// carries all its addresses, which is why one message each way is enough.
///
/// Threading. Most of the WebRTC API is synchronous and waits for WebRTC's own
/// signaling or network thread, and WebRTC calls back on those same threads.
/// Three rules keep any thread from waiting on another for ever:
///
/// - Every call into WebRTC is made on `queue`, a serial queue of this session.
///   Callers never block: they hand over the work and, when they need a result,
///   wait for it without holding a thread.
/// - A callback from WebRTC never calls into WebRTC. It records what it was
///   told and returns. Anything more is done later on `queue`.
/// - Nothing calls into WebRTC while holding `lock`.
public final class WebRTCSession: NSObject, PeerSession, @unchecked Sendable {
    public enum Failure: Error {
        case cannotCreateConnection
        case cannotCreateDataChannel
        case negotiationFailed
        case closed
    }

    /// Addresses of the two ends of the connection in use.
    public struct Path: Sendable, Equatable {
        public let local: String
        public let remote: String
    }

    public let events: AsyncStream<PeerSessionEvent>

    private static var noConstraints: RTCMediaConstraints {
        RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    }
    /// Gathering host candidates takes milliseconds. This only guards against a stack that never reports completion.
    private static let gatheringTimeout: Duration = .seconds(2)

    private let eventContinuation: AsyncStream<PeerSessionEvent>.Continuation
    private let queue = DispatchQueue(label: "nuzzlecam.webrtc-session")
    // Only touched on `queue`.
    private var connection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var talkBackSender: RTCRtpSender?
    private var videoSender: RTCRtpSender?
    private var isIncomingAudioEnabled = true
    private var outgoingAudio: RTCAudioTrack?
    // Guarded by `lock`: a copy of what WebRTC reported, readable from any thread.
    private let lock = NSLock()
    private var incomingVideo: RTCVideoTrack?
    private var isTransportConnected = false
    private var isChannelOpen = false
    private var isGatheringComplete = false
    private var hasAnnouncedConnection = false
    private var gatheringWaiters: [CheckedContinuation<Void, Never>] = []

    public init(factory: RTCPeerConnectionFactory) throws {
        let configuration = RTCConfiguration()
        configuration.iceServers = []
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.tcpCandidatePolicy = .disabled
        configuration.continualGatheringPolicy = .gatherOnce
        guard let connection = factory.peerConnection(with: configuration, constraints: Self.noConstraints, delegate: nil) else {
            throw Failure.cannotCreateConnection
        }
        self.connection = connection
        (events, eventContinuation) = AsyncStream.makeStream(of: PeerSessionEvent.self)
        super.init()
        connection.delegate = self
    }

    // MARK: Media

    /// Attaches the tracks this end sends. Call before `makeOffer`.
    public func addOutgoingMedia(audio: RTCAudioTrack, video: RTCVideoTrack, maxVideoBitrate: Int, maxFramerate: Int) {
        queue.async { [self] in
            guard let connection else { return }
            connection.add(audio, streamIds: ["room"])
            applyIncomingAudio(to: connection)
            guard let sender = connection.add(video, streamIds: ["room"]) else { return }
            let parameters = sender.parameters
            for encoding in parameters.encodings {
                encoding.maxBitrateBps = NSNumber(value: maxVideoBitrate)
                encoding.maxFramerate = NSNumber(value: maxFramerate)
            }
            sender.parameters = parameters
            videoSender = sender
        }
    }

    /// The picture received from the other end, once its offer has been accepted.
    public var remoteVideoTrack: RTCVideoTrack? {
        lock.withLock { incomingVideo }
    }

    /// Starts or stops sending audio towards the other end. Needs no renegotiation.
    /// Without a track the sender is also deactivated, so no audio stream runs at all.
    public func setOutgoingAudio(_ track: RTCAudioTrack?) {
        queue.async { [self] in
            outgoingAudio = track
            applyOutgoingAudio()
        }
    }

    /// Runs on `queue`.
    private func applyOutgoingAudio() {
        guard let talkBackSender else { return }
        talkBackSender.track = outgoingAudio
        let parameters = talkBackSender.parameters
        for encoding in parameters.encodings {
            encoding.isActive = outgoingAudio != nil
        }
        talkBackSender.parameters = parameters
    }

    /// Plays the audio received from the other end, or keeps it silent.
    public func setIncomingAudioEnabled(_ isEnabled: Bool) {
        queue.async { [self] in
            isIncomingAudioEnabled = isEnabled
            if let connection { applyIncomingAudio(to: connection) }
        }
    }

    /// Runs on `queue`.
    private func applyIncomingAudio(to connection: RTCPeerConnection) {
        for transceiver in connection.transceivers where transceiver.mediaType == .audio {
            transceiver.receiver.track?.isEnabled = isIncomingAudioEnabled
        }
    }

    /// Sends the picture to this peer, or holds it back while the sound keeps flowing.
    /// Each peer has its own setting, so one parent's audio-only mode leaves the other's picture alone.
    public func setOutgoingVideoActive(_ isActive: Bool) {
        queue.async { [self] in
            guard let videoSender else { return }
            let parameters = videoSender.parameters
            for encoding in parameters.encodings {
                encoding.isActive = isActive
            }
            videoSender.parameters = parameters
        }
    }

    /// The addresses of the candidate pair that carries the media, for diagnostics.
    public func selectedPath() async -> Path? {
        await statistics { statistics in
            // The transport names the pair in use. Older stacks only flag it on the pair itself.
            let selectedID = statistics.values
                .first { $0.type == "transport" && $0.values["selectedCandidatePairId"] != nil }?
                .values["selectedCandidatePairId"] as? String
            let pair = selectedID.flatMap { statistics[$0] } ?? statistics.values.first {
                $0.type == "candidate-pair" && ($0.values["nominated"] as? NSNumber)?.boolValue == true
            }
            func address(_ key: String) -> String? {
                guard let id = pair?.values[key] as? String, let candidate = statistics[id] else { return nil }
                return (candidate.values["address"] ?? candidate.values["ip"]) as? String
            }
            guard let local = address("localCandidateId"), let remote = address("remoteCandidateId") else { return nil }
            return Path(local: local, remote: remote)
        }
    }

    /// How many frames of the incoming picture have been decoded so far.
    /// A count that stops rising while the picture should flow means the stream has frozen.
    public func decodedVideoFrameCount() async -> Int? {
        await statistics { statistics in
            let inbound = statistics.values.first {
                $0.type == "inbound-rtp" && ($0.values["kind"] as? String) == "video"
            }
            return (inbound?.values["framesDecoded"] as? NSNumber)?.intValue
        }
    }

    // MARK: PeerSession

    public func makeOffer() async throws -> String {
        try await onQueue { [self] connection in
            let configuration = RTCDataChannelConfiguration()
            configuration.isOrdered = true
            guard let channel = connection.dataChannel(forLabel: "control", configuration: configuration) else {
                throw Failure.cannotCreateDataChannel
            }
            adopt(channel)
        }
        let offer = try await createDescription(.offer)
        try await setDescription(.offer, offer, isLocal: true)
        return try await completeLocalDescription()
    }

    public func makeAnswer(to offer: String) async throws -> String {
        try await setDescription(.offer, offer, isLocal: false)
        try await onQueue { [self] connection in
            prepareIncomingMedia(of: connection)
        }
        let answer = try await createDescription(.answer)
        try await setDescription(.answer, answer, isLocal: true)
        return try await completeLocalDescription()
    }

    public func accept(answer: String) async throws {
        try await setDescription(.answer, answer, isLocal: false)
    }

    @discardableResult
    public func send(_ data: Data) -> Bool {
        guard lock.withLock({ isChannelOpen }) else { return false }
        queue.async { [self] in
            dataChannel?.sendData(RTCDataBuffer(data: data, isBinary: true))
        }
        return true
    }

    public func close() {
        eventContinuation.finish()
        resumeGatheringWaiters()
        lock.withLock { isChannelOpen = false }
        queue.async { [self] in
            connection?.close()
            // Released here, on the session's own queue: letting go of a connection waits on WebRTC's threads too.
            connection = nil
            dataChannel = nil
            talkBackSender = nil
            videoSender = nil
        }
    }

    // MARK: Work on the session's queue

    /// Runs `work` on the session's queue and returns its result, without holding the caller's thread.
    private func onQueue<Result: Sendable>(
        _ work: @escaping @Sendable (RTCPeerConnection) throws -> Result
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let connection else {
                    continuation.resume(throwing: Failure.closed)
                    return
                }
                continuation.resume(with: Swift.Result { try work(connection) })
            }
        }
    }

    private func statistics<Value: Sendable>(
        _ extract: @escaping @Sendable ([String: RTCStatistics]) -> Value?
    ) async -> Value? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let connection else {
                    continuation.resume(returning: nil)
                    return
                }
                connection.statistics { report in
                    continuation.resume(returning: extract(report.statistics))
                }
            }
        }
    }

    // MARK: Negotiation

    private func createDescription(_ type: RTCSdpType) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let completion: @Sendable (RTCSessionDescription?, (any Error)?) -> Void = { description, error in
                if let description {
                    continuation.resume(returning: description.sdp)
                } else {
                    continuation.resume(throwing: error ?? Failure.negotiationFailed)
                }
            }
            queue.async { [self] in
                guard let connection else {
                    continuation.resume(throwing: Failure.closed)
                    return
                }
                if type == .offer {
                    connection.offer(for: Self.noConstraints, completionHandler: completion)
                } else {
                    connection.answer(for: Self.noConstraints, completionHandler: completion)
                }
            }
        }
    }

    private func setDescription(_ type: RTCSdpType, _ sdp: String, isLocal: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let completion: @Sendable ((any Error)?) -> Void = { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
            queue.async { [self] in
                guard let connection else {
                    continuation.resume(throwing: Failure.closed)
                    return
                }
                let description = RTCSessionDescription(type: type, sdp: sdp)
                if isLocal {
                    connection.setLocalDescription(description, completionHandler: completion)
                } else {
                    connection.setRemoteDescription(description, completionHandler: completion)
                }
            }
        }
    }

    /// Waits until every local address is gathered, then returns the description that lists them.
    private func completeLocalDescription() async throws -> String {
        let timeout = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.gatheringTimeout)) != nil else { return }
            self?.resumeGatheringWaiters()
        }
        defer { timeout.cancel() }
        await withCheckedContinuation { continuation in
            let isComplete = lock.withLock { () -> Bool in
                if isGatheringComplete { return true }
                gatheringWaiters.append(continuation)
                return false
            }
            if isComplete { continuation.resume() }
        }
        return try await onQueue { connection in
            guard let description = connection.localDescription else { throw Failure.negotiationFailed }
            return description.sdp
        }
    }

    /// Lets every caller waiting for the local addresses go on. Later callers do not wait at all.
    private func resumeGatheringWaiters() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isGatheringComplete = true
            defer { gatheringWaiters = [] }
            return gatheringWaiters
        }
        waiters.forEach { $0.resume() }
    }

    /// On the answering side: keeps the incoming picture, and opens the audio
    /// line in both directions so talk-back can start later without renegotiating.
    /// Runs on `queue`.
    private func prepareIncomingMedia(of connection: RTCPeerConnection) {
        for transceiver in connection.transceivers {
            switch transceiver.mediaType {
            case .audio:
                var error: NSError?
                transceiver.setDirection(.sendRecv, error: &error)
                talkBackSender = transceiver.sender
                // Nothing is sent until talk-back starts, unless it already has.
                applyOutgoingAudio()
                transceiver.receiver.track?.isEnabled = isIncomingAudioEnabled
            case .video:
                let track = transceiver.receiver.track as? RTCVideoTrack
                lock.withLock { incomingVideo = track }
            default:
                break
            }
        }
    }

    /// Runs on `queue`.
    private func adopt(_ channel: RTCDataChannel) {
        dataChannel = channel
        channel.delegate = self
        channelStateDidChange(channel)
    }

    /// Runs on `queue`.
    private func channelStateDidChange(_ channel: RTCDataChannel) {
        let state = channel.readyState
        LinkLog.note("data channel state \(state.rawValue)")
        lock.withLock { isChannelOpen = state == .open }
        if state == .closed {
            // The other end hung up. Saying so now spares the wait for the silence timeout.
            eventContinuation.yield(.failed)
        } else {
            announceConnectionIfReady()
        }
    }

    /// The session counts as connected once media can flow and the data channel is open.
    private func announceConnectionIfReady() {
        let shouldAnnounce = lock.withLock { () -> Bool in
            guard !hasAnnouncedConnection, isTransportConnected, isChannelOpen else { return false }
            hasAnnouncedConnection = true
            return true
        }
        if shouldAnnounce {
            eventContinuation.yield(.connected)
        }
    }
}

// Callbacks from WebRTC's own threads. None of them calls into WebRTC.
extension WebRTCSession: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        LinkLog.note("transport state \(newState.rawValue)")
        switch newState {
        case .connected, .completed:
            lock.withLock { isTransportConnected = true }
            announceConnectionIfReady()
        case .failed, .closed:
            eventContinuation.yield(.failed)
        default:
            // A brief disconnection often heals by itself. The link's keepalive decides when it is lost.
            break
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete {
            resumeGatheringWaiters()
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        queue.async { [weak self] in
            self?.adopt(dataChannel)
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
}

extension WebRTCSession: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        queue.async { [weak self] in
            self?.channelStateDidChange(dataChannel)
        }
    }

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        eventContinuation.yield(.message(buffer.data))
    }
}
