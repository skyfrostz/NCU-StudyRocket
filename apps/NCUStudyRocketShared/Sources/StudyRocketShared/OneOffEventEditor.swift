#if canImport(SwiftUI)
import SwiftUI

public struct OneOffEventEditor: View {
    private let source: String
    private let save: ([OneOffEvent]) async throws -> Void
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
    public init(source: String, save: @escaping ([OneOffEvent]) async throws -> Void) {
        self.source = source; self.save = save
        _events = State(initialValue: (try? OneOffSchedule.read(source)) ?? [])
    }
    public var body: some View {
        NavigationStack {
            Form {
                Section("当天活动，不重复") {
                    TextField("活动名称", text: $title)
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                    TextField("开始时间，例如 19:00", text: $start)
                    TextField("结束时间，可留空", text: $end)
                    TextField("地点，可留空", text: $location)
                    TextField("说明，可留空", text: $note)
                    Button(editingID == nil ? "加入预览" : "更新预览") {
                        let event = OneOffEvent(id: editingID ?? UUID().uuidString, date: PlanningDate.key(date), start: start,
                            end: end.isEmpty ? nil : end, title: title, location: location.isEmpty ? nil : location, note: note.isEmpty ? nil : note)
                        do {
                            try OneOffSchedule.validate([event])
                            events.removeAll { $0.id == event.id }; events.append(event)
                            editingID = nil; title = ""; start = ""; end = ""; location = ""; note = ""; message = nil
                        } catch { message = "请提供有效日期、名称和开始时间；结束时间应晚于开始时间。" }
                    }
                }
                Section("待保存的活动") {
                    ForEach(events) { event in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(event.date) \(event.start)\(event.end.map { "–" + $0 } ?? "") · \(event.title)")
                            if let location = event.location { Text(location).foregroundStyle(.secondary) }
                            HStack {
                                Button("编辑") {
                                    editingID = event.id; date = PlanningDate.date(event.date) ?? .now; title = event.title
                                    start = event.start; end = event.end ?? ""; location = event.location ?? ""; note = event.note ?? ""
                                }
                                Button("删除", role: .destructive) { events.removeAll { $0.id == event.id } }
                            }
                            if let previewSource = try? OneOffSchedule.write(events, in: source),
                               let eventDate = PlanningDate.date(event.date),
                               let entry = StudyRocketTimetableParser.snapshot(from: previewSource, now: eventDate).days.first(where: { $0.id == event.date })?.entries.first(where: { $0.id == event.id }),
                               entry.note?.contains("⚠️") == true {
                                Text(entry.note ?? "").foregroundStyle(.orange)
                            }
                        }
                    }
                }
                DisclosureGroup("预览活动记录差异") {
                    Text((try? OneOffSchedule.write(events, in: source)) ?? "活动记录无效")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                if let message { Text(message).foregroundStyle(.orange) }
            }.navigationTitle("单次活动")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认并保存") {
                        guard title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { message = "请先将正在编辑的活动加入预览。"; return }
                        isSaving = true
                        Task {
                            defer { isSaving = false }
                            do { _ = try OneOffSchedule.write(events, in: source); try await save(events); dismiss() }
                            catch { message = error.localizedDescription }
                        }
                    }.disabled(isSaving)
                }
            }
        }.environment(\.timeZone, PlanningDate.calendar.timeZone).frame(minWidth: 320, minHeight: 420)
    }
}

#endif
