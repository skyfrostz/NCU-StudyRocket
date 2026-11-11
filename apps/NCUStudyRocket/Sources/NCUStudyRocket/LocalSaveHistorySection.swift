import SwiftUI
import StudyRocketShared

struct LocalSaveHistorySection: View {
    let root: URL
    @State private var status = ""

    var body: some View {
        Section("本地版本记录") {
            Text(DesktopCloudBinding.isManaged(root) ? "旧本机 Git 历史保留只读；云模式的新版本由云服务记录。" : "保存学业文件后，连续修改会合并到一条本机 Git 记录。")
            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .task(id: root) {
            while !Task.isCancelled {
                status = LocalSaveHistory.shared.status(for: root)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
