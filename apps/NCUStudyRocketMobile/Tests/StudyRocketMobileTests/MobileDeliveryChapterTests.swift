import XCTest
@testable import StudyRocketMobile
import StudyRocketShared

@MainActor
final class MobileDeliveryChapterTests: XCTestCase {
    func testStrikeCanUndoBeforeSubmission() {
        var state = MobileDeliveryChapterState(repositoryGeneration: 7)
        let token = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let mutation = state.begin(deliveryID: "final", token: token)

        XCTAssertEqual(
            mutation,
            MobileDeliveryMutation(deliveryID: "final", token: token, repositoryGeneration: 7)
        )
        XCTAssertTrue(state.undo(mutation!))
        XCTAssertEqual(state.phase, .list)
        XCTAssertEqual(state.finishStrike(mutation!), .none)
    }

    func testOnlyMatchingAuthoritativeFinalTokenSealsAndAnnouncesOnce() {
        var state = MobileDeliveryChapterState(repositoryGeneration: 3)
        let mutation = state.begin(
            deliveryID: "final",
            token: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )!
        XCTAssertEqual(state.finishStrike(mutation), .submit(mutation))

        state.resolve(.confirmed(snapshot(deliveries: [delivery("final", completed: true)])), for: mutation)
        XCTAssertEqual(state.phase, .sealing(mutation))
        XCTAssertEqual(state.finishSeal(mutation), .announceCompletion)
        XCTAssertEqual(state.phase, .completed)
        XCTAssertEqual(state.finishSeal(mutation), .none)

        var mismatched = MobileDeliveryChapterState(repositoryGeneration: 3)
        let old = mismatched.begin(deliveryID: "missing", token: UUID())!
        XCTAssertEqual(mismatched.finishStrike(old), .submit(old))
        mismatched.resolve(.confirmed(snapshot(deliveries: [delivery("final", completed: true)])), for: old)
        XCTAssertEqual(mismatched.phase, .list)
        XCTAssertEqual(mismatched.finishSeal(old), .none)
    }

    func testNonfinalQueuedFailureAndStaleResultsReturnToList() {
        var nonfinal = awaitingState(deliveryID: "one", generation: 1)
        let nonfinalMutation = nonfinal.phase.mutation!
        nonfinal.resolve(
            .confirmed(snapshot(deliveries: [
                delivery("one", completed: true),
                delivery("two", completed: false)
            ])),
            for: nonfinalMutation
        )
        XCTAssertEqual(nonfinal.phase, .list)

        for result in [
            MobileDeliveryToggleResult.queuedOffline,
            .failed("revision conflict"),
            .staleGeneration
        ] {
            var state = awaitingState(deliveryID: "one", generation: 1)
            let mutation = state.phase.mutation!
            state.resolve(result, for: mutation)
            XCTAssertEqual(state.phase, .list)
        }
    }

    func testStartupAndExternalCompletionAreStaticWithoutAnnouncementEffect() {
        var startup = MobileDeliveryChapterState(
            allAuthoritativelyCompleted: true,
            repositoryGeneration: 4
        )
        XCTAssertEqual(startup.phase, .completed)
        let unrelated = MobileDeliveryMutation(deliveryID: "final", token: UUID(), repositoryGeneration: 4)
        XCTAssertEqual(startup.finishSeal(unrelated), .none)

        var external = MobileDeliveryChapterState(repositoryGeneration: 4)
        external.synchronize(allAuthoritativelyCompleted: true, repositoryGeneration: 4)
        XCTAssertEqual(external.phase, .completed)
        XCTAssertEqual(external.finishSeal(unrelated), .none)
    }

    func testRepositoryGenerationInvalidatesOldToken() {
        var state = MobileDeliveryChapterState(repositoryGeneration: 10)
        let mutation = state.begin(deliveryID: "final", token: UUID())!
        state.synchronize(allAuthoritativelyCompleted: false, repositoryGeneration: 11)

        XCTAssertEqual(state.phase, .list)
        XCTAssertEqual(state.finishStrike(mutation), .none)
    }

