import Foundation

/// What kind of network an IP address belongs to, which decides whether another phone can reach it.
public enum AddressScope: String, Sendable, Equatable {
    /// Reachable only from this phone.
    case loopback
    /// Reachable only on the same link (169.254.0.0/16, fe80::/10).
    case linkLocal
    /// Reachable only inside the local network (RFC 1918, fc00::/7).
    case privateNetwork
    /// Behind an operator's address translation (100.64.0.0/10, 192.0.0.0/24): no inbound path.
    case carrierNAT
    /// Public IPv4. On a phone this is nearly always the router's address, not the phone's.
    case publicIPv4
    /// Public IPv6: the address a remote phone can send to directly.
    case globalIPv6
    case unknown

    public static func of(_ address: String) -> AddressScope {
        let host = address.split(separator: "%").first.map(String.init) ?? address
        if host.contains(":") { return ofIPv6(host.lowercased()) }
        return ofIPv4(host)
    }

    private static func ofIPv4(_ host: String) -> AddressScope {
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return .unknown }
        switch (parts[0], parts[1]) {
        case (127, _): return .loopback
        case (169, 254): return .linkLocal
        case (10, _), (192, 168), (172, 16...31): return .privateNetwork
        case (100, 64...127): return .carrierNAT
        case (192, 0) where parts[2] == 0: return .carrierNAT
        default: return .publicIPv4
        }
    }

    private static func ofIPv6(_ host: String) -> AddressScope {
        if host == "::1" { return .loopback }
        guard let firstGroup = host.split(separator: ":", omittingEmptySubsequences: false).first,
              let prefix = UInt16(firstGroup.isEmpty ? "0" : firstGroup, radix: 16)
        else { return .unknown }
        if prefix & 0xffc0 == 0xfe80 { return .linkLocal }
        if prefix & 0xfe00 == 0xfc00 { return .privateNetwork }
        if prefix & 0xe000 == 0x2000 { return .globalIPv6 }
        return .unknown
    }
}

/// Reads the addresses a session description advertises.
public enum SessionDescriptionInspector {
    /// The address of every candidate listed in `description`.
    public static func candidateAddresses(in description: String) -> [String] {
        description
            .split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("a=candidate:") }
            .compactMap { line in
                // a=candidate:<foundation> <component> <protocol> <priority> <address> <port> typ <type> ...
                let fields = line.split(separator: " ")
                return fields.count > 4 ? String(fields[4]) : nil
            }
    }

    /// Whether `description` lists an address a phone on another network can send to:
    /// a public IPv6 address, or a port the router forwards from its public IPv4 address.
    public static func offersRemotePath(_ description: String) -> Bool {
        candidateAddresses(in: description).contains {
            let scope = AddressScope.of($0)
            return scope == .globalIPv6 || scope == .publicIPv4
        }
    }
}
