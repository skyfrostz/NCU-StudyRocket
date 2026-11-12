import SwiftUI
import StudyRocketShared

/// The overview reads the named columns and sections of the existing academic files.
/// Keep a missing value distinct from an actual achievement.
private struct AcademicSource {
    var rows: [[String: String]] = []
    var sections: [(heading: String, lines: [String])] = []
    var updated = ""

    init(_ markdown: String = "") {
        var header: [String] = []
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("|"), line.hasSuffix("|") {
                let cells = line.dropFirst().dropLast().components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if header.isEmpty { header = cells }
                else if cells.count == header.count, !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) {
                    var row: [String: String] = [:]
                    for (name, value) in zip(header, cells) { row[name] = value }
                    rows.append(row)
                }
                continue
            }
            header = []
            if line.hasPrefix("#") {
                sections.append((String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces), []))
            } else if line.hasPrefix(">") {
                if let match = line.range(of: #"更新日期[：:]\s*[0-9]{4}-[0-9]{2}(-[0-9]{2})?"#, options: .regularExpression) {
                    updated = String(line[match]).replacingOccurrences(of: "更新日期", with: "看板更新")
                }
            } else if !sections.isEmpty, !line.isEmpty, !line.hasPrefix("<!--") {
                let text = line.replacingOccurrences(of: #"^(?:- \[[ xX]\] |- |\d+\. )"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                sections[sections.count - 1].lines.append(line.lowercased().hasPrefix("- [x] ") ? "已完成 · " + text : text)
            }
        }
    }

    func lines(_ heading: String) -> [String] {
        sections.first { $0.heading.contains(heading) }?.lines ?? []
    }
}

private enum BoardFile: String, CaseIterable {
    case courses = "工作台/航线/课程.md"
    case research = "工作台/航线/科研.md"
    case admission = "工作台/航线/保研.md"
    case life = "工作台/航线/生活.md"
    case board = "保研/保研进度看板.md"
    case targets = "保研/目标院校库.md"
    case policy = "保研/保研政策与时间线.md"
    case checklist = "保研/背景提升清单.md"
}

private struct OverviewItem: Identifiable {
    let title: String
    let symbol: String
    let summary: String
    let detail: [(String, [String])]
    let source: BoardFile
    var id: String { title }
}

private struct BoardContent {
    var sources: [BoardFile: AcademicSource] = [:]
    var unreadable: Set<BoardFile> = []
    var timetable: TimetableSnapshot?
    var timetableUnavailable = false
    init() {}
    init(root: URL) {
        let repo = MarkdownRepository(root: root)
        for file in BoardFile.allCases {
            do { sources[file] = AcademicSource(try repo.read(file.rawValue)) }
            catch { unreadable.insert(file) }
        }
        do { timetable = StudyRocketTimetableParser.snapshot(from: try repo.read(StudyRocketTimetableParser.sourceFile)) }
        catch { timetableUnavailable = true }
    }

    subscript(_ file: BoardFile) -> AcademicSource { sources[file] ?? AcademicSource() }
    var rules: [String] { self[.admission].lines("新专业推免规则").filter { $0.contains("待核实") } }
    var actions: [String] { self[.board].rows.compactMap { row in
        guard let name = row["维度"], let next = row["下一步动作"], !next.isEmpty else { return nil }
        return name + " · " + next
    } }
    var goals: [String] { self[.board].rows.compactMap { row in
        guard let name = row["维度"], let goal = row["阶段目标"], !goal.isEmpty else { return nil }
        return name + " · " + goal
    } }

