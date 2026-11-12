import Foundation

/// Keeps the original document and its two activity sources separate. Opening
/// the editor must never normalize Markdown or create an empty events block.
public struct OneOffEventEditorDocument: Sendable {
    public let source: String
    public let events: [OneOffEvent]
    public let timetableActivities: [TimetableRecord]

    public init(source: String) throws {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaskLinkageError.malformed
        }
        let lines = source.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let hasTimetable = source.contains("studyrocket:timetable:")
        let hasEvents = source.contains("studyrocket:events:")
        guard hasTimetable || hasEvents else { throw TaskLinkageError.malformed }
        if hasTimetable {
            guard lines.filter({ $0 == "<!-- studyrocket:timetable:start -->" }).count == 1,
                  lines.filter({ $0 == "<!-- studyrocket:timetable:end -->" }).count == 1 else {
                throw TaskLinkageError.malformed
            }
            timetableActivities = try StudyRocketTimetableParser.document(from: source).entries.filter { $0.entry.kind == .event }
        } else {
            timetableActivities = []
        }
        events = try OneOffSchedule.read(source)
        if hasEvents {
            // OneOffSchedule deliberately accepts documents with no events block;
            // a damaged marker must not be mistaken for an empty activity list.
            let exactLines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            guard exactLines.filter({ $0 == OneOffSchedule.startMarker }).count == 1,
                  exactLines.filter({ $0 == OneOffSchedule.endMarker }).count == 1 else {
                throw TaskLinkageError.malformed
            }
        }
        self.source = source
    }

    public func hasChanges(_ candidate: [OneOffEvent]) -> Bool {
        events.sorted { $0.id < $1.id } != candidate.sorted { $0.id < $1.id }
    }

    public func preview(_ candidate: [OneOffEvent]) throws -> String {
        try OneOffSchedule.validate(candidate)
        guard hasChanges(candidate) else { return source }
        return try OneOffSchedule.write(candidate, in: source)
    }
}

#if canImport(SwiftUI)
import SwiftUI

public struct OneOffEventEditor: View {
    private let source: String
    private let save: ([OneOffEvent]) async throws -> Void
    private let sourceError: String?
    private let document: OneOffEventEditorDocument?
    @Environment(\.dismiss) private var dismiss
    @State private var events: [OneOffEvent]
    @State private var editingID: String?
    @State private var date = Date()
    @State private var title = ""
    @State private var start = ""
    @State private var end = ""
    @State private var location = ""
    @State private var note = ""
    @State private var message: String?
    @State private var isSaving = false
    @State private var previewSource: String?
    @State private var previewEvents: [OneOffEvent]?
    @State private var conflicts: [String: String] = [:]
    @State private var previewGeneration = 0

    public init(source: String, save: @escaping ([OneOffEvent]) async throws -> Void) {
        self.source = source
        self.save = save
        do {
            let document = try OneOffEventEditorDocument(source: source)
            self.document = document
            _events = State(initialValue: document.events)
            sourceError = nil
        } catch {
            document = nil
            _events = State(initialValue: [])
            sourceError = "活动记录暂时无法读取，请关闭并刷新课表后重试。原记录未改动。"
        }
    }

    public var body: some View {
        presentation
            .environment(\.timeZone, PlanningDate.calendar.timeZone)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .interactiveDismissDisabled(isSaving)
            .onChange(of: events) { _, _ in previewGeneration += 1 }
            .task(id: previewGeneration) { await updatePreview() }
    }

