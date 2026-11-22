import Foundation

public enum PeerSessionEvent: Sendable, Equatable {
    /// Media and data flow directly between the two phones.
    case connected
    /// A message arrived on the data channel.
    case message(Data)
    /// The direct connection could not be made, or broke for good.
    case failed
}

/// One direct media connection between the two phones.
///
/// The app implements it on top of WebRTC. The core only needs these few
/// operations, which keeps connection logic testable without a device.
public protocol PeerSession: AnyObject, Sendable {
    /// Connection events, for a single consumer. Finishes when the session closes.
    var events: AsyncStream<PeerSessionEvent> { get }

    /// Describes this end, including every address it can be reached at.
    func makeOffer() async throws -> String
    /// Accepts the other end's offer and describes this end in return.
    func makeAnswer(to offer: String) async throws -> String
    /// Completes an offer made earlier with the other end's answer.
    func accept(answer: String) async throws
    /// Sends a message on the data channel. Returns false when it could not be queued.
    @discardableResult func send(_ data: Data) -> Bool
    func close()
}

/// Creates sessions. Called once per connection attempt.
public typealias PeerSessionFactory = @Sendable () throws -> any PeerSession

/// Finds the paired baby unit on the local network. Parent side.
public protocol LocalSignalingConnecting: Sendable {
    /// Returns an authenticated channel to the baby unit, or throws when none is found in time.
    func connect(timeout: Duration) async throws -> any FrameChannel
}

/// Accepts parent units on the local network. Baby side.
public protocol LocalSignalingListening: Sendable {
    /// Starts advertising. Each element is an authenticated channel from the paired parent unit.
    func start() async throws -> AsyncStream<any FrameChannel>
    func stop() async
}
