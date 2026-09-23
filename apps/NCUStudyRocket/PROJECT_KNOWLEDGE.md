# NCU StudyRocket 项目知识库

更新时间：2026-09-23

本文件汇总当前 Codex 项目会话中仍有维护价值的内容，并与当前源码交叉核验。它不是发布说明，也不替代 `AGENTS.md`、`README.md`、源码或测试。

## 1. 使用与证据规则

维护时按以下优先级判断事实：

1. 当前源码、测试和运行时只读检查。
2. 已完成并有构建、测试或运行验收证据的会话结果。
3. 仅诊断或仅形成计划的会话。
4. 已被后续协议、实现或用户决策覆盖的历史结论。

文中使用以下标签：

- **当前事实**：已在 2026-08-23 的源码或配置中复核。
- **会话验证**：会话中有明确测试、构建或运行结果，但可能随源码继续变化。
- **产品决策**：用户已明确选择，后续实现应保持。
- **待验收**：不能由构建或单元测试替代的真实运行行为。
- **已淘汰**：只用于解释历史，不应重新实现。

## 2. 会话覆盖

本次共清点当前项目路径与项目 ID 下的 29 个会话。重复自动提醒只提炼规则，空白会话不形成知识结论。

### 2.1 应用开发与修复会话（7 个）

- `019ff46b-9595-7233-8daa-1c823e1c9254`，标题“开发”：建立仓库、macOS 应用、Host、手机端和大量早期 UI 规则。有效内容以当前源码与后续修复为准。
- `019ffbe6-9a13-73e1-a7bb-2fe54bf29b98`，标题“开发 (2)”：继续完善学业助理、动态工具、跨端构建和真机边界。
- `01a004b3-9af9-7d61-bd4e-7bf762eb46f2`，标题“修复对话页卡死与白屏”：确认 SwiftUI 布局反馈、Markdown 降级和 SSE 约 61 秒超时问题；同时形成双语 README 与手机目录边界。
- `01a005da-0830-7f70-9adf-8a5eeb9a1674`，标题“按照这个plan开始修复……”：给出聊天滚动、Markdown、SSE 心跳与重连方案；早期轮次受只读权限阻塞，不能把整个计划视为已实现。
- `01a00877-d58d-7192-8e36-5f5756a99ece`，标题“ncu studyrocket desktop学业助理一直卡在读取资料……”：实现任务描述符迁移、typed 终态、切页不断连和历史兜底。
- `01a00eb9-8d18-7be1-abfa-857526c53fb6`，标题“修复双端安全稳定性问题”：实现并验证 Host HTTP、写入、Keychain、nonce、challenge、路径安全、generation 隔离和跨端 UI 修复；后续又诊断 Host 自检阻塞首页的问题。
- `01a01523-9228-7ca3-b3b1-64fc9e1ff490`，标题“修复手机首页与 Host 自检”：当时的主修复会话，覆盖 Host 降级、协议 v4、交付物与今日时段联动、完成动画、连接页、网络分流、任务权限和手机待同步队列卡死；当前协议已由后续维护升级为 v5。

### 2.2 学业对话与动态工具会话（2 个）

- `019ff539-bc1a-7b73-9a29-6340b47690e0`，标题“StudyRocket 学业助理”：形成高数计划，并暴露旧工具的 `Unsupported dynamic tool namespace: null` 故障。未成功提交的旧计划不得当作仓库事实。
- `019ffa5a-0958-7d61-bc29-b7ddb2417ae6`，标题“StudyRocket 学业助理”：验证结构化草案流程，并确认“计划表可包含学习、出行、运动；交付物只包含学习产出”的产品规则。

### 2.3 自动提醒会话（12 个）

每日行为账会话：

- `019ff62b-41e4-7ed3-80a4-b81f57c60d95`
- `019ffb52-03f4-7640-9309-ca9ae275ef30`
- `01a00078-c0c8-7f70-a3c9-ede689eb894e`
- `01a005a4-8688-7221-aba4-7ca426a7f5bc`
- `01a00e47-f695-7382-8893-176f6c0a5fd4`
- `01a00feb-d7f1-71a2-96fe-90a616524323`
- `01a01511-6300-7313-ae2a-0c416fd97f14`
- `01a01a3d-56d9-7733-8f4b-6c74b46357ac`
- `01a01f5e-a786-7bf3-b70f-cbd6f40632ed`
- `01a0248c-31d9-73d0-bd41-941d7dc4b2ac`
- `01a029b6-ad7b-79a0-ad21-e534036b4f00`

