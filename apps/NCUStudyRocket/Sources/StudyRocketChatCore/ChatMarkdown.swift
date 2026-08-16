import Foundation
import CryptoKit
import cmark_gfm
import cmark_gfm_extensions

public indirect enum ChatMarkdownInline: Equatable, Sendable {
    case text(String)
    case strong([ChatMarkdownInline])
    case emphasis([ChatMarkdownInline])
    case strikethrough([ChatMarkdownInline])
    case code(String)
    case link([ChatMarkdownInline], url: String, title: String?)
    case lineBreak
}

public struct ChatMarkdownTask: Equatable, Sendable {
    public let checked: Bool
    public let content: [ChatMarkdownInline]

    public init(checked: Bool, content: [ChatMarkdownInline]) {
        self.checked = checked
        self.content = content
    }
}

public indirect enum ChatMarkdownBlock: Equatable, Sendable {
    case paragraph([ChatMarkdownInline])
    case heading(level: Int, content: [ChatMarkdownInline])
    case quote([ChatMarkdownBlock])
    case bulletedList([[ChatMarkdownInline]])
    case numberedList(start: Int, items: [[ChatMarkdownInline]])
    case taskList([ChatMarkdownTask])
    case codeBlock(language: String?, code: String)
    case table(headers: [[ChatMarkdownInline]], rows: [[[ChatMarkdownInline]]])
    case divider
}

public struct ChatMarkdownDocument: Equatable, Sendable {
    public let blocks: [ChatMarkdownBlock]

    public init(blocks: [ChatMarkdownBlock]) {
        self.blocks = blocks
    }

    public init(_ markdown: String) {
        self = ChatMarkdownParser.parse(markdown)
    }
}