    @ViewBuilder private var presentation: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("单次活动").studyTypography(.title2)
                Text("安排一次训练、会议或其他到场活动。确认后保存到课表。")
                    .studyTypography(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            Divider()
            editor
            Divider()
            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                StudyButton("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                saveButton.keyboardShortcut(.defaultAction)
            }.padding(20)
        }.frame(width: 620, height: 660)
        #else
        NavigationStack {
            editor.navigationTitle("单次活动").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { StudyButton("取消") { dismiss() }.disabled(isSaving) }
                    ToolbarItem(placement: .confirmationAction) { saveButton }
                }
        }
        #endif
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let sourceError { StudyLabel(sourceError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if let activities = document?.timetableActivities, !activities.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("这些安排已在课表中，调整可在学业对话中提出。")
                                .studyTypography(.callout).foregroundStyle(.secondary)
                            ForEach(activities) { record in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.entry.title).studyTypography(.body, weight: .medium)
                                    Text([record.date, record.entry.startTime.map { $0 + (record.entry.endTime.map { "–" + $0 } ?? "") }, record.entry.location]
                                        .compactMap { $0 }.joined(separator: " · "))
                                        .studyTypography(.callout).foregroundStyle(.secondary)
                                }
                            }
                        }.padding(.top, 10)
                    } label: {
                        StudyLabel("课表已有活动 · \(activities.count)", systemImage: "calendar")
                            .studyTypography(.headline)
                    }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        field("名称", placeholder: "例如：羽毛球队训练", text: $title)
                        #if os(macOS)
                        HStack {
                            Text("日期").studyTypography(.callout).foregroundStyle(.secondary)
                            StudyRocketCalendarPicker("活动日期", selection: $date)
                        }
                        #else
                        DatePicker("日期", selection: $date, displayedComponents: .date).datePickerStyle(.compact)
                        #endif
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 16) { timeFields }
                            VStack(alignment: .leading, spacing: 14) { timeFields }
                        }
                        field("地点", placeholder: "选填", text: $location)
                        field("说明", placeholder: "选填，例如到场要求", text: $note)
                        HStack {
                            if editingID != nil { StudyButton("取消编辑") { clearFields() }.buttonStyle(.borderless) }
                            Spacer()
                            StudyButton(editingID == nil ? "加入活动" : "更新活动", action: addToPreview)
                                .buttonStyle(.bordered).disabled(isSaving || sourceError != nil)
                        }
                    }.padding(8)
                } label: { StudyLabel(editingID == nil ? "新增活动" : "编辑活动", systemImage: "calendar.badge.plus") }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("单独添加的活动").studyTypography(.headline)
                        Text("\(events.count)").studyTypography(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if events.isEmpty {
                        Text("尚未单独添加活动。课表已有安排会继续保留。")
                            .studyTypography(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
                    } else {
                        ForEach(events.sorted { ($0.date, $0.start) < ($1.date, $1.start) }) { event in
                            eventRow(event)
                        }
                    }
                }
                if document?.hasChanges(events) == true, previewEvents == events, let previewSource, previewSource != source {
                    DisclosureGroup("查看本次变更") {
                        StudyProposalDiffView(original: source, proposed: previewSource).padding(.top, 10)
                    }
                }
                if let message { StudyLabel(message, systemImage: "exclamationmark.circle").studyTypography(.callout).foregroundStyle(.orange) }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.disabled(isSaving)
    }

    private var timeFields: some View {
        Group {
            field("开始", placeholder: "19:00", text: $start)
            field("结束", placeholder: "选填，例 21:00", text: $end)
        }
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).studyTypography(.callout).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func eventRow(_ event: OneOffEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title).studyTypography(.body, weight: .medium)
                    Text("\(event.date) · \(event.start)\(event.end.map { "–" + $0 } ?? "")")
                        .studyTypography(.callout).monospacedDigit().foregroundStyle(.secondary)
                    if let location = event.location, !location.isEmpty { Text(location).studyTypography(.callout).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    StudyButton("编辑") { edit(event) }
                    StudyButton("删除活动", role: .destructive) { events.removeAll { $0.id == event.id } }
                } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }
                    .menuStyle(.borderlessButton).accessibilityLabel("\(event.title)的操作")
            }
            if let conflict = conflicts[event.id] {
                Text(conflict).studyTypography(.callout).foregroundStyle(.orange)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private var saveButton: some View {
        StudyButton(isSaving ? "正在保存…" : "确认并保存") {
            guard let document, document.hasChanges(events), previewEvents == events else { return }
            guard title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                message = "请先将正在编辑的活动加入列表。"; return
            }
            isSaving = true
            Task {
                defer { isSaving = false }
                do {
                    _ = try document.preview(events)
                    try await save(events)
                    dismiss()
                } catch { message = error.localizedDescription }
            }
        }.buttonStyle(.borderedProminent).disabled(isSaving || sourceError != nil || document?.hasChanges(events) != true || previewEvents != events || previewSource == nil || previewSource == source)
    }

    private func addToPreview() {
        let event = OneOffEvent(id: editingID ?? UUID().uuidString, date: PlanningDate.key(date), start: start,
            end: end.isEmpty ? nil : end, title: title, location: location.isEmpty ? nil : location, note: note.isEmpty ? nil : note)
        do {
            try OneOffSchedule.validate([event])
            events.removeAll { $0.id == event.id }
            events.append(event)
            clearFields()
            message = nil
        } catch { message = "请填写活动名称和有效的开始时间（HH:mm）；结束时间应晚于开始时间。" }
    }

    private func edit(_ event: OneOffEvent) {
        editingID = event.id
        date = PlanningDate.date(event.date) ?? .now
        title = event.title; start = event.start; end = event.end ?? ""
        location = event.location ?? ""; note = event.note ?? ""
        message = nil
    }

    private func clearFields() {
        editingID = nil; title = ""; start = ""; end = ""; location = ""; note = ""
    }

    private func updatePreview() async {
        guard let document, sourceError == nil else { return }
        let snapshot = events
        // Parse once per distinct date, off the UI executor, and only after the
        // event list changes. Typing in a form field never reparses the timetable.
        let work = Task.detached(priority: .userInitiated) { () -> (String?, [String: String]) in
            guard let candidate = try? document.preview(snapshot) else { return (nil, [:]) }
            var warnings: [String: String] = [:]
            for date in Set(snapshot.map(\.date)) {
                if Task.isCancelled { return (nil, [:]) }
                guard let value = PlanningDate.date(date) else { continue }
                let timetable = StudyRocketTimetableParser.snapshot(from: candidate, now: value)
                for entry in timetable.days.first(where: { $0.id == date })?.entries ?? [] {
                    if let note = entry.note, note.contains("⚠️") { warnings[entry.id] = note }
                }
            }
            return (candidate, warnings)
        }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !Task.isCancelled, events == snapshot else { return }
        previewSource = result.0
        previewEvents = snapshot
        conflicts = result.1
    }
}
#endif