周复盘与排期会话：

- `01a00e47-f695-7382-8893-17417b80aabc`

这些会话没有提供新的学业事实。稳定规则是：每日只询问五项可证事实，缺失写 `待补`；周复盘先确认完成项、净时长、未完成原因和硬节点，确认前不写文件；排期保持 12–15 小时容量、缓冲和撞车降级。

### 2.4 协议探针、重复初始化与空白会话（8 个）

协议探针：

- `019ffa26-70d9-7442-83ea-99433d6093f4`
- `019ffa27-d554-7061-baed-1a1523e1d278`
- `019ffa36-dec8-7c31-9084-00e104a605d0`

它们只证明旧动态工具发现或调用路径曾失败，不提供产品事实。当前应使用规范 `studyrocket` 命名空间和协议 v5。

重复初始化会话：

- `019ff445-c987-7bb0-b961-925b3df5f454`
- `019ffbe4-7b1d-70a2-98a3-07fd3fdacb5d`
- `019ffbe4-c18b-7cb0-bc6e-fcd9d6f85fab`
- `019ffbe5-1db2-7b50-8d36-45b15dd0138f`

这些会话与“开发”主线重复，没有独立于当前仓库的有效结论。

空白问候会话：

- `01a01057-a391-7690-9ca6-e406d12eede2`

该会话不进入知识结论。

## 3. 当前架构

### 3.1 数据所有权

**当前事实**：Markdown 仓库是唯一事实源。

- Desktop 直接读写 Markdown，但编辑先留在内存，用户保存后才落盘。
- Host 是 Mobile 的唯一仓库写入代理。
- Mobile 只保存快照缓存、待提交操作、日结草稿、连接和身份材料，不保存第二份 Markdown 事实。
- Codex 学业任务只读；任何 Markdown 修改必须先形成结构化草案，再由用户确认应用。

核心管理边界包括：

- `studyrocket:weekly`
- `studyrocket:deliveries`
- `studyrocket:buffer`
- `studyrocket:period-completion`

管理标记必须整行精确识别，不能删除、移动或由正文注入。边界外正文保持原样。

### 3.2 组件职责

- `apps/NCUStudyRocket/Sources/NCUStudyRocket/`：macOS 主应用、Markdown 编辑、首页和桌面学业对话。
- `apps/NCUStudyRocket/Sources/StudyRocketChatCore/`：聊天 reducer、滚动策略、Markdown 与草案协议。
- `apps/NCUStudyRocket/Sources/StudyRocketHost/`：loopback HTTP、配对、SSE、Codex 任务、认证写入。
- `apps/NCUStudyRocketMobile/`：iPhone SwiftUI 客户端、连接、缓存、通知、离线与补交状态。
- `apps/NCUStudyRocketShared/`：HTTP v1 DTO、签名、任务描述符、单实例租约和共享匹配器。

### 3.3 Codex 学业任务

**当前事实**：`StudyRocketAPI.academicTaskProtocolVersion = 5`。

- 描述符按标准化仓库路径的 SHA-256 隔离，只保存 `threadID` 和协议版本。
- v4 或其他不兼容任务首次迁移时只读取有限文字历史，创建带规范 `studyrocket` 动态工具声明的新任务并保存 v5 描述符；若 v5 描述符指向未持久化的 rollout，则仅对 `no rollout found for thread id` 自动重建，其他错误保持可见。
- 后续启动恢复同一 v5 任务。
- `thread/start` 可以声明动态工具；`thread/resume` 不传 `dynamicTools`。
- 动态工具声明可随任务持久化，但处理器属于发起回合的 StudyRocket 连接。直接在 Codex 桌面历史页续聊可能仍发现工具，却返回 `Unsupported dynamic tool namespace: studyrocket`；Host health 不能证明另一个连接的工具路由。应在 StudyRocket 内发起真实请求并核对待确认草案，不通过直接改 Markdown 恢复。
- Host 子 app-server 不继承调用端的 `CODEX_SESSION_ID`、`CODEX_THREAD_ID`、`CODEX_APP_TOOLS_PIPE_PATH` 等任务绑定变量；它保留本机登录状态与 `CODEX_ACCESS_TOKEN`。
- Desktop 与 Host 共用 Codex 单实例租约，不允许两个 `app-server` 同时拥有同一工作区会话。
- 页面切换不终止回合；显式停止、换仓库或应用退出才清理连接。

