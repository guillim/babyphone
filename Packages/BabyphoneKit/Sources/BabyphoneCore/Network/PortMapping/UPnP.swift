import Foundation

/// The messages of UPnP Internet Gateway Device, the protocol most home routers speak.
///
/// It takes three steps: find the router's description with a search datagram,
/// read in it where the router takes commands, then send those commands as
/// small XML documents over HTTP. This type builds and reads the messages;
/// sending them is the transport's job.
public enum UPnP {
    public static let searchPort: UInt16 = 1900
    /// Where every UPnP device on the network listens for searches.
    public static let searchGroup = "239.255.255.250"

    /// A service of the router that opens ports.
    public struct Service: Sendable, Equatable {
        /// The exact service type, to repeat in every command.
        public var type: String
        public var controlURL: URL

        public init(type: String, controlURL: URL) {
            self.type = type
            self.controlURL = controlURL
        }
    }

    public enum Failure: Error, Equatable {
        /// The router refused, with the protocol's error code.
        case refused(code: Int)
        case unreadableResponse
    }

    /// The router has no room at that external port: another device took it.
    public static let conflictCode = 718
    /// The router only knows leases without an end.
    public static let permanentLeaseOnlyCode = 725

    // MARK: Search

    /// The datagram that asks routers to announce themselves.
    public static func searchRequest() -> Data {
        Data([
            "M-SEARCH * HTTP/1.1",
            "HOST: \(searchGroup):\(searchPort)",
            "MAN: \"ssdp:discover\"",
            "MX: 1",
            "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1",
            "", "",
        ].joined(separator: "\r\n").utf8)
    }

    /// Reads where a router that answered the search publishes its description.
    public static func descriptionURL(inSearchResponse data: Data) -> URL? {
        let text = String(decoding: data, as: UTF8.self)
        guard text.hasPrefix("HTTP/"), text.contains(" 200 ") else { return nil }
        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == "location" else { continue }
            return URL(string: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    // MARK: Description

    /// Finds, in a router's description, the service that opens ports.
    public static func portMappingService(inDescription xml: String, at location: URL) -> Service? {
        let base = firstValue(of: "URLBase", in: xml).flatMap { URL(string: $0) } ?? location
        for block in blocks(of: "service", in: xml) {
            guard
                let type = firstValue(of: "serviceType", in: block),
                type.contains(":WANIPConnection:") || type.contains(":WANPPPConnection:"),
                let control = firstValue(of: "controlURL", in: block),
                let url = URL(string: control, relativeTo: base)?.absoluteURL
            else { continue }
            return Service(type: type, controlURL: url)
        }
        return nil
    }

    // MARK: Commands

    public static func externalAddressRequest(to service: Service) -> HTTPRequest {
        command("GetExternalIPAddress", arguments: [], to: service)
    }

    public static func externalAddress(in response: HTTPResponse) throws -> String {
        try value(of: "NewExternalIPAddress", in: response)
    }

    /// Asks for a UDP port forwarded to this device for `lifetime` seconds. A lifetime of 0 means no end.
    public static func addMappingRequest(
        to service: Service, externalPort: UInt16, internalAddress: String, internalPort: UInt16,
        lifetime: UInt32, description: String
    ) -> HTTPRequest {
        command("AddPortMapping", arguments: [
            ("NewRemoteHost", ""),
            ("NewExternalPort", String(externalPort)),
            ("NewProtocol", "UDP"),
            ("NewInternalPort", String(internalPort)),
            ("NewInternalClient", internalAddress),
            ("NewEnabled", "1"),
            ("NewPortMappingDescription", description),
            ("NewLeaseDuration", String(lifetime)),
        ], to: service)
    }

    public static func deleteMappingRequest(to service: Service, externalPort: UInt16) -> HTTPRequest {
        command("DeletePortMapping", arguments: [
            ("NewRemoteHost", ""),
            ("NewExternalPort", String(externalPort)),
            ("NewProtocol", "UDP"),
        ], to: service)
    }

    /// Throws when the router refused a command.
    public static func check(_ response: HTTPResponse) throws {
        guard response.status != 200 else { return }
        let text = String(decoding: response.body, as: UTF8.self)
        guard let code = firstValue(of: "errorCode", in: text).flatMap({ Int($0) }) else { throw Failure.unreadableResponse }
        throw Failure.refused(code: code)
    }

    private static func command(_ action: String, arguments: [(String, String)], to service: Service) -> HTTPRequest {
        let fields = arguments.map { "<\($0.0)>\(escaped($0.1))</\($0.0)>" }.joined()
        let body = """
            <?xml version="1.0"?>\
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
            <s:Body><u:\(action) xmlns:u="\(service.type)">\(fields)</u:\(action)></s:Body></s:Envelope>
            """
        return HTTPRequest(
            method: "POST",
            url: service.controlURL,
            headers: [
                ("Content-Type", "text/xml; charset=\"utf-8\""),
                ("SOAPAction", "\"\(service.type)#\(action)\""),
            ],
            body: Data(body.utf8)
        )
    }

    private static func value(of tag: String, in response: HTTPResponse) throws -> String {
        try check(response)
        guard let value = firstValue(of: tag, in: String(decoding: response.body, as: UTF8.self)), !value.isEmpty else {
            throw Failure.unreadableResponse
        }
        return value
    }

    // MARK: XML, as little of it as these documents need

    /// The text inside the first `<tag>`, whatever namespace prefix it carries.
    static func firstValue(of tag: String, in xml: String) -> String? {
        blocks(of: tag, in: xml).first?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The content of every `<tag>…</tag>` in `xml`, in order, whatever namespace prefix the tag carries.
    static func blocks(of tag: String, in xml: String) -> [String] {
        var result: [String] = []
        var rest = xml[...]
        while let open = rest.firstIndex(of: "<"), let endOfOpen = rest[open...].firstIndex(of: ">") {
            let isMatch = name(ofTag: rest[rest.index(after: open)..<endOfOpen]) == tag.lowercased()
            rest = rest[rest.index(after: endOfOpen)...]
            guard isMatch else { continue }
            // The block runs to the first closing tag of the same name.
            var search = rest
            while let close = search.range(of: "</"), let endOfClose = search[close.upperBound...].firstIndex(of: ">") {
                if name(ofTag: search[close.upperBound..<endOfClose]) == tag.lowercased() {
                    result.append(String(rest[..<close.lowerBound]))
                    rest = search[search.index(after: endOfClose)...]
                    break
                }
                search = search[search.index(after: endOfClose)...]
            }
        }
        return result
    }

    /// The name of a tag without its namespace prefix or attributes, in lowercase. Empty for a closing tag.
    private static func name(ofTag inside: Substring) -> String {
        let ends: (Character) -> Bool = { $0 == " " || $0 == "/" || $0.isNewline }
        guard let first = inside.split(omittingEmptySubsequences: false, whereSeparator: ends).first, !first.isEmpty else { return "" }
        return (first.split(separator: ":").last.map(String.init) ?? "").lowercased()
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
