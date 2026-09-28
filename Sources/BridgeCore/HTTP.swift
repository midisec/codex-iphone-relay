import Foundation

public struct HTTPRequest {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
}

public struct HTTPParser {
    private var buffer = Data()
    private var headerEnd: Int?
    private var method = ""
    private var path = ""
    private var headers = [String: String]()
    private var length = 0
    public init() {}
    public mutating func append(_ data: Data) throws -> HTTPRequest? {
        buffer.append(data)
        if headerEnd == nil {
            guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 32_768 { throw BridgeError.invalid("Headers too large") }; return nil
            }
            guard range.upperBound <= 32_768,
                  let text = String(data: buffer.prefix(range.lowerBound), encoding: .utf8) else { throw BridgeError.invalid("Invalid headers") }
            let lines = text.components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            guard first.count == 3, first[2] == "HTTP/1.1", first[1].hasPrefix("/"), !first[1].hasPrefix("//") else { throw BridgeError.invalid("Expected HTTP/1.1 origin form") }
            method = String(first[0]); path = String(first[1])
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { throw BridgeError.invalid("Malformed header") }
                let name = String(line[..<colon]).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, name.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 58 }),
                      RequestPolicy.safeHeaderValue(value), headers[name] == nil else { throw BridgeError.invalid("Invalid or duplicate header") }
                headers[name] = value
            }
            guard headers["transfer-encoding"] == nil else { throw BridgeError.invalid("Chunked request uploads are unsupported; send Content-Length") }
            if let value = headers["content-length"] {
                guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let size = Int(value), size <= BridgeProtocol.maxBody else { throw BridgeError.invalid("Invalid Content-Length or body over 16 MiB") }
                length = size
            } else if method == "POST" { throw BridgeError.invalid("Content-Length is required") }
            headerEnd = range.upperBound
        }
        let start = headerEnd!
        guard buffer.count <= start + length else { throw BridgeError.invalid("HTTP pipelining is unsupported") }
        guard buffer.count == start + length else { return nil }
        return HTTPRequest(method: method, path: path, headers: headers, body: buffer.subdata(in: start..<buffer.count))
    }
}

public enum RequestPolicy {
    // CRLF is a single Swift grapheme, so checking String.contains("\r") is insufficient.
    public static func safeHeaderValue(_ value: String) -> Bool {
        value.utf8.allSatisfy { $0 == 9 || ($0 >= 32 && $0 != 127) }
    }
    public static func upstream(base: String, path: String, method: String, allowLoopback: Bool = false) throws -> URL {
        let allowed = (method == "POST" && ["/responses", "/responses/compact"].contains(path)) || (method == "GET" && path == "/models")
        guard allowed else { throw BridgeError.invalid("API route is not allowed") }
        guard let parts = URLComponents(string: base), let host = parts.host,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (allowLoopback && parts.scheme == "http" && host == "127.0.0.1") else {
            throw BridgeError.invalid("Upstream must be an HTTPS base URL")
        }
        guard let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else { throw BridgeError.invalid("Invalid upstream URL") }
        return url
    }
    public static func filteredHeaders(_ headers: [String: String]) -> [String: String] {
        let allowed: Set<String> = ["content-type", "content-encoding", "accept", "openai-beta", "openai-organization", "openai-project", "x-codex-turn-state"]
        return headers.filter { allowed.contains($0.key.lowercased()) && safeHeaderValue($0.value) }
    }
}