### 3.4 Host 状态与降级

**当前事实**：Host 支持“首页可用 · 对话未就绪”。

- Host 仅监听 `127.0.0.1:43817`。
- 仓库已绑定且 Codex 已安装时，首页、snapshot、week、daily、勾选和 SSE 不依赖 `dynamicToolsReady == true`。
- 自检失败或超时后保留 listener、配对、本地会话和已认证计划接口。
- 聊天和草案在认证后返回受控 `codex_starting`；未认证请求优先返回 401。
- 后续自检成功可原地恢复，不需要重启 Host 或手机。
- 短暂故障后读取历史成功，应将 `unavailable` 恢复为 `protocolReadyAuthUnknown`，重新开放聊天；已确认的 `authFailed` 不因只读历史成功而清除。协议恢复不等于模型认证或提案调用已验收。
- Host 每 20 秒发送 SSE heartbeat；客户端忽略 heartbeat 正文。

### 3.5 Mobile 连接与同步

**当前事实**：Host HTTP 可用性、SSE 状态和写入业务错误分离。

- SSE 失败只触发后台重连；连续失败后通过 health/snapshot 探测 Host，而不是立即显示整个连接失败。
- `409/422` 等业务错误保留为写入错误，不污染全局连接状态。
- 连接 generation 阻止旧 Host 的异步结果回写。
- repository generation 阻止同一地址下旧仓库、旧 SSE、旧快照、旧聊天和旧动画回写。
- 新式交付物和时段草稿携带幂等键，连接恢复后按“交付物 -> 时段”顺序自动补交，并每次使用最新 revision。
- Host 已达到目标状态时直接清除草稿，不重复写入。
- 老版本无幂等键队列必须先逐项审核；未审核前不自动写入。
- 周计划正文和日结草稿仍由用户比较后手动提交。
- “正在同步完成状态”只在真实 replay task 存活时显示。

### 3.6 交付物与今日安排

**产品决策与当前实现**：

- 首页显示当周全部真实、未完成交付物，不截断为 3 或 5 项；真实数据少于 7 项时不制造占位项。
- 排序为逾期、有日期、无日期；已完成项从首页隐藏。
- 交付物完成时只联动日期相同且通过共享文字匹配器的时段任务。
- `studyrocket:period-completion` 兼容旧四列表格，并允许第五列来源 `delivery:<SHA-256>`。
- 取消交付物只移除该来源；手动来源或其它交付物来源仍存在时，时段保持完成。
- “现在先做什么”直接根据今日非空时段的有效完成状态计算，不回退到其它周交付物。
- 今日全部完成显示“今日安排已完成”；零时段显示“今日尚未安排”。
- 周交付物全部权威完成且队列清空后才显示完成印章。
- 今日时段和交付物勾选都有完整 1 秒可中断窗口；可见的“再次轻点可撤销”小字已删除，但 VoiceOver 仍说明撤销能力。
- 周计划中“缓冲与降级”使用连续编号列表；计划表可包含学习、出行、运动，交付物只包含学习产出。

完成动效的最终语义：

- `0–1000ms` 从左向右划线，期间再次点击反向恢复，且不产生网络写入。
- 撤销窗口结束后，节点和删除线收进分段环；Host 未确认时只显示静态待同步环，不显示成功勾号。
- 权威 snapshot 确认全部完成且队列清空后，分段环闭合为完成印章，只触发一次轻量触感和播报。
- 最终状态不循环闪光、不加彩屑；外部 SSE 完成和启动即完成只使用静态或短淡入。
- Reduce Motion 保留 1 秒撤销能力，后续改用短交叉淡化。

