import SwiftUI

struct SeasonalVerse: Identifiable {
    let id: String
    let text: String
    let author: String
    let work: String
    let source: URL

    var punctuatedText: String { text.hasSuffix("。") ? text : text + "。" }

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private static let verses: [String: Self] = {
        let url = Bundle.main.url(forResource: "SeasonalVerses", withExtension: "tsv")
            ?? Bundle.module.url(forResource: "SeasonalVerses", withExtension: "tsv")
        guard let url, let data = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var entries: [String: Self] = [:]
        for line in data.split(separator: "\n") {
            let columns = line.components(separatedBy: "\t")
            guard columns.count == 5, let link = URL(string: columns[4]) else { continue }
            entries[columns[0]] = Self(id: columns[0], text: columns[1], author: columns[2], work: columns[3], source: link)
        }
        return entries
    }()

    static func on(_ date: Date) -> Self? {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return verses[String(format: "%02d-%02d", parts.month!, parts.day!)]
    }
}

struct SeasonalHeader: View {
    let record: () -> Void
    @State private var showSource = false
    @State private var anchor = Date.now
    private static let weekdayLabel = Date.FormatStyle(
        locale: Locale(identifier: "en_US"),
        calendar: SeasonalVerse.calendar,
        timeZone: SeasonalVerse.calendar.timeZone
    ).weekday(.wide)
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
                    Text(verbatim: context.date.formatted(Self.weekdayLabel))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    if let verse = SeasonalVerse.on(context.date) {
                        Button { showSource.toggle() } label: {
                            Text(verbatim: verse.punctuatedText).font(.system(size: 24, weight: .semibold))
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        }
                        .buttonStyle(.plain).help("查看诗句出处")
                        .accessibilityHint("查看作者与篇名")
                        .popover(isPresented: $showSource) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(verse.punctuatedText).font(.headline)
                                Text("宋 · \(verse.author)《\(verse.work)》").foregroundStyle(.secondary)
                                Link("阅读原文", destination: verse.source)
                            }.padding(18).frame(maxWidth: 360, alignment: .leading)
                        }
                    }
                    Text(Self.dateLabel.string(from: context.date)).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("记一件事", systemImage: "square.and.pencil", action: record)
            }
        }
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
