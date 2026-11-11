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

首页和“更多”均可打开“记一件事”。已连接过仓库后可离线保存多条本机草稿；连接恢复后用同一编号提交，Host 确认后才显示“已保存”。旧五项草稿在记录页可查看原文。

在“更多 → 提醒”查看 iOS 权限及实际登记的下一次提醒。每日提醒由 iPhone 在北京时间 21:30 发送；点击进入记录输入框。当天已记录且手机已知时跳过，周月复盘沿用原设置。对话页支持右上角刷新和下拉刷新，失败消息可以恢复到输入框后自行编辑、发送。

## Cloud mode (implemented; production/device acceptance pending)

The pairing screen also accepts the configured public HTTPS cloud service. The
service owns the Markdown repository and the shared academic conversation; the
Mac does not need to stay online. Existing v1 P-256 request signatures, proposal
challenge/confirmation, revision checks, and explicit offline target states are
retained. Model credentials stay on the server.

Changing services first saves and verifies the old queue bytes. Pairing the same
stable repository UUID preserves original operation IDs and revisions, including
uncertain chat requests; an endpoint move rebinds their transport addresses.
Changing repository UUID isolates the previous drafts in **More → old-service
review drafts**. No old queue is silently replayed into another repository. A
backup failure prevents the switch. Business errors such as 409 remain write
issues and do not mark a working connection offline.

**More** provides paginated full text history and read-only cloud file versions.
SSE reconnects with an event cursor and reconciles authoritative history. Known
terminal turns release persisted request IDs; unknown outcomes keep their IDs
and input. Foreground refresh remains necessary after iOS suspends the app.

Verification includes 63 Swift tests and a generic-device Release build. The
existing shared `NCUStudyRocketMobile-SelfCheck` scheme can build the production
configuration with `-configuration Release`; this does not run the SelfCheck
launch action. Tests use temporary fixtures. These results do not establish
production TLS, real-device pairing, old queue review, or installation success.

### 首次云身份迁移与旧队列审核

认证后的 health 可返回 `legacyRepositoryID`，将旧 Host 路径身份映射至云 UUID。身份变化时，手机先原样归档 pending drafts/facts/chats、未发送文字及旧 snapshot，随后隔离旧队列；映射本身不会自动重放。更多 → 旧服务待审核草稿按事实、交付物、时段任务、整份计划分别显示原稿和当前云内容。

事实经逐项确认以原 fact UUID 提交，丢回执仍重用 UUID；服务器同时核对历史 Markdown 中相同 UUID 的内容。勾选只有稳定 ID、操作编号及旧缓存的内容指纹可验证时才可提交；指纹包含所有任务、安排、日期和关联子项，只忽略完成状态字段。确认使用当前已展示的云 snapshot 做 CAS，保留原操作编号和目标状态；云内容若在确认期间变化则停止。整份周计划、活动、缺基线旧日结只供对照，不能把旧 revision 直接换成最新 revision。已确认项目保存独立 receipt，原始归档持续保留。

常规离线日结现在持久保存原始 revision 和 operation ID；断网、409、重启后按原编号/原基线重试。没有原基线的旧稿不允许提交。草稿入口先显示原稿与云内容，再单独确认提交，服务端冲突不能覆盖另一端修改。
