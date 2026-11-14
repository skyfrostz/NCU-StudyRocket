import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
import UIKit
import QuickLook
#endif

struct MobileChatComposer: View {
    @ObservedObject var session: MobileSession
    @ObservedObject var store: MobileChatDraftStore
    var focus: FocusState<Bool>.Binding
    let send: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @State private var importing = false
    @State private var pickerGeneration: UInt64 = 0
    #if os(iOS)
    @State private var pickingPhoto = false
    @State private var takingPhoto = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var previewURL: URL?
    #endif
    private var sendDisabled: Bool { !hasContent || !session.isChatAvailable || (session.isChatBusy && !session.supportsTargetedInterrupt) || session.retryingChat || store.replacement != nil || !store.uploading.isEmpty || (!store.attachments.isEmpty && !store.ready) }
    private var hasContent: Bool { !session.inputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.attachments.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pending = store.replacement {
                HStack(alignment: .top) {
                    Image(systemName: "clock")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pending.submitted ? "正在确认新消息" : "已保存，等待上一条回复结束").font(.caption)
                        if !pending.text.isEmpty { Text(pending.text).font(.caption).lineLimit(2) }
                    }
                    Spacer()
                    Button("检查") { Task { await session.resumePendingReplacement() } }.font(.caption)
                }.foregroundStyle(.secondary)
            }
            if !store.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(store.attachments) { item in attachment(item) }
                    }
                }.scrollIndicators(.hidden)
            }
            if let issue = store.issue { Text(issue).font(.caption).foregroundStyle(.red).accessibilityLabel("附件提示：" + issue) }
            VStack(alignment: .leading, spacing: 6) {
                MobileMultilineComposerInput(text: $session.inputDraft, focus: focus)
                    .padding(.horizontal, 10).padding(.top, 7)
                HStack {
                    Menu {
                        #if os(iOS)
                        Button("照片图库", systemImage: "photo") { pickerGeneration = session.repositoryGeneration; pickingPhoto = true }
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button("拍照", systemImage: "camera") { pickerGeneration = session.repositoryGeneration; takingPhoto = true }
                        }
                        #endif
                        Button("选择文件", systemImage: "doc") { pickerGeneration = session.repositoryGeneration; importing = true }
                    } label: { Image(systemName: "plus").font(.title3).frame(width: 44, height: 44) }
                    .accessibilityLabel("添加照片或文件")
                    .disabled(!session.supportsChatAttachments)
                    .accessibilityHint(session.supportsChatAttachments ? "" : "请连接支持附件的新版学业服务")
                    Spacer()
                    if session.isChatBusy && !hasContent {
                        Button { Task { await session.interruptChat() } } label: {
                            Image(systemName: "stop.fill").font(.subheadline)
                                .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                                .frame(width: 36, height: 36).background(.primary, in: Circle())
                                .frame(width: 44, height: 44)
                        }.disabled(!session.supportsTargetedInterrupt).accessibilityLabel("停止当前回复")
                    } else {
                        Button {
                            focus.wrappedValue = false; send()
                        } label: {
                            Image(systemName: "arrow.up").font(.body.weight(.semibold))
                                .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                                .frame(width: 36, height: 36).background(.primary, in: Circle())
                                .frame(width: 44, height: 44)
                        }
                        .opacity(sendDisabled ? 0.35 : 1)
                        .disabled(sendDisabled)
                        .accessibilityLabel(session.isChatBusy ? "停止当前回复并发送新消息" : "发送消息")
                        .accessibilityHint(session.isChatBusy ? "先保存新消息，确认上一条回复停止后发送" : "")
                    }
                }.padding(.horizontal, 5)
            }
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 26))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.background)
        .task(id: store.attachments.map(\.id)) {
            for item in store.attachments { await store.prepareThumbnail(item.id) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: MobileChatDraftStore.allowedExtensions.compactMap { UTType(filenameExtension: $0) }, allowsMultipleSelection: true) { result in
            guard pickerGeneration == session.repositoryGeneration else { return }
            do {
                for url in try result.get() { let item = try store.importFile(url); Task { await session.uploadAttachment(item) } }
            } catch { store.issue = error.localizedDescription }
        }
        #if os(iOS)
        .photosPicker(isPresented: $pickingPhoto, selection: $photos, maxSelectionCount: max(1, 10 - store.attachments.count), matching: .images)
        .onChange(of: photos) { _, selection in
            let generation = pickerGeneration
            Task {
                for photo in selection {
                    do {
                        if let data = try await photo.loadTransferable(type: Data.self) {
                            guard generation == session.repositoryGeneration else { return }
                            let ext = photo.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                            let item = try store.importData(data, name: "照片-" + UUID().uuidString.prefix(6) + "." + ext)
                            await session.uploadAttachment(item)
                        }
                    } catch { store.issue = error.localizedDescription }
                }
                photos = []
            }
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            MobileChatCamera { data in
                takingPhoto = false
                guard let data, pickerGeneration == session.repositoryGeneration else { return }
                do { let item = try store.importData(data, name: "拍照-" + UUID().uuidString.prefix(6) + ".jpg"); Task { await session.uploadAttachment(item) } }
                catch { store.issue = error.localizedDescription }
            }.ignoresSafeArea()
        }
        .quickLookPreview($previewURL)
        #endif
    }

    private func attachment(_ item: MobileChatAttachment) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Button {
                    #if os(iOS)
                    previewURL = store.url(for: item)
                    #endif
                } label: {
                    HStack {
                        #if os(iOS)
                        if item.isImage, let data = item.thumbnailData, let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFill().frame(width: 38, height: 38).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
                        } else { Image(systemName: "doc").frame(width: 32) }
                        #else
                        Image(systemName: item.isImage ? "photo" : "doc")
                        #endif
                        Text(item.name).font(.caption).lineLimit(2).frame(maxWidth: 140, alignment: .leading)
                    }
                }.buttonStyle(.plain).accessibilityLabel("预览 " + item.name)
                Button { session.removeAttachment(item) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44) }.accessibilityLabel("移除 " + item.name)
            }
            if store.uploading.contains(item.id) {
                ProgressView(value: store.progress[item.id] ?? 0)
                Text((store.progress[item.id] ?? 0) >= 1 ? "正在读取附件…" : "正在上传…").font(.caption2).foregroundStyle(.secondary)
            } else if let issue = item.issue {
                Text(issue).font(.caption2).foregroundStyle(.red).lineLimit(2)
                Button("重试") { Task { await session.uploadAttachment(item) } }.font(.caption).frame(minHeight: 32)
            } else if !item.isReady {
                Button("上传附件") { Task { await session.uploadAttachment(item) } }.font(.caption).frame(minHeight: 32)
            } else { Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file)).font(.caption2).foregroundStyle(.secondary) }
        }.padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// TextEditor keeps Return as a newline and leaves IME marked text to the system.