    var routes: [OverviewItem] {
        let courseRows = self[.courses].rows.filter { $0["课程名"] != nil }
        let courseDetails = courseRows.map { row in
            [row["课程名"], row["进度"], row["最近作业/考试"].flatMap { $0 == "待补" ? nil : "作业／考试：" + $0 }].compactMap { $0 }.joined(separator: " · ")
        }
        let schedule = (timetable?.days ?? []).flatMap { day in
            day.entries.map { entry in
                [day.dateLabel, entry.timeText, StudyRocketTimetableCourseCatalog.displayTitle(for: entry.title).primary, entry.location].compactMap { $0 }.joined(separator: " · ")
            }
        }
        let research = self[.research].lines("方向探索")
        let buffer = self[.life].lines("缓冲块")
        return [
            .init(title: "课程", symbol: "books.vertical", summary: courseRows.isEmpty ? "尚无课程进度" : "已列入 \(courseRows.count) 门课程 · 查看进度与近期作业", detail: [("课程进度与作业", courseDetails), ("本周课表", schedule)], source: .courses),
            .init(title: "科研", symbol: "magnifyingglass", summary: research.first ?? "尚无研究方向记录", detail: [("方向与下一步", research), ("高中阶段的项目基础", self[.research].lines("既往项目"))], source: .research),
            .init(title: "保研", symbol: "graduationcap", summary: rules.first ?? "查看申请节点与材料", detail: [("待核实的规则", rules), ("夏令营", self[.admission].lines("夏令营")), ("推免系统", self[.admission].lines("推免系统")), ("申请材料", self[.admission].lines("文书材料"))], source: .admission),
            .init(title: "生活", symbol: "leaf", summary: buffer.first ?? "查看作息与缓冲安排", detail: [("日常作息", self[.life].lines("日常作息")), ("缓冲安排", buffer)], source: .life)
        ]
    }

