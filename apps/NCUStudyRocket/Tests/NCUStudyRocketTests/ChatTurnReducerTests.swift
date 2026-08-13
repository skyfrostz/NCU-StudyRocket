import StudyRocketChatCore

@main
struct ChatTurnReducerTests {
    static func main() {
        testRetryableErrorDoesNotTerminateTurn()
        testCompletedItemUsesAuthoritativeTextAndIgnoresDuplicates()
        testCommentaryAndFinalAnswerRemainSeparateItems()
        testCompletedTurnIsSuccessfulTerminalState()
        testInterruptedTurnIsNotReportedAsFailure()
        testFailedTurnUsesNestedTurnError()
        testNonRetryableErrorTerminatesImmediately()
        testNamespacedProposalContract()
        testEmbeddedProposalExtraction()
        print("ChatTurnReducerTests: 9 passed")
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

    private static func testNamespacedProposalContract() {
        expect(
            StudyRocketDynamicToolContract.accepts(namespace: "studyrocket", tool: "propose_changes"),
            true,
            "proposal tools must use the studyrocket namespace"
        )
        expect(
            StudyRocketDynamicToolContract.accepts(namespace: nil, tool: "propose_changes"),
            false,
            "legacy unnamespaced tool calls must not be accepted"
        )
    }

    private static func testEmbeddedProposalExtraction() {
        let text = "已生成草案。\n\n```studyrocket-proposal\n{\"path\":\"PROFILE.md\",\"content\":\"# Profile\",\"reason\":\"同步档案\"}\n```\n\n请确认差异。"
        let extraction = StudyRocketProposalProtocol.extract(from: text)
        expect(extraction.visibleText, "已生成草案。\n\n请确认差异。", "proposal envelope should not leak into the visible reply")
        expect(extraction.proposals, [StudyRocketProposalPayload(path: "PROFILE.md", content: "# Profile", reason: "同步档案")], "proposal payload must preserve path, content and reason")
        expect(extraction.invalidBlockCount, 0, "valid proposal envelope should parse cleanly")
    }
}
