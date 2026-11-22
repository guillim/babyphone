import BabyphoneCore
import Foundation
@preconcurrency import WebRTC

/// One direct WebRTC connection between the two phones.
///
/// The connection uses host candidates only: the ICE server list is empty, so
/// there is no STUN lookup and no TURN relay. Each side's description already
/// carries all its addresses, which is why one message each way is enough.
public final class WebRTCSession: NSObject, PeerSession, @unchecked Sendable {
    public enum Failure: Error {
        case cannotCreateConnection
        case cannotCreateDataChannel
        case negotiationFailed
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

    private let connection: RTCPeerConnection
    private let eventContinuation: AsyncStream<PeerSessionEvent>.Continuation
    private let lock = NSLock()
    private var dataChannel: RTCDataChannel?
    private var talkBackSender: RTCRtpSender?
    private var incomingVideo: RTCVideoTrack?
    private var isTransportConnected = false
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
        connection.add(audio, streamIds: ["room"])
        guard let videoSender = connection.add(video, streamIds: ["room"]) else { return }
        let parameters = videoSender.parameters
        for encoding in parameters.encodings {
            encoding.maxBitrateBps = NSNumber(value: maxVideoBitrate)
            encoding.maxFramerate = NSNumber(value: maxFramerate)
        }
        videoSender.parameters = parameters
    }

    /// The picture received from the other end, once its offer has been accepted.
    public var remoteVideoTrack: RTCVideoTrack? {
        lock.withLock { incomingVideo }
    }

    /// Starts or stops sending audio towards the other end. Needs no renegotiation.
    public func setOutgoingAudio(_ track: RTCAudioTrack?) {
        lock.withLock { talkBackSender }?.track = track
    }

    /// The addresses of the candidate pair that carries the media, for diagnostics.
    public func selectedPath() async -> Path? {
        await withCheckedContinuation { continuation in
            connection.statistics { report in
                let statistics = report.statistics
                let pair = statistics.values.first {
                    $0.type == "candidate-pair" && ($0.values["nominated"] as? NSNumber)?.boolValue == true
                        && ($0.values["state"] as? String) == "succeeded"
                }
                func address(_ key: String) -> String? {
                    guard let id = pair?.values[key] as? String, let candidate = statistics[id] else { return nil }
                    return (candidate.values["address"] ?? candidate.values["ip"]) as? String
                }
                if let local = address("localCandidateId"), let remote = address("remoteCandidateId") {
                    continuation.resume(returning: Path(local: local, remote: remote))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: PeerSession

    public func makeOffer() async throws -> String {
        let channelConfiguration = RTCDataChannelConfiguration()
        channelConfiguration.isOrdered = true
        guard let channel = connection.dataChannel(forLabel: "control", configuration: channelConfiguration) else {
            throw Failure.cannotCreateDataChannel
        }
        adopt(channel)
        let offer = try await createDescription(.offer)
        try await setDescription(.offer, offer, isLocal: true)
        return try await completeLocalDescription()
    }

    public func makeAnswer(to offer: String) async throws -> String {
        try await setDescription(.offer, offer, isLocal: false)
        prepareIncomingMedia()
        let answer = try await createDescription(.answer)
        try await setDescription(.answer, answer, isLocal: true)
        return try await completeLocalDescription()
    }

    public func accept(answer: String) async throws {
        try await setDescription(.answer, answer, isLocal: false)
    }

    @discardableResult
    public func send(_ data: Data) -> Bool {
        guard let channel = lock.withLock({ dataChannel }), channel.readyState == .open else { return false }
        return channel.sendData(RTCDataBuffer(data: data, isBinary: true))
    }

    public func close() {
        connection.close()
        eventContinuation.finish()
        resumeGatheringWaiters()
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
            if type == .offer {
                connection.offer(for: Self.noConstraints, completionHandler: completion)
            } else {
                connection.answer(for: Self.noConstraints, completionHandler: completion)
            }
        }
    }

    private func setDescription(_ type: RTCSdpType, _ sdp: String, isLocal: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let description = RTCSessionDescription(type: type, sdp: sdp)
            let completion: @Sendable ((any Error)?) -> Void = { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
            if isLocal {
                connection.setLocalDescription(description, completionHandler: completion)
            } else {
                connection.setRemoteDescription(description, completionHandler: completion)
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
                if connection.iceGatheringState == .complete { return true }
                gatheringWaiters.append(continuation)
                return false
            }
            if isComplete { continuation.resume() }
        }
        guard let description = connection.localDescription else { throw Failure.negotiationFailed }
        return description.sdp
    }

    private func resumeGatheringWaiters() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { gatheringWaiters = [] }
            return gatheringWaiters
        }
        waiters.forEach { $0.resume() }
    }

    /// On the answering side: keeps the incoming picture, and opens the audio
    /// line in both directions so talk-back can start later without renegotiating.
    private func prepareIncomingMedia() {
        for transceiver in connection.transceivers {
            switch transceiver.mediaType {
            case .audio:
                var error: NSError?
                transceiver.setDirection(.sendRecv, error: &error)
                lock.withLock { talkBackSender = transceiver.sender }
            case .video:
                let track = transceiver.receiver.track as? RTCVideoTrack
                lock.withLock { incomingVideo = track }
            default:
                break
            }
        }
    }

    private func adopt(_ channel: RTCDataChannel) {
        lock.withLock { dataChannel = channel }
        channel.delegate = self
        announceConnectionIfReady()
    }

    /// The session counts as connected once media can flow and the data channel is open.
    private func announceConnectionIfReady() {
        let shouldAnnounce = lock.withLock { () -> Bool in
            guard !hasAnnouncedConnection, isTransportConnected, dataChannel?.readyState == .open else { return false }
            hasAnnouncedConnection = true
            return true
        }
        if shouldAnnounce {
            eventContinuation.yield(.connected)
        }
    }
}

extension WebRTCSession: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
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
        adopt(dataChannel)
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
        if dataChannel.readyState == .closed {
            // The other end hung up. Saying so now spares the wait for the silence timeout.
            eventContinuation.yield(.failed)
        } else {
            announceConnectionIfReady()
        }
    }

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        eventContinuation.yield(.message(buffer.data))
    }
}
