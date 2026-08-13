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
        testNestedProposalRoutesToVisibleTurn()
        testLegacyThreadRequiresOneTimeMigration()
        testChatScrollPolicy()
        print("ChatTurnReducerTests: 11 passed")
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

    private static func testLegacyThreadRequiresOneTimeMigration() {
        expect(StudyRocketThreadProtocol.requiresMigration(storedThreadID: "legacy", storedVersion: 0), true, "legacy persisted threads must migrate")
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
        policy.update(isNearBottom: false)
        expect(policy.shouldFollowIncrementalChanges(), false, "reading history disables incremental following")
        policy.forceToBottom()
        expect(policy.isNearBottom && policy.shouldFollowIncrementalChanges(), true, "returning to bottom restores following")
    }
}