### 3.7 跨端 UI 约定

这些约定来自早期长会话中反复确认的界面决策，维护时应先检查当前实现再调整：

- Desktop 助理 Markdown 正文与用户气泡共用同一正文字号令牌；草案摘要、修改理由和确认提示也使用正文层级，时间和连接状态保持辅助字号。
- 助理消息的时间与复制操作固定显示，不依赖鼠标悬停。
- 未确认草案使用弱于主确认按钮的橙色层级；新草案自动展开，全部应用后自动折叠，部分应用后保留剩余草案展开。
- 周计划“缓冲与降级”阅读和编辑正文使用系统默认行距；交付物可使用更舒展的行距。
- Mobile 每日時段输入框单行约 44pt，内容增加时最多扩到四行，不能为单行内容预留三四行空高度。
- Mobile 首页和“更多”都必须让连接状态与 Mac Host 入口容易发现；详细 task ID 和 repository ID 放在折叠的技术信息中。
- Desktop 和 Mobile 的周交付物均使用纵向时间轴，不增加灰色横线。

## 4. 安全、权限与网络边界

### 4.1 Host 安全

- 未认证请求不能获取配对设备、task ID、repository ID 等敏感信息。
- 配对使用一次性码；设备签名密钥保存在 Keychain/Secure Enclave。
- Host 验证时间戳、nonce、签名、API 版本、revision、幂等键和路径边界。
- 写入锁覆盖读取、revision 校验、备份、写入和幂等结果保存。
- 拒绝路径穿越、最终符号链接、管理标记注入、重复 marker、重复 header、含歧义 framing 和过大请求。
- 批量草案应用需要一次性 challenge 和本地生物认证签名。

### 4.2 Codex 任务权限

**当前事实**：项目 `.codex/config.toml` 只保留说明，不设置旧 sandbox 或 approval 字段。

- 完全访问、工作区和只读由 Codex 桌面端逐任务选择。
- 没有独立 UI 权限记录的旧任务保留原有数据库权限，不批量放宽或收紧。
- StudyRocket 学业任务在 `thread/start`、`thread/resume` 和 `turn/start` 显式只读。
- 开发任务的完全访问不能传入学业任务，学业任务的只读也不能覆盖其它项目会话。

### 4.3 Shadowrocket、Tailscale 与 Codex

**当前配置检查（2026-08-23）**：当前用户 `launchctl` 中大小写代理变量均未设置；`~/.codex/.env` 不存在，失效代理只保留为时间戳备份。

期望的职责划分：

- Shadowrocket TUN 负责公网默认路由和普通 DNS。
- Tailscale 负责 `100.64.0.0/10`、Tailscale IPv6 和 `*.ts.net`。
- Codex 和子 agent 不设置显式 HTTP/HTTPS/ALL proxy，沿系统路由运行。
- StudyRocket Host 使用 loopback `127.0.0.1:43817`，远端访问由用户控制的 Tailscale Serve 提供 HTTPS。
- 不使用 Tailscale Exit Node，不让 Homebrew 再启动第二个 Tailscale daemon。
- 网络检查和应用权限彼此独立；不要通过修改 sandbox 解决 VPN 问题。
- 只有签名验证明确失败时才重新配对，不因普通 SSE 或网络重连删除配对。
- `agent-reach` 或其它子工具出现网络问题时先运行其 `doctor --json` 与更新检查，确认没有继承失效代理；修复使用用户目录，不使用 `sudo`，也不向大学仓库写入工具环境。

## 5. 已淘汰或需谨慎使用的历史结论

- **已淘汰**：协议版本 3 或 4 是当前版本。当前源码为 v5。
- **已淘汰**：`dynamicToolsReady=false` 时关闭整个 Host。当前应进入降级状态。
- **已淘汰**：给 `thread/resume` 传 `dynamicTools`。该参数不受支持。
- **已淘汰**：Codex 固定使用 `127.0.0.1:7890` 显式代理。该端口曾无监听，现已移除显式代理。
- **已淘汰**：Mobile 首页只展示前三项、Mac 首页只展示前五项或排除当天交付物。
- **已淘汰**：SSE 断开立即把整个 Host 标记为失败。
- **已淘汰**：根据“本地有效状态”再次取反决定待同步命令。现在必须显式提交目标 `isCompleted`。
- **历史计划**：高数日期和安排只在 Markdown 已确认写入后才是事实；旧会话中的未提交草案不能覆盖当前文件。
- **谨慎**：旧会话宣称的构建或安装结果只证明当时版本，不证明当前 dirty worktree。

