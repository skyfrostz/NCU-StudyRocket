# 大学学业与保研助理仓库

把 Codex 当长期学业规划副驾：绑这个文件夹，它自动读上下文、排计划、写复盘。

当前项目：数据科学与大数据技术（中外合作办学）/ Biomedical Data Sciences，4 年 4+0 双学位项目。

## 快速开始

1. 在 Codex 中打开本文件夹（`/Users/skyfrost/Desktop/大学`）
2. 先填 `PROFILE.md`（个人档案）
3. 对助理说话即可（见下方"指挥手册"）

## 必填清单（第一次使用）

按优先级：

1. `PROFILE.md` — 专业、GPA、排名、英语、目标
2. `工作台/航线/课程.md` — 本学期课程名+进度+考试日期
3. `工作台/航线/保研.md` — 保研节点+截止日
4. `工作台/学期/大一上.md` — 学期时间范围+关键节点
5. `工作台/航线/生活.md` — 作息目标+摆烂阈值

专业资料和官方来源见 `专业/专业画像与能力树.md`、`智库/学校文件/来源索引.md`。

## 指挥手册

- 排下周计划 → 对助理说"排下周"或"重排下周"
- 写本周复盘 → "写复盘"或"这周总结"
- 出学期路线 → "出大一上路线"或"重排这学期"
- 保研倒计时 → "夏令营还有 3 周怎么排"
- 读 PDF → "整理智库里的课件"或"抽这份论文要点"
- 保研咨询 → "保研要看哪些学期成绩"或"夏令营怎么准备"
- 更新校历 → "更新校历"（附上教务通知截图）

## 目录结构

见 `AGENTS.md` 文件地图。

## 注意事项

- 别让助理编数字：排名、GPA、截止日你没填的，它会写 `待补`
- PDF 别一次塞太多：先放 3-5 份跑通"整理PDF"，再批量
- 每周日固定仪式：先"写复盘" → 再"排下周"，顺序别反
- 崩了别硬撑：连续 2 天没学，让助理"重置缓冲"，砍计划比硬扛强

## 版本与备份

- Markdown、Skill、脚本和可检索文本进入 GitHub 私有仓库 `NCU-StudyRocket`。
- PDF 放在私有云盘单独备份，不进入 Git 历史。
- 日常提交：`git add -A && git commit -m "更新学习记录" && git push`。
- 查看状态：`git status --short`；误改恢复前先让助理检查差异，不直接执行破坏性回滚。

## 故障排查

- Skill 不出现：重启 Codex，并确认从本目录启动。
- 规则不生效：检查根目录 `AGENTS.md` 是否为空、是否存在更近的 `AGENTS.override.md`。
- 资料过大：只把 Markdown 或 `PDF提取文本/` 的文本交给助理，PDF 保留在云盘。
# NCU-StudyRocket

南昌大学玛丽女王学院数据科学与大数据技术（中外合作办学）学生的个人学业工作台。Markdown 是唯一数据源，Codex 负责答疑、规划与复盘，原生 macOS 应用负责清晰查看和编辑。

## 原生应用

应用源码位于 `apps/NCUStudyRocket/`，不启动服务器、不创建后台常驻进程、不使用数据库。

```bash
cd apps/NCUStudyRocket
./Scripts/install_app.sh
```

安装后从 `/Applications/NCU StudyRocket.app` 打开。首次路径失效时，在“设置”或侧边栏选择包含 `AGENTS.md` 与 `PROFILE.md` 的仓库目录。应用只写入仓库内 Markdown，明确点击“保存”后才落盘；Git 提交和推送仍由用户在终端完成。

## 常用操作

- 首页：按当天星期直接展示上午、下午、晚上任务与本周交付物；勾选交付物会立即原子写回 `工作台/下周计划.md`。
- 周计划：编辑七日时间块与交付物，按 `⌘S` 或“保存”写入 `工作台/下周计划.md`；已勾选的交付物会保留状态。
- 每日复盘：填写五项行为账，保存到对应月份文件后，应用会幂等更新 `工作台/助理偏好与习惯.md` 的当天证据。
- 航线、保研、资料库：查看或编辑 Markdown 原文。
- 学业对话：打开独立的“StudyRocket 学业助理”任务，聊天历史由本机 Codex 保存；当前应用开发任务不会被续接。
- “在 Codex 中打开”：通过 `codex://threads/<threadId>` 打开同一个学业任务；快捷报告会预填每日、每周或月度事实问题。
- 原生提醒：设置页登记每日 21:30、每周日 19:30、每月最后一天 19:30 的 macOS 通知。三类提醒独立执行；验收完成前保留旧 Scheduled Tasks。

