import Foundation

/// Merges a newly imported timetable into the managed Markdown document.
/// Identity is normalized through the course catalog so legacy support rows
/// are updated instead of duplicated when their canonical course is imported.
public enum StudyRocketTimetableDocumentMerge {
    public struct Result: Equatable, Sendable {
        public let document: TimetableDocument
        public let addedCount: Int
        public let updatedCount: Int
    }

    public static func merge(
        existing: TimetableDocument?,
        imported: TimetableDocument
    ) -> Result {
        guard let existing else {
            return Result(document: imported, addedCount: imported.entries.count, updatedCount: 0)
        }

        var entries = existing.entries
        var positions: [String: Int] = [:]
        for (index, entry) in entries.enumerated() {
            positions[identity(for: entry)] = index
        }

        var added = 0
        var updated = 0
        for record in imported.entries {
            let key = identity(for: record)
            if let index = positions[key] {
                entries[index] = merged(existing: entries[index], imported: record)
                updated += 1
            } else {
                positions[key] = entries.count
                entries.append(record)
                added += 1
            }
        }

        return Result(
            document: TimetableDocument(
                classLabel: nonEmpty(imported.classLabel) ?? existing.classLabel,
                termLabel: nonEmpty(imported.termLabel) ?? existing.termLabel,
                firstImportedDate: min(existing.firstImportedDate, imported.firstImportedDate),
                lastImportedDate: max(existing.lastImportedDate, imported.lastImportedDate),
                entries: entries
            ),
            addedCount: added,
            updatedCount: updated
        )
    }

    private static func merged(existing: TimetableRecord, imported: TimetableRecord) -> TimetableRecord {
        let previous = existing.entry
        let incoming = imported.entry
        return TimetableRecord(
            date: imported.date,
            teachingWeek: imported.teachingWeek ?? existing.teachingWeek,
            entry: TimetableEntrySnapshot(
                id: previous.id,
                kind: incoming.kind,
                title: nonEmpty(incoming.title) ?? previous.title,
                startTime: incoming.startTime ?? previous.startTime,
                endTime: incoming.endTime ?? previous.endTime,
                periodLabel: incoming.periodLabel ?? previous.periodLabel,
                location: incoming.location ?? previous.location,
                instructor: incoming.instructor ?? previous.instructor,
                note: incoming.note ?? previous.note
            )
        )
    }

    private static func identity(for record: TimetableRecord) -> String {
        let rawEntry = record.entry
        let presentation = StudyRocketTimetableCourseCatalog.presentation(
            kind: rawEntry.kind,
            title: rawEntry.title
        )
        return [
            record.date,
            normalized(presentation.title),
            rawEntry.startTime ?? "",
            rawEntry.periodLabel ?? "",
            presentation.kind.rawValue
        ]
        .joined(separator: "\u{1f}")
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    private static func normalized(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }
}
