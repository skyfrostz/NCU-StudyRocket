import StudyRocketShared
import SwiftUI

/// Bundled content remains available before pairing and while the service is offline.
struct MobileDailyVerseView: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var anchor = Date.now
  @State private var selectedVerse: SeasonalVerse?

  var body: some View {
    TimelineView(.periodic(from: SeasonalVerse.calendar.startOfDay(for: anchor), by: 60)) { context in
      if let verse = SeasonalVerse.on(context.date) {
        Button {
          // Keep the tapped verse stable if midnight passes while its source is open.
          selectedVerse = verse
        } label: {
          Text(verbatim: verse.punctuatedText)
            .studyPoetryTypography(size: 22, relativeTo: .title2, weight: .regular)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.dailyVerse")
        .accessibilityHint("查看作者、篇名与原文出处")
      }
    }
    .id(anchor)
    .onAppear { anchor = .now }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { anchor = .now }
    }
    .sheet(item: $selectedVerse) { verse in
      MobileVerseSourceSheet(verse: verse)
    }
  }
}

private struct MobileVerseSourceSheet: View {
  let verse: SeasonalVerse
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text(verbatim: verse.punctuatedText)
            .studyPoetryTypography(size: 24, relativeTo: .title2, weight: .regular)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
        Section {
          LabeledContent("作者", value: "宋 · \(verse.author)")
          LabeledContent("篇名", value: verse.work)
          Link(destination: verse.source) {
            Label("阅读原文", systemImage: "arrow.up.right.square")
          }
        } header: {
          Text("出处")
        } footer: {
          Text("诗句已随应用收录，按北京时间每日更换。")
        }
      }
      .studyTypography()
      .navigationTitle("诗句出处")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") { dismiss() }
        }
      }
    }
  }
}
