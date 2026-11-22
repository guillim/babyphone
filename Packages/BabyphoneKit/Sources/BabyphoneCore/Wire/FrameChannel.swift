import Foundation

public enum FrameChannelError: Error, Equatable {
    case closed
    case frameTooLarge
}

/// A reliable, ordered, message-oriented channel between the two phones.
///
/// Pairing and local signaling both run on top of it, so the transport
/// underneath (TCP today) is written once.
public protocol FrameChannel: Sendable {
    func send(_ frame: Data) async throws
    /// Waits for the next frame. Throws once the channel is closed.
    func receive() async throws -> Data
    /// Closes the channel. A pending `receive` then throws.
    func close()
}

extension FrameChannel {
    /// Waits for the next frame, closing the channel if none arrives in time.
    ///
    /// A step that times out leaves the exchange in an unknown state, so the
    /// channel is not reusable afterwards.
    public func receive(timeout: Duration) async throws -> Data {
        let deadline = Task {
            try await Task.sleep(for: timeout)
            close()
        }
        defer { deadline.cancel() }
        return try await receive()
    }

    func send<Message: Encodable>(_ message: Message) async throws {
        try await send(WireCoding.encode(message))
    }

    func receive<Message: Decodable>(_ type: Message.Type, timeout: Duration) async throws -> Message {
        try WireCoding.decode(type, from: try await receive(timeout: timeout))
    }
}

/// Length-prefixed framing for byte streams: a 4-byte big-endian length, then the payload.
public enum FrameCodec {
    public static let maxFrameSize = 256 * 1024
    static let headerSize = 4

    public static func encode(_ payload: Data) throws -> Data {
        guard payload.count <= maxFrameSize else { throw FrameChannelError.frameTooLarge }
        var frame = Data(capacity: headerSize + payload.count)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }
}

/// Reassembles frames from a byte stream that delivers them in arbitrary chunks.
public struct FrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    /// Adds received bytes and returns every frame they complete.
    public mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []
        while buffer.count >= FrameCodec.headerSize {
            let length = buffer.prefix(FrameCodec.headerSize).reduce(0) { ($0 << 8) | Int($1) }
            guard length <= FrameCodec.maxFrameSize else { throw FrameChannelError.frameTooLarge }
            guard buffer.count >= FrameCodec.headerSize + length else { break }
            let start = buffer.startIndex + FrameCodec.headerSize
            frames.append(Data(buffer[start..<(start + length)]))
            buffer = Data(buffer[(start + length)...])
        }
        return frames
    }
}
