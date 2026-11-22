import Foundation

/// A plain HTTP request to a device on the local network, such as the home router.
///
/// Routers answer UPnP over unencrypted HTTP. This type and `HTTPResponse` are
/// just enough of the protocol to talk to them.
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [(name: String, value: String)]
    public var body: Data

    public init(method: String = "GET", url: URL, headers: [(name: String, value: String)] = [], body: Data = Data()) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    public static func == (lhs: HTTPRequest, rhs: HTTPRequest) -> Bool {
        lhs.serialized == rhs.serialized
    }

    public var host: String { url.host ?? "" }
    public var port: UInt16 { UInt16(url.port ?? 80) }

    /// The bytes to send. The connection is closed after the response, so its end marks the end of the body.
    public var serialized: Data {
        var target = url.path.isEmpty ? "/" : url.path
        if let query = url.query { target += "?\(query)" }
        var lines = ["\(method) \(target) HTTP/1.1", "Host: \(host):\(port)", "Connection: close"]
        lines += headers.map { "\($0.name): \($0.value)" }
        if !body.isEmpty || method != "GET" { lines.append("Content-Length: \(body.count)") }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    /// Header names in lowercase.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Reads everything a server sent before it closed the connection. Returns nil when that is not a response.
    public init?(parsing data: Data) {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<separator.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let statusFields = lines[0].split(separator: " ")
        guard statusFields.count >= 2, statusFields[0].hasPrefix("HTTP/"), let status = Int(statusFields[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let rest = Data(data[separator.upperBound...])
        self.status = status
        self.headers = headers
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = Self.decodingChunks(rest)
        } else if let length = headers["content-length"].flatMap({ Int($0) }), length >= 0, length <= rest.count {
            body = rest.prefix(length)
        } else {
            body = rest
        }
    }

    /// Whether `data`, received so far, already holds the whole response. Lets a reader stop
    /// without waiting for a server that keeps the connection open.
    public static func isComplete(_ data: Data) -> Bool {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: data[data.startIndex..<separator.lowerBound], as: UTF8.self).lowercased()
        let received = data.distance(from: separator.upperBound, to: data.endIndex)
        if head.contains("transfer-encoding: chunked") {
            return data.suffix(5) == Data("0\r\n\r\n".utf8)
        }
        for line in head.components(separatedBy: "\r\n") where line.hasPrefix("content-length:") {
            return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)).map { received >= $0 } ?? false
        }
        return false
    }

    private static func decodingChunks(_ data: Data) -> Data {
        var body = Data()
        var rest = data[...]
        let lineEnd = Data("\r\n".utf8)
        while let endOfSize = rest.range(of: lineEnd) {
            let sizeField = String(decoding: rest[rest.startIndex..<endOfSize.lowerBound], as: UTF8.self)
            guard let size = Int(sizeField.split(separator: ";").first ?? "", radix: 16), size > 0 else { break }
            let chunk = rest[endOfSize.upperBound...].prefix(size)
            body.append(chunk)
            guard chunk.count == size else { break }
            rest = rest[endOfSize.upperBound...].dropFirst(size + lineEnd.count)
        }
        return body
    }
}
