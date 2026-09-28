import SwiftUI
import WidgetKit

private struct StudyRocketEntry: TimelineEntry {
    let date: Date
    let snapshot: DesktopWidgetSnapshot?
}

private struct StudyRocketProvider: TimelineProvider {
    func placeholder(in context: Context) -> StudyRocketEntry { sample(at: .now) }

    func getSnapshot(in context: Context, completion: @escaping (StudyRocketEntry) -> Void) {
        completion(context.isPreview ? sample(at: .now) : entry(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StudyRocketEntry>) -> Void) {
        let now = Date()
        let midnight = DesktopWidgetSnapshot.nextMidnight(after: now)
        completion(Timeline(entries: [entry(at: now), StudyRocketEntry(date: midnight, snapshot: nil)], policy: .after(midnight.addingTimeInterval(60))))
    }

    private func entry(at date: Date) -> StudyRocketEntry {
        let snapshot = DesktopWidgetSnapshotStore.load().flatMap { $0.day == DesktopWidgetSnapshot.dayKey(date) ? $0 : nil }
        return StudyRocketEntry(date: date, snapshot: snapshot)
    }

    private func sample(at date: Date) -> StudyRocketEntry {
        StudyRocketEntry(date: date, snapshot: DesktopWidgetSnapshot(
            day: DesktopWidgetSnapshot.dayKey(date), updatedAt: date,
            focus: "整理高数课堂笔记", focusPeriod: "晚上",
            tasks: [
                .init(id: "1", period: "上午", title: "完成 Python 练习", completed: true),
                .init(id: "2", period: "晚上", title: "整理高数课堂笔记", completed: false)
            ],
            timetableStatus: "available", hasToday: true,
            lessons: [
                .init(id: "1", time: "08:00", title: "高等数学", location: "主教楼 302"),
                .init(id: "2", time: "14:00", title: "学术英语", location: "综合楼 106")
            ]
        ))
    }
}

@main
struct NCUStudyRocketDesktopWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NCUStudyRocketDesktopWidget", provider: StudyRocketProvider()) { entry in
            StudyRocketWidgetView(entry: entry)
        }
        .configurationDisplayName("StudyRocket 今日安排")
        .description("查看今日课表、待办和现在先做什么。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct StudyRocketWidgetView: View {
    let entry: StudyRocketEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                switch family {
                case .systemSmall: small(snapshot)
                case .systemMedium: medium(snapshot)
                default: large(snapshot)
                }
            } else {
                Label("打开 StudyRocket 更新今日安排", systemImage: "arrow.clockwise")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .privacySensitive()
        .widgetURL(URL(string: "ncustudyrocket-mac://home"))
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
    }

    private func header(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.blue)
            .lineLimit(1)
    }

    private func small(_ snapshot: DesktopWidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header("现在先做什么", symbol: "sparkle")
            if let focus = snapshot.focus {
                if let period = snapshot.focusPeriod {
                    Text(period).font(.caption).foregroundStyle(.secondary)
                }
                Text(focus)
                    .font(.headline)
                    .lineLimit(textSize.isAccessibilitySize ? 2 : 3)
            } else {
                Text(snapshot.tasks.isEmpty ? "今日尚未安排" : "今日安排已完成")
                    .font(.headline)
                    .foregroundStyle(snapshot.tasks.isEmpty ? Color.secondary : Color.green)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Text("\(snapshot.tasks.filter(\.completed).count)/\(snapshot.tasks.count) 已完成")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func medium(_ snapshot: DesktopWidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header("今日课表", symbol: "calendar")
            timetable(snapshot, limit: textSize.isAccessibilitySize ? 2 : 4)
            Spacer(minLength: 0)
        }
    }

    private func large(_ snapshot: DesktopWidgetSnapshot) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                header("今日课表", symbol: "calendar")
                timetable(snapshot, limit: textSize.isAccessibilitySize ? 2 : 5)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                header("今日待办", symbol: "checklist")
                let limit = textSize.isAccessibilitySize ? 2 : 5
                if snapshot.tasks.isEmpty {
                    Text("今日尚未安排").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(snapshot.tasks.prefix(limit))) { task in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(task.completed ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.period).font(.caption2).foregroundStyle(.secondary)
                                Text(task.title).font(.caption).lineLimit(2)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(task.period)，\(task.completed ? "已完成" : "未完成")，\(task.title)")
                    }
                    if snapshot.tasks.count > limit {
                        Text("另有 \(snapshot.tasks.count - limit) 项")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func timetable(_ snapshot: DesktopWidgetSnapshot, limit: Int) -> some View {
        if snapshot.lessons.isEmpty {
            Text(timetableMessage(snapshot))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } else {
            ForEach(Array(snapshot.lessons.prefix(limit))) { lesson in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(lesson.time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lesson.title).font(.caption.weight(.medium)).lineLimit(1)
                        if let location = lesson.location, !textSize.isAccessibilitySize {
                            Text(location).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([lesson.time, lesson.title, lesson.location].compactMap { $0 }.joined(separator: "，"))
            }
            if snapshot.lessons.count > limit {
                Text("另有 \(snapshot.lessons.count - limit) 节")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func timetableMessage(_ snapshot: DesktopWidgetSnapshot) -> String {
        switch snapshot.timetableStatus {
        case "available": return snapshot.hasToday ? "今日无课" : "今日课表待刷新"
        case "notImported": return "课表尚未导入"
        case "invalid": return "课表需要重新导入"
        case "beforeTerm": return "本学期尚未开始"
        case "afterTerm": return "本学期已结束"
        default: return "课表暂不可用"
        }
    }
}
