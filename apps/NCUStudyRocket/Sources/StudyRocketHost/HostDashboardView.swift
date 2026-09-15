import AppKit
import SwiftUI

@MainActor
struct HostDashboardView: View {
    @ObservedObject var host: HostController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                connectionControl
                endpointPanel
                statusOverview
                pairingPanel
                devicePanel
                securityPanel
                if let error = host.errorMessage { errorPanel(error) }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(24)
        }
        .background(background)
        .onAppear { host.refreshDevices() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            HostBrandMark(size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text("StudyRocket Host")
                    .font(.system(size: 24, weight: .semibold))
                Text("Mac 私有连接管理")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HostStatusBadge(status: host.status)
            }
            Spacer(minLength: 16)
            HStack(spacing: 6) {
                Button {
                    host.openMainApplication()
                } label: {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.bordered)
                .help("打开 NCU StudyRocket")
                .accessibilityLabel("打开 NCU StudyRocket")
                if let address = host.tailscaleStatus.address {
                    Button {
                        host.copyToPasteboard(address)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .help("复制手机连接地址")
                    .accessibilityLabel("复制手机连接地址")
                }
            }
            .controlSize(.regular)
        }
    }

    private var connectionControl: some View {
        HStack(spacing: 12) {
            Button {
                host.isRunning ? host.stop() : host.start()
            } label: {
                Label(host.isRunning ? "停止手机连接" : "启动手机连接", systemImage: host.isRunning ? "stop.fill" : "play.fill")
                    .frame(minWidth: 138)
            }
            .buttonStyle(.borderedProminent)
            .tint(host.isRunning ? .orange : .accentColor)
            .controlSize(.large)

            if host.chatBusy {
                Button {
                    host.stopTurn()
                } label: {
                    Label("停止当前回合", systemImage: "stop.circle")
                }
                .buttonStyle(.bordered)
            }

            Spacer()
            Text(host.isRunning ? "关闭窗口不会中断手机连接" : "启动后仅允许本机监听")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private var endpointPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("iPhone Host 地址", systemImage: "lock.shield")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                endpointStateBadge
            }

            if let address = host.tailscaleStatus.address {
                HStack(spacing: 10) {
                    Text(address)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button {
                        host.copyToPasteboard(address)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .help("复制 iPhone Host 地址")
                    .accessibilityLabel("复制 iPhone Host 地址")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                Text(host.tailscaleStatus.state == .served
                     ? "在 iPhone 的 NCU StudyRocket 中粘贴此地址，再输入本页配对码。"
                     : "地址已识别。启用 Tailscale Serve 后，iPhone 才能安全访问 Host。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("等待 Tailscale 连接", systemImage: "network.slash", description: Text("连接 Tailnet 后会在这里显示 iPhone 使用的 HTTPS 地址。"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.accentColor.opacity(0.24)))
    }

    private var endpointStateBadge: some View {
        let isReady = host.tailscaleStatus.state == .served
        return Label(isReady ? "可配对" : "等待 Serve", systemImage: isReady ? "checkmark.circle.fill" : "clock")
            .font(.footnote.weight(.medium))
            .foregroundStyle(isReady ? .teal : .orange)
    }

    private var statusOverview: some View {
        HostSection(title: "连接状态", subtitle: "首页与计划功能独立于学业对话协议自检") {
            VStack(spacing: 0) {
                HostStatusRow(icon: host.status.systemImage, title: "Host", value: host.status.title, tint: host.status.color)
                Divider().padding(.leading, 38)
                HostStatusRow(icon: "folder.badge.gearshape", title: "仓库", value: host.repositoryStatus, tint: host.repositoryIsValid ? .teal : .orange)
                Divider().padding(.leading, 38)
                HostStatusRow(icon: "sparkles", title: "Codex", value: host.chatStatus == "未连接" ? host.codexStatus : host.chatStatus, tint: host.codexIsAvailable ? .teal : .orange)
                Divider().padding(.leading, 38)
                HostStatusRow(icon: host.tailscaleStatus.systemImage, title: "Tailscale", value: host.tailscaleStatus.title, tint: tailscaleTint)
            }
        }
    }

    private var pairingPanel: some View {
        HostSection(title: "iPhone 配对", subtitle: "配对码 5 分钟有效，连续错误 5 次后失效") {
            if host.isRunning, let code = host.pairingCode {
                HStack(alignment: .center, spacing: 16) {
                    Text(code)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .textSelection(.enabled)
                    Button {
                        host.copyToPasteboard(code)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .help("复制配对码")
                    Spacer()
                    Button("生成新配对码") {
                        host.regeneratePairingCode()
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                ContentUnavailableView("尚未生成配对码", systemImage: "number.square", description: Text("启动手机连接后，在这里获取 iPhone 的一次性配对码。"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }
    }

    private var devicePanel: some View {
        HostSection(title: "已配对设备", subtitle: "撤销后该设备的所有请求会立即被拒绝") {
            if host.devices.isEmpty {
                Text("暂时没有已配对设备。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(host.devices, id: \.id) { device in
                        HStack(spacing: 12) {
                            Image(systemName: device.isRevoked ? "iphone.slash" : "iphone")
                                .foregroundStyle(device.isRevoked ? .secondary : Color.teal)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).font(.body.weight(.medium))
                                Text(device.isRevoked ? "已撤销" : "已授权")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !device.isRevoked {
                                Button("撤销") { host.revoke(device.id) }
                                    .buttonStyle(.bordered)
                                    .tint(.orange)
                            }
                        }
                        .padding(.vertical, 10)
                        if device.id != host.devices.last?.id { Divider().padding(.leading, 32) }
                    }
                }
            }
        }
    }

    private var securityPanel: some View {
        HostSection(title: "安全边界", subtitle: "连接只在你确认后由 Tailscale Serve 转发到 tailnet") {
            VStack(alignment: .leading, spacing: 10) {
                Label("Host 仅绑定 127.0.0.1，不监听局域网或公网地址。", systemImage: "lock.shield")
                Label("iPhone 请求使用设备密钥签名；草案应用仍需要 Face ID。", systemImage: "faceid")
                Label("关闭 Host 会立即关闭网络入口与 Codex 子进程。", systemImage: "power")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private func errorPanel(_ error: String) -> some View {
        HostSection(title: "最近错误", subtitle: "") {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tailscaleTint: Color {
        switch host.tailscaleStatus.state {
        case .served: .teal
        case .notServed: .orange
        case .unavailable: .secondary
        }
    }

    private var background: some View {
        Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
    }
}

private struct HostSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold))
                if !subtitle.isEmpty {
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color(nsColor: .separatorColor).opacity(reduceTransparency ? 0.78 : 0.46)))
    }
}

private struct HostStatusRow: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 20)
            Text(title)
                .font(.subheadline.weight(.medium))
                .frame(width: 54, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }
}

private struct HostStatusBadge: View {
    let status: HostController.Status

    var body: some View {
        Label(status.title, systemImage: status.systemImage)
            .font(.footnote.weight(.medium))
            .foregroundStyle(status.color)
    }
}

private struct HostBrandMark: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let iconURL, let icon = NSImage(contentsOf: iconURL) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            } else {
                // Keep the panel usable if it is launched before the main app has
                // been installed or while an older Host bundle is being rebuilt.
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                        .fill(Color(red: 0.05, green: 0.46, blue: 0.50))
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: size * 0.43, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }

    private var iconURL: URL? {
        Bundle.main.url(forResource: "NCUStudyRocket", withExtension: "icns")
    }
}
