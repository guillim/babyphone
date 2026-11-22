import Foundation

/// What the parent unit presents to prove it stands next to the baby unit.
public enum PairingCredential: Sendable, Equatable {
    /// The six digits typed by hand.
    case code(String)
    /// The random token carried by the QR code.
    case token(Data)

    public enum Kind: String, Codable, Sendable {
        case code
        case token
    }

    public var kind: Kind {
        switch self {
        case .code: .code
        case .token: .token
        }
    }

    var secret: Data {
        switch self {
        case .code(let digits): Data(digits.utf8)
        case .token(let bytes): bytes
        }
    }
}

/// The one-time credentials the baby unit shows on its pairing screen.
public struct PairingInvitation: Sendable, Equatable {
    public static let codeLength = 6
    static let tokenByteCount = 16
    private static let scheme = "nuzzlecam"
    private static let host = "pair"
    private static let version = "1"

    /// Six digits, shown next to the QR code.
    public let code: String
    /// Random token, carried by the QR code.
    public let token: Data

    public init(code: String, token: Data) {
        self.code = code
        self.token = token
    }

    public static func random() -> PairingInvitation {
        var generator = SystemRandomNumberGenerator()
        let number = Int.random(in: 0..<1_000_000, using: &generator)
        let digits = String(number)
        let code = String(repeating: "0", count: codeLength - digits.count) + digits
        let token = Data((0..<tokenByteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return PairingInvitation(code: code, token: token)
    }

    /// Text encoded in the QR code.
    public var qrPayload: String {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [
            URLQueryItem(name: "v", value: Self.version),
            URLQueryItem(name: "t", value: token.base64URLEncodedString),
        ]
        return components.string ?? ""
    }

    /// Reads the credential out of a scanned QR code. Returns nil for any other QR code.
    public static func credential(fromQRPayload payload: String) -> PairingCredential? {
        guard
            let components = URLComponents(string: payload),
            components.scheme == scheme,
            components.host == host,
            let items = components.queryItems,
            items.first(where: { $0.name == "v" })?.value == version,
            let encoded = items.first(where: { $0.name == "t" })?.value,
            let token = Data(base64URLEncoded: encoded),
            token.count == tokenByteCount
        else { return nil }
        return .token(token)
    }

    /// Whether `text` has the shape of a pairing code.
    public static func isWellFormedCode(_ text: String) -> Bool {
        text.count == codeLength && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    func credential(for kind: PairingCredential.Kind) -> PairingCredential {
        switch kind {
        case .code: .code(code)
        case .token: .token(token)
        }
    }
}

extension Data {
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded text: String) {
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: base64)
    }
}
