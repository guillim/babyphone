import Foundation

/// A UDP port the home router forwards from the internet to this device.
///
/// It gives a baby unit on an IPv4-only line a path a remote parent unit can
/// send to. The router does it at the device's request, over the local
/// network: no server is involved.
public struct PortMapping: Sendable, Equatable {
    /// The protocol the router answered.
    public enum Method: String, Sendable {
        case natPMP = "NAT-PMP"
        case upnp = "UPnP"
    }

    public var method: Method
    /// The router's address on the internet.
    public var externalAddress: String
    public var externalPort: UInt16
    /// This device's address on the local network.
    public var internalAddress: String
    public var internalPort: UInt16
    /// How long the router keeps the port open without a renewal.
    public var lifetime: TimeInterval

    public init(
        method: Method, externalAddress: String, externalPort: UInt16,
        internalAddress: String, internalPort: UInt16, lifetime: TimeInterval
    ) {
        self.method = method
        self.externalAddress = externalAddress
        self.externalPort = externalPort
        self.internalAddress = internalAddress
        self.internalPort = internalPort
        self.lifetime = lifetime
    }
}

/// What came of asking the router for a port.
public enum PortMappingOutcome: Sendable, Equatable {
    case mapped(PortMapping)
    /// This device has no IPv4 router to ask: it is not on Wi-Fi.
    case noRouter
    /// The router answers neither NAT-PMP nor UPnP, or refuses.
    case unsupported
    /// The router's own address is not public: the operator shares it between
    /// customers, or a second router sits in front. A port opened here leads nowhere.
    case sharedAddress(String)
}

/// Asks the home router to open and close ports.
public protocol PortMapper: Sendable {
    /// Asks the router to forward a UDP port to `internalPort` on this device.
    func open(internalAddress: String, internalPort: UInt16) async -> PortMappingOutcome
    /// Gives the port back.
    func close(_ mapping: PortMapping) async
}

extension SessionDescriptionInspector {
    /// The address and port a router could forward to: the first IPv4 host candidate on the local network.
    public static func mappableCandidate(in description: String) -> (address: String, port: UInt16)? {
        for line in description.split(whereSeparator: \.isNewline) {
            guard let candidate = HostCandidate(line: line), AddressScope.of(candidate.address) == .privateNetwork else { continue }
            return (candidate.address, candidate.port)
        }
        return nil
    }

    /// Adds the router's forwarded port to `description`, next to the local candidate it leads to.
    ///
    /// The peer then also sends to the router's public address, and the router
    /// passes those packets on. Nothing else in the description changes.
    public static func adding(_ mapping: PortMapping, to description: String) -> String {
        // Session descriptions end their lines with a carriage return and a line feed, which Swift reads as one character.
        let ending: Character = description.contains("\r\n") ? "\r\n" : "\n"
        return description
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == ending })
            .flatMap { line -> [String] in
                guard
                    let candidate = HostCandidate(line: line),
                    candidate.address == mapping.internalAddress, candidate.port == mapping.internalPort
                else { return [String(line)] }
                return [String(line), candidate.forwarded(through: mapping)]
            }
            .joined(separator: String(ending))
    }
}

/// One `a=candidate` line of type host over UDP.
private struct HostCandidate {
    /// a=candidate:<foundation> <component> <protocol> <priority> <address> <port> typ <type> ...
    private let fields: [Substring]
    let address: String
    let port: UInt16

    init?(line: some StringProtocol) {
        let fields = Substring(line).split(separator: " ")
        guard
            fields.count >= 8, fields[0].hasPrefix("a=candidate:"),
            fields[2].lowercased() == "udp", fields[6] == "typ", fields[7] == "host",
            let port = UInt16(fields[5])
        else { return nil }
        self.fields = fields
        address = String(fields[4])
        self.port = port
    }

    /// The same candidate as seen from the internet: the router's address and port, pointing back to this one.
    func forwarded(through mapping: PortMapping) -> String {
        // Type preference 100 and local preference 65535, as for any address learnt from outside.
        let priority = (100 << 24) + (65535 << 8) + (256 - (Int(fields[1]) ?? 1))
        var result = [
            "a=candidate:\(mapping.externalPort)", String(fields[1]), "udp", String(priority),
            mapping.externalAddress, String(mapping.externalPort),
            "typ", "srflx", "raddr", address, "rport", String(port),
        ]
        result += fields.dropFirst(8).map(String.init)
        return result.joined(separator: " ")
    }
}