## 6. 故障定位索引

### 首页卡在“协议自检”

1. 检查 `/v1/health` 的 `repositoryBound`、`codexReady`、`dynamicToolsReady`。
2. 若前两项正常而动态工具未就绪，首页和计划应继续工作，只有聊天/草案降级。
3. 若 Host listener 已停止，检查运行状态机是否误把自检超时当成全局停止。

### 聊天永久“正在读取资料”

1. 检查 descriptor 协议版本和 `thread/resume` 是否错误携带 `dynamicTools`。
2. 检查 Host 是否发送 `inProgress/completed/interrupted/failed` typed 状态。
3. 检查历史兜底是否能按 turn ID 或提交文本结算终态。
4. 页面切换不能触发 `disconnect()`。

### SSE 约一分钟断开

1. 确认 Host 20 秒 heartbeat 存在。
2. 确认事件请求使用长超时并有 0.5、1、2、5 秒上限退避。
3. 重连成功应清除错误；重连只做一次权威历史或 snapshot 校准。

### 手机交付物一直“正在同步”

1. 检查 `isReplayingPendingToggles` 是否对应真实 task。
2. 区分 keyed 新队列、legacy 未审核队列、离线等待和冲突暂停。
3. 首页完成提交明确 `true`，周计划恢复提交明确 `false`。
4. 写入超时后用一次 5 秒 snapshot 核对权威状态。
5. 最终封章需要权威全部完成、相同 generation、相同 transition token 且队列为空。

### 切换 Host 后出现旧内容

1. 先停止旧 SSE。
2. 递增连接和 repository generation。
3. 清空旧 Host 专属的快照、聊天、资料和动画上下文。
4. 所有异步回写都检查 generation。

### 权限与网络异常混在一起

1. 先检查 `.codex/config.toml` 是否出现旧 sandbox/approval 字段。
2. 再检查任务 UI 权限、持久化档案和数据库 policy 是否一致。
3. 独立检查 `launchctl` 代理变量、监听端口、系统路由和 DNS。
4. 不把失效代理改成另一个显式端口；TUN 正常时保持 Codex 无显式代理。

## 7. 验证矩阵

### 7.1 基础与 Shared

```bash
cd /Users/skyfrost/Desktop/大学/apps/NCUStudyRocketShared
swift run StudyRocketSharedChecks

cd /Users/skyfrost/Desktop/大学
git diff --check
```

### 7.2 Desktop、Host 与 Markdown

```bash
cd /Users/skyfrost/Desktop/大学/apps/NCUStudyRocket
./Scripts/test_markdown.sh
swift build
swift build -c release
swift run NCUStudyRocketTests
```

`NCUStudyRocketTests` 是 executable check，不是 SwiftPM XCTest target；不要用 `swift test` 代替。

Host 专项检查源码：

- `Tests/HostHTTPRequestParserChecks.swift`
- `Tests/HostPairingStoreChecks.swift`
- `Tests/HostWriteServiceChecks.swift`
- `Tests/WeeklyPlanModelChecks.swift`

它们应覆盖 HTTP framing、Keychain 与重放、临时仓库写入、路径/marker 安全、交付物来源和历史/未来完成记录。

### 7.3 Mobile

```bash
cd /Users/skyfrost/Desktop/大学/apps/NCUStudyRocketMobile
swift test
swift build -c release

xcodebuild \
  -project NCUStudyRocketMobile.xcodeproj \
  -scheme NCUStudyRocketMobile \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  build
```

模拟器名称和 UUID 必须先通过 `xcrun simctl list devices available` 获取，不要写死旧设备。真机安装使用当前 `xcrun devicectl` 发现的设备 ID。