应用是 Markdown 的轻量视图，不维护独立数据库。Codex Skill 生成的内容先展示草案；应用中的结构化编辑只有点击“保存”后才写入文件。若 Codex 与应用同时编辑同一文件，应用会按加载时哈希提示冲突，不会静默覆盖。

学业对话中的 Markdown 修改先生成草案。应用只接受允许范围内的 `.md` 文件，显示候选正文和理由；确认“应用已选修改”后才进行 SHA-256 冲突检查、备份和原子保存。周复盘中，只有三次以上可证据规律才可提出仓库 Skill 修改草案；确认后仅能更新八个现有 `SKILL.md`，不会更新 YAML、脚本、应用源码或全局 Skill。

航线、保研和资料库默认以正常 Markdown 格式打开，支持标题、引用、任务清单、代码块和表格。顶部“查看 / 编辑”可在渲染预览与 Markdown 源码之间切换；切换文件前若有未保存修改，应用会要求选择保存、放弃或取消。

## 重新构建与卸载

```bash
cd apps/NCUStudyRocket
./Scripts/test_markdown.sh
./Scripts/build_app.sh
```

快速验证使用 `./Scripts/test_markdown.sh`，不依赖完整 Xcode 或 XCTest。

卸载只需退出应用并移除 `/Applications/NCU StudyRocket.app`。备份位于 `~/Library/Application Support/NCU StudyRocket/Backups/`，不会提交到 GitHub。

关闭应用会终止本次 app-server 子进程，不创建 LaunchAgent、登录项、菜单栏常驻程序或网络监听端口。系统通知由 macOS 独立投递，点击后重新打开应用并进入学业对话。

## iPhone 伴随端（iOS 26）

手机端源码位于 `apps/NCUStudyRocketMobile/`，共享 DTO 位于 `apps/NCUStudyRocketShared/`。手机不运行 Codex、不保存 Markdown 事实，也不携带模型令牌；Mac 仍是唯一 Host、唯一 Markdown 写入端和 Codex 运行端。手机只缓存最近一次只读快照与未发送草稿，离线时不能写入仓库。

Mac 端的手机 Host 是独立的菜单栏应用，手动启动后才监听 `127.0.0.1:43817`；它不创建 LaunchAgent、登录项或常驻后台服务。Host 启动时先恢复固定学业任务并校验 `studyrocket` 动态工具声明，协议自检成功前聊天和草案接口保持不可用。Host 随后在 `~/Library/Application Support/NCU StudyRocket/` 写入权限为 600 的短期本地会话令牌和 Codex 单实例租约，停止时删除。主应用检测到令牌后优先复用 Host 的固定学业任务；Host 自检期间会短暂等待，不会抢占第二个 app-server；Host 未启动时仍使用原有本机 stdio 路径，不影响原应用单独运行。需要完整 Xcode 26 才能签名运行 iPhone target，CommandLineTools 仅能验证 SwiftPM 代码：

```bash
cd apps/NCUStudyRocket
./Scripts/build_host_app.sh
# 需要安装到 /Applications 时再执行
./Scripts/install_host_app.sh
```

手机与 Mac 可通过同一 Tailscale tailnet 的 Serve HTTPS 地址连接。首次连接使用 Host 菜单栏显示的 5 分钟一次性配对码；之后每个请求由 iPhone Secure Enclave 密钥签名，Host 在 Keychain 中保存公钥。学业对话仍续接固定的 `StudyRocket 学业助理` 任务，普通聊天只读；Markdown 或 Skill 修改先变成草案，手机 Face ID 确认后还要签署 Host 发出的短时一次性挑战，Host 再做哈希、白名单和原子写入检查。手机端拒绝明文 HTTP 地址，Host 只绑定 `127.0.0.1`，菜单栏会显示 Tailscale Serve 检测结果并提供复制地址操作。移动端对话使用与 Mac 相同的 `swift-markdown-ui 2.4.1` GFM 渲染，后台时会断开 SSE，回到前台再刷新。

手机通知的每日、每周、月末提醒独立登记，点击后进入“对话”并预填对应报告问题。Mac 原生提醒在没有明确保存过设置的新安装中默认关闭，已有设置不被覆盖。迁移验收期间保留现有 Codex Scheduled Tasks；不要因为安装手机端而停用原提醒。

原始 PDF 继续由 `.gitignore` 排除并使用私有云盘单独备份；不要把账号、令牌、身份证号或医疗隐私写入仓库。
