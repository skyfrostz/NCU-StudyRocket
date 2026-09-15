import SwiftUI
import StudyRocketWidgetSupport
import WidgetKit

private struct StudyRocketWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: StudyRocketWidgetSnapshot?
}

private struct StudyRocketWidgetTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> StudyRocketWidgetEntry {
        sampleEntry(at: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (StudyRocketWidgetEntry) -> Void) {
        completion(entry(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StudyRocketWidgetEntry>) -> Void) {
        let now = Date()
        let dayBoundary = StudyRocketWidgetSnapshot.nextDayBoundary(after: now)
        let nextRefresh = StudyRocketWidgetSnapshot.nextDayBoundary(after: dayBoundary)
        let entries = [
            entry(at: now),
            StudyRocketWidgetEntry(date: dayBoundary, snapshot: nil)
        ]
        completion(Timeline(entries: entries, policy: .after(nextRefresh)))
    }

    private func entry(at date: Date) -> StudyRocketWidgetEntry {
        let snapshot = StudyRocketWidgetSnapshotStore.load().flatMap { snapshot in
            snapshot.referenceDay == StudyRocketWidgetSnapshot.dayKey(for: date) ? snapshot : nil
        }
        return StudyRocketWidgetEntry(date: date, snapshot: snapshot)
    }

    private func sampleEntry(at date: Date) -> StudyRocketWidgetEntry {
        StudyRocketWidgetEntry(
            date: date,
            snapshot: StudyRocketWidgetSnapshot(
                referenceDay: StudyRocketWidgetSnapshot.dayKey(for: date),
                updatedAt: date,
                dateLabel: "9月13日 · 周日",
                nextTask: "完成导数例题并整理错题",
                nextTaskPeriodTitle: "上午",
                todayPeriods: [
                    StudyRocketWidgetPeriod(id: "morning", title: "上午", text: "完成导数例题并整理错题", isCompleted: false),
                    StudyRocketWidgetPeriod(id: "noon", title: "中午", text: "复习英语词汇", isCompleted: true),
                    StudyRocketWidgetPeriod(id: "evening", title: "晚上", text: "整理本周交付物", isCompleted: false)
                ],
                completedToday: 1,
                totalToday: 3,
                completedDeliveries: 2,
                totalDeliveries: 5,
                firstOpenDelivery: "完成本周课程笔记",
                timetableStatus: .available,
                hasTodayTimetableDay: true,
                totalTodayLessons: 3,
                todayLessons: [
                    StudyRocketWidgetLesson(id: "math", timeLabel: "08:00\n09:40", title: "高等数学", location: "主教楼 302"),
                    StudyRocketWidgetLesson(id: "python", timeLabel: "10:00\n11:40", title: "Python 程序设计", location: "实验楼 204"),
                    StudyRocketWidgetLesson(id: "english", timeLabel: "14:00\n15:40", title: "学术英语", location: "综合楼 106")
                ]
            )
        )
    }
}

@main
struct NCUStudyRocketWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: StudyRocketWidgetConfiguration.kind, provider: StudyRocketWidgetTimelineProvider()) { entry in
            StudyRocketWidgetView(entry: entry)
        }
        .configurationDisplayName("今日学习")
        .description("查看已同步的今日安排与本周进度。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct StudyRocketWidgetView: View {
    let entry: StudyRocketWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                switch family {
                case .systemSmall:
                    StudyRocketSmallWidget(snapshot: snapshot)
                case .systemMedium:
                    StudyRocketMediumWidget(snapshot: snapshot)
                default:
                    StudyRocketLargeWidget(snapshot: snapshot)
                }
            } else {
                StudyRocketEmptyWidget()
            }
        }
        .privacySensitive()
        .widgetURL(URL(string: "ncustudyrocket://home"))
        .containerBackground(for: .widget) {
            Color(uiColor: .systemBackground)
        }
    }
}

private enum StudyRocketWidgetPalette {
    static let brand = Color(red: 0.03, green: 0.42, blue: 0.86)
    static let completion = Color.teal
}

private struct StudyRocketWidgetHeader: View {
    let dateLabel: String
    var compact = false

    private var displayedDateLabel: String {
        guard compact else { return dateLabel }
        return dateLabel.components(separatedBy: " · ").first ?? dateLabel
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "graduationcap.fill")
                .foregroundStyle(StudyRocketWidgetPalette.brand)
            Text(compact ? "今日" : "StudyRocket")
                .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 6)
            Text(displayedDateLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
        }
    }
}

