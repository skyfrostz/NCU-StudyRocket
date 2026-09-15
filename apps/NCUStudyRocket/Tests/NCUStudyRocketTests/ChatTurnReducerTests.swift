import Foundation
import StudyRocketChatCore

@main
struct ChatTurnReducerTests {
    static func main() async {
        testRetryableErrorDoesNotTerminateTurn()
        testCompletedItemUsesAuthoritativeTextAndIgnoresDuplicates()
        testCommentaryAndFinalAnswerRemainSeparateItems()
        testCompletedTurnIsSuccessfulTerminalState()
        testInterruptedTurnIsNotReportedAsFailure()
        testFailedTurnUsesNestedTurnError()
        testNonRetryableErrorTerminatesImmediately()
        testCodexAuthenticationErrorsAreSafeForUI()
        testNamespacedProposalContract()
        testNestedProposalRoutesToVisibleTurn()
        testLegacyThreadRequiresOneTimeMigration()
        testChatScrollPolicy()
        testHistoryLoadCoordinator()
        testScrollCoordinatorCoalescesRequests()
        testScrollCoordinatorConsumesOnlyCurrentRequest()
        testStreamAccumulatorKeepsStableItemIDs()
        testScrollHysteresis()
        await testChatMarkdownParserAndCache()
        print("ChatTurnReducerTests: 18 passed")
    }

