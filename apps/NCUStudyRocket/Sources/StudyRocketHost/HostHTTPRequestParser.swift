import Foundation

struct HostHTTPRequest {
    let method: String
    let path: String
    let headers: String
    let body: Data
}

enum HostHTTPRequestParseResult {
    case incomplete
    case complete(HostHTTPRequest)
    case rejected(status: String, code: String, message: String)
}

/// Deliberately small HTTP/1.1 parser for the Host's one-request-per-connection
/// protocol. It rejects ambiguous framing rather than attempting to support
/// pipelining or transfer encodings that the mobile and local clients never use.
enum HostHTTPRequestParser {
    static let maximumHeaderBytes = 32 * 1024
    static let maximumBodyBytes = 2 * 1024 * 1024
    private static let maximumHeaderCount = 64
    private static let headerTerminator = Data("\r\n\r\n".utf8)
    private static let allowedMethods = Set(["GET", "POST", "PUT"])

    static func parse(_ data: Data) -> HostHTTPRequestParseResult {
        guard let headerEnd = data.range(of: headerTerminator) else {
            if data.count > maximumHeaderBytes {
                return .rejected(status: "431 Request Header Fields Too Large", code: "headers_too_large", message: "请求头过大。")
            }
            return .incomplete
        }
        guard headerEnd.lowerBound <= maximumHeaderBytes else {
            return .rejected(status: "431 Request Header Fields Too Large", code: "headers_too_large", message: "请求头过大。")
        }

        let headerData = data[..<headerEnd.lowerBound]
        guard !headerData.contains(0), let headers = String(data: headerData, encoding: .utf8) else {
            return .rejected(status: "400 Bad Request", code: "invalid_headers", message: "请求头格式无效。")
        }
        let lines = headers.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .rejected(status: "400 Bad Request", code: "invalid_request", message: "请求格式无效。")
        }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3,
              allowedMethods.contains(String(requestParts[0])),
              requestParts[2] == "HTTP/1.1" else {
            return .rejected(status: "400 Bad Request", code: "invalid_request", message: "请求行格式无效。")
        }

        let method = String(requestParts[0])
        let rawTarget = String(requestParts[1])
        guard rawTarget.hasPrefix("/"), !rawTarget.contains("#"), rawTarget.utf8.count <= 2_048 else {
            return .rejected(status: "400 Bad Request", code: "invalid_path", message: "请求路径无效。")
        }
        let path = rawTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawTarget

        guard lines.count - 1 <= maximumHeaderCount else {
            return .rejected(status: "431 Request Header Fields Too Large", code: "headers_too_large", message: "请求头数量过多。")
        }
        var values: [String: String] = [:]
        let validHeaderName = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~")
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                return .rejected(status: "400 Bad Request", code: "invalid_headers", message: "请求头格式无效。")
            }
            let name = String(line[..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  name.unicodeScalars.allSatisfy({ validHeaderName.contains($0) }),
                  !value.unicodeScalars.contains(where: { $0.value < 0x20 && $0.value != 0x09 }) else {
                return .rejected(status: "400 Bad Request", code: "invalid_headers", message: "请求头格式无效。")
            }
            let key = name.lowercased()
            guard values.updateValue(value, forKey: key) == nil else {
                return .rejected(status: "400 Bad Request", code: "duplicate_header", message: "请求头不能重复。")
            }
        }

        guard values["transfer-encoding"] == nil else {
            return .rejected(status: "400 Bad Request", code: "unsupported_framing", message: "不支持此请求传输格式。")
        }
        let contentLength: Int
        if let rawLength = values["content-length"] {
            guard !rawLength.isEmpty,
                  rawLength.allSatisfy(\.isNumber),
                  let parsed = Int(rawLength),
                  parsed <= maximumBodyBytes else {
                return .rejected(status: "413 Payload Too Large", code: "payload_too_large", message: "请求正文过大或长度无效。")
            }
            contentLength = parsed
        } else {
            contentLength = 0
        }
        if (method == "POST" || method == "PUT"), values["content-length"] == nil {
            return .rejected(status: "411 Length Required", code: "length_required", message: "请求缺少正文长度。")
        }

        let bodyStart = headerEnd.upperBound
        let expectedCount = bodyStart + contentLength
        guard data.count >= expectedCount else { return .incomplete }
        guard data.count == expectedCount else {
            return .rejected(status: "400 Bad Request", code: "ambiguous_request", message: "请求包含多余数据。")
        }
        return .complete(HostHTTPRequest(
            method: method,
            path: path,
            headers: headers,
            body: Data(data[bodyStart..<expectedCount])
        ))
    }
}
