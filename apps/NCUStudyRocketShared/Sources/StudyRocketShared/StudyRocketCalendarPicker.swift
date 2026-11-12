#if os(macOS) && canImport(SwiftUI)
import SwiftUI

/// A compact date label with the platform's calendar in a popover. A native
/// compact DatePicker renders as a segmented stepper on macOS instead.
public struct StudyRocketCalendarPicker: View {
    private let title: String
    @Binding private var selection: Date
    @State private var isPresented = false

    public init(_ title: String, selection: Binding<Date>) {
        self.title = title
        _selection = selection
    }

    public var body: some View {
        Button { isPresented.toggle() } label: {
            StudyLabel(selection.formatted(dateStyle.month().day().weekday(.wide)), systemImage: "calendar")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(title)
        .accessibilityValue(selection.formatted(dateStyle.year().month().day()))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                DatePicker(title, selection: $selection, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: PlanningDate.key(selection)) { _, _ in isPresented = false }
                HStack {
                    StudyButton("今天") { selection = .now; isPresented = false }
                    Spacer()
                    StudyButton("完成") { isPresented = false }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .environment(\.calendar, PlanningDate.calendar)
            .environment(\.timeZone, PlanningDate.calendar.timeZone)
            .environment(\.locale, Locale(identifier: "zh_CN"))
        }
    }

    private var dateStyle: Date.FormatStyle {
        Date.FormatStyle(locale: Locale(identifier: "zh_CN"), calendar: PlanningDate.calendar,
                         timeZone: PlanningDate.calendar.timeZone)
    }
}
#endif
