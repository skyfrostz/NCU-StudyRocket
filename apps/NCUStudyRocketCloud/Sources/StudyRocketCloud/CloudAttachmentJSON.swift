import Foundation

/// Syntax-only JSON validation. Never materialize strings, arrays, or an object tree.
/// UTF-8 validity is checked by the adjacent streaming text validator.
struct AttachmentJSONValidator {
    let file: FileHandle
    var buffer=Data()
    var offset=0
    var eof=false
    static func validate(_ url:URL) throws {
        let file=try FileHandle(forReadingFrom:url);defer{try? file.close()}
        var parser=Self(file:file)
        try parser.value(depth:0);try parser.whitespace()
        guard try parser.peek() == nil else {throw parser.invalid()}
    }
    func invalid()->CloudError {CloudError(422,"invalid_attachment_json","JSON附件语法无效或嵌套超过128层。")}
    mutating func peek() throws -> UInt8? {
        if offset == buffer.count && !eof {
            buffer=try file.read(upToCount:262144) ?? Data();offset=0;eof=buffer.isEmpty
        }
        return offset < buffer.count ? buffer[offset]:nil
    }
    @discardableResult mutating func take() throws -> UInt8? {let byte=try peek();if byte != nil {offset+=1};return byte}
    mutating func expect(_ byte:UInt8) throws {guard try take() == byte else {throw invalid()}}
    mutating func whitespace() throws {while let byte=try peek(),[UInt8(9),10,13,32].contains(byte) {_ = try take()}}
    mutating func value(depth:Int) throws {
        guard depth <= 128 else {throw invalid()}
        try whitespace()
        guard let byte=try peek() else {throw invalid()}
        switch byte {
        case 34:try string()
        case 91:
            try expect(91);try whitespace()
            if try peek() == 93 {_ = try take();return}
            while true {
                try value(depth:depth+1);try whitespace()
                if try peek() == 93 {_ = try take();return}
                try expect(44)
            }
        case 123:
            try expect(123);try whitespace()
            if try peek() == 125 {_ = try take();return}
            while true {
                try whitespace();try string();try whitespace();try expect(58)
                try value(depth:depth+1);try whitespace()
                if try peek() == 125 {_ = try take();return}
                try expect(44)
            }
        case 116:for byte in "true".utf8 {try expect(byte)}
        case 102:for byte in "false".utf8 {try expect(byte)}
        case 110:for byte in "null".utf8 {try expect(byte)}
        case 45,48...57:try number()
        default:throw invalid()
        }
    }
    mutating func string() throws {
        try expect(34)
        while let byte=try take() {
            if byte == 34 {return}
            guard byte >= 32 else {throw invalid()}
            if byte == 92 {
                guard let escaped=try take() else {throw invalid()}
                if escaped == 117 {
                    for _ in 0..<4 {
                        guard let hex=try take(),(48...57).contains(hex) || (65...70).contains(hex) || (97...102).contains(hex) else {throw invalid()}
                    }
                } else if ![UInt8(34),47,92,98,102,110,114,116].contains(escaped) {throw invalid()}
            }
        }
        throw invalid()
    }
    mutating func digits() throws {
        guard let first=try peek(),(48...57).contains(first) else {throw invalid()}
        while let byte=try peek(),(48...57).contains(byte) {_ = try take()}
    }
    mutating func number() throws {
        if try peek() == 45 {_ = try take()}
        if try peek() == 48 {_ = try take()}
        else {guard let first=try peek(),(49...57).contains(first) else {throw invalid()};try digits()}
        if try peek() == 46 {_ = try take();try digits()}
        if let byte=try peek(),byte == 101 || byte == 69 {
            _ = try take()
            if let sign=try peek(),sign == 43 || sign == 45 {_ = try take()}
            try digits()
        }
    }
}
