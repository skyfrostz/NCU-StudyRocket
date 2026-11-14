# 聊天与附件维护验证（2026-11-14）

## 已实现

- 聊天页从 `MobileRootView` 拆出；消息、原生输入区、附件和草案 sheet 分工。继续使用原生系统字体、单共享历史和原有流式合并/滚动意图保护；用户消息靠右、内部左对齐。
- 原生照片图库、相机和 Files；HEIC/HEIF 转 JPEG；私有缓存副本；后台 ImageIO 128px 缩略图；QuickLook 按需预览；上传进度、失败重试及移除。
- 支持 10 个附件、总计 100 MiB；图片 20 MiB、文档 100 MiB、文本/表格 32 MiB。附件和文字共同持久保存，云端按用户确认从上传起最多保留 30 天；已发送本地缓存按期限清理，只删除应用私有副本。
- 新消息打断前冻结文字、附件和请求身份，独立保存 stop operation ID；等待指定旧回合权威终态后发送。冻结附件移出可编辑输入区。未知回执不换 ID、不盲发；仅操作日志明确 `operation_not_found` 才按原 ID/原内容发送。失败重试不覆盖普通输入草稿。
- `chat-attachments`、`targeted-interrupt` 能力门禁防止旧服务静默丢弃新字段。连接/仓库 generation 同时保护上传、预览、picker 迟到结果。

## 自动验证

- PASS：Mobile `swift test`，141 项，0 失败（日志 `/tmp/mobile-chat-tests.log`）。
- PASS：iOS Simulator Debug 构建（日志 `/tmp/mobile-chat-ios-debug.log`）。
- PASS：iOS generic-device Release，沿用现有签名设置（日志 `/tmp/mobile-chat-ios-signed-release.log`）；`codesign --verify --deep --strict` 通过。产物 `/tmp/studyrocket-chat-redesign-mobile/Build/Products/Release-iphoneos/NCUStudyRocketMobile.app`。
- PASS：SelfCheck 配置模拟器构建及严格签名验证；仅安装到既有 iPhone 17 Pro 隔离 bundle `com.skyfrost.ncustudyrocket.mobile.selfcheck`，后续原位升级并启动，localhost:43827 绑定及已知合成输入草稿核验保留。日志 `/tmp/mobile-chat-ios-selfcheck.log`。
- PASS：`git diff --check -- apps/NCUStudyRocketMobile`。
- 新增 fixture 覆盖文字/附件/冻结状态重启、仓库隔离、源文件保留、附件数量和类型、仅已发送 30 天缓存清理、到期/未确认附件禁发、续传新身份和副本字节、后台缩略尺寸、等待指定终态、连续点击不多发、纯附件冻结、未知回执重启、POST 前崩溃原 ID 恢复、旧服务能力缺失禁发。

## 验收边界

此轮自动测试使用临时目录与 URLProtocol fixture；未发送生产测试聊天、未改真实学业 Markdown。签名构建不代表真机现场验收；总控安装和隔离界面结果见下方。VoiceOver、辅助功能超大字号、物理相机、中文组合输入、真机键盘避让与跨网新附件流程尚未执行。

## 后续正确性与输入修复

- `ChatInterruptResponse` 严格核对 targetTurnID、operationID、terminal.turnID 和状态；即使旧回合从有限近期历史中淘汰，也保存并使用权威终态。若另一端的新回合正在运行，保持它的 busy 状态，不停止它。
- 已提交请求的 operation 已终结但历史被淘汰时，定向读取该旧请求的终态，不重复发送。旧草稿 schema 缺 stop/read operation ID 时，先分别生成并持久保存，不与 send ID 共用；新增重启和历史淘汰 fixture。
- 输入区改为原生 `TextEditor`，Return 保持换行语义，无 submit 回调；文字自然测高并保留系统输入法组合态。QuickLook 缓存使用 UUID 目录与原始文件名，避免标题显示 UUID 前缀。
- 较早 SelfCheck 原位升级后的广泛全文件 hash 一致性检查未通过，不能宣称该次全部缓存逐字节相同；后续专门确认 localhost:43827 绑定及 `A short test` 合成草稿 SHA 保留后启动。详情 `/tmp/mobile-chat-selfcheck-upgrade.json`。这一历史结果与下方正式设备最终安装回读分开记录。

## 最终阻断修复（139 项测试）

- 普通未知发送也会读取操作日志并核验 typed 终态；历史窗口淘汰不再导致永远待确认。完成则结清 pending，失败保留显式重试入口、原附件 ID 和当前普通输入草稿；旧连接的迟到成功不回写新连接提示。
- GET 历史和发送回执共用单调请求序；较新请求结果已经应用后，较旧结果及其错误不得覆盖当前聊天。当前会话已确认的普通 ID 消息在近期历史窗口移动后仍保持可见。专项 fixture 覆盖 refreshChat/refreshConversation 双向迟到和旧正文降级。
- 输入区右侧只显示一个主按钮：忙碌且空输入为停止，有新内容为打断后发送；空闲无内容发送按钮明确降至 35% opacity。停止不继承发送有效性条件，编辑区持续可输入。
- 最后一次隔离 SelfCheck 原位升级，endpoint、inputDraft、repositoryID、deviceID 四个核心值逐值一致，再启动现有 localhost:43827 绑定。证据 `/tmp/mobile-chat-selfcheck-latest-upgrade.json`；不据此推定其他缓存完全一致。

## 跨仓库冻结附件保护（141 项测试）

- 清理过期已发送缓存前扫描所有 scope archive，保护普通草稿与冻结 replacement 引用的私有文件；不可读取的 archive 使本次清理保守推迟。只有所有草稿都已解除引用的过期 receipt 才删除文件。
- 新增临时目录测试覆盖跨 scope 的旧发送附件重试/冻结、重启恢复、解除引用后的清理及损坏 archive 保护。
- 签名 Release 已重建，执行文件 SHA256 `4c89775ca0ec38cef9fcf40557b73dda4cbb57d023182a1d2d50283b67863e2d`；真实设备更新由总控执行，本子任务没有操作真机。

## 总控安装与隔离界面验证

- PASS：最终到期日界面包 `82999ba9876922d1c297082e2c460b3cef5b06254af235655b6bf0ec95ab9927` 原位安装到已有 iPhone；先备份 Application Support 和 Preferences，安装后回读 6/6 文件字节与 SHA 完全相同，无丢失/变化/新增；安装查询成功，未自动启动。私有回执 `/tmp/studyrocket-phone-chat-redesign-receipt.json`，不提交设备身份或原始缓存。
- PASS：SelfCheck 原生照片选择器导入合成 PNG，纯附件发送、缩略图、历史文件卡片和 QuickLook 原件；菜单复制/选择文字；Return 多行，标准最大字号及深浅色，表格内部滚动；阅读历史后刷新回到最新，无连接/缓存提示卡回跳。
- PASS：合成慢流期间继续输入，按钮由停止变为打断发送；旧回合保持部分文字并进入 interrupted，新回合仅创建一次并 completed。收据与截图位于 `/tmp/studyrocket-chat-ui-evidence/`。
- 上述屏幕检查使用 139 项阶段的界面包；最终 141 项仅增加缓存引用保护，未改界面。最终缓存代码有自动回归及真机安装证据，未重新逐项重跑屏幕矩阵。

- 最终文件卡片使用 DTO 真实 expiresAt，按北京时间显示到期日并提供 VoiceOver 值；141 项测试、Release/SelfCheck 和严格签名均再次通过。
