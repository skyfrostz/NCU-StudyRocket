# 学业对话重设计与附件验证（2026-11-14）

状态：两端新版已原位安装；云端已正式部署，Mac 签名读取和最新备份下载核验通过。用户已明确接受供应商极简 PDF 空解析限制，原始 FAIL 保留。

## 产品与数据边界

- 两端采用原生 ChatGPT 风格，保留 StudyRocket 导航和单个跨端学业会话。
- 系统字体；右侧用户气泡内部左对齐；学业 Markdown 仍只经草案确认写入。
- 上传原件属于聊天材料；用户已确认从上传起最多保留 30 天；用户源照片/文件不修改。
- 同时一个模型回合；打断必须绑定旧回合，终态确认后新请求只发送一次。
- 保留现有身份、历史、队列、草稿与备份；24 小时等待已由用户豁免，并非通过。

## 当前证据

| 检查 | 结果 | 范围 |
| --- | --- | --- |
| Shared 检查 | PASS | 含分块续传、整件下载哈希、损坏拒绝、不覆盖目标、文件变化拒绝、旧备份 DTO |
| Desktop 自动检查 | PASS | 18 组；Debug/Release、真实 NSTextView 试探宽度及窗口变化回归、消息渲染、定向停止及冻结草稿恢复 |
| Mobile 自动检查 | PASS | 141 项；Debug/Release/SelfCheck、签名、未知回执、迟到历史隔离、跨仓库普通/冻结附件保留 |
| Mac 实际窗口 | PASS | 窗口与全屏阅读区、内部表格滚动、原生输入换行/高度、返回最新位置稳定；合成输入已清除且未发送 |
| iOS 隔离界面 | PASS | 原生相册导入、纯附件发送、缩略图/QuickLook、选择文字、深浅色、标准最大字号、Return 换行、阅读历史后刷新回到最新 |
| iOS 隔离打断发送 | PASS | 流式过程中继续输入，旧回合 interrupted，新回合 completed 且仅创建一次；旧回复保留，无白屏/刷新提示卡回跳 |
| iPhone 原位安装 | PASS | 签名包 82999ba9…ab9927，安装后查询成功；Application Support 和 Preferences 共 6 个文件回读逐字节一致，未自动启动 |
| Mac 原位安装 | PASS | 严格签名验证，最终执行文件 b70dc569…23afa7f，实际启动并完成上述窗口复验 |
| 云端当前只读健康 | PASS | StudyRocket、SoulCourse、Nginx active；观察时可用内存 784MiB、磁盘剩余16GiB；非新候选压测 |
| Linux 最终候选与真实模型附件 | PASS WITH ACCEPTED LIMITATION | SHA 95d44340…e75cba；Linux 80 项、首轮四格式和补充九格式通过；标准图文 PDF 三次正确，极简矢量 PDF 三次为空，用户已接受此限制 |
| 新版本生产部署 | PASS WITH ACCEPTED LIMITATION | 95d44340…e75cba 已启用；正式数据基线不变，既有配对 Mac 读取/附件入口及 38 项备份下载核验通过 |
| 物理相机、VoiceOver、辅助功能超大字号、中文组合输入、真机键盘避让及跨网附件 | NOT RUN | 不以自动测试、标准最大字号或模拟器截图替代真机现场验收 |

## 本轮发现并修复的问题

- 实际 Mac 全屏输入发现 SwiftUI 试探测宽污染正在编辑的 NSTextView，造成窄列换行；改为独立测量对象，活动文本容器只跟随实际 clip bounds，真实窗口重验通过。
- Mac 跨仓库连接残留旧冻结/失败发送状态，现按 scope 分别持久化和恢复；损坏缓存保守停止清理。HEIC/HEIF 已补齐副本转换及原件保留检查，JSON 使用 32MiB 限制。
- 手机已发送缓存可能同时被另一仓库草稿或冻结重试引用；清理前保护所有 archive 引用，不可读 archive 时保守推迟删除。141 项回归测试及最终手机原位安装通过。
- 供应商可能把 XLSX 转换为 Markdown，回执字节数与原始文件不同；原件哈希和字节数保持独立，新增严格核验的 providerByteCount。此前清理失败保留为历史失败；最终两轮四格式、九格式与 PDF 对照共 19/19 原生对象删除已确认。
- 恢复流程拒绝路径穿越、重复 JSON 键和非法附件元数据；未知取消/发送回执使用持久化身份协调，不重复发送或误取消新回合。

界面合成证据保存在本机 `/tmp/studyrocket-chat-ui-evidence/`；手机数据备份保存在用户私有迁移目录。截图和设备身份不提交 Git。

## 参考

- [ChatGPT macOS 附件交互](https://help.openai.com/en/articles/9295234-chatgpt-macos-app-file-uploads-and-photos)
- [DeepSeek 原生视觉](https://api-docs.deepseek.com/guides/vision/)
- [DeepSeek 文件解析](https://api-docs.deepseek.com/guides/document_parsing/)
- [DeepSeek 文件上传及到期参数](https://api-docs.deepseek.com/api/create-file/)：自动到期只支持 `created_at`，上限 2,592,000 秒；当前实现以供应商实际到期时间为上界，客户端显示 DTO 到期日。用户已明确确认采用“上传后最多 30 天”；未发送本地草稿继续保留。
- [SwiftUI Agent Skill](https://github.com/twostraws/SwiftUI-Agent-Skill/tree/f2920b63995263f57b3e198674e89a602efba6d2)，仅参考适用于现有部署目标的条目。

## 已接受的外部限制

用户明确选择“先上线，明确保留 PDF 限制”。699 字节合法极简矢量 PDF 在有界同 ID 0/15/60 秒实验均被供应商解析为空；14,360 字节标准导出的图文 PDF 三次正确识别图形、颜色、数字及正文。没有新增客户端渲染后备，也不自动重复上传产生解析费用。遇到此类不可读文件时，应重新导出 PDF 或上传页面照片；不能宣称模型已经读取其内容。此限制不改变正式 Markdown 的草案确认流程。

QA 使用独立临时仓库，整个 QA 期间没有采集生产 Markdown/业务表的前后哈希，不能据此宣称全程哈希一致。正式切换另从静止状态采集新基线，核对文件和全部既有业务表，并仅允许空附件表新增。

## 正式发布结果

- 2026-11-14 13:34（北京时间）部署 `20261114-chat-redesign-95d44340bc67`；只重启 StudyRocket。SoulCourse PID、配置和数据库健康保持正常，实际 Nginx 配置恢复原字节，备份 timer 恢复。
- 从切换静止基线核对 36 份 Markdown、473 条消息、2 个设备、2 份既有草案及所有已有 SQLite 表摘要/仓库身份，全部不变；只新增空 attachments 表。没有恢复或覆盖正式数据。
- 7 个新附件/定向停止未签名接口均返回 401。Mac 现有配对读取、附件菜单启用通过；新备份 `20261114T053433Z-896d13e1` 共 38 项下载、长度和 SHA256 核验通过。
- 首次发布因控制器 umask 导致新 release 目录不可遍历，在新版备份阶段安全中止；旧版备份已验证，二进制切回且基线完全保留。显式设置 release 目录权限、增加服务用户读取检查后重试成功。保留此失败记录，不记为首轮成功。
- 测试与发布均未制造真实学业记录、勾选或确认草案。24 小时观察仍为用户豁免。