    var subjects: [OverviewItem] {
        var items = self[.board].rows.compactMap { row -> OverviewItem? in
            guard let name = row["维度"] else { return nil }
            return .init(title: name, symbol: "list.bullet", summary: row["阶段目标"] ?? "待补充", detail: [
                ("建表时的记录", [row["当前状态"]].compactMap { $0 }), ("阶段目标", [row["阶段目标"]].compactMap { $0 }),
                ("下一步行动", [row["下一步动作"]].compactMap { $0 })], source: .board)
        }
        let targets = self[.targets].rows.compactMap { row -> String? in
            guard let name = row["院校"], !["待填","待补",""].contains(name) else { return nil }
            return [name, row["学院/项目"], row["定位"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        items.append(.init(title: "目标院校", symbol: "building.columns", summary: targets.isEmpty ? "尚未建立目标院校" : "已建档 \(targets.count) 所院校", detail: [("目标院校", targets.isEmpty ? ["尚未建立目标院校"] : targets), ("申请方向", self[.targets].lines("当前方向"))], source: .targets))
        items.append(.init(title: "申请材料", symbol: "folder", summary: "查看材料清单", detail: [("材料准备", self[.admission].lines("文书材料"))], source: .admission))
        items.append(.init(title: "规则核实", symbol: "checklist", summary: "查看待核实事项", detail: [("学院规则", self[.policy].lines("南昌大学待核实清单"))], source: .policy))
        items.append(.init(title: "背景提升", symbol: "flag", summary: "大一可以开始的准备", detail: [("大一值得做", self[.checklist].lines("大一值得做")), ("到大二前的里程碑", self[.checklist].lines("到大二前"))], source: .checklist))
        return items
    }
}

struct AcademicOverview: View {
    let admission: Bool
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var document: MarkdownDocumentModel
    @State private var content = BoardContent()
    @State private var selected: String?
    @State private var editor = false
    @State private var showReadError = false
    @State private var confirmClose = false
    @State private var expandedSummaries: Set<String> = []

    private var title: String { admission ? "保研" : "四条航线" }
    private var items: [OverviewItem] {
        (admission ? content.subjects : content.routes).map { value in
            guard content.unreadable.contains(value.source) else { return value }
            return OverviewItem(title: value.title, symbol: value.symbol, summary: "暂时无法读取来源",
                                detail: value.detail, source: value.source)
        }
    }
    private var item: OverviewItem? { items.first { $0.id == selected } }

    var body: some View {
        PageScaffold {
            VStack(alignment: .leading, spacing: 20) {
                if !content.unreadable.isEmpty || content.timetableUnavailable {
                    StudySurface {
                        VStack(alignment: .leading, spacing: 8) {
                            StudyLabel("部分来源暂时无法读取", systemImage: "exclamationmark.circle")
                                .studyTypography(.headline)
                            Text("已读取的内容仍可查看。检查文件是否存在，或稍后重新读取。")
                                .foregroundStyle(.secondary)
                            DisclosureGroup("查看来源") {
                                ForEach(content.unreadable.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) {
                                    Text($0.rawValue).studyTypography(.caption).textSelection(.enabled)
                                }
                                if content.timetableUnavailable { Text(StudyRocketTimetableParser.sourceFile).studyTypography(.caption) }
                            }
                            StudyButton("重新读取", action: reload)
                        }
                    }
                }
                if let item {
                    StudyButton(title, systemImage: "chevron.left") { selected = nil }.buttonStyle(.link)
                    PageTitleBar(title: item.title, subtitle: item.summary) {
                        if content.sources[item.source] != nil {
                            StudyButton("查看／编辑原文") {
                                document.updateRoot(workspace.rootURL)
                                document.load(item.source.rawValue)
                                editor = document.errorMessage == nil && document.relative == item.source.rawValue
                                showReadError = !editor
                            }
                        }
                    }
                    if !content.unreadable.contains(item.source) {
                        ForEach(item.detail.indices, id: \.self) { index in
                            if item.detail[index].0 == "本周课表", content.timetableUnavailable {
                                Text("课表尚未载入").foregroundStyle(.secondary)
                            } else {
                                linesCard(item.detail[index].0, item.detail[index].1)
                            }
                        }
                    }
                } else {
                    PageTitleBar(title: title, subtitle: admission ? content[.board].updated : "课程、科研、保研与生活") { EmptyView() }
                    if admission {
                        if !content.unreadable.contains(.board) {
                            linesCard("阶段目标", content.goals, previewLimit: 2)
                            linesCard("下一步行动", content.actions, previewLimit: 2)
                        }
                        if !content.unreadable.contains(.admission) { linesCard("待核实的规则", content.rules) }
                        Text("分项查看").studyTypography(.headline)
                    }
                    ForEach(items) { item in
                        Button { selected = item.id } label: {
                            HStack(spacing: 14) {
                                Image(systemName: item.symbol).studyTypography(.title2).foregroundStyle(.tint).frame(width: 32)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.title).studyTypography(.headline)
                                    Text(item.summary).studyTypography(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").studyTypography(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 5).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider()
                    }
                }
            }.frame(maxWidth: 960, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear(perform: reload)
        .onChange(of: workspace.rootURL) { _, _ in selected = nil; reload() }
        .onReceive(NotificationCenter.default.publisher(for: .studyRocketWorkspaceChanged)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .studyRocketTimetableChanged)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
        .alert("无法打开原文", isPresented: $showReadError) { StudyButton("好", role: .cancel) {} } message: {
            Text(document.errorMessage ?? "请检查来源文件是否仍在当前仓库中。")
        }
        .sheet(isPresented: $editor, onDismiss: reload) {
            VStack(alignment: .trailing) {
                MarkdownDocumentView(document: document)
                StudyButton("完成") { if document.isDirty { confirmClose = true } else { editor = false } }.padding()
            }.frame(minWidth: 580, minHeight: 420)
            .interactiveDismissDisabled(document.isDirty)
            .confirmationDialog("保存原文修改？", isPresented: $confirmClose) {
                StudyButton("保存并关闭") { Task { if await document.save() { workspace.notifyWorkspaceChanged(); editor = false } } }
                StudyButton("放弃修改", role: .destructive) { document.text = document.original; editor = false }
                StudyButton("继续编辑", role: .cancel) {}
            }
        }
    }

    private func reload() { content = BoardContent(root: workspace.rootURL) }

    private func linesCard(_ title: String, _ values: [String], previewLimit: Int? = nil) -> some View {
        let isExpanded = expandedSummaries.contains(title)
        let visible = previewLimit.map { isExpanded ? values : Array(values.prefix($0)) } ?? values
        return StudySurface {
            VStack(alignment: .leading, spacing: 9) {
                Text(title).studyTypography(.headline)
                ForEach(Array(visible.enumerated()), id: \.offset) { _, line in Text(verbatim: line).textSelection(.enabled) }
                if values.isEmpty { Text("尚无记录").foregroundStyle(.secondary) }
                if let limit = previewLimit, values.count > limit {
                    StudyButton(isExpanded ? "收起" : "查看全部 \(values.count) 项") {
                        if isExpanded { expandedSummaries.remove(title) } else { expandedSummaries.insert(title) }
                    }.buttonStyle(.link)
                    if !isExpanded { Text("显示 \(visible.count) / \(values.count) 项").studyTypography(.caption).foregroundStyle(.secondary) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
