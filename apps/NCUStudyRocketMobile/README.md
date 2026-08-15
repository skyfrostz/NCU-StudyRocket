# NCU StudyRocket Mobile

这是 iPhone 端 SwiftUI 客户端源码。它不运行 Codex，也不保存 Markdown 事实；所有学业数据和 Codex 会话仍由 Mac 上的 StudyRocket Host 管理。对话正文使用 `swift-markdown-ui 2.4.1` 渲染标题、列表、任务清单、表格、引用和代码块；SSE 只在前台运行，进入后台会释放连接。

## Xcode 设置

1. 安装完整 Xcode 26，并登录与 Mac/iPhone 相同的 Apple ID。
2. 打开 `NCUStudyRocketMobile.xcodeproj`，让 Xcode 解析同目录的本地 Swift Package。
3. 选择 iPhone 17 真机，设置 Personal Team；工程已固定 Bundle ID `com.skyfrost.ncustudyrocket.mobile` 和 iOS 26 Deployment Target。
4. `App/Info.plist` 已包含 Face ID 使用说明；不要把个人签名证书或配对密钥提交到 Git。
5. 在 iPhone 开启开发者模式并运行。

## 连接 Mac

1. 在 Mac 启动 `StudyRocket Host`，手动启动手机连接。
2. Mac 和 iPhone 登录同一 Tailscale tailnet，使用 Tailscale Serve 提供 HTTPS 地址。
3. 在 iPhone 的“更多”输入 HTTPS 地址和 Mac 菜单栏显示的一次性配对码；手机端不会接受明文 HTTP 地址。
4. 配对成功后，设备签名密钥存入 Keychain；离线时只展示最近缓存并保留草稿。

## Host 的生命周期与性能边界

- Mac Host 不是主应用的后台服务：只有在“StudyRocket Host.app”被手动启动且菜单中选择“启动手机连接”后才监听。
- Host 只监听 `127.0.0.1:43817`，启动时先恢复固定任务并完成动态工具协议自检，再通过 Tailscale Serve 暴露 HTTPS；它不创建 LaunchAgent、登录项、网络监听常驻进程或独立模型连接。
- Host 菜单栏会显示 Tailscale Serve 是否可用并提供复制 HTTPS 地址；Host 不会替用户启动 Tailscale 或修改其网络配置。
- 手机上只缓存最近一次只读快照和当前草稿；Codex 子进程只在手机访问对话接口时启动，退出 Host 或停止连接后释放。
- 批量草案确认采用 Host 一次性挑战和 Secure Enclave 签名；Face ID 取消、失败或挑战过期时不会写入仓库。
- 构建 Host：`apps/NCUStudyRocket/Scripts/build_host_app.sh`；安装 Host：`apps/NCUStudyRocket/Scripts/install_host_app.sh`。这两个脚本不重建或替换 `/Applications/NCU StudyRocket.app`。

当前 SwiftPM 目标可在 Mac 上用于编译检查；真机签名和通知权限必须在完整 Xcode 中验收。
