import BabyphoneCore
import Foundation
@preconcurrency import Network

/// A frame channel over one TCP connection.
final class NetworkFrameChannel: FrameChannel, @unchecked Sendable {
    private let connection: NWConnection
    // Everything below is only touched on `LocalTransport.queue`.
    private var decoder = FrameDecoder()
    private var inbox: [Data] = []
    private var receiver: CheckedContinuation<Data, any Error>?
    private var readiness: [SingleResume<Void>] = []
    private var isReady = false
    private var failure: (any Error)?

    init(connection: NWConnection) {
        self.connection = connection
    }

    /// Opens the connection and waits until it can carry data, which for a
    /// secured connection means the other phone proved it holds the pairing key.
    func open(timeout: Duration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let ready = SingleResume(continuation)
            LocalTransport.queue.async { [self] in
                readiness.append(ready)
                connection.stateUpdateHandler = { [weak self] state in
                    self?.handle(state)
                }
                connection.start(queue: LocalTransport.queue)
            }
            LocalTransport.queue.asyncAfter(deadline: .now() + timeout.timeInterval) { [weak self] in
                guard let self, !isReady else { return }
                fail(FrameChannelError.closed)
                connection.cancel()
            }
        }
    }

    func send(_ frame: Data) async throws {
        let encoded = try FrameCodec.encode(frame)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: encoded, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            LocalTransport.queue.async { [self] in
                if !inbox.isEmpty {
                    continuation.resume(returning: inbox.removeFirst())
                } else if let failure {
                    continuation.resume(throwing: failure)
                } else {
                    receiver = continuation
                }
            }
        }
    }

    func close() {
        connection.cancel()
        LocalTransport.queue.async { [self] in
            fail(FrameChannelError.closed)
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isReady = true
            readiness.forEach { $0(.success(())) }
            readiness = []
            readNext()
        case .failed(let error), .waiting(let error):
            // A connection that waits has no route, or failed its handshake. Neither heals in time to be useful.
            fail(error)
            connection.cancel()
        case .cancelled:
            fail(FrameChannelError.closed)
        default:
            break
        }
    }

    private func readNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] bytes, _, isComplete, error in
            guard let self else { return }
            do {
                if let bytes {
                    for frame in try decoder.append(bytes) {
                        deliver(frame)
                    }
                }
            } catch {
                fail(error)
                connection.cancel()
                return
            }
            if let error {
                fail(error)
            } else if isComplete {
                fail(FrameChannelError.closed)
            } else {
                readNext()
            }
        }
    }

    private func deliver(_ frame: Data) {
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: frame)
        } else {
            inbox.append(frame)
        }
    }

    private func fail(_ error: any Error) {
        guard failure == nil else { return }
        failure = error
        readiness.forEach { $0(.failure(error)) }
        readiness = []
        receiver?.resume(throwing: error)
        receiver = nil
    }
}
