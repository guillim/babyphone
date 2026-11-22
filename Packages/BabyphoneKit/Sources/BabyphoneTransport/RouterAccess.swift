import BabyphoneCore
import Foundation
@preconcurrency import Network

/// Finds the router this device sends its IPv4 traffic to.
public enum DefaultGateway {
    /// The address of the default IPv4 router, preferring the one on Wi-Fi. Nil when there is none.
    public static func current() -> String? {
        // The kernel's routing table, restricted to IPv4 routes that go through a gateway. These are
        // CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS and RTF_GATEWAY: iOS does not publish the last one.
        var query: [Int32] = [4, 17, 0, 2, 2, 0x2]
        var size = 0
        guard sysctl(&query, UInt32(query.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var table = [UInt8](repeating: 0, count: size)
        guard sysctl(&query, UInt32(query.count), &table, &size, nil, 0) == 0 else { return nil }
        return gateway(inRoutingTable: Array(table.prefix(size)))
    }

    /// Size of the header of each route in the table (`struct rt_msghdr`).
    private static let headerSize = 92

    static func gateway(inRoutingTable table: [UInt8]) -> String? {
        var fallback: String?
        var offset = 0
        while offset + headerSize <= table.count {
            let length = Int(table[offset]) | Int(table[offset + 1]) << 8
            guard length >= headerSize, offset + length <= table.count else { break }
            defer { offset += length }
            let interface = UInt32(table[offset + 4]) | UInt32(table[offset + 5]) << 8
            let present = table[offset + 12]
            // The addresses follow the header in a fixed order: destination first, then gateway.
            var cursor = offset + headerSize
            var destination: [UInt8]?
            var gateway: [UInt8]?
            for bit in 0..<2 where present & (1 << bit) != 0 {
                guard cursor + 2 <= offset + length else { break }
                let addressLength = Int(table[cursor])
                var address: [UInt8] = [0, 0, 0, 0]
                if table[cursor + 1] == UInt8(AF_INET), addressLength >= 8, cursor + 8 <= offset + length {
                    address = Array(table[cursor + 4..<cursor + 8])
                }
                if bit == 0 { destination = address } else { gateway = address }
                // Each address is padded to a multiple of four bytes.
                cursor += addressLength == 0 ? 4 : (addressLength + 3) & ~3
            }
            // The default route is the one to "0.0.0.0".
            guard destination == [0, 0, 0, 0], let gateway, gateway != [0, 0, 0, 0] else { continue }
            let address = gateway.map(String.init).joined(separator: ".")
            // Wi-Fi and Ethernet interfaces are named "en0", "en1", and so on.
            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            let isNamed = if_indextoname(interface, &name) != nil
            if isNamed, name[0] == CChar(UInt8(ascii: "e")), name[1] == CChar(UInt8(ascii: "n")) { return address }
            fallback = fallback ?? address
        }
        return fallback
    }
}

/// One question to devices on the local network, over UDP, and the first answer that makes sense.
enum Datagram {
    /// Sends `payload` to every destination, again after each wait, and returns what `parse`
    /// makes of the first reply it accepts. Returns nil when none came before the last wait ended.
    static func request<Answer: Sendable>(
        _ payload: Data,
        to destinations: [(host: String, port: UInt16)],
        waits: [TimeInterval],
        parse: @escaping @Sendable (Data) -> Answer?
    ) async -> Answer? {
        let destinations = destinations.map { Destination(host: $0.host, port: $0.port) }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: blockingRequest(payload, to: destinations, waits: waits, parse: parse))
            }
        }
    }

    private struct Destination: Sendable {
        let host: String
        let port: UInt16
    }

    private static func blockingRequest<Answer>(
        _ payload: Data, to destinations: [Destination], waits: [TimeInterval], parse: (Data) -> Answer?
    ) -> Answer? {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        let capacity = 4096
        var reply = [UInt8](repeating: 0, count: capacity)
        for wait in waits {
            for destination in destinations {
                send(payload, to: destination, from: descriptor)
            }
            let deadline = Date().addingTimeInterval(wait)
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { break }
                var limit = timeval(tv_sec: Int(remaining), tv_usec: Int32((remaining - remaining.rounded(.down)) * 1_000_000))
                setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
                let count = recv(descriptor, &reply, capacity, 0)
                if count > 0, let answer = parse(Data(reply[0..<count])) { return answer }
                // A timeout or an interruption only ends this wait. Anything else ends the request.
                if count < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR { return nil }
            }
        }
        return nil
    }

    private static func send(_ payload: Data, to destination: Destination, from descriptor: Int32) {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = destination.port.bigEndian
        guard inet_pton(AF_INET, destination.host, &address.sin_addr) == 1 else { return }
        payload.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { target in
                    // A destination that cannot be reached is simply one that will not answer.
                    _ = sendto(descriptor, bytes.baseAddress, bytes.count, 0, target, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}

/// Plain HTTP to a device on the local network, such as the home router.
enum LocalHTTP {
    /// Sends `request` and returns the response, or nil when none came within `timeout`.
    static func send(_ request: HTTPRequest, timeout: TimeInterval = 4) async -> HTTPResponse? {
        guard let port = NWEndpoint.Port(rawValue: request.port), !request.host.isEmpty else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(request.host), port: port, using: .tcp)
        defer { connection.cancel() }
        let received = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            let finish = SingleResume(continuation)
            let buffer = Buffer()

            @Sendable func receiveMore() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let data { buffer.append(data) }
                    let all = buffer.contents
                    if isComplete || error != nil || HTTPResponse.isComplete(all) {
                        finish(.success(all))
                    } else {
                        receiveMore()
                    }
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: request.serialized, completion: .contentProcessed { error in
                        if let error { finish(.failure(error)) } else { receiveMore() }
                    })
                case .failed(let error), .waiting(let error):
                    finish(.failure(error))
                default:
                    break
                }
            }
            connection.start(queue: LocalTransport.queue)
            LocalTransport.queue.asyncAfter(deadline: .now() + timeout) {
                finish(.failure(LocalNetworkError.notFound))
            }
        }
        return received.flatMap(HTTPResponse.init(parsing:))
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        var contents: Data { lock.withLock { data } }

        func append(_ more: Data) {
            lock.withLock { data.append(more) }
        }
    }
}
