import SwiftUI
import AppKit
import StudyRocketShared

struct DesktopCloudSettingsSection: View {
    let root: URL
    @ObservedObject private var backupStatus = DesktopCloudBackupStatus.shared
    @State private var endpoint = "https://studyrocket.soulcourse.cn"
    @State private var code = ""
    @State private var issue = ""
    @State private var busy = false
    @State private var drafts: [DesktopCloudDraft] = []
    @State private var selected: DesktopCloudDraft?
    @State private var history: [CloudArchivedMessage] = []
    @State private var historyCursor: Int?
    @State private var historyLoaded = false
    @State private var showPairing = false

    private var isManaged: Bool { DesktopCloudBinding.isManaged(root) }

    var body: some View {
        Section("云学业服务") {
            LabeledContent("当前模式", value: isManaged ? "云端同步" : "本机资料")
            if isManaged {
                LabeledContent("服务地址") {
                    Text(endpoint).foregroundStyle(.secondary).textSelection(.enabled)
                        .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("更换或重新配对服务", isExpanded: $showPairing) { pairingFields }
            } else {
                pairingFields
            }
            Text("与手机共用学业会话和草案。离线保存进入独立草稿，正式文件仅在云服务确认后更新。首次同步发现本机差异会保留原文供审核。")
                .studyTypography(.caption).foregroundStyle(.secondary)
            if isManaged {
                StudyButton("刷新云文件与待提交草稿") { Task { await refresh() } }.disabled(busy)
                ForEach(drafts) { draft in
                    Button { selected = draft } label: {
                        VStack(alignment: .leading) {
                            Text(draft.fact?.text ?? draft.files.map(\.path).joined(separator: "、")).lineLimit(2)
                            Text(draft.message).studyTypography(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }.buttonStyle(.plain)
                }
                if drafts.isEmpty { Text("没有待提交草稿").studyTypography(.caption).foregroundStyle(.secondary) }
                Text(backupStatus.repositoryID == (try? DesktopCloudBinding.read(root).repositoryID) ? backupStatus.message : "当前仓库的一致备份尚未校验").studyTypography(.caption).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                  HStack {
                    StudyButton("检查并下载最新一致备份") { Task { await DesktopCloudBackup.shared.refreshAutomatically(root: root) } }
                    if backupStatus.repositoryID == (try? DesktopCloudBinding.read(root).repositoryID), let location = backupStatus.location { StudyButton("在 Finder 查看备份") { NSWorkspace.shared.activateFileViewerSelecting([location]) } }
                  }
                  VStack(alignment: .leading, spacing: 8) {
                    StudyButton("检查并下载最新一致备份") { Task { await DesktopCloudBackup.shared.refreshAutomatically(root: root) } }
                    if backupStatus.repositoryID == (try? DesktopCloudBinding.read(root).repositoryID), let location = backupStatus.location { StudyButton("在 Finder 查看备份") { NSWorkspace.shared.activateFileViewerSelecting([location]) } }
                  }
                }
                DesktopCloudVersionsView(root: root).id((try? DesktopCloudBinding.read(root).repositoryID) ?? root.path)
                DisclosureGroup("完整文字历史（只读）") {
                    ForEach(history) { message in
                        VStack(alignment: .leading) {
                            Text("\(message.role) · \(message.date.formatted())").studyTypography(.caption).foregroundStyle(.secondary)
                            Text(message.text).textSelection(.enabled)
                        }.padding(.vertical, 4)
                    }
                    if !historyLoaded || historyCursor != nil {
                        StudyButton("加载更多历史") { Task { await loadHistory() } }.disabled(busy)
                    }
                }
            }
            if !issue.isEmpty { Text(issue).studyTypography(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .task(id: root) {
            history = []; historyCursor = nil; historyLoaded = false
            if let binding = try? DesktopCloudBinding.read(root) { endpoint = binding.endpoint.absoluteString }
            drafts = (try? await DesktopCloudWorkspace.shared.drafts(root: root, includeOtherRepositories: true)) ?? []
        }
        .sheet(item: $selected) { draft in
            DesktopCloudDraftReview(root: root, draft: draft) { Task { await refresh() } }
        }
    }
    private var pairingFields: some View {
        Group {
            TextField("HTTPS 服务地址", text: $endpoint)
            SecureField("一次性配对码", text: $code)
            StudyButton(busy ? "正在连接…" : "配对并启用云模式") { Task { await pair() } }
                .disabled(busy || code.isEmpty)
        }
    }
    private func pair() async {
        guard let url = URL(string: endpoint), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { issue = "请输入无子路径的 HTTPS 服务地址。"; return }
        busy = true; defer { busy = false }
        do {
            let api = DesktopCloudAPI(endpoint: url)
            _ = try await api.pair(code: code)
            let health: HealthResponse = try await api.get("/v1/health", as: HealthResponse.self)
            guard health.backend == "cloud", let repositoryID = health.repositoryID else { throw DesktopCloudError.message("目标不是兼容的云学业服务。") }
            let binding = DesktopCloudBinding(endpoint: url, repositoryID: repositoryID)
            let lock = try PlanningRepositoryLock.acquire(root: root)
            do {
                // Keep old binding for audit; switching never removes old draft directories.
                if let previous = try? Data(contentsOf: DesktopCloudBinding.marker(root)) {
                    let backup = DesktopCloudBinding.marker(root).appendingPathExtension("previous-" + UUID().uuidString)
                    try previous.write(to: backup, options: .atomic)
                }
                try JSONEncoder().encode(binding).write(to: DesktopCloudBinding.marker(root), options: .atomic)
                lock.unlock()
            } catch { lock.unlock(); throw error }
            code = ""
            showPairing = false
            history = []; historyCursor = nil; historyLoaded = false
            NotificationCenter.default.post(name: .studyRocketCloudBindingChanged, object: nil)
            try await DesktopCloudWorkspace.shared.synchronize(root: root)
            drafts = try await DesktopCloudWorkspace.shared.drafts(root: root, includeOtherRepositories: true)
            issue = "云模式已启用。请在学业对话中重新连接；本机差异可在此逐项查看。"
        } catch { issue = error.localizedDescription }
    }
    private func refresh() async {
        busy = true; defer { busy = false }
        do { try await DesktopCloudWorkspace.shared.synchronize(root: root); issue = "云文件已刷新。" }
        catch { issue = error.localizedDescription }
        drafts = (try? await DesktopCloudWorkspace.shared.drafts(root: root, includeOtherRepositories: true)) ?? []
    }
    private func loadHistory() async {
        busy = true; defer { busy = false }
        do {
            let binding = try DesktopCloudBinding.read(root)
            let page: CloudHistoryPage = try await DesktopCloudAPI(endpoint: binding.endpoint).get("/v1/history?after=\(historyCursor ?? 0)&limit=100", as: CloudHistoryPage.self)
            history.append(contentsOf: page.messages); historyCursor = page.nextCursor; historyLoaded = true
        } catch { issue = error.localizedDescription }
    }
}

private struct DesktopCloudDraftReview: View {
    let root: URL
    let draft: DesktopCloudDraft
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cloud: [String: CloudFileContent] = [:]
    @State private var loadingCloud = true
    @State private var issue = ""
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("云保存草稿与冲突").studyTypography(.title2)
            Text(draft.message).foregroundStyle(.secondary)
            if draft.repositoryID != (try? DesktopCloudBinding.read(root).repositoryID) { Text("此草稿属于其他仓库，仅供核对，不能直接提交。").foregroundStyle(.orange) }
            ScrollView {
                if let fact = draft.fact { Text(fact.text).textSelection(.enabled) }
                ForEach(draft.files, id: \.path) { file in
                    Text(file.path).studyTypography(.headline)
                    if let current = cloud[file.path] {
                        StudyProposalDiffView(original: file.content, proposed: current.content,
                            originalTitle: "本机草稿", proposedTitle: "当前云版本",
                            renderMarkdown: { AnyView(DesktopProposalMarkdownPreview(source: $0)) })
                        StudyButton("采用此云版本更新本机（保留草稿副本）") { Task {
                            busy = true; defer { busy = false }
                            do {
                                try await DesktopCloudWorkspace.shared.acceptCloud(path: file.path, root: root,
                                    expectedLocalHash: RequestSigning.bodyHash(Data(file.content.utf8)), expectedCloudHash: current.hash)
                                issue = "本机已采用云版本；原草稿仍保留。"; cloud[file.path] = current; changed()
                            } catch { issue = error.localizedDescription }
                        } }.disabled(busy || draft.repositoryID != (try? DesktopCloudBinding.read(root).repositoryID))
                    } else if loadingCloud {
                        ProgressView("正在读取云版本…").controlSize(.small)
                    } else {
                        StudyLabel("云版本尚未载入，本机草稿仍保留。", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                        StudyButton("重新读取") { Task { await loadCloud() } }
                    }
                }
            }
            if !issue.isEmpty { Text(issue).studyTypography(.caption) }
            HStack {
                StudyButton("关闭") { dismiss() }
                Spacer()
                StudyButton("按原版本安全重试") { Task {
                    busy = true; defer { busy = false }
                    do { try await DesktopCloudWorkspace.shared.submit(draft, root: root); changed(); dismiss() }
                    catch { issue = error.localizedDescription }
                } }.disabled(busy || draft.repositoryID != (try? DesktopCloudBinding.read(root).repositoryID))
            }
            Text("重试使用原操作编号与原版本；冲突时不会覆盖。需要合并的内容请在文件编辑器逐项修改后保存。")
                .studyTypography(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 520, idealWidth: 840, minHeight: 480, idealHeight: 620)
        .task { await loadCloud() }
    }
    private func loadCloud() async {
        loadingCloud = true
        defer { loadingCloud = false }
        for file in draft.files {
            do { cloud[file.path] = try await DesktopCloudWorkspace.shared.cloudContent(path: file.path, root: root) }
            catch { if !Task.isCancelled { issue = error.localizedDescription } }
        }
    }
}

private struct DesktopCloudVersionsView: View {
    let root: URL
    @State private var versions: [CloudVersionEntry] = []
    @State private var cursor: Int?
    @State private var loaded = false
    @State private var busy = false
    @State private var issue = ""
    @State private var selectedText: String?
    var body: some View {
        DisclosureGroup("云文件版本历史") {
            Text("历史版本只读；需要恢复时请复制到编辑器，确认差异后按当前版本保存。")
                .studyTypography(.caption).foregroundStyle(.secondary)
            ForEach(versions) { version in
                DisclosureGroup(version.date.formatted()) {
                    ForEach(version.paths, id: \.self) { path in
                        StudyButton(path) { Task {
                            do {
                                let binding = try DesktopCloudBinding.read(root)
                                let file: CloudFileContent = try await DesktopCloudAPI(endpoint: binding.endpoint).post("/v1/versions/read", body: CloudVersionReadRequest(id: version.id, path: path), as: CloudFileContent.self)
                                selectedText = file.content
                            } catch { issue = error.localizedDescription }
                        } }
                    }
                }
            }
            if !loaded || cursor != nil { StudyButton("加载更多版本") { Task { await load() } }.disabled(busy) }
            if !issue.isEmpty { Text(issue).studyTypography(.caption) }
        }
        .sheet(isPresented: Binding(get: { selectedText != nil }, set: { if !$0 { selectedText = nil } })) {
            VStack(alignment: .leading) {
                Text("历史版本（只读）").studyTypography(.title2)
                ScrollView { Text(selectedText ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                StudyButton("关闭") { selectedText = nil }
            }.padding(24).frame(minWidth: 650, minHeight: 500)
        }
    }
    private func load() async {
        busy = true; defer { busy = false }
        do {
            let binding = try DesktopCloudBinding.read(root)
            let page: CloudVersionPage = try await DesktopCloudAPI(endpoint: binding.endpoint).get("/v1/versions?after=\(cursor ?? 0)&limit=50", as: CloudVersionPage.self)
            versions.append(contentsOf: page.versions); cursor = page.nextCursor; loaded = true
        } catch { issue = error.localizedDescription }
    }
}