/// A hidden native Text measures only the height; it never replaces editing text.
private struct MobileMultilineComposerInput: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var lineHeight: CGFloat = 24
    @State private var measuredHeight: CGFloat = 24
    var body: some View {
        TextEditor(text: $text)
            .font(.body).focused(focus)
            .scrollContentBackground(.hidden)
            .frame(height: min(max(lineHeight + 12, measuredHeight + 12), lineHeight * (dynamicTypeSize.isAccessibilitySize ? 3 : 6) + 12))
            .background(alignment: .topLeading) {
                Text(text.isEmpty ? " " : text + "\n")
                    .font(.body).lineLimit(1...(dynamicTypeSize.isAccessibilitySize ? 3 : 6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 5)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredHeight = $0 }
                    .hidden().accessibilityHidden(true)
            }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("发送消息").font(.body).foregroundStyle(.secondary)
                        .padding(.leading, 5).padding(.top, 8)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .accessibilityLabel("消息输入框")
    }
}

#if os(iOS)
private struct MobileChatCamera: UIViewControllerRepresentable {
    let completion: (Data?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController(); picker.sourceType = .camera; picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (Data?) -> Void
        init(_ completion: @escaping (Data?) -> Void) { self.completion = completion }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) { completion((info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.9)) }
    }
}
#endif