public enum ChatMarkdownParser {
    public static func parse(_ markdown: String) -> ChatMarkdownDocument {
        cmark_gfm_core_extensions_ensure_registered()
        let bytes = Array(markdown.utf8)
        let parser = cmark_parser_new(CMARK_OPT_DEFAULT)
        guard let parser else { return fallback(markdown) }
        for name in ["autolink", "strikethrough", "tagfilter", "tasklist", "table"] {
            if let syntaxExtension = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, syntaxExtension)
            }
        }
        bytes.withUnsafeBufferPointer { buffer in
            cmark_parser_feed(parser, buffer.baseAddress, buffer.count)
        }
        guard let document = cmark_parser_finish(parser) else {
            cmark_parser_free(parser)
            return fallback(markdown)
        }
        cmark_parser_free(parser)
        defer { cmark_node_free(document) }
        let taskLines = Set(markdown.components(separatedBy: .newlines).enumerated().compactMap { index, line in
            line.range(of: #"^\s*[-+*]\s+\[[ xX]\]"#, options: .regularExpression) == nil ? nil : index + 1
        })
        return ChatMarkdownDocument(blocks: parseBlocks(document, taskLines: taskLines))
    }

    private static func fallback(_ markdown: String) -> ChatMarkdownDocument {
        markdown.isEmpty ? ChatMarkdownDocument(blocks: []) : ChatMarkdownDocument(blocks: [.paragraph([.text(markdown)])])
    }

    private static func parseBlocks(_ root: UnsafeMutablePointer<cmark_node>, taskLines: Set<Int>) -> [ChatMarkdownBlock] {
        var result: [ChatMarkdownBlock] = []
        var child = cmark_node_first_child(root)
        while let node = child {
            if let block = parseBlock(node, taskLines: taskLines) { result.append(block) }
            child = cmark_node_next(node)
        }
        return result
    }

    private static func parseBlock(_ node: UnsafeMutablePointer<cmark_node>, taskLines: Set<Int>) -> ChatMarkdownBlock? {
        let type = String(cString: cmark_node_get_type_string(node))
        switch type {
        case "paragraph": return .paragraph(parseInlines(node))
        case "heading": return .heading(level: max(1, Int(cmark_node_get_heading_level(node))), content: parseInlines(node))
        case "block_quote": return .quote(parseBlocks(node, taskLines: taskLines))
        case "thematic_break": return .divider
        case "code_block":
            let info = cmark_node_get_fence_info(node).map(String.init(cString:))
            return .codeBlock(language: info?.isEmpty == false ? info : nil, code: literal(node))
        case "html_block":
            return .paragraph([.text(literal(node))])
        case "list": return parseList(node, taskLines: taskLines)
        case "table": return parseTable(node)
        default: return nil
        }
    }

    private static func parseList(_ node: UnsafeMutablePointer<cmark_node>, taskLines: Set<Int>) -> ChatMarkdownBlock? {
        let isOrdered = cmark_node_get_list_type(node) == CMARK_ORDERED_LIST
        var items: [[ChatMarkdownInline]] = []
        var tasks: [ChatMarkdownTask] = []
        var child = cmark_node_first_child(node)
        let startLine = Int(cmark_node_get_start_line(node))
        let endLine = Int(cmark_node_get_end_line(node))
        let hasTaskMarker = taskLines.contains { $0 >= startLine && $0 <= endLine }
        var sawTask = false
        while let item = child {
            let content = listItemContent(item)
            let checked = cmark_gfm_extensions_get_tasklist_item_checked(item)
            sawTask = sawTask || checked || hasTaskMarker
            tasks.append(ChatMarkdownTask(checked: checked, content: content))
            items.append(content)
            child = cmark_node_next(item)
        }
        if sawTask && !isOrdered { return .taskList(tasks) }
        return isOrdered
            ? .numberedList(start: max(1, Int(cmark_node_get_list_start(node))), items: items)
            : .bulletedList(items)
    }

    private static func listItemContent(_ item: UnsafeMutablePointer<cmark_node>) -> [ChatMarkdownInline] {
        guard let paragraph = cmark_node_first_child(item) else { return [] }
        return parseInlines(paragraph)
    }

    private static func parseTable(_ node: UnsafeMutablePointer<cmark_node>) -> ChatMarkdownBlock {
        var headers: [[ChatMarkdownInline]] = []
        var rows: [[[ChatMarkdownInline]]] = []
        var row = cmark_node_first_child(node)
        while let rowNode = row {
            var cells: [[ChatMarkdownInline]] = []
            var cell = cmark_node_first_child(rowNode)
            while let cellNode = cell {
                cells.append(parseInlines(cellNode))
                cell = cmark_node_next(cellNode)
            }
            if cmark_gfm_extensions_get_table_row_is_header(rowNode) != 0 { headers = cells }
            else { rows.append(cells) }
            row = cmark_node_next(rowNode)
        }
        return .table(headers: headers, rows: rows)
    }

    private static func parseInlines(_ parent: UnsafeMutablePointer<cmark_node>) -> [ChatMarkdownInline] {
        var result: [ChatMarkdownInline] = []
        var child = cmark_node_first_child(parent)
        while let node = child {
            let type = String(cString: cmark_node_get_type_string(node))
            switch type {
            case "text": result.append(.text(literal(node)))
            case "softbreak", "linebreak": result.append(.lineBreak)
            case "code": result.append(.code(literal(node)))
            case "emph": result.append(.emphasis(parseInlines(node)))
            case "strong": result.append(.strong(parseInlines(node)))
            case "strikethrough": result.append(.strikethrough(parseInlines(node)))
            case "link":
                result.append(.link(parseInlines(node), url: cmark_node_get_url(node).map(String.init(cString:)) ?? "", title: cmark_node_get_title(node).map(String.init(cString:))) )
            case "image":
                let url = cmark_node_get_url(node).map(String.init(cString:)) ?? ""
                let alt = inlinePlainText(parseInlines(node))
                result.append(.link([.text(alt.isEmpty ? url : alt)], url: url, title: alt.isEmpty ? nil : alt))
            case "html_inline": result.append(.text(literal(node)))
            default:
                let nested = parseInlines(node)
                if !nested.isEmpty { result.append(contentsOf: nested) }
            }
            child = cmark_node_next(node)
        }
        return result
    }

    private static func inlinePlainText(_ inlines: [ChatMarkdownInline]) -> String {
        inlines.map { inline in
            switch inline {
            case .text(let value), .code(let value): return value
            case .strong(let children), .emphasis(let children), .strikethrough(let children): return inlinePlainText(children)
            case .link(let children, _, _): return inlinePlainText(children)
            case .lineBreak: return "\n"
            }
        }.joined()
    }

    private static func literal(_ node: UnsafeMutablePointer<cmark_node>) -> String {
        cmark_node_get_literal(node).map(String.init(cString:)) ?? ""
    }
}

public actor ChatMarkdownCache {
    public struct Key: Hashable, Sendable {
        public let messageID: String
        public let exactTextHash: String

        public init(messageID: String, exactTextHash: String) {
            self.messageID = messageID
            self.exactTextHash = exactTextHash
        }
    }

    public private(set) var parseCount = 0
    public let capacity: Int
    private var values: [Key: ChatMarkdownDocument] = [:]
    private var lru: [Key] = []

    public init(capacity: Int = 60) {
        self.capacity = max(1, capacity)
    }

    public static func exactTextHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func document(for messageID: String, text: String) -> ChatMarkdownDocument {
        let key = Key(messageID: messageID, exactTextHash: Self.exactTextHash(text))
        if let value = values[key] {
            touch(key)
            return value
        }
        let value = ChatMarkdownDocument(text)
        parseCount += 1
        values[key] = value
        lru.removeAll { $0 == key }
        lru.append(key)
        while lru.count > capacity {
            values.removeValue(forKey: lru.removeFirst())
        }
        return value
    }

    public func removeAll() {
        values.removeAll()
        lru.removeAll()
    }

    public var count: Int { values.count }

    private func touch(_ key: Key) {
        lru.removeAll { $0 == key }
        lru.append(key)
    }
}