    private static func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        guard actual == expected else {
            fatalError("\(message)\nexpected: \(expected)\nactual: \(actual)")
        }
    }

    private static func testRetryableErrorDoesNotTerminateTurn() {
        var reducer = ChatTurnReducer()
        expect(
            reducer.reduce(.error(message: "Reconnecting... 2/5", willRetry: true)),
            [.retrying("Reconnecting... 2/5")],
            "retryable errors should surface as progress"
        )
        expect(reducer.isTerminal, false, "retryable errors must not terminate the turn")
        expect(
            reducer.reduce(.agentMessageDelta(itemID: "answer", delta: "恢复")),
            [.streamChanged(itemID: "answer", text: "恢复")],
            "streaming must continue after a retryable error"
        )
    }

    private static func testCompletedItemUsesAuthoritativeTextAndIgnoresDuplicates() {
        var reducer = ChatTurnReducer()
        _ = reducer.reduce(.agentMessageDelta(itemID: "answer", delta: "测"))
        _ = reducer.reduce(.agentMessageDelta(itemID: "answer", delta: "试"))
        let completed = ChatTurnReducer.CompletedMessage(
            itemID: "answer",
            text: "测试通过",
            phase: .finalAnswer
        )
        expect(
            reducer.reduce(.agentMessageCompleted(
                itemID: "answer",
                text: "测试通过",
                phase: .finalAnswer
            )),
            [.messageCompleted(completed)],
            "item/completed text must replace accumulated deltas"
        )
        expect(reducer.streams["answer"], nil, "completed streams must be removed")
        expect(
            reducer.reduce(.agentMessageCompleted(
                itemID: "answer",
                text: "测试通过",
                phase: .finalAnswer
            )),
            [],
            "duplicate item/completed events must be ignored"
        )
        expect(
            reducer.reduce(.agentMessageDelta(itemID: "answer", delta: "重复")),
            [],
            "late deltas for completed items must be ignored"
        )
    }

    private static func testCommentaryAndFinalAnswerRemainSeparateItems() {
        var reducer = ChatTurnReducer()
        expect(
            reducer.reduce(.agentMessageCompleted(
                itemID: "commentary",
                text: "正在读取档案。",
                phase: .commentary
            )),
            [.messageCompleted(.init(
                itemID: "commentary",
                text: "正在读取档案。",
                phase: .commentary
            ))],
            "commentary should remain an independent item"
        )
        expect(
            reducer.reduce(.agentMessageCompleted(
                itemID: "final",
                text: "请回答五项事实。",
                phase: .finalAnswer
            )),
            [.messageCompleted(.init(
                itemID: "final",
                text: "请回答五项事实。",
                phase: .finalAnswer
            ))],
            "final answers should remain independent from commentary"
        )
    }

    private static func testCompletedTurnIsSuccessfulTerminalState() {
        var reducer = ChatTurnReducer()
        expect(
            reducer.reduce(.turnCompleted(status: .completed, errorMessage: nil)),
            [.turnCompleted],
            "completed turns should succeed"
        )
        expect(reducer.isTerminal, true, "completed turns should be terminal")
        expect(
            reducer.reduce(.error(message: "late", willRetry: false)),
            [],
            "late events must not finish a turn twice"
        )
    }

    private static func testInterruptedTurnIsNotReportedAsFailure() {
        var reducer = ChatTurnReducer()
        expect(
            reducer.reduce(.turnCompleted(status: .interrupted, errorMessage: nil)),
            [.turnInterrupted],
            "user interruption should be a distinct terminal state"
        )
        expect(reducer.isTerminal, true, "interrupted turns should be terminal")
    }

    private static func testFailedTurnUsesNestedTurnError() {
        var reducer = ChatTurnReducer()
        expect(
            reducer.reduce(.turnCompleted(status: .failed, errorMessage: "认证失效")),
            [.turnFailed("认证失效")],
            "failed turns should expose turn.error.message"
        )
        expect(reducer.isTerminal, true, "failed turns should be terminal")
    }

    private static func testNonRetryableErrorTerminatesImmediately() {
        var reducer = ChatTurnReducer()
        expect(
            reducer.reduce(.error(message: "请求无效", willRetry: false)),
            [.turnFailed("请求无效")],
            "non-retryable errors should fail immediately"
        )
        expect(reducer.isTerminal, true, "non-retryable errors should be terminal")
    }

    private static func testCodexAuthenticationErrorsAreSafeForUI() {
        let presented = StudyRocketCodexErrorPresentation.message(
            for: "unexpected status 401 Unauthorized: invalid_api_key sk-test-credential-12345"
        )
        expect(
            presented,
            StudyRocketCodexErrorPresentation.authenticationFailureMessage,
            "authentication failures must use the recovery guidance instead of the upstream response"
        )
        let environment = StudyRocketCodexErrorPresentation.childProcessEnvironment(from: [
            "OPENAI_API_KEY": "test",
            "OPENAI_BASE_URL": "https://example.invalid",
            "CODEX_ACCESS_TOKEN": "valid-session",
            "PATH": "/usr/bin"
        ])
        expect(environment["OPENAI_API_KEY"], nil, "direct API keys must not enter the Codex child process")
        expect(environment["OPENAI_BASE_URL"], nil, "endpoint overrides must not enter the Codex child process")
        expect(environment["CODEX_ACCESS_TOKEN"], "valid-session", "normal Codex login sessions must remain available")
    }

    private static func testNamespacedProposalContract() {
        expect(
            StudyRocketDynamicToolContract.accepts(namespace: "studyrocket", tool: "propose_changes"),
            true,
            "proposal tools must use the studyrocket namespace"
        )
        expect(
            StudyRocketDynamicToolContract.accepts(namespace: "studyrocket", tool: "propose_skill_update"),
            true,
            "canonical skill proposal tools must remain accepted"
        )
        expect(
            StudyRocketDynamicToolContract.normalizedCall(namespace: nil, tool: "studyrocket_propose_changes")?.tool,
            "propose_changes",
            "the one observed legacy flat proposal name should normalize to the canonical tool"
        )
        expect(
            StudyRocketDynamicToolContract.accepts(namespace: nil, tool: "propose_changes"),
            false,
            "legacy unnamespaced tool calls must not be accepted"
        )
        expect(
            StudyRocketDynamicToolContract.accepts(namespace: nil, tool: "studyrocket.propose_changes"),
            false,
            "legacy dot-form proposal calls must not be accepted"
        )
        expect(
            StudyRocketDynamicToolContract.accepts(namespace: nil, tool: "studyrocket_propose_skill_update"),
            false,
            "unnamespaced skill updates must not be accepted"
        )
        expect(
            StudyRocketDynamicToolContract.accepts(namespace: "foreign", tool: "propose_changes"),
            false,
            "proposal tools from foreign namespaces must not be accepted"
        )
    }

    private static func testLegacyThreadRequiresOneTimeMigration() {
        expect(StudyRocketThreadProtocol.currentVersion, 4, "the dynamic-tool task contract must be v4")
        expect(StudyRocketThreadProtocol.requiresMigration(storedThreadID: "legacy", storedVersion: 3), true, "v3 persisted threads must migrate once")
        expect(StudyRocketThreadProtocol.requiresMigration(storedThreadID: "current", storedVersion: StudyRocketThreadProtocol.currentVersion), false, "current protocol threads must resume in place")
        expect(StudyRocketThreadProtocol.requiresMigration(storedThreadID: nil, storedVersion: 0), false, "a missing thread should be created without migration")
    }

    private static func testNestedProposalRoutesToVisibleTurn() {
        expect(
            StudyRocketDynamicToolContract.routedTurnID(eventThreadID: "thread", currentThreadID: "thread", activeTurnID: "visible-turn"),
            "visible-turn",
            "nested dynamic tools must attach to the visible active turn"
        )
        expect(
            StudyRocketDynamicToolContract.routedTurnID(eventThreadID: "other", currentThreadID: "thread", activeTurnID: "visible-turn"),
            nil,
            "dynamic tools from another thread must be rejected"
        )
        expect(
            StudyRocketDynamicToolContract.routedTurnID(eventThreadID: "thread", currentThreadID: "thread", activeTurnID: nil),
            nil,
            "late dynamic tools must be rejected after the active turn ends"
        )
    }

    private static func testChatScrollPolicy() {
        var policy = ChatScrollPolicy()
        expect(policy.shouldFollowIncrementalChanges(), true, "new chat follows the latest message")
        expect(policy.update(isNearBottom: false), true, "moving away from the bottom changes policy")
        expect(policy.update(isNearBottom: false), false, "repeating the same bottom state must not publish")
        expect(policy.shouldFollowIncrementalChanges(), false, "reading history disables incremental following")
        expect(policy.forceToBottom(), true, "manual return to bottom changes policy")
        expect(policy.forceToBottom(), false, "repeating force-to-bottom must not publish")
        expect(policy.isNearBottom && policy.shouldFollowIncrementalChanges(), true, "returning to bottom restores following")
    }

    private static func testHistoryLoadCoordinator() {
        var coordinator = ChatHistoryLoadCoordinator<[String]>(initialValue: [])
        expect(coordinator.replace([]), true, "loading an empty history still completes the first load")
        expect(coordinator.state, .loaded, "empty history must have a loaded state")
        expect(coordinator.replace([]), false, "duplicate history must not publish a new value")
        expect(coordinator.fail("断开"), true, "a load failure must be visible")
        expect(coordinator.value, [], "load failure must retain the last usable history")
        expect(coordinator.beginLoading(), true, "a reconnect returns to loading")
        expect(coordinator.replace(["turn-1"]), true, "new history publishes once")
        expect(coordinator.value, ["turn-1"], "new history replaces the old snapshot")
    }

    private static func testScrollCoordinatorCoalescesRequests() {
        var coordinator = ChatScrollCoordinator()
        expect(coordinator.enqueue(target: "turn-1", force: false), true, "first scroll request is accepted")
        expect(coordinator.enqueue(target: "turn-1", force: false), false, "duplicate incremental requests merge")
        expect(coordinator.enqueue(target: "chat-bottom", force: true), true, "a manual request supersedes an incremental request")
        expect(coordinator.pending, .init(target: "chat-bottom", force: true), "latest scroll target is retained")
    }

    private static func testStreamAccumulatorKeepsStableItemIDs() {
        var accumulator = ChatStreamAccumulator()
        expect(accumulator.append(itemID: "answer", delta: "测"), "测", "first delta is stored by item ID")
        expect(accumulator.append(itemID: "answer", delta: "试"), "测试", "later deltas extend the same item")
        expect(accumulator.streams["answer"], "测试", "stream identity remains stable")
        expect(accumulator.complete(itemID: "answer", text: "测试通过"), "测试通过", "authoritative completion replaces deltas")
        expect(accumulator.complete(itemID: "answer", text: "重复"), nil, "duplicate completion is ignored")
        expect(accumulator.append(itemID: "answer", delta: "迟到"), nil, "late deltas are ignored")
        accumulator.clearStreams()
        expect(accumulator.append(itemID: "answer", delta: "更晚"), nil, "terminal tombstones survive stream cleanup")
    }

    private static func testScrollCoordinatorConsumesOnlyCurrentRequest() {
        var coordinator = ChatScrollCoordinator()
        _ = coordinator.enqueue(target: "turn-1", force: false)
        let first = coordinator.pending?.id
        _ = coordinator.enqueue(target: "chat-bottom", force: true)
        expect(coordinator.consume(id: first ?? UUID()), nil, "stale scroll callback cannot clear the latest request")
        let current = coordinator.pending?.id
        expect(coordinator.consume(id: current ?? UUID())?.target, Optional("chat-bottom"), "current scroll request is consumed")
        expect(coordinator.pending, nil, "consuming clears the request")
    }

    private static func testScrollHysteresis() {
        var policy = ChatScrollPolicy()
        expect(policy.update(distanceFromBottom: 119), false, "119pt remains attached")
        expect(policy.update(distanceFromBottom: 121), true, "121pt detaches from the bottom")
        expect(policy.isNearBottom, false, "detached state is retained")
        expect(policy.update(distanceFromBottom: 49), false, "49pt does not reattach")
        expect(policy.update(distanceFromBottom: 48), true, "48pt reattaches")
    }

    private static func testChatMarkdownParserAndCache() async {
        let source = """
        # 标题

        **粗体** *斜体* ~~删~~ `code` [链接](https://x)

        > 引用

        - [ ] 待办
        - [x] 完成

        ```swift
        let x = 1
        ```

        | A | B |
        | --- | --- |
        | 1 | |

        `a | b` 非表格管道

        <b>x</b>
        """
        let document = ChatMarkdownDocument(source)
        expect(document.blocks.contains { if case .heading = $0 { return true }; return false }, true, "heading is parsed")
        expect(document.blocks.contains { if case .quote = $0 { return true }; return false }, true, "quote is parsed")
        expect(document.blocks.contains { if case .taskList = $0 { return true }; return false }, true, "task list is parsed")
        expect(document.blocks.contains { if case .codeBlock = $0 { return true }; return false }, true, "code fence is parsed")
        expect(document.blocks.contains { if case .table = $0 { return true }; return false }, true, "GFM table is parsed")
        guard let table = document.blocks.first(where: { if case .table = $0 { return true }; return false }) else { fatalError("table block missing") }
        guard case .table(let headers, let rows) = table else { fatalError("table block has the wrong shape") }
        expect(headers.count, 2, "table keeps both header cells")
        expect(rows.count, 1, "table keeps the data row")
        expect(rows.first?.count, 2, "table preserves an empty trailing cell")
        expect(inlinePlain(rows.first?.first ?? []), "1", "table keeps the first data cell")
        guard document.blocks.contains(where: { blockContainsText(block: $0, needle: "<b>x</b>") }) else { fatalError("HTML is literal text: \(document.blocks)") }

        let cache = ChatMarkdownCache()
        for _ in 0..<1_001 { _ = await cache.document(for: "message", text: source) }
        expect(await cache.parseCount, 1, "same message text parses once")
        _ = await cache.document(for: "message", text: source + "\nchanged")
        expect(await cache.parseCount, 2, "changed message text reparses")
        for index in 0..<61 { _ = await cache.document(for: "message-\(index)", text: "# \(index)") }
        expect(await cache.count, 60, "markdown cache keeps an LRU of 60")
    }

    private static func blockContainsText(block: ChatMarkdownBlock, needle: String) -> Bool {
        switch block {
        case .paragraph(let inlines), .heading(_, let inlines):
            return inlinePlain(inlines).contains(needle)
        case .bulletedList(let items), .numberedList(_, let items):
            return items.contains { inlinePlain($0).contains(needle) }
        case .taskList(let items): return items.contains { inlinePlain($0.content).contains(needle) }
        case .quote(let blocks): return blocks.contains { blockContainsText(block: $0, needle: needle) }
        case .table(let headers, let rows): return headers.contains { inlinePlain($0).contains(needle) } || rows.flatMap { $0 }.contains { inlinePlain($0).contains(needle) }
        case .codeBlock(_, let code): return code.contains(needle)
        case .divider: return false
        }
    }

    private static func inlinePlain(_ inlines: [ChatMarkdownInline]) -> String {
        inlines.map { inline in
            switch inline {
            case .text(let value), .code(let value): return value
            case .strong(let children), .emphasis(let children), .strikethrough(let children): return inlinePlain(children)
            case .link(let children, _, _): return inlinePlain(children)
            case .lineBreak: return "\n"
            }
        }.joined()
    }
}