### 7.4 安装与签名

```bash
cd /Users/skyfrost/Desktop/大学/apps/NCUStudyRocket
./Scripts/install_app.sh
./Scripts/install_host_app.sh

codesign --verify --deep --strict '/Applications/NCU StudyRocket.app'
codesign --verify --deep --strict '/Applications/StudyRocket Host.app'
```

同时替换 Desktop 与 Host 时，可以为两条安装命令设置 `STUDYROCKET_NO_LAUNCH=1`，再只启动计划作为 Codex owner 的一端，避免两个 app-server 争夺同一租约。

Mobile 产物也必须做严格签名验证，并确认 bundle ID 为 `com.skyfrost.ncustudyrocket.mobile`。

### 7.5 真实数据保护

```bash
cd /Users/skyfrost/Desktop/大学
shasum -a 256 '工作台/下周计划.md'
```

写入验收前后都记录哈希。所有 Host 写入、交付物联动、冲突、回滚和离线补交测试使用临时 fixture 仓库。

### 7.6 运行验收不能由构建替代

- 长历史快速滚动至少 60 秒，无卡死、白屏、强制跳底和重复消息。
- 流式回复期间切页再返回，回合继续且终态正确。
- Host SSE 空闲超过两个 heartbeat 周期，再断开、重连和重启。
- Host 自检失败时首页和计划仍可用，聊天受控 503，未授权 401。
- Mobile 真机完成配对、HTTPS、Tailscale Serve、SSE、前后台、revision 冲突和写入失败回滚。
- 旧队列审核、自动补交、显式恢复、慢 Host、响应丢失和 generation 切换。
- 1 秒中断动画、Reduce Motion、VoiceOver、Dynamic Type 和深浅色模式。
- Mac 与 Host 的 Codex 单实例租约。

## 8. 2026-09-15 跨端计划、离线同步与发布沉淀

### 8.1 已实现的计划与界面契约

**会话验证（2026-09-15）**：提交 `d3592dc` 和 `f79eed7` 覆盖本轮跨端计划改造与历史日期离线补交修复。后续维护应保持以下行为：

- 一个日期时段可以有多条独立任务；每条任务都以自己的 `taskID`、完成状态和来源参与渲染与写入，不能再把同一时段的多项内容压成一段不可单独勾选的文本。
- Desktop 首页、Mobile 首页和 Mobile“周计划”必须基于同一份 Host snapshot 展示时段任务。修改其中一端时，要同时检查另两端是否仍能显示、勾选和回显同一条任务。
- Markdown 中的 `[ ]` / `[x]` 是输入层完成标记，不是任务标题的一部分。解析时应把标记转换为完成状态，界面不得把部分任务显示为带中括号的原始文本、部分任务显示为普通文本。
- Host snapshot 必须同时覆盖周计划的主区、历史区和未来区。手机只读 Host 的 `SnapshotResponse`，因此只更新 iPhone 包不能修复运行中 Mac Host 的旧 snapshot 逻辑。
- 新 Logo 需作为受控品牌资源同时进入 Desktop、Mobile 的 App Icon/Mark 及相应生成脚本或构建目标；替换源图后必须重建、签名并验证实际安装包，而不是只检查仓库中的 PNG。
- iOS 主屏小组件只读取 App Group 中经过脱敏的 snapshot 投影；它不能写 Markdown、代替 Host 写入，也不能持有待同步队列或 Host 凭据。

### 8.2 离线完成与队列恢复

- 离线勾选必须保存“目标完成状态”、幂等键、revision 和独立任务定位信息；重放时按目标状态协调，不能依据本地显示状态再次取反。
- `ScheduledRowSnapshot.id` 是不透明的结构标识，不能假定它等于 `yyyy-MM-dd`。历史和未来行的离线操作必须用实际 `dateLabel` 找到日期行，再用时段/任务标识定位独立任务；本轮故障正是历史 `2026-09-14` 队首项目被错误地拿日期去匹配不透明 ID，导致后续项目都无法补交。
- Host 已达到目标状态时直接确认并清除该条队列；任务被删除、改名或旧队列没有安全定位信息时，保留为逐项人工审核，不得批量清空缓存、队列或真实 Markdown。
- 队列按原有意图顺序重放。出现队首阻塞时先修正匹配或提示用户处理该条，不得静默跳过、重排或把后续任务写到错误目标。
- iOS 进入后台后系统会暂停 SSE 和网络执行，不能承诺后台立即自动补交；应用回到前台时应刷新 snapshot 并重放可安全执行的队列。显示“正在同步”只能对应真实存活的补交任务，不能当作最终完成证据。

