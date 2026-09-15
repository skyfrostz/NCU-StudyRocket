import AppKit
import SwiftUI
import UniformTypeIdentifiers
import StudyRocketShared
import StudyRocketTimetableImport

extension Notification.Name {
    static let studyRocketTimetableChanged = Notification.Name("studyrocket.timetable.changed")
}

struct TimetableView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model = TimetablePageModel()
    @State private var showImporter = false
    @State private var weekNavigationDirection: TimetableWeekNavigationDirection = .next

    var body: some View {
        PageScaffold {
            VStack(alignment: .leading, spacing: StudyRocketTheme.sectionGap) {
                PageTitleBar(title: "课表", subtitle: model.subtitle) {
                    Button {
                        showImporter = true
                    } label: {
                        Label("导入课表", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("选择 Excel、CSV 或 StudyRocket 课表 Markdown")
                }

                if let pending = model.pendingImport {
                    TimetableImportPreviewCard(
                        pending: pending,
                        save: { model.savePendingImport(workspace: workspace) },
                        discard: model.discardPendingImport
                    )
                }

                if let range = model.weekRange {
                    TimetableWeekNavigator(
                        snapshot: model.selectedSnapshot,
                        range: range,
                        select: selectWeek
                    )
                    TimetableWeekTransitionContainer(
                        snapshot: model.selectedSnapshot,
                        direction: weekNavigationDirection,
                        reduceMotion: reduceMotion
                    )
                } else {
                    TimetableUnavailableState(snapshot: model.currentSnapshot)
                }

                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: TimetableImportFileTypes.supported
        ) { result in
            guard case .success(let url) = result else { return }
            model.stageImport(from: url)
        }
        .onAppear { model.load(from: workspace.rootURL) }
        .onChange(of: workspace.rootURL) { _, root in model.load(from: root) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard model.pendingImport == nil else { return }
            model.load(from: workspace.rootURL)
        }
    }

    private func selectWeek(_ week: Int, direction: TimetableWeekNavigationDirection) {
        guard model.selectedSnapshot.teachingWeek != week else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.14) : .easeInOut(duration: 0.22)) {
            weekNavigationDirection = direction
            model.selectWeek(week)
        }
    }
}

@MainActor
private final class TimetablePageModel: ObservableObject {
    struct PendingImport: Identifiable, Equatable {
        let preview: TimetableImportPreview
        let mergedDocument: TimetableDocument
        let managedMarkdown: String
        let addedCount: Int
        let updatedCount: Int

        var id: String { preview.fileName + managedMarkdown }
    }

    @Published private(set) var currentSnapshot = StudyRocketTimetableParser.snapshot(from: nil)
    @Published private(set) var selectedSnapshot = StudyRocketTimetableParser.snapshot(from: nil)
    @Published private(set) var weekRange: ClosedRange<Int>?
    @Published private(set) var pendingImport: PendingImport?
    @Published private(set) var errorMessage: String?

    private var root: URL?
    private var source = ""
    private var loadedHash = ""
    private var document: TimetableDocument?
    private var selectedWeek = 1

    var subtitle: String {
        guard let document else { return "尚未导入课表" }
        return "\(document.classLabel) · \(document.termLabel)"
    }

    func load(from root: URL) {
        self.root = root
        let repository = MarkdownRepository(root: root)
        source = (try? repository.read(StudyRocketTimetableParser.sourceFile)) ?? ""
        loadedHash = repository.hash(source)
        document = try? StudyRocketTimetableParser.document(from: source)
        weekRange = StudyRocketTimetableParser.teachingWeekRange(from: source)
        currentSnapshot = StudyRocketTimetableParser.snapshot(from: source)
        if let range = weekRange {
            let currentWeek = currentSnapshot.teachingWeek
            selectedWeek = min(max(currentWeek ?? range.lowerBound, range.lowerBound), range.upperBound)
            selectedSnapshot = StudyRocketTimetableParser.snapshot(from: source, teachingWeek: selectedWeek)
        } else {
            selectedSnapshot = currentSnapshot
        }
        pendingImport = nil
        errorMessage = nil
    }

    func selectWeek(_ week: Int) {
        guard let range = weekRange, range.contains(week) else { return }
        selectedWeek = week
        selectedSnapshot = StudyRocketTimetableParser.snapshot(from: source, teachingWeek: week)
    }