    func testQueuedFinalMutationSealsOnlyAfterAuthoritativeReplayClearsDraft() {
        var state = awaitingState(deliveryID: "final", generation: 12)
        let mutation = state.phase.mutation!
        state.resolve(.queuedOffline, for: mutation, queuedOfflineCompletesAll: true)

        XCTAssertEqual(state.phase, .list)
        state.synchronize(
            allAuthoritativelyCompleted: true,
            repositoryGeneration: 12,
            hasPendingDelivery: true
        )
        XCTAssertEqual(state.phase, .list)

        state.synchronize(
            allAuthoritativelyCompleted: true,
            repositoryGeneration: 12,
            hasPendingDelivery: false
        )
        XCTAssertEqual(state.phase, .sealing(mutation))
        XCTAssertEqual(state.finishSeal(mutation), .announceCompletion)
        XCTAssertEqual(state.finishSeal(mutation), .none)
    }

    func testCancellingQueuedFinalMutationPreventsDelayedCeremony() {
        var state = awaitingState(deliveryID: "final", generation: 13)
        let mutation = state.phase.mutation!
        state.resolve(.queuedOffline, for: mutation, queuedOfflineCompletesAll: true)
        state.synchronize(
            allAuthoritativelyCompleted: false,
            repositoryGeneration: 13,
            hasPendingDelivery: false
        )
        state.synchronize(
            allAuthoritativelyCompleted: true,
            repositoryGeneration: 13,
            hasPendingDelivery: false
        )

        XCTAssertEqual(state.phase, .completed)
        XCTAssertEqual(state.finishSeal(mutation), .none)
    }

    func testAuthoritativeSnapshotWaitsForLocalDraftToClearBeforeShowingSeal() {
        XCTAssertEqual(
            MobileDeliveryChapterPresentation.body(
                phase: .list,
                total: 7,
                completed: 7,
                allAuthoritativelyCompleted: true,
                hasPending: true
            ),
            .waitingForOfflineSync
        )
        XCTAssertEqual(
            MobileDeliveryChapterPresentation.body(
                phase: .list,
                total: 7,
                completed: 7,
                allAuthoritativelyCompleted: true,
                hasPending: false
            ),
            .completed
        )
    }

    func testSessionReturnsQueuedAndDeduplicatesTokenWithoutRequest() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileDeliveryChapterTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = MobileSession(cacheDirectory: directory)
        let item = delivery("offline", completed: false)
        let mutation = MobileDeliveryMutation(
            deliveryID: item.id,
            token: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            repositoryGeneration: session.repositoryGeneration
        )

        let firstResult = await session.toggleDelivery(item, isCompleted: true, mutation: mutation)
        let duplicateResult = await session.toggleDelivery(item, isCompleted: true, mutation: mutation)
        XCTAssertEqual(firstResult, .queuedOffline)
        XCTAssertEqual(duplicateResult, .queuedOffline)
        XCTAssertEqual(session.pendingDeliveryCount, 1)

        let stale = MobileDeliveryMutation(
            deliveryID: item.id,
            token: UUID(),
            repositoryGeneration: session.repositoryGeneration &+ 1
        )
        let staleResult = await session.toggleDelivery(item, isCompleted: true, mutation: stale)
        XCTAssertEqual(staleResult, .staleGeneration)
        XCTAssertEqual(session.pendingDeliveryCount, 1)
    }

    private func awaitingState(deliveryID: String, generation: UInt64) -> MobileDeliveryChapterState {
        var state = MobileDeliveryChapterState(repositoryGeneration: generation)
        let mutation = state.begin(deliveryID: deliveryID, token: UUID())!
        XCTAssertEqual(state.finishStrike(mutation), .submit(mutation))
        return state
    }

    private func delivery(_ id: String, completed: Bool) -> DeliverySnapshot {
        DeliverySnapshot(id: id, text: "交付物 \(id)", isCompleted: completed, dateLabel: "8月19日")
    }

    private func snapshot(deliveries: [DeliverySnapshot]) -> SnapshotResponse {
        SnapshotResponse(
            revision: UUID().uuidString,
            home: HomeSnapshot(
                dateLabel: "8月19日",
                periods: [],
                firstOpenTask: nil,
                visibleDeliveries: deliveries.filter { !$0.isCompleted },
                completedDeliveries: deliveries.filter(\.isCompleted).count,
                totalDeliveries: deliveries.count
            ),
            week: WeeklyPlanSnapshot(days: [], bufferRules: [], deliveries: deliveries),
            daily: DailySnapshot(date: "2026-08-19"),
            summaries: []
        )
    }
}
