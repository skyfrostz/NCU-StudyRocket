import SwiftUI
import StudyRocketShared
#if os(iOS)
import QuickLook
#endif

struct MobileSentAttachments: View {
    let attachments: [ChatAttachmentDTO]
    @ObservedObject var session: MobileSession
    @State private var preview: URL?
    @State private var loading: String?
    @State private var issue: String?
    private static let expiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "M月d日"
        return formatter
    }()
    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(attachments) { attachment in
                Button {
                    loading = attachment.id
                    Task {
                        do { preview = try await session.previewAttachment(attachment) }
                        catch { issue = error.localizedDescription }
                        loading = nil
                    }
                } label: {
                    HStack {
                        if loading == attachment.id { ProgressView() }
                        else { Image(systemName: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc") }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(attachment.filename).font(.subheadline).lineLimit(2)
                            Text((attachment.expiresAt < .now ? "附件已过期" : ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
                                 + " · " + Self.expiryFormatter.string(from: attachment.expiresAt) + "到期")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain).disabled(loading != nil || attachment.expiresAt < .now)
                .accessibilityLabel("预览附件 " + attachment.filename)
                .accessibilityValue(Self.expiryFormatter.string(from: attachment.expiresAt) + "到期")
            }
            if let issue { Text(issue).font(.caption).foregroundStyle(.red) }
        }
        #if os(iOS)
        .quickLookPreview($preview)
        #endif
    }
}