    func stageImport(from fileURL: URL) {
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }
        do {
            let defaults = TimetableImportDefaults(
                classLabel: document?.classLabel ?? StudyRocketTimetableParser.defaultClassLabel,
                termLabel: document?.termLabel ?? "2026-2027 秋季学期",
                maximumTeachingWeek: weekRange?.upperBound ?? 16
            )
            let preview = try StudyRocketTimetableImport.preview(fileURL: fileURL, defaults: defaults)
            let merge = StudyRocketTimetableDocumentMerge.merge(existing: document, imported: preview.document)
            let managedMarkdown = StudyRocketTimetableParser.managedMarkdown(for: merge.document)
            let validated = try StudyRocketTimetableParser.document(from: managedMarkdown)
            pendingImport = PendingImport(
                preview: preview,
                mergedDocument: validated,
                managedMarkdown: managedMarkdown,
                addedCount: merge.addedCount,
                updatedCount: merge.updatedCount
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func discardPendingImport() {
        pendingImport = nil
        errorMessage = nil
    }

    func savePendingImport(workspace: WorkspaceStore) {
        guard let root, let pendingImport else { return }
        let repository = MarkdownRepository(root: root)
        do {
            let replacement = replaceManagedBlock(in: source, with: pendingImport.managedMarkdown, document: pendingImport.mergedDocument)
            try repository.save(replacement, relative: StudyRocketTimetableParser.sourceFile, loadedHash: loadedHash)
            source = replacement
            loadedHash = repository.hash(replacement)
            document = pendingImport.mergedDocument
            weekRange = StudyRocketTimetableParser.teachingWeekRange(from: replacement)
            currentSnapshot = StudyRocketTimetableParser.snapshot(from: replacement)
            if let range = weekRange {
                selectedWeek = min(max(selectedWeek, range.lowerBound), range.upperBound)
                selectedSnapshot = StudyRocketTimetableParser.snapshot(from: replacement, teachingWeek: selectedWeek)
            }
            self.pendingImport = nil
            errorMessage = nil
            workspace.refreshMarkdownIndex()
            workspace.refreshGitStatus()
            NotificationCenter.default.post(name: .studyRocketTimetableChanged, object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func replaceManagedBlock(in source: String, with block: String, document: TimetableDocument) -> String {
        let start = "<!-- studyrocket:timetable:start -->"
        let end = "<!-- studyrocket:timetable:end -->"
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            let title = "# \(document.termLabel)个人课表"
            let prefix = source.trimmingCharacters(in: .whitespacesAndNewlines)
            return prefix.isEmpty ? "\(title)\n\n\(block)\n" : "\(prefix)\n\n\(block)\n"
        }
        var updated = source
        updated.replaceSubrange(startRange.lowerBound..<endRange.upperBound, with: block)
        return updated
    }
}

private enum TimetableWeekNavigationDirection {
    case previous
    case next

    var insertionEdge: Edge {
        switch self {
        case .previous: .leading
        case .next: .trailing
        }
    }

    var removalEdge: Edge {
        switch self {
        case .previous: .trailing
        case .next: .leading
        }
    }
}

private enum TimetableImportFileTypes {
    static let supported: [UTType] = [
        UTType(filenameExtension: "xlsx") ?? .data,
        .commaSeparatedText,
        .plainText
    ]
}

private struct TimetableImportPreviewCard: View {
    let pending: TimetablePageModel.PendingImport
    let save: () -> Void
    let discard: () -> Void

    var body: some View {
        StudySurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label("导入预览", systemImage: "doc.badge.arrow.up")
                        .font(.headline)
                    Spacer(minLength: 12)
                    Text(pending.preview.format.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("文件", value: pending.preview.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                LabeledContent("范围", value: "\(pending.mergedDocument.firstImportedDate) 至 \(pending.mergedDocument.lastImportedDate)")
                LabeledContent("课程记录", value: "新增 \(pending.addedCount) 条，更新 \(pending.updatedCount) 条")
                ForEach(pending.preview.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button("保存课表", systemImage: "square.and.arrow.down") { save() }
                        .buttonStyle(.borderedProminent)
                    Button("放弃导入", role: .cancel) { discard() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }
}

private struct TimetableWeekNavigator: View {
    let snapshot: TimetableSnapshot
    let range: ClosedRange<Int>
    let select: (Int, TimetableWeekNavigationDirection) -> Void

    var body: some View {
        let currentWeek = snapshot.teachingWeek ?? range.lowerBound
        VStack(spacing: 3) {
            ZStack {
                Menu {
                    ForEach(Array(range), id: \.self) { week in
                        Button {
                            select(week, week < currentWeek ? .previous : .next)
                        } label: {
                            if week == currentWeek {
                                Label("第\(week)周", systemImage: "checkmark")
                            } else {
                                Text("第\(week)周")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(snapshot.weekLabel ?? "第\(currentWeek)周")
                            .font(.headline)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .padding(.horizontal, 56)
                .accessibilityLabel("教学周")
                .accessibilityValue("第\(currentWeek)周")
                .accessibilityHint("选择要查看的教学周")

                HStack(spacing: 0) {
                    StudyIconButton(
                        systemImage: "chevron.left",
                        label: "上一周",
                        action: { select(currentWeek - 1, .previous) },
                        disabled: currentWeek <= range.lowerBound
                    )
                    .frame(width: 44, height: 44)
                    Spacer(minLength: 0)
                    StudyIconButton(
                        systemImage: "chevron.right",
                        label: "下一周",
                        action: { select(currentWeek + 1, .next) },
                        disabled: currentWeek >= range.upperBound
                    )
                    .frame(width: 44, height: 44)
                }
            }
            Text("\(snapshot.classLabel) · \(dateRange) · 第\(range.lowerBound)-\(range.upperBound)周")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var dateRange: String {
        guard let first = snapshot.days.first?.timetableShortDate,
              let last = snapshot.days.last?.timetableShortDate else {
            return snapshot.weekStartDate ?? "日期待定"
        }
        return first == last ? first : "\(first) - \(last)"
    }
}

private struct TimetableWeekTransitionContainer: View {
    let snapshot: TimetableSnapshot
    let direction: TimetableWeekNavigationDirection
    let reduceMotion: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TimetableWeekCanvas(snapshot: snapshot)
                .id(snapshot.teachingWeek ?? 0)
                .transition(contentTransition)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var contentTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: direction.insertionEdge).combined(with: .opacity),
            removal: .move(edge: direction.removalEdge).combined(with: .opacity)
        )
    }
}

private struct TimetableWeekCanvas: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let snapshot: TimetableSnapshot

    var body: some View {
        StudySurface {
            if dynamicTypeSize.isAccessibilitySize {
                TimetableWeekAgenda(snapshot: snapshot)
            } else {
                TimetableWeekOverview(snapshot: snapshot)
            }
        }
    }
}

private struct TimetableWeekOverview: View {
    let snapshot: TimetableSnapshot

    var body: some View {
        TimetableWeekTimeline(snapshot: snapshot)
            .accessibilityElement(children: .contain)
    }
}

/// A continuous weekly calendar: all seven days share one clock so gaps and
/// lesson lengths stay visually comparable instead of reading as stacked cards.
private struct TimetableWeekTimeline: View {
    let snapshot: TimetableSnapshot

    var body: some View {
        let metrics = TimetableTimelineMetrics(snapshot: snapshot)
        let allDayRows = snapshot.days
            .map { TimetableTimelineLayout.allDayEntries(in: $0).count }
            .max() ?? 0

        VStack(spacing: 0) {
            TimetableTimelineHeaderRow(snapshot: snapshot)

            if allDayRows > 0 {
                TimetableAllDayLane(snapshot: snapshot, rowCount: allDayRows)
            }

            HStack(alignment: .top, spacing: 0) {
                TimetableTimeRuler(metrics: metrics)
                    .frame(
                        width: TimetableTimelineMetrics.timeRulerWidth,
                        height: metrics.timelineHeight,
                        alignment: .top
                    )

                ZStack(alignment: .topLeading) {
                    TimetableHourGrid(metrics: metrics)

                    HStack(alignment: .top, spacing: 0) {
                        ForEach(snapshot.days.indices, id: \.self) { index in
                            let day = snapshot.days[index]
                            TimetableDayTimeline(
                                day: day,
                                metrics: metrics,
                                isReferenceDate: day.id == snapshot.referenceDate
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .overlay(alignment: .leading) {
                                if index != snapshot.days.startIndex {
                                    Rectangle()
                                        .fill(.quaternary)
                                        .frame(width: 1)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: metrics.timelineHeight, alignment: .topLeading)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct TimetableTimelineHeaderRow: View {
    let snapshot: TimetableSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("时间")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 8)
                .frame(
                    width: TimetableTimelineMetrics.timeRulerWidth,
                    height: TimetableTimelineMetrics.headerHeight,
                    alignment: .bottomTrailing
                )
                .accessibilityHidden(true)

            ForEach(snapshot.days.indices, id: \.self) { index in
                let day = snapshot.days[index]
                TimetableTimelineDayHeader(
                    day: day,
                    isReferenceDate: day.id == snapshot.referenceDate
                )
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    if index != snapshot.days.startIndex {
                        Rectangle()
                            .fill(.quaternary)
                            .frame(width: 1)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .frame(height: TimetableTimelineMetrics.headerHeight)
    }
}

private struct TimetableTimelineDayHeader: View {
    let day: TimetableDaySnapshot
    let isReferenceDate: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(day.weekdayLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(isReferenceDate ? Color.accentColor : .secondary)
            Text(day.timetableShortDate)
                .font(.subheadline.weight(isReferenceDate ? .semibold : .medium))
                .lineLimit(1)
            if isReferenceDate {
                Text("今天")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            } else {
                Color.clear.frame(height: 11)
            }
        }
        .padding(.horizontal, 3)
        .frame(
            maxWidth: .infinity,
            minHeight: TimetableTimelineMetrics.headerHeight,
            alignment: .center
        )
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isReferenceDate ? "\(day.dateLabel)，今天" : day.dateLabel)
    }
}

private struct TimetableAllDayLane: View {
    let snapshot: TimetableSnapshot
    let rowCount: Int

    private var height: CGFloat {
        CGFloat(rowCount) * TimetableTimelineMetrics.allDayEntryHeight
            + CGFloat(max(0, rowCount - 1)) * TimetableTimelineMetrics.allDayEntrySpacing
            + 8
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("全天")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 8)
                .frame(
                    width: TimetableTimelineMetrics.timeRulerWidth,
                    height: height,
                    alignment: .topTrailing
                )
                .accessibilityHidden(true)

            ForEach(snapshot.days.indices, id: \.self) { index in
                let day = snapshot.days[index]
                TimetableAllDayColumn(
                    entries: TimetableTimelineLayout.allDayEntries(in: day),
                    dayLabel: day.dateLabel
                )
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .top)
                .overlay(alignment: .leading) {
                    if index != snapshot.days.startIndex {
                        Rectangle()
                            .fill(.quaternary)
                            .frame(width: 1)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
    }
}

private struct TimetableAllDayColumn: View {
    let entries: [TimetableEntrySnapshot]
    let dayLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: TimetableTimelineMetrics.allDayEntrySpacing) {
            ForEach(entries) { entry in
                TimetableAllDayEntryButton(entry: entry, dayLabel: dayLabel)
                    .frame(height: TimetableTimelineMetrics.allDayEntryHeight)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct TimetableAllDayEntryButton: View {
    let entry: TimetableEntrySnapshot
    let dayLabel: String
    @State private var showsDetails = false

    private var displayTitle: TimetableDisplayTitle {
        StudyRocketTimetableCourseCatalog.displayTitle(for: entry.title)
    }

    private var borderColor: Color { entry.timetableTint.opacity(0.5) }

    var body: some View {
        Button {
            showsDetails = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: entry.timetableSymbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(entry.timetableTint)
                    .accessibilityHidden(true)
                Text(displayTitle.primary)
                    .font(.caption2.weight(entry.kind == .course ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                TimetableTimelineCardSurface(
                    tint: entry.timetableTint,
                    tintOpacity: entry.kind == .course ? 0.12 : 0.08
                )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("查看完整课程信息")
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            TimetableEntryDetailPopover(entry: entry)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(dayLabel)，\(entry.timetableAccessibilityText)")
        .accessibilityHint("打开完整课程信息")
    }
}

private struct TimetableTimeRuler: View {
    let metrics: TimetableTimelineMetrics

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                ForEach(metrics.hourTicks, id: \.self) { minute in
                    Text(TimetableTimelineMetrics.clockLabel(for: minute))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 8)
                        .offset(y: labelOffset(for: minute, height: proxy.size.height))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func labelOffset(for minute: Int, height: CGFloat) -> CGFloat {
        let labelHeight: CGFloat = 14
        return min(
            max(metrics.offset(for: minute) - labelHeight / 2, 0),
            max(0, height - labelHeight)
        )
    }
}

private struct TimetableHourGrid: View {
    let metrics: TimetableTimelineMetrics

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(metrics.hourTicks.dropFirst(), id: \.self) { minute in
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: proxy.size.width, height: 1)
                        .offset(y: metrics.offset(for: minute))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct TimetableDayTimeline: View {
    let day: TimetableDaySnapshot
    let metrics: TimetableTimelineMetrics
    let isReferenceDate: Bool

    private var placements: [TimetableTimelinePlacement] {
        TimetableTimelineLayout.placements(for: day)
    }

    private var hasAllDayEntry: Bool {
        !TimetableTimelineLayout.allDayEntries(in: day).isEmpty
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if placements.isEmpty, !hasAllDayEntry {
                    Text("无课程")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                ForEach(placements) { placement in
                    let width = cardWidth(for: placement, containerWidth: proxy.size.width)
                    let height = metrics.eventHeight(
                        startMinute: placement.startMinute,
                        endMinute: placement.endMinute
                    )
                    TimetableTimelineEntryButton(
                        entry: placement.entry,
                        dayLabel: day.dateLabel,
                        visualHeight: height,
                        availableWidth: width
                    )
                    .frame(width: width, height: height, alignment: .topLeading)
                    .offset(
                        x: TimetableTimelineMetrics.eventHorizontalInset
                            + CGFloat(placement.lane) * (width + TimetableTimelineMetrics.eventLaneGap),
                        y: metrics.offset(for: placement.startMinute)
                    )
                }
            }
            .background(isReferenceDate ? Color.accentColor.opacity(0.04) : Color.clear)
        }
    }

    private func cardWidth(
        for placement: TimetableTimelinePlacement,
        containerWidth: CGFloat
    ) -> CGFloat {
        let usableWidth = containerWidth
            - TimetableTimelineMetrics.eventHorizontalInset * 2
            - CGFloat(max(0, placement.laneCount - 1)) * TimetableTimelineMetrics.eventLaneGap
        return max(1, usableWidth / CGFloat(max(1, placement.laneCount)))
    }
}

private enum TimetableTimelineCardDensity {
    case strip
    case compact
    case standard
    case expanded
}

/// Keeps the timeline's clock grid visible between entries without letting it
/// cut through a card's readable content.
private struct TimetableTimelineCardSurface: View {
    let tint: Color
    let tintOpacity: Double

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
    }

    var body: some View {
        shape
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay {
                shape.fill(tint.opacity(tintOpacity))
            }
    }
}

private struct TimetableTimelineEntryButton: View {
    let entry: TimetableEntrySnapshot
    let dayLabel: String
    let visualHeight: CGFloat
    let availableWidth: CGFloat
    @State private var showsDetails = false

    private var displayTitle: TimetableDisplayTitle {
        StudyRocketTimetableCourseCatalog.displayTitle(for: entry.title)
    }

    private var density: TimetableTimelineCardDensity {
        if visualHeight < 22 || availableWidth < 46 { return .strip }
        if visualHeight < 48 || availableWidth < 82 { return .compact }
        if visualHeight < 82 { return .standard }
        return .expanded
    }

    private var contentPadding: CGFloat {
        switch density {
        case .strip: 2
        case .compact: 4
        case .standard: 5
        case .expanded: 6
        }
    }

    private var borderColor: Color { entry.timetableTint.opacity(0.52) }

    var body: some View {
        Button {
            showsDetails = true
        } label: {
            cardContent
                .padding(contentPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background {
                    TimetableTimelineCardSurface(
                        tint: entry.timetableTint,
                        tintOpacity: entry.kind == .course ? 0.13 : 0.09
                    )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("查看完整课程信息")
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            TimetableEntryDetailPopover(entry: entry)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(dayLabel)，\(entry.timetableAccessibilityText)")
        .accessibilityHint("打开完整课程信息")
    }

    @ViewBuilder
    private var cardContent: some View {
        switch density {
        case .strip:
            HStack(spacing: 3) {
                Capsule()
                    .fill(entry.timetableTint)
                    .frame(width: 2)
                Text(displayTitle.primary)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        case .compact:
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.timetableCompactTimeText)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(displayTitle.primary)
                    .font(.caption2.weight(entry.kind == .course ? .semibold : .medium))
                    .lineLimit(2)
            }
        case .standard:
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.timetableCompactTimeText)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(displayTitle.primary)
                    .font(.caption.weight(entry.kind == .course ? .semibold : .medium))
                    .lineLimit(2)
                if let secondary = displayTitle.secondary {
                    Text(secondary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        case .expanded:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 3) {
                    Image(systemName: entry.timetableSymbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(entry.timetableTint)
                        .accessibilityHidden(true)
                    Text(entry.timetableCompactTimeText)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(displayTitle.primary)
                    .font(.caption.weight(entry.kind == .course ? .semibold : .medium))
                    .lineLimit(2)
                if let secondary = displayTitle.secondary {
                    Text(secondary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !entry.timetableMetadata.isEmpty {
                    Text(entry.timetableMetadata)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

private struct TimetableTimelineMetrics {
    static let defaultStartMinute = 8 * 60
    static let defaultEndMinute = 22 * 60
    static let pointsPerMinute: CGFloat = 0.68
    static let timeRulerWidth: CGFloat = 62
    static let headerHeight: CGFloat = 56
    static let eventGap: CGFloat = 3
    static let eventHorizontalInset: CGFloat = 3
    static let eventLaneGap: CGFloat = 3
    static let allDayEntryHeight: CGFloat = 26
    static let allDayEntrySpacing: CGFloat = 4
    static let fallbackDurationMinutes = 50

    let startMinute: Int
    let endMinute: Int

    init(snapshot: TimetableSnapshot) {
        let intervals = snapshot.days.flatMap { day in
            day.entries.compactMap(TimetableTimelineLayout.interval(for:))
        }
        let earliest = intervals.map(\.startMinute).min()
        let latest = intervals.map(\.endMinute).max()

        if let earliest {
            startMinute = min(Self.defaultStartMinute, (earliest / 60) * 60)
        } else {
            startMinute = Self.defaultStartMinute
        }
        if let latest {
            endMinute = max(Self.defaultEndMinute, ((latest + 59) / 60) * 60)
        } else {
            endMinute = Self.defaultEndMinute
        }
    }

    var timelineHeight: CGFloat {
        CGFloat(endMinute - startMinute) * Self.pointsPerMinute
    }

    var hourTicks: [Int] {
        Array(stride(from: startMinute, through: endMinute, by: 60))
    }

    func offset(for minute: Int) -> CGFloat {
        CGFloat(min(max(minute, startMinute), endMinute) - startMinute) * Self.pointsPerMinute
    }

    func eventHeight(startMinute: Int, endMinute: Int) -> CGFloat {
        max(1, CGFloat(max(1, endMinute - startMinute)) * Self.pointsPerMinute - Self.eventGap)
    }

    static func minutes(from time: String?) -> Int? {
        guard let time else { return nil }
        let parts = time.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        return hour * 60 + minute
    }

    static func clockLabel(for minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}

private struct TimetableTimelineInterval {
    let entry: TimetableEntrySnapshot
    let startMinute: Int
    let endMinute: Int
}

private struct TimetableTimelinePlacement: Identifiable {
    let entry: TimetableEntrySnapshot
    let startMinute: Int
    let endMinute: Int
    let lane: Int
    var laneCount: Int

    var id: String { entry.id }
}

private enum TimetableTimelineLayout {
    static func allDayEntries(in day: TimetableDaySnapshot) -> [TimetableEntrySnapshot] {
        day.entries
            .filter { $0.kind == .holiday || interval(for: $0) == nil }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind { return lhs.kind == .holiday }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    static func interval(for entry: TimetableEntrySnapshot) -> TimetableTimelineInterval? {
        guard entry.kind != .holiday,
              let startMinute = TimetableTimelineMetrics.minutes(from: entry.startTime) else {
            return nil
        }
        let fallbackEnd = startMinute + TimetableTimelineMetrics.fallbackDurationMinutes
        let parsedEnd = TimetableTimelineMetrics.minutes(from: entry.endTime)
        let endMinute = (parsedEnd ?? fallbackEnd) > startMinute ? (parsedEnd ?? fallbackEnd) : fallbackEnd
        return TimetableTimelineInterval(
            entry: entry,
            startMinute: startMinute,
            endMinute: endMinute
        )
    }

    static func placements(for day: TimetableDaySnapshot) -> [TimetableTimelinePlacement] {
        let intervals = day.entries
            .compactMap(interval(for:))
            .sorted { lhs, rhs in
                if lhs.startMinute != rhs.startMinute { return lhs.startMinute < rhs.startMinute }
                if lhs.endMinute != rhs.endMinute { return lhs.endMinute < rhs.endMinute }
                return lhs.entry.title.localizedStandardCompare(rhs.entry.title) == .orderedAscending
            }
        guard !intervals.isEmpty else { return [] }

        var placements: [TimetableTimelinePlacement] = []
        var active: [(endMinute: Int, lane: Int)] = []
        var groupStartIndex = 0
        var groupEndMinute = 0
        var groupLaneCount = 0
        var hasActiveGroup = false

        func finishCurrentGroup() {
            guard groupStartIndex < placements.count else { return }
            for index in groupStartIndex..<placements.count {
                placements[index].laneCount = max(1, groupLaneCount)
            }
        }

        for interval in intervals {
            if hasActiveGroup, interval.startMinute >= groupEndMinute {
                finishCurrentGroup()
                active.removeAll()
                groupStartIndex = placements.count
                groupLaneCount = 0
                hasActiveGroup = false
            }

            if !hasActiveGroup {
                groupEndMinute = interval.endMinute
                hasActiveGroup = true
            }

            active.removeAll { $0.endMinute <= interval.startMinute }
            let occupiedLanes = Set(active.map { $0.lane })
            var lane = 0
            while occupiedLanes.contains(lane) {
                lane += 1
            }
            active.append((endMinute: interval.endMinute, lane: lane))
            groupLaneCount = max(groupLaneCount, lane + 1)
            groupEndMinute = max(groupEndMinute, interval.endMinute)
            placements.append(
                TimetableTimelinePlacement(
                    entry: interval.entry,
                    startMinute: interval.startMinute,
                    endMinute: interval.endMinute,
                    lane: lane,
                    laneCount: 1
                )
            )
        }

        finishCurrentGroup()
        return placements
    }
}

private extension TimetableEntrySnapshot {
    var timetableTint: Color {
        switch kind {
        case .course: Color.accentColor
        case .support: .teal
        case .officeHour: .indigo
        case .event: .secondary
        case .holiday: .orange
        }
    }

    var timetableSymbol: String {
        switch kind {
        case .course: "book.closed"
        case .support: "questionmark.circle"
        case .officeHour: "person.crop.circle"
        case .event: "calendar.badge.clock"
        case .holiday: "sun.max.fill"
        }
    }

    var timetableKindLabel: String {
        switch kind {
        case .course: "课程"
        case .support: "学习支持"
        case .officeHour: "答疑"
        case .event: "活动"
        case .holiday: "假期"
        }
    }

    var timetableMetadata: String {
        let location = location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructor = instructor?.trimmingCharacters(in: .whitespacesAndNewlines)
        var values = [String]()
        if let location, !location.isEmpty {
            values.append("地点 \(location)")
        } else if kind == .course {
            values.append("地点待确认")
        }
        if let instructor, !instructor.isEmpty {
            values.append("教师 \(instructor)")
        } else if kind == .course {
            values.append("教师待确认")
        }
        return values.joined(separator: " · ")
    }

    var timetableCompactTimeText: String {
        switch (startTime, endTime) {
        case let (start?, end?): "\(start)-\(end)"
        case let (start?, nil): start
        case (nil, nil): periodLabel.map { "第\($0)节" } ?? "全天"
        case let (nil, end?): "至 \(end)"
        }
    }

    var timetableAccessibilityText: String {
        [timetableKindLabel, timetableCompactTimeText, title, timetableMetadata, note]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "，")
    }
}

private struct TimetableWeekGrid: View {
    let snapshot: TimetableSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(snapshot.days.indices, id: \.self) { index in
                let day = snapshot.days[index]
                TimetableWeekDayColumn(
                    day: day,
                    isReferenceDate: day.id == snapshot.referenceDate
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 6)
                .overlay(alignment: .leading) {
                    if index != snapshot.days.startIndex {
                        Rectangle()
                            .fill(.quaternary)
                            .frame(width: 1)
                    }
                }
            }
        }
    }
}

private struct TimetableWeekDayColumn: View {
    let day: TimetableDaySnapshot
    let isReferenceDate: Bool

    private var allDayEntries: [TimetableEntrySnapshot] {
        day.entries.filter { entry in
            entry.kind == .holiday || entry.startTime == nil
        }
    }

    private var timedEntries: [TimetableEntrySnapshot] {
        day.entries
            .filter { entry in
                entry.kind != .holiday && entry.startTime != nil
            }
            .sorted { lhs, rhs in
                let leftTime = lhs.startTime ?? "99:99"
                let rightTime = rhs.startTime ?? "99:99"
                if leftTime != rightTime { return leftTime < rightTime }
                return lhs.title < rhs.title
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimetableWeekDayHeader(day: day, isReferenceDate: isReferenceDate)

            ForEach(allDayEntries) { entry in
                TimetableWeekEntryButton(entry: entry, isAllDay: true)
            }

            if timedEntries.isEmpty, allDayEntries.isEmpty {
                Text("无课程")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
            } else {
                ForEach(timedEntries) { entry in
                    TimetableWeekEntryButton(entry: entry)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct TimetableWeekDayHeader: View {
    let day: TimetableDaySnapshot
    let isReferenceDate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(day.weekdayLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(isReferenceDate ? Color.accentColor : .secondary)
            Text(day.timetableShortDate)
                .font(.subheadline.weight(isReferenceDate ? .semibold : .medium))
                .lineLimit(1)
            if isReferenceDate {
                Text("今天")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

private struct TimetableWeekEntryButton: View {
    let entry: TimetableEntrySnapshot
    var isAllDay = false
    @State private var showsDetails = false

    private var displayTitle: TimetableDisplayTitle {
        StudyRocketTimetableCourseCatalog.displayTitle(for: entry.title)
    }

    var body: some View {
        Button {
            showsDetails = true
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                    Text(isAllDay ? "全天" : timeText)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                Text(displayTitle.primary)
                    .font(.caption.weight(entry.kind == .course ? .semibold : .medium))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if let secondary = displayTitle.secondary {
                    Text(secondary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !metadata.isEmpty {
                    Text(metadata)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
            .background(tint.opacity(entry.kind == .course ? 0.12 : 0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(tint.opacity(0.28), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("查看完整课程信息")
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            TimetableEntryDetailPopover(entry: entry)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("打开完整课程信息")
    }

    private var tint: Color {
        switch entry.kind {
        case .course: Color.accentColor
        case .support: .teal
        case .officeHour: .indigo
        case .event: .secondary
        case .holiday: .orange
        }
    }

    private var symbol: String {
        switch entry.kind {
        case .course: "book.closed"
        case .support: "questionmark.circle"
        case .officeHour: "person.crop.circle"
        case .event: "calendar.badge.clock"
        case .holiday: "sun.max.fill"
        }
    }

    private var metadata: String {
        let location = entry.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructor = entry.instructor?.trimmingCharacters(in: .whitespacesAndNewlines)
        var values = [String]()
        if let location, !location.isEmpty {
            values.append("地点 \(location)")
        } else if entry.kind == .course {
            values.append("地点待确认")
        }
        if let instructor, !instructor.isEmpty {
            values.append("教师 \(instructor)")
        } else if entry.kind == .course {
            values.append("教师待确认")
        }
        return values
            .joined(separator: " · ")
    }

    private var timeText: String {
        let period = entry.periodLabel.map { " · 第\($0)节" } ?? ""
        return switch (entry.startTime, entry.endTime) {
        case let (start?, end?): "\(start)-\(end)\(period)"
        case let (start?, nil): "\(start)\(period)"
        case (nil, nil): entry.periodLabel.map { "第\($0)节" } ?? "时间待定"
        case let (nil, end?): "至 \(end)\(period)"
        }
    }

    private var accessibilityText: String {
        [timeText, entry.title, metadata, entry.note]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "，")
    }
}

private struct TimetableEntryDetailPopover: View {
    @Environment(\.dismiss) private var dismiss
    let entry: TimetableEntrySnapshot

    private var displayTitle: TimetableDisplayTitle {
        StudyRocketTimetableCourseCatalog.displayTitle(for: entry.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayTitle.primary)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if let secondary = displayTitle.secondary {
                        Text(secondary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("关闭课程详情")
            }

            Divider()

            TimetableEntryDetailLine(symbol: "clock", title: "时间", value: timeText)
            if let period = entry.periodLabel, !period.isEmpty {
                TimetableEntryDetailLine(symbol: "number", title: "节次", value: "第\(period)节")
            }
            TimetableEntryDetailLine(symbol: "mappin.and.ellipse", title: "地点", value: locationText)
            TimetableEntryDetailLine(symbol: "person", title: "教师", value: instructorText)
            if let note = entry.note, !note.isEmpty {
                TimetableEntryDetailLine(symbol: "text.alignleft", title: "备注", value: note)
            }
        }
        .padding(16)
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 360, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch entry.kind {
        case .course: "book.closed"
        case .support: "questionmark.circle"
        case .officeHour: "person.crop.circle"
        case .event: "calendar.badge.clock"
        case .holiday: "sun.max.fill"
        }
    }

    private var tint: Color {
        switch entry.kind {
        case .course: Color.accentColor
        case .support: .teal
        case .officeHour: .indigo
        case .event: .secondary
        case .holiday: .orange
        }
    }

    private var timeText: String {
        let period = entry.periodLabel.map { " · 第\($0)节" } ?? ""
        return switch (entry.startTime, entry.endTime) {
        case let (start?, end?): "\(start) - \(end)\(period)"
        case let (start?, nil): "\(start)\(period)"
        case (nil, nil): entry.periodLabel.map { "第\($0)节" } ?? "全天"
        case let (nil, end?): "至 \(end)\(period)"
        }
    }

    private var locationText: String {
        guard let value = entry.location?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return entry.kind == .course ? "待确认" : "未提供"
        }
        return value
    }

    private var instructorText: String {
        guard let value = entry.instructor?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return entry.kind == .course ? "待确认" : "未提供"
        }
        return value
    }
}

private struct TimetableEntryDetailLine: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct TimetableWeekAgenda: View {
    let snapshot: TimetableSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(snapshot.days) { day in
                VStack(alignment: .leading, spacing: 8) {
                    Text(day.dateLabel)
                        .font(.subheadline.weight(.semibold))
                    TimetableDayContent(day: day)
                }
                .padding(.vertical, 10)
                if day.id != snapshot.days.last?.id {
                    Divider()
                }
            }
        }
    }
}

private struct TimetableDayContent: View {
    let day: TimetableDaySnapshot

    var body: some View {
        let holidays = day.entries.filter { $0.kind == .holiday }
        let entries = day.entries.filter { $0.kind != .holiday }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(holidays) { holiday in
                Label(holiday.title, systemImage: "sun.max.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .padding(.vertical, 8)
            }
            if entries.isEmpty {
                Text(holidays.isEmpty ? "无课程安排" : "假期")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44, alignment: .leading)
            } else {
                ForEach(entries) { entry in
                    TimetableDetailRow(entry: entry)
                }
            }
        }
    }
}

private struct TimetableDetailRow: View {
    let entry: TimetableEntrySnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(entry.kind == .course ? Color.accentColor : .secondary)
                .frame(width: 20, height: 20)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(timeText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(displayTitle.primary)
                    .font(.subheadline.weight(entry.kind == .course ? .medium : .regular))
                    .fixedSize(horizontal: false, vertical: true)
                if let secondary = displayTitle.secondary {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let location = entry.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if entry.kind == .course {
                    Label("地点待确认", systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let instructor = entry.instructor, !instructor.isEmpty {
                    Label(instructor, systemImage: "person")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if entry.kind == .course {
                    Label("教师待确认", systemImage: "person")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let note = entry.note, !note.isEmpty {
                    Label(note, systemImage: "text.alignleft")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 30) }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch entry.kind {
        case .course: "book.closed"
        case .support: "questionmark.circle"
        case .officeHour: "person.crop.circle"
        case .event: "calendar.badge.clock"
        case .holiday: "sun.max.fill"
        }
    }

    private var displayTitle: TimetableDisplayTitle {
        StudyRocketTimetableCourseCatalog.displayTitle(for: entry.title)
    }

    private var timeText: String {
        let period = entry.periodLabel.map { " · 第\($0)节" } ?? ""
        return switch (entry.startTime, entry.endTime) {
        case let (start?, end?): "\(start) - \(end)\(period)"
        case let (start?, nil): "\(start)\(period)"
        case (nil, nil): entry.periodLabel.map { "第\($0)节" } ?? "时间待定"
        case let (nil, end?): "至 \(end)\(period)"
        }
    }
}

private extension TimetableDaySnapshot {
    var timetableShortDate: String {
        dateLabel
            .split(separator: "·", maxSplits: 1)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? dateLabel
    }
}

private struct TimetableUnavailableState: View {
    let snapshot: TimetableSnapshot

    var body: some View {
        StudySurface {
            Label(message, systemImage: symbol)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var message: String {
        switch snapshot.status {
        case .notImported: "尚未导入课表。"
        case .invalid: "现有课表 Markdown 格式无效。"
        case .beforeTerm: "课表尚未到开始日期。"
        case .afterTerm: "课表已超过已导入范围。"
        case .available: "课表尚无可显示的周次。"
        }
    }

    private var symbol: String {
        switch snapshot.status {
        case .invalid: "exclamationmark.triangle.fill"
        case .notImported: "calendar.badge.exclamationmark"
        default: "calendar"
        }
    }
}
