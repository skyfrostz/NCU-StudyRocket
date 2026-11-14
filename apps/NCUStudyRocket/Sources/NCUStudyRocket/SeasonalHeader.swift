import SwiftUI
import StudyRocketShared

struct SeasonalHeader: View {
    let record: () -> Void
    @State private var selectedVerse: SeasonalVerse?
    @Environment(\.scenePhase) private var scenePhase
    @State private var anchor = Date.now
    private static func greeting(at date: Date) -> String {
        switch SeasonalVerse.calendar.component(.hour, from: date) {
        case 5..<11: return "早上好，桦桦。"
        case 11..<14: return "中午好，桦桦。"
        case 14..<18: return "下午好，桦桦。"
        default: return "晚上好，桦桦。"
        }
    }
    private static let dateLabel: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = SeasonalVerse.calendar.timeZone
        f.dateFormat = "M 月 d 日，EEEE"
        return f
    }()

    var body: some View {
        TimelineView(.periodic(from: SeasonalVerse.calendar.startOfDay(for: anchor), by: 60)) { context in
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: Self.greeting(at: context.date))
                        .studyTypography(.subheadline, weight: .medium)
                        .foregroundStyle(.secondary)
                    if let verse = SeasonalVerse.on(context.date) {
                        Button { selectedVerse = verse } label: {
                            Text(verbatim: verse.punctuatedText).studyPoetryTypography()
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        }
                        .buttonStyle(.plain).help("查看诗句出处")
                        .accessibilityHint("查看作者与篇名")
                    }
                    Text(Self.dateLabel.string(from: context.date)).studyTypography(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                StudyButton("记一件事", systemImage: "square.and.pencil", action: record)
            }
        }
        .id(anchor)
        .popover(item: $selectedVerse) { verse in
            VStack(alignment: .leading, spacing: 8) {
                Text(verse.punctuatedText).studyPoetryTypography(size: 17, relativeTo: .headline)
                Text("宋 · \(verse.author)《\(verse.work)》").foregroundStyle(.secondary)
                Link("阅读原文", destination: verse.source)
            }.padding(18).frame(maxWidth: 360, alignment: .leading)
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { anchor = .now } }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in anchor = .now }
    }
}

/// Measures both cards at the final column width so wrapping determines their shared height.
struct TodayCardsLayout: Layout {
    private let gap: CGFloat = 16
    private func twoColumns(_ width: CGFloat) -> Bool { width >= 656 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 656
        let columns = twoColumns(width)
        let cardWidth = columns ? (width - gap) / 2 : width
        let heights = subviews.map { $0.sizeThatFits(.init(width: cardWidth, height: nil)).height }
        return CGSize(width: width, height: columns ? heights.max() ?? 0 : heights.reduce(0, +) + gap)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = twoColumns(bounds.width)
        let width = columns ? (bounds.width - gap) / 2 : bounds.width
        var origin = bounds.origin
        for card in subviews {
            let height = columns ? bounds.height : card.sizeThatFits(.init(width: width, height: nil)).height
            card.place(at: origin, anchor: .topLeading, proposal: .init(width: width, height: height))
            if columns { origin.x += width + gap } else { origin.y += height + gap }
        }
    }
}
