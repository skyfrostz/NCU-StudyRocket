#if canImport(SwiftUI)
import SwiftUI

/// The editor holds a draft. Only its explicit save button submits a repository change.
public struct TaskLinkageEditor: View {
    private let plan: WeeklyPlanSnapshot
    private let timetableSource: String
    private let save: (WeeklyPlanSnapshot, [OneOffEvent]?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TaskLinkage
    @State private var selectedTask: String?
    @State private var date = Date()
    @State private var period = "morning"
    @State private var message: String?
    @State private var isSaving = false
    @State private var routed: PlanningChangeRouter.SnapshotResult?
    @State private var bulk: LinkedDelivery?
    public init(plan: WeeklyPlanSnapshot, timetableSource: String = "", save: @escaping (WeeklyPlanSnapshot, [OneOffEvent]?) async throws -> Void) {
        self.plan = plan; self.save = save; self.timetableSource = timetableSource
        _draft = State(initialValue: (plan.linkage ?? TaskLinkage(activationDate: PlanningDate.key(.now))).reconciled(with: plan))
    }
    public var body: some View {
        NavigationStack {
            Form {
                Section("任务联动") {
                    Text(plan.linkage == nil ? "启用后，从今天开始把未完成的学习、科研和交办事务结转到本周交付物。更早的历史不会补入。" : "改期保留任务关联；完成后会同时更新今日任务和所属交付物。")
                    Text("原安排日期保留在历史记录中，不会改成原当天完成。")
                        .foregroundStyle(.secondary)
                }
                Section("任务与类别") {
                    ForEach(draft.tasks.filter { !$0.cancelled }) { task in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Button { perform { try draft.setTask(task.id, completed: !task.isCompleted) } } label: {
                                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                                }.buttonStyle(.borderless)
                                TextField("任务", text: Binding(get: { draft.tasks.first(where: { $0.id == task.id })?.text ?? task.text }, set: { value in perform { try draft.rename(task.id, text: value) } })).strikethrough(task.isCompleted)
                            }
                            Text("原安排：\(task.originDate)").studyTypography(.caption).foregroundStyle(.secondary)
                            Picker("类别", selection: Binding(get: { task.category }, set: { category in perform { try draft.classify(task.id, as: category) } })) {
                                ForEach(PlanningCategory.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            Picker("所属交付物", selection: Binding(get: { task.deliveryID ?? "" }, set: { id in perform { try draft.link(task.id, to: id.isEmpty ? nil : id) } })) {
                                Text("独立任务").tag("")
                                ForEach(draft.deliveries.filter { !$0.cancelled }) { Text($0.text).tag($0.id) }
                            }
                            if let due = task.dueAt { Text("截止：" + due.prefix(16).replacingOccurrences(of: "T", with: " ")).studyTypography(.caption) }
                            Picker("提醒／缓冲关联", selection: Binding(get: { task.reminderForTaskID ?? "" }, set: { value in perform { try draft.setReminder(task.id, for: value.isEmpty ? nil : value) } })) {
                                Text("独立工作项").tag("")
                                ForEach(draft.tasks.filter { $0.id != task.id && !$0.cancelled && $0.reminderForTaskID == nil }) { related in
                                    Text("关联：" + related.text).tag(related.id)
                                }
                            }
                            if task.deliveryID == nil, let candidate = draft.deliveries.first(where: { !$0.cancelled && DeliveryPeriodMatcher.matches(deliveryText: $0.text, periodText: task.text) }) {
                                StudyButton("建议关联到：" + candidate.text) { perform { try draft.link(task.id, to: candidate.id) } }
                            }
                            if !task.isCompleted {
                                StudyButton("安排到某日") { selectedTask = task.id }
                            }
                            StudyMenu("其他操作") {
                                ForEach(draft.assignments.filter { $0.active && $0.taskID == task.id }) { a in
                                    StudyButton("移除 \(a.date) 的安排") { perform { try draft.removeAssignment(a.id) } }
                                }
                                StudyButton("取消任务", role: .destructive) { perform { try draft.cancel(task.id) } }
                            }
                        }.padding(.vertical, 4)
                    }
                }
                Section("交付物及已完成记录") {
                    ForEach(draft.deliveries.filter { !$0.cancelled }) { delivery in
                        Button {
                            if draft.isCompleted(delivery) { perform { try draft.setDelivery(delivery.id, completed: false) } }
                            else if draft.pendingChildren(of: delivery.id).isEmpty { perform { try draft.setDelivery(delivery.id, completed: true) } }
                            else { bulk = delivery }
                        } label: {
                            StudyLabel(delivery.text, systemImage: draft.isCompleted(delivery) ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
                Section("改期与历史") {
                    ForEach(draft.assignments.filter { a in !a.active || draft.tasks.first(where: { $0.id == a.taskID })?.completedAt.map { $0 > a.date } == true }) { a in
                        if let task = draft.tasks.first(where: { $0.id == a.taskID }) {
                            Text("\(a.date) · \(task.text) · \(task.completedAt.map { "后来完成于 " + $0 } ?? (task.cancelled ? "已取消" : "已移除或改期"))")
                                .studyTypography(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                DisclosureGroup(plan.linkage == nil ? "预览新增关联记录" : "预览待保存关联记录") {
                    Text((try? TaskLinkageMarkdown.write(draft, in: "")) ?? "关联记录无效")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                if let message { Text(message).foregroundStyle(.orange) }
            }
            .navigationTitle(plan.linkage == nil ? "启用任务联动" : "任务关联与改期")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { StudyButton("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    StudyButton("确认并保存") {
                        do {
                            let prepared = try PlanningChangeRouter.route(plan: draft.projected(plan), timetable: timetableSource)
                            if prepared.events != nil { routed = prepared }
                            else { submit(prepared) }
                        } catch { message = error.localizedDescription }
                    }
                    .disabled(isSaving || draft.tasks.contains { !$0.cancelled && ($0.category == .unclassified && $0.reminderForTaskID == nil) })
                }
            }
            .sheet(isPresented: Binding(get: { routed != nil }, set: { if !$0 { routed = nil } })) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("活动进入当天课表").studyTypography(.title2)
                    Text("确认后同时保存任务关联和单次活动。活动从今日任务移到下列日期。")
                    ScrollView {
                        if let prepared = routed {
                            ForEach(prepared.events ?? []) { event in
                                Text("\(event.date) \(event.start) · \(event.title)").frame(maxWidth: .infinity, alignment: .leading)
                            }
                            DisclosureGroup("任务关联保存后") {
                                Text((try? TaskLinkageMarkdown.write(prepared.plan.linkage ?? draft, in: "")) ?? "")
                                    .studyTypography(.caption).textSelection(.enabled)
                            }
                            DisclosureGroup("课表保存后") {
                                Text((try? OneOffSchedule.write(prepared.events ?? [], in: timetableSource)) ?? "")
                                    .studyTypography(.caption).textSelection(.enabled)
                            }
                        }
                    }
                    if let message { Text(message).foregroundStyle(.orange) }
                    HStack {
                        StudyButton("返回修改") { routed = nil }
                        Spacer()
                        StudyButton("确认并成组保存") { if let prepared = routed { submit(prepared) } }.disabled(isSaving)
                    }
                }.padding().frame(minWidth: 320, minHeight: 420)
            }
            .sheet(isPresented: Binding(get: { selectedTask != nil }, set: { if !$0 { selectedTask = nil } })) {
                NavigationStack {
                    Form {
                        DatePicker("日期", selection: $date, in: Date()..., displayedComponents: .date)
                        Picker("时段", selection: $period) {
                            Text("上午").tag("morning"); Text("中午").tag("noon"); Text("晚上").tag("evening")
                        }
                    }.navigationTitle("安排到某日")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { StudyButton("取消") { selectedTask = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            StudyButton("确定") {
                                if let id = selectedTask { perform { try draft.reschedule(id, date: PlanningDate.key(date), periodID: period) } }
                                selectedTask = nil
                            }
                        }
                    }
                }.frame(minWidth: 300, minHeight: 240)
            }
            .confirmationDialog("将一并完成这些子任务", isPresented: Binding(get: { bulk != nil }, set: { if !$0 { bulk = nil } }), titleVisibility: .visible) {
                if let delivery = bulk {
                    StudyButton("确认全部完成") {
                        perform { try draft.setDelivery(delivery.id, completed: true, confirmedTaskIDs: draft.pendingChildren(of: delivery.id).map(\.id)) }
                        bulk = nil
                    }
                }
                StudyButton("取消", role: .cancel) { bulk = nil }
            } message: {
                Text(bulk.map { draft.pendingChildren(of: $0.id).map(\.text).joined(separator: "\n") } ?? "")
            }
        }
        .environment(\.timeZone, PlanningDate.calendar.timeZone)
        .frame(minWidth: 320, minHeight: 420)
    }
    private func submit(_ prepared: PlanningChangeRouter.SnapshotResult) {
        isSaving = true
        Task {
            defer { isSaving = false }
            do { try await save(prepared.plan, prepared.events); routed = nil; dismiss() }
            catch { message = error.localizedDescription }
        }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); message = nil } catch { message = error.localizedDescription }
    }
}

#endif