### 8.3 网络、安装与验收边界

- Tailscale Serve 可跨热点和不同局域网工作，同一 Wi-Fi/LAN 不是同步前提。热点或代理改写 DNS 导致的 MagicDNS 解析异常是独立问题，应分别检查名称解析、Tailscale 路由和 Host HTTPS 可达性。
- 手机成功拉到 snapshot 只能证明当次 Host 链路可用，不能单独证明后台重放、SSE、MagicDNS 或下一次网络切换均正常。
- Mac Desktop、Mac Host 与 iPhone 是三份独立部署物。涉及 snapshot 或写入协议的修复，必须重新构建并替换运行中的 Host；涉及手机体验的修复，再单独构建、签名、安装 iPhone 包。为保留用户的现有缓存和待同步队列，旧队列场景下安装完成后默认不自动启动手机应用。
- 本轮 Mobile Release 构建、严格签名验证、安装和 45 项 Mobile 测试均已通过；这仅是当时源码与设备安装的证据。真实队列清空、前后台恢复和热点切换仍需由当时运行设备观察确认。

### 8.4 GitHub `main` 发布规则

**产品决策（2026-09-15）**：此后每一次实际修改 StudyRocket 源码、资源、维护文档或维护 Skill 的更新，都必须在相应验证通过后提交并推送到 GitHub `origin/main`。只读诊断不创建无意义提交。

1. 提交前运行 `git fetch origin main`，核对 `origin/main...HEAD` 的领先/落后关系和工作区状态。
2. 只能以明确路径暂存本次文件，检查 staged diff 与 `git diff --check`；不得借本次发布带入用户的 Markdown、Office 文件、构建产物、缓存或其他无关改动。
3. 仅在可安全快进或已正确整合上游 `main` 时执行 `git push origin HEAD:main`。遇到冲突、非快进或无法判断归属的用户改动时，不得强推，先保留现场并报告。
4. 交付结果必须说明实际提交 SHA、`main` 推送结果、自动验证范围，以及仍需用户在真机确认的行为。

## 9. 最近验证状态与未完成边界

**会话验证（2026-08-21）**：Mobile 21 项测试、Shared checks、17 项聊天检查、Markdown、Host HTTP/配对/写入/周计划模型、Debug/Release、模拟器与真机 Release 构建、签名和安装均通过；真实周计划哈希在该次操作前后保持一致。

**当前事实（2026-08-23）**：

- 工作树仍包含大量未提交 Desktop、Host、Mobile、Shared 和 `.codex/config.toml` 修改。
- `工作台/下周计划.md` 当前也有用户未提交修改，维护任务必须避开。
- 当前 Codex 用户会话没有显式代理变量，旧代理环境文件只保留备份。

**待验收或需重新确认**：

- 真机旧版 `3 + 2` 待同步队列是否已由用户审核，当前未知；在确认前不要设计自动清理。
- 当前源码下的实际 Tailscale Serve 首页、SSE、写入和聊天恢复链路需要按当日网络状态重新验收。
- 过去的模拟器或真机安装不证明当前 dirty worktree 已部署；每次发布都重新构建、签名和核对安装版本。
- 构建通过不证明长历史滚动、动画、VoiceOver、前后台和网络重连。

## 10. 维护本知识库

- 新会话只有形成稳定产品决策、已验证实现、明确失败模式或可复用验收方法时才加入。
- 计划未实施时标为“待验收”或“仅计划”，不要合并到当前架构。
- 协议、DTO、管理标记或部署命令变化时同步更新本文件和 `$studyrocket-maintenance`。
- 不记录配对码、私钥、设备签名材料、账号、手机号、真实 Host 地址或其它敏感信息。
