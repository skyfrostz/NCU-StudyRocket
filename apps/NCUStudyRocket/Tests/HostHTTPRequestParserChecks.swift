import Foundation

@main
struct HostHTTPRequestParserChecks {
    static func main() throws {
        try requireIncomplete(Data("POST /v1/chat/send HTTP/1.1\r\nContent-Length: 4\r\n\r\n{}".utf8))
        try requireComplete(Data("POST /v1/chat/send HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}".utf8), body: "{}")
        try requireRejected(Data("POST /v1/chat/send HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8), code: "payload_too_large")
        try requireRejected(Data("POST /v1/chat/send HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx".utf8), code: "duplicate_header")
        try requireRejected(Data("POST /v1/chat/send HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n".utf8), code: "unsupported_framing")
        try requireRejected(Data("GET /v1/health HTTP/1.1\r\n\r\nextra".utf8), code: "ambiguous_request")
        try requireRejected(Data(repeating: 65, count: HostHTTPRequestParser.maximumHeaderBytes + 1), code: "headers_too_large")
        let oversized = Data("POST /v1/week HTTP/1.1\r\nContent-Length: \(HostHTTPRequestParser.maximumBodyBytes + 1)\r\n\r\n".utf8)
        try requireRejected(oversized, code: "payload_too_large")
        print("HostHTTPRequestParserChecks: bounded and unambiguous HTTP framing passed")
    }

    private static func requireComplete(_ data: Data, body: String) throws {
        guard case .complete(let request) = HostHTTPRequestParser.parse(data), String(data: request.body, encoding: .utf8) == body else {
            throw CheckError.failed("expected complete request")
        }
    }

    private static func requireIncomplete(_ data: Data) throws {
        guard case .incomplete = HostHTTPRequestParser.parse(data) else { throw CheckError.failed("expected incomplete request") }
    }

    private static func requireRejected(_ data: Data, code: String) throws {
        guard case .rejected(_, let actualCode, _) = HostHTTPRequestParser.parse(data), actualCode == code else {
            throw CheckError.failed("expected rejection \(code)")
        }
    }
}

private enum CheckError: Error {
    case failed(String)
}
