import Foundation
import StudyRocketShared

typealias HostWriteError = AcademicWriteError

/// Preserve the legacy Host interface while sharing all business edits with
/// the cloud service. Authority is checked inside the repository write lock.
final class HostWriteService {
    private let service: AcademicWriteService

    init(root: URL, backupRoot: URL? = StudyRocketSelfCheckConfiguration.current?.backupDirectory, recordLocalHistory: Bool = false) {
        service = AcademicWriteService(root: root, backupRoot: backupRoot, recordLocalHistory: recordLocalHistory,
            localWriteAuthorization: { try LocalHostRepositoryPolicy.ensureLocalWritesAllowed(root) })
    }

    func applyWeek(_ request: PlanWriteRequest) throws -> SnapshotResponse { try service.applyWeek(request) }
    func toggleDelivery(_ request: DeliveryToggleRequest) throws -> SnapshotResponse { try service.toggleDelivery(request) }
    func togglePeriod(_ request: PeriodCompletionToggleRequest) throws -> SnapshotResponse { try service.togglePeriod(request) }
    func appendFact(_ request: FactWriteRequest) throws -> SnapshotResponse { try service.appendFact(request) }
    func applyDaily(_ request: DailyWriteRequest) throws -> SnapshotResponse { try service.applyDaily(request) }
}
