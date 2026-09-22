---
name: studyrocket-maintenance
description: 维护和排查 NCU StudyRocket 的 macOS Desktop、Mac Host、iPhone Mobile 与 Shared 协议。用户要求修复 StudyRocket 应用、聊天生命周期、SSE、配对、计划写入、跨端同步、构建安装或运行验收时使用；学业规划、复盘和课程答疑改用对应学业 Skill。
---

# StudyRocket Maintenance

## 开始前

1. 读取仓库根目录 `AGENTS.md`、`PROFILE.md` 和 `apps/NCUStudyRocket/PROJECT_KNOWLEDGE.md`。
2. 运行 `git status --short`，保留所有既有未提交修改；不要把历史会话中的旧路径或旧结论直接当作当前源码事实。
3. 按证据优先级工作：当前源码与测试结果 > 当前运行状态 > 已验证会话结论 > 计划与诊断草案。
4. 先确定问题属于 Desktop、Host、Mobile、Shared、Markdown 数据、Codex 学业任务、网络还是任务权限，再决定修改面。

## 不可破坏的边界

- Markdown 仓库是唯一事实源。应用和手机缓存都不是第二套数据库。
- 不使用真实 `工作台/下周计划.md` 做写入测试；使用临时仓库，并在部署前后核对真实文件哈希。
- 保留所有 `studyrocket` 管理标记、边界外正文、配对、聊天历史、缓存和用户草稿，除非用户明确授权删除。
- 学业任务始终只读。Markdown 修改必须经 `studyrocket.propose_changes` 形成草案并由用户确认；不要使用旧工具名或通过 `exec` 包装动态工具。
- `academicTaskProtocolVersion` 当前为 5。`thread/start` 声明规范动态工具；`thread/resume` 不传 `dynamicTools`。
- Host 自检失败时允许首页、计划、日结、勾选和 SSE 降级运行；聊天与草案仍受动态工具门禁，不得绕过认证。
- Mobile 必须用连接 generation 和 repository generation 隔离旧 Host、旧仓库、旧 SSE 与迟到请求。
- 业务错误如 409/422 不得直接污染全局连接状态；SSE 状态和 Host HTTP 可用性分开处理。
- 任务权限由 Codex 桌面端逐任务选择；项目 `.codex/config.toml` 不得加入旧 `sandbox_mode`、`sandbox_workspace_write` 或 `approval_policy`。
- 不擅自启动、停止或改写 Tailscale、Shadowrocket、系统代理、配对或签名配置。网络修复先做只读检查。
- 同一时段可包含多条独立任务；时段行 ID 是结构标识，日期关联必须使用实际日期标签，任务关联必须使用独立任务 ID。不得把多项任务回退为一段文本，也不得把 Markdown 的 `[ ]` / `[x]` 原样渲染为任务标题。
- 离线队列保存目标状态而非“再切换一次”的意图。Host 已到目标状态时可确认该条；定位不足、改名、删除或 legacy 队列必须逐项审核，禁止批量清空用户缓存、待同步项目或真实计划。
- iOS 后台不保证继续运行 SSE 或离线重放。只有应用回到前台后的权威 snapshot 和实际补交结果可以确认同步完成。

## GitHub `main` 发布规则

用户已在 2026-09-15 决定：每一次实际 StudyRocket 源码、资源、维护文档或维护 Skill 更新，均须在验证后提交并推送至 GitHub `origin/main`；只读诊断不创建空提交。

1. 开始和提交前均运行 `git status --short` 与 `git fetch origin main`，再用 `git rev-list --left-right --count origin/main...HEAD` 和 `git log --oneline origin/main..HEAD` 核对发布范围。
2. 只用带路径的 `git add -- <path>` 暂存本次文件；先审核 `git diff --cached`、运行受影响检查和 `git diff --check`。绝不将既有用户 Markdown、Office 文件、构建目录、缓存、签名材料或无关改动带入提交。
3. 仅当 `origin/main` 是当前提交的祖先，或已安全整合上游 `main` 后，执行 `git push origin HEAD:main`。不得使用强推、重置、清理工作区或把不明归属的改动带入 rebase。
4. 若上游非快进、冲突涉及用户内容，或验证失败，保留现场并报告原因；不要用“先推再修”绕过发布门槛。
5. 交付时报告提交 SHA、`main` 推送结果、自动验证范围和剩余真机验收项。

## 实施方法

1. 用日志、health、snapshot、SSE 或最小 fixture 复现；诊断请求只报告原因，不擅自修复。
2. 修改请求采用最小局部补丁，优先复用 Shared DTO、匹配器、写入锁、generation 和现有状态机。
3. 跨端契约变化先改 Shared，再同步 Host、Desktop、Mobile 和兼容读取；除非确有必要，不升级 HTTP v1 或动态工具协议。涉及日期行时，用 `dateLabel` 匹配真实日期，不能以不透明 row ID 代替日期。
4. 同一时段的任务必须逐条建模、逐条定位、逐条勾选。界面显示的是解析后的任务标题和完成状态，不是原始 Markdown checkbox 文本。
5. 写入路径必须保留 revision、幂等键、认证、路径边界、备份和原子保存。交付物与时段联动必须处于同一写入事务；离线重放提交显式目标状态，先协调 Host 权威状态再决定是否写入。
6. UI 状态必须映射真实任务：只有真实补交任务存活时显示“正在同步”；权威写入确认前不得封章或显示最终成功。iOS 回前台时再执行安全的刷新与重放，不能承诺后台即时同步。
7. Desktop 与 Mobile 同类体验分别检查并报告，不假设一端修复会自动覆盖另一端。Host snapshot/写入逻辑变更必须单独替换运行中的 Mac Host；仅安装 iPhone 包不能修复旧 Host。
8. Tailscale Serve 可跨热点与不同局域网工作；把 MagicDNS、代理 DNS、HTTPS 可达性、SSE 和队列业务冲突分开诊断，不能以“不是同一 LAN”解释同步失败。

## 验证与部署

- 按 `apps/NCUStudyRocket/PROJECT_KNOWLEDGE.md` 的“验证矩阵”选择与风险匹配的检查。
- 至少运行受影响包的 Debug/Release 构建、对应专项检查和 `git diff --check`。
- Host 写入、安全和迁移检查只使用临时目录；运行时验收不得提交测试聊天或真实计划勾选。
- macOS 安装后做 `codesign --verify --deep --strict`。Mobile 必须用完整 Xcode 构建；SwiftPM 成功不能替代 iOS 模拟器/真机验收。
- 真机存在旧版待同步队列时，只安装不启动，直到审核 UI 已就绪并由用户处理。
- 涉及时段任务时，至少覆盖“同一时段两条独立任务”“历史或未来日期任务”“原始 checkbox 前缀不出现在标题”“离线完成后前台补交”四类 fixture；Desktop 首页、Mobile 首页和 Mobile 周计划分别检查。
- 更新 Logo 或图标时，检查 Desktop 资源、Mobile App Icon/Mark、Host 图标生成与目标成员关系；安装包中的图标、签名和实际设备展示是不同证据，不能互相替代。
- 交付时区分：源码已实现、自动检查通过、模拟器通过、真机通过、真实 Tailscale 链路通过、仍待用户确认。

## 输出要求

- 先报告结果和仍有风险，再列关键文件与验证。
- 明确说明是否修改真实 Markdown、是否保留原哈希、是否安装或启动应用。
- 不把“构建通过”表述为已验证滚动、断线恢复、配对、SSE、动画或真机网络行为。