private struct StudyRocketFocus: View {
    let snapshot: StudyRocketWidgetSnapshot
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack(spacing: 5) {
                Text(snapshot.nextTaskPeriodTitle ?? "现在先做什么")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudyRocketWidgetPalette.brand)
                Spacer(minLength: 4)
                StudyRocketProgress(completed: snapshot.completedToday, total: snapshot.totalToday, compact: true)
            }
            if let task = snapshot.nextTask {
                Text(task)
                    .font(compact ? .headline : .title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(compact ? 2 : 3)
                    .fixedSize(horizontal: false, vertical: true)
            } else if snapshot.totalToday > 0 {
                Label("今日安排已完成", systemImage: "checkmark.seal.fill")
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                    .foregroundStyle(StudyRocketWidgetPalette.completion)
                    .lineLimit(2)
            } else {
                Text("今日尚未安排")
                    .font(compact ? .subheadline.weight(.medium) : .headline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct StudyRocketProgress: View {
    let completed: Int
    let total: Int
    var compact = false

    var body: some View {
        let progress = total == 0 ? 0 : Double(completed) / Double(total)
        HStack(spacing: 5) {
            if !compact {
                Text("今日")
                    .foregroundStyle(.secondary)
            }
            Text(total == 0 ? "未安排" : "\(completed)/\(total)")
                .monospacedDigit()
                .foregroundStyle(total > 0 && completed == total ? StudyRocketWidgetPalette.completion : .secondary)
            if !compact, total > 0 {
                ProgressView(value: progress)
                    .tint(StudyRocketWidgetPalette.completion)
                    .frame(width: 54)
            }
        }
        .font(.caption.weight(.medium))
        .accessibilityLabel(total == 0 ? "今日未安排" : "今日完成 \(completed)，共 \(total) 项")
    }
}

private struct StudyRocketTaskRow: View {
    let period: StudyRocketWidgetPeriod
    var compact = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: period.isCompleted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(period.isCompleted ? StudyRocketWidgetPalette.completion : .secondary)
                .font(.caption)
                .frame(width: 14, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(period.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(period.text)
                    .font(.caption)
                    .foregroundStyle(period.isCompleted ? .secondary : .primary)
                    .lineLimit(compact && !dynamicTypeSize.isAccessibilitySize ? 1 : 2)
                    .strikethrough(period.isCompleted, color: .secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let status = period.isCompleted ? "已完成" : "未完成"
        return "\(period.title)，\(status)，\(period.text)"
    }
}

private struct StudyRocketWidgetSectionHeader: View {
    let title: String
    let systemImage: String
    var trailingText: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudyRocketWidgetPalette.brand)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 2)
            if let trailingText {
                Text(trailingText)
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct StudyRocketLessonRow: View {
    let lesson: StudyRocketWidgetLesson
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isAccessibilitySize: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        Group {
            if isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    Text(lesson.timeLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(lesson.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
            } else {
                HStack(alignment: .top, spacing: 7) {
                    Text(lesson.timeLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .frame(width: 34, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lesson.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        if let location = lesson.location {
                            Label(location, systemImage: "mappin.and.ellipse")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lessonAccessibilityLabel)
    }

    private var lessonAccessibilityLabel: String {
        [
            lesson.timeLabel.replacingOccurrences(of: "\n", with: "至"),
            lesson.title,
            lesson.location
        ]
        .compactMap { $0 }
        .joined(separator: "，")
    }
}

private struct StudyRocketTimetableState: View {
    let status: StudyRocketWidgetTimetableStatus
    let hasTodayTimetableDay: Bool

    private var message: String {
        switch status {
        case .available:
            hasTodayTimetableDay ? "今日无课" : "今日课表待刷新"
        case .unavailable:
            "课表暂不可用"
        case .notImported:
            "课程表尚未导入"
        case .invalid:
            "课程表需重新导入"
        case .beforeTerm:
            "本学期尚未开始"
        case .afterTerm:
            "本学期已结束"
        }
    }

    private var symbol: String {
        switch status {
        case .available:
            hasTodayTimetableDay ? "calendar" : "calendar.badge.clock"
        case .unavailable:
            "calendar.badge.questionmark"
        case .notImported:
            "calendar.badge.plus"
        case .invalid:
            "calendar.badge.exclamationmark"
        case .beforeTerm, .afterTerm:
            "calendar.badge.clock"
        }
    }

    var body: some View {
        Label(message, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

private struct StudyRocketTimetableColumn: View {
    let snapshot: StudyRocketWidgetSnapshot
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var visibleLessons: [StudyRocketWidgetLesson] {
        Array(snapshot.todayLessons.prefix(dynamicTypeSize.isAccessibilitySize ? 2 : 4))
    }

    private var hiddenLessonCount: Int {
        max(0, snapshot.totalTodayLessons - visibleLessons.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StudyRocketWidgetSectionHeader(title: "今日课表", systemImage: "calendar")
            if snapshot.todayLessons.isEmpty {
                StudyRocketTimetableState(
                    status: snapshot.timetableStatus,
                    hasTodayTimetableDay: snapshot.hasTodayTimetableDay
                )
            } else {
                ForEach(visibleLessons) { lesson in
                    StudyRocketLessonRow(lesson: lesson)
                }
                if hiddenLessonCount > 0 {
                    Text("另有 \(hiddenLessonCount) 节课程")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct StudyRocketTodoColumn: View {
    let snapshot: StudyRocketWidgetSnapshot
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var visiblePeriods: [StudyRocketWidgetPeriod] {
        Array(snapshot.todayPeriods.prefix(dynamicTypeSize.isAccessibilitySize ? 2 : 3))
    }

    private var hiddenPeriodCount: Int {
        max(0, snapshot.totalToday - visiblePeriods.count)
    }

    private var progressText: String {
        snapshot.totalToday == 0 ? "未安排" : "完成 \(snapshot.completedToday)/\(snapshot.totalToday)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StudyRocketWidgetSectionHeader(
                title: "今日待办",
                systemImage: "checklist",
                trailingText: dynamicTypeSize.isAccessibilitySize ? nil : progressText
            )
            if snapshot.todayPeriods.isEmpty {
                Text("今日尚未安排")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visiblePeriods) { period in
                    StudyRocketTaskRow(period: period, compact: true)
                }
                if hiddenPeriodCount > 0 {
                    Text("另有 \(hiddenPeriodCount) 项待办")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct StudyRocketSyncLabel: View {
    let date: Date

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.2.circlepath")
            Text("更新")
            Text(date, format: .dateTime.hour().minute())
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

private struct StudyRocketSmallWidget: View {
    let snapshot: StudyRocketWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StudyRocketWidgetHeader(dateLabel: snapshot.dateLabel, compact: true)
            StudyRocketFocus(snapshot: snapshot)
            Spacer(minLength: 0)
            HStack {
                StudyRocketProgress(completed: snapshot.completedToday, total: snapshot.totalToday)
                Spacer(minLength: 6)
                StudyRocketSyncLabel(date: snapshot.updatedAt)
            }
        }
    }
}

private struct StudyRocketMediumWidget: View {
    let snapshot: StudyRocketWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StudyRocketWidgetHeader(dateLabel: snapshot.dateLabel)
            HStack(alignment: .top, spacing: 16) {
                StudyRocketFocus(snapshot: snapshot, compact: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(snapshot.todayPeriods.prefix(2))) { period in
                        StudyRocketTaskRow(period: period)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            HStack {
                Text(snapshot.totalDeliveries == 0 ? "本周暂无交付物" : "本周交付物 \(snapshot.completedDeliveries)/\(snapshot.totalDeliveries)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                StudyRocketSyncLabel(date: snapshot.updatedAt)
            }
        }
    }
}

private struct StudyRocketLargeWidget: View {
    let snapshot: StudyRocketWidgetSnapshot
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StudyRocketWidgetHeader(dateLabel: snapshot.dateLabel)
            HStack(alignment: .top, spacing: 12) {
                StudyRocketTimetableColumn(snapshot: snapshot)
                Divider()
                StudyRocketTodoColumn(snapshot: snapshot)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if !dynamicTypeSize.isAccessibilitySize {
                HStack {
                    Spacer(minLength: 0)
                    StudyRocketSyncLabel(date: snapshot.updatedAt)
                }
            }
        }
    }
}

private struct StudyRocketEmptyWidget: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "graduationcap.fill")
                    .foregroundStyle(StudyRocketWidgetPalette.brand)
                Text("StudyRocket")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text("暂无今日安排")
                .font(.headline)
            Text("打开 StudyRocket 刷新")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
