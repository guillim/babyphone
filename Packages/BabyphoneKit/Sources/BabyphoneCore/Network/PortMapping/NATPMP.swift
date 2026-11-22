import Foundation

/// The messages of NAT-PMP (RFC 6886), the simpler of the two protocols a home router may speak.
///
/// Requests go by UDP to port 5351 of the router. This type only builds and
/// reads the bytes; sending them is the transport's job.
public enum NATPMP {
    public static let port: UInt16 = 5351

    public enum Response: Sendable, Equatable {
        /// The router's address on the internet.
        case externalAddress(String)
        case mapping(internalPort: UInt16, externalPort: UInt16, lifetime: UInt32)
        /// The router refused, with the protocol's result code.
        case refused(code: UInt16)
    }

    /// Asks the router for its address on the internet.
    public static func externalAddressRequest() -> Data {
        Data([0, 0])
    }

    /// Asks the router to forward a UDP port for `lifetime` seconds. A lifetime of 0 gives the port back.
    public static func mappingRequest(internalPort: UInt16, externalPort: UInt16, lifetime: UInt32) -> Data {
        var data = Data([0, 1, 0, 0])
        data.append(bigEndian: internalPort)
        data.append(bigEndian: lifetime == 0 ? 0 : externalPort)
        data.append(bigEndian: lifetime)
        return data
    }

    /// Reads a response. Returns nil for anything that is not one.
    public static func parse(_ data: Data) -> Response? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0] == 0, bytes[1] >= 128 else { return nil }
        let code = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        guard code == 0 else { return .refused(code: code) }
        switch bytes[1] - 128 {
        case 0 where bytes.count >= 12:
            return .externalAddress(bytes[8..<12].map(String.init).joined(separator: "."))
        case 1 where bytes.count >= 16:
            return .mapping(
                internalPort: UInt16(bytes[8]) << 8 | UInt16(bytes[9]),
                externalPort: UInt16(bytes[10]) << 8 | UInt16(bytes[11]),
                lifetime: bytes[12..<16].reduce(0) { $0 << 8 | UInt32($1) }
            )
        default:
            return nil
        }
    }
}

extension Data {
    mutating func append(bigEndian value: UInt16) {
        append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xff)])
    }

    mutating func append(bigEndian value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
    }
}
