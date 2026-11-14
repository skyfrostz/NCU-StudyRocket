import SwiftUI
import StudyRocketShared

/// Measures the padded bubble against the real row width, without stretching short text.
struct UserMessageLayout: Layout {
    private let spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let sizes = sizes(in: width, subviews: subviews)
        return CGSize(width: width, height: sizes.reduce(0) { $0 + $1.height } + spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = sizes(in: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (view, size) in zip(subviews, sizes) {
            view.place(at: CGPoint(x: bounds.maxX, y: y), anchor: .topTrailing,
                       proposal: ProposedViewSize(size))
            y += size.height + spacing
        }
    }

    private func sizes(in width: CGFloat, subviews: Subviews) -> [CGSize] {
        let limit = max(0, min(600, width * 0.7))
        return subviews.map { $0.sizeThatFits(ProposedViewSize(width: limit, height: nil)) }
    }
}

struct UserMessageView: View {
    @EnvironmentObject private var chat: StudyChatStore
    let message: ChatMessage
    @Binding var showTime: Bool
    var body: some View {
        UserMessageLayout {
            VStack(alignment: .leading, spacing: 8) {
            ForEach(message.attachments) { attachment in
                DesktopAttachmentCard(metadata: attachment, preview: { chat.previewAttachment(attachment) })
            }
            if !message.text.isEmpty { Text(message.text)
                .studyChatTypography(size: StudyRocketTheme.bodySize)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 18, style: .continuous)).foregroundStyle(.primary)
                .contextMenu { StudyButton("复制", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) } }
            }
            }
            HStack(spacing: 5) {
                if let state = message.turnState, state != .completed { Text(state == .interrupted ? "已中断" : state == .failed ? "未完成" : "进行中") }
                Text(message.date.formatted(date: .omitted, time: .shortened))
                    .opacity(showTime ? 1 : 0)
                    .accessibilityHidden(!showTime)
            }
            .studyTypography(.caption2).foregroundStyle(.secondary)
            .frame(minHeight: 16, alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onHover { showTime = $0 }
    }
}
