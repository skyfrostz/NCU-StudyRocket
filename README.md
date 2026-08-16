# NCU StudyRocket

> **Local-first academic workspace for NCU Biomedical Data Sciences students**
>
> **南昌大学数据科学与大数据技术（中外合作办学）/ Biomedical Data Sciences 本地优先学业工作台**

NCU StudyRocket turns a Markdown repository into a structured academic workspace. The macOS application provides the primary desktop experience, Codex provides the separate academic-assistant workflow, an optional macOS Host exposes a controlled local API for the iPhone companion client, and Markdown remains the single source of truth.

NCU StudyRocket 将 Markdown 仓库变成结构化学业工作台。macOS 原生应用提供桌面主体验，Codex 负责独立的学业助理任务，可选的 macOS Host 为 iPhone 伴随端提供受控本地 API，而 Markdown 始终是唯一事实来源。

## 1. Executive Summary

### 中文

NCU StudyRocket 面向需要长期维护课程、复盘、科研、英语和保研资料的学生。它不是第二套数据库，也不是把学习事实上传到云端的 SaaS；它是绑定本地仓库的原生工作台：

- Markdown 文件保存课程计划、每日行为账、航线、保研资料和学业事实。
- macOS 桌面端负责查看、编辑、提醒和学业对话。
- Codex 学业对话使用独立的固定任务，不读取当前开发任务。
- 学业对话中的文件修改先生成草案，用户确认后才经过冲突检查、备份和原子写入。
- iPhone 端只缓存只读快照和未发送草稿；受控的计划/复盘更新通过 Mac Host 完成。
- Mac Host 默认不运行、不监听端口、不创建 LaunchAgent；只有用户手动启动并开启手机连接后才工作。

### English

NCU StudyRocket is designed for students who need a durable workspace for courses, reviews, research, English study, and graduate recommendation planning. It is not a second database and not a cloud SaaS product that uploads academic facts. It is a native, repository-bound workspace:

- Markdown files store plans, daily evidence, routes, graduate-recommendation material, and academic facts.
- The macOS desktop app provides viewing, editing, reminders, and academic chat.
- Academic chat uses a dedicated fixed StudyRocket task and does not reuse the current development task.
- File changes proposed by academic chat become a reviewable draft first, then go through conflict detection, backup, and atomic writing after confirmation.
- The iPhone app caches read-only snapshots and unsent drafts; controlled plan and review writes go through the Mac Host.
- The Mac Host is opt-in. It does not listen, run as a LaunchAgent, or create a background service until the user manually starts mobile connectivity.

## 2. Product Scope and Boundaries

| Surface | Platform | Responsibility | Persistence |
| --- | --- | --- | --- |
| StudyRocket desktop | macOS 14+ | Markdown workspace, desktop chat, reminders, editing | Repository Markdown plus local app support data |
| StudyRocket Host | macOS 14+ | Optional iPhone bridge, Codex lease, pairing, authenticated API | Keychain, short-lived local session, repository Markdown |
| StudyRocket Mobile | iOS 26+ | Read-only snapshot, chat, controlled plan/review actions, local notifications | Device Keychain, local cache, local drafts |
| StudyRocket Shared | macOS/iOS | DTOs, protocol versioning, request signing, lease model | No independent data store |
| Codex | Existing local installation | Academic-assistant task execution | Local Codex task state |

The repository is intentionally single-user and single-workspace oriented. It does not currently provide multi-tenant accounts, cloud synchronization, organization administration, remote database storage, server-side user management, or a hosted production control plane.

## 3. Core Principles

1. **Markdown is authoritative.** The UI is a view and editing layer, not a replacement database.
2. **Explicit writes only.** Drafts, structured edits, and mobile writes require an explicit confirmation path.
3. **Local-first privacy.** Academic facts and PDFs remain local or in the user’s private backup workflow.
4. **Conflict-aware writes.** Revision/hash checks prevent silent overwrite when another process changes a file.
5. **Least privilege.** The iPhone never runs Codex and never writes the repository directly.
6. **Stable protocol boundaries.** Desktop, Host, Mobile, and Shared code have separate responsibilities and a versioned API.
7. **Graceful degradation.** Offline mobile mode retains the latest snapshot and drafts; Host/SSE failures retain visible history rather than blanking the UI.
8. **No silent background service.** The Host and reminders are user-visible, opt-in, and stoppable.

## 4. Capabilities

### Desktop workspace

- Home view with daily time slots and weekly deliverables.
- Weekly-plan editing with managed Markdown boundaries.
- Daily behavioral log with evidence-oriented fields.
- Route views for courses, research, lifestyle, and graduate recommendation planning.
- Markdown preview/source editing with save, discard, cancel, and external-change conflict handling.
- PDF-derived text consumption without committing original PDFs.
- macOS native reminders for daily, weekly, and monthly review prompts.
- A dedicated StudyRocket academic conversation with draft-based file changes.

### Chat reliability

- Recent history is intentionally bounded to the latest 20 turns.
- Stable turn and message identifiers are preserved across streaming deltas and completion events.
- Host clients consume typed SSE events instead of rebuilding the full history every 500 ms.
- Load failures expose an explicit state and retain the last usable history.
- Streaming responses use lightweight text rendering; completed Markdown is parsed once and cached.
- Markdown tables use a stable text fallback inside the fast-scrolling transcript to avoid geometry feedback from table layout.
- Scroll requests are coalesced; reading older history never forces an automatic jump to the bottom.

### iPhone companion

- Read-only home, weekly plan, daily review, summaries, and academic chat.
- Foreground SSE updates with reconnect backoff.
- Offline snapshot cache and pending draft storage.
- HTTPS-only Host endpoint configuration.
- One-time pairing code plus per-device request signatures.
- Keychain-backed device identity; on iPhone, the signing key uses Secure Enclave when available.
- Face ID authorization for controlled proposal application.
- Independent local notifications; the iPhone does not keep SSE alive in the background.

## 5. Architecture

~~~mermaid
flowchart LR
    Repo[(Markdown repository)]
    Desktop[macOS desktop app]
    Codex[Local Codex academic task]
    Host[Optional StudyRocket Host]
    Mobile[iPhone companion]
    Tailnet[Tailscale Serve HTTPS]
    Shared[StudyRocketShared DTOs and signing]

    Desktop -->|read/write with explicit save| Repo
    Desktop -->|stdio fallback or Host SSE| Codex
    Desktop -.->|optional local session| Host
    Mobile -->|HTTPS, signed requests| Tailnet
    Tailnet --> Host
    Mobile --> Shared
    Host --> Shared
    Host -->|fixed task, lease protected| Codex
    Host -->|validated atomic writes| Repo
    Host -->|typed SSE snapshots and chat events| Mobile
~~~

### Runtime modes

#### Desktop without Host

The desktop app uses the existing local Codex stdio path. No network listener is created by the desktop app.

#### Desktop with Host

When the optional Host is available, the desktop app can reuse the Host-owned fixed academic task through a short-lived local session. The two components share one Codex lease and must not start two app-server instances for the same workspace.

#### iPhone with Host

The iPhone connects to the Host through a Tailscale Serve HTTPS address. The Host remains the only Mac-side process allowed to own the Codex session and write the repository for mobile requests.

## 6. Repository Layout

~~~text
.
├── AGENTS.md                         # Operating rules and repository boundaries
├── PROFILE.md                        # User profile; complete before planning
├── README.md                         # This bilingual product and operations guide
├── 校历与重要日期.md                  # Academic calendar and important dates
├── 工作台/                            # Active planning and evidence workspace
│   ├── 下周计划.md
│   ├── 每日记录/
│   ├── 航线/
│   └── 学期/
├── 保研/                              # Graduate recommendation planning
├── 答疑/                              # Archived academic Q&A
├── 智库/                              # Source material and official documents
├── PDF提取文本/                       # Generated searchable PDF text
├── apps/
│   ├── NCUStudyRocket/                # macOS app, Host, chat core, tests
│   ├── NCUStudyRocketMobile/          # iPhone SwiftUI app and Xcode project
│   └── NCUStudyRocketShared/          # Shared macOS/iOS protocol package
└── scripts/                           # Repository-level utilities, if present
~~~

### Platform ownership

| Directory | Owner surface | Notes |
| --- | --- | --- |
| apps/NCUStudyRocket/Sources/NCUStudyRocket/ | macOS desktop | Main app, Markdown editor, desktop chat |
| apps/NCUStudyRocket/Sources/StudyRocketChatCore/ | macOS core | Chat reducer, history state, scroll and stream coordination |
| apps/NCUStudyRocket/Sources/StudyRocketHost/ | macOS Host | Menu-bar Host, pairing, API, SSE, write service |
| apps/NCUStudyRocketMobile/ | iPhone | SwiftUI client, cache, notifications, pairing UI |
| apps/NCUStudyRocketShared/ | Shared | API DTOs, signing, lease and protocol checks |

## 7. Requirements

### Required for desktop development

- macOS 14 or later.
- Swift toolchain compatible with the package manifests.
- A working Codex installation bundled with ChatGPT at:
  /Applications/ChatGPT.app/Contents/Resources/codex
- A repository containing both AGENTS.md and PROFILE.md.
- The user’s existing Codex login/session configuration.

### Required for Host and iPhone development

- macOS 14 or later for the Host.
- Full Xcode 26 for the iOS app, iOS 26 SDK, signing, device installation, and notification permission validation.
- An iPhone configured for development mode.
- A Tailscale account and tailnet if the iPhone is connecting outside the local loopback boundary.
- Tailscale Serve configured by the user; StudyRocket does not start Tailscale or change its network settings.

CommandLineTools can compile some Swift Package targets, but it is not sufficient for final iPhone signing or device acceptance.

## 8. Quick Start: macOS Desktop

### 8.1 Bind a workspace

1. Open the repository in Codex or launch the installed app.
2. Confirm that the selected root contains AGENTS.md and PROFILE.md.
3. Complete PROFILE.md before asking for personalized planning.
4. Keep original PDFs outside Git; use PDF提取文本/ for generated searchable text.

The app can be built and installed from the package directory:

~~~bash
cd apps/NCUStudyRocket
./Scripts/test_markdown.sh
./Scripts/install_app.sh
~~~

The install script builds the release bundle, creates the local app bundle, ad-hoc signs it, verifies the signature, copies it to:

~~~text
/Applications/NCU StudyRocket.app
~~~

The script is intended for local development and acceptance. It does not produce a notarized DMG or a distribution-signed installer.

### 8.2 Build without installing

~~~bash
cd apps/NCUStudyRocket
swift build
swift build -c release
./Scripts/build_app.sh release
~~~

### 8.3 Debug stress fixture

The Debug-only fixture does not connect to the real academic task. It generates 20 turns and 60 messages with long text, tables, code blocks, and a continuously streaming answer:

~~~bash
cd apps/NCUStudyRocket
./Scripts/build_app.sh debug
open -n ".build/NCU StudyRocket.app" --args --chat-stress-fixture
~~~

Use this fixture for fast scrolling, window resizing, stream updates, process expansion, and return-to-latest checks. Do not use it as a production data source.

## 9. Optional Mac Host and iPhone Setup

### 9.1 Build and install the Host

~~~bash
cd apps/NCUStudyRocket
./Scripts/build_host_app.sh
./Scripts/install_host_app.sh
~~~

The Host is installed as:

~~~text
/Applications/StudyRocket Host.app
~~~

After launch, open the menu-bar item and explicitly choose “启动手机连接” / “Start mobile connection”. The Host first:

1. Binds the selected repository.
2. Acquires the single Codex lease.
3. Resumes the fixed StudyRocket academic task.
4. Validates the required studyrocket dynamic-tool contract.
5. Starts the local API only after readiness checks pass.

If readiness checks fail, chat and proposal APIs remain unavailable.

### 9.2 Configure Tailscale Serve

1. Sign in to the same Tailscale tailnet on the Mac and iPhone.
2. Configure Tailscale Serve for the Host’s local port.
3. Confirm that the Host menu shows a usable HTTPS address.
4. Copy the HTTPS address and the one-time pairing code from the Host menu.

StudyRocket Host listens on 127.0.0.1:43817. The Host does not bind a public interface and does not start Tailscale automatically.

### 9.3 Pair the iPhone

1. Open the iPhone target from apps/NCUStudyRocketMobile/NCUStudyRocketMobile.xcodeproj in full Xcode 26.
2. Select a development team and an iPhone running iOS 26.
3. Launch the app and open the connection settings.
4. Enter the HTTPS Host address and the one-time pairing code.
5. Confirm the paired device in the Host menu.
6. Verify health, snapshot, chat, SSE, and controlled write paths.

The pairing code is six digits, expires after five minutes, and is invalidated after five failed attempts. The device public key is stored on the Host in Keychain after pairing.

### 9.4 Mobile validation boundary

The authoritative mobile build is the iOS target in full Xcode 26:

~~~text
apps/NCUStudyRocketMobile/NCUStudyRocketMobile.xcodeproj
~~~

The Mobile package includes iOS-only SwiftUI APIs and is not a supported macOS command-line acceptance target. Use Xcode for compilation, signing, device installation, Face ID, notifications, background/foreground behavior, and Tailscale acceptance. The platform-neutral Shared package can still be checked from the command line:

~~~bash
swift run --package-path apps/NCUStudyRocketShared StudyRocketSharedChecks
~~~

## 10. API Contract

The current protocol version is 1 and the default Host port is 43817. All non-pairing device requests are authenticated with the paired device signature. Health and pairing are bootstrap paths.

| Method | Endpoint | Purpose | Write |
| --- | --- | --- | --- |
| GET | /v1/health | Host readiness, repository binding, Codex and protocol status | No |
| POST | /v1/pair | Exchange a five-minute pairing code for a device record | No |
| GET | /v1/snapshot | Full read-only home/week/daily/summaries snapshot | No |
| GET | /v1/week | Read the weekly plan | No |
| POST | /v1/week | Apply a validated weekly-plan snapshot | Yes |
| GET | /v1/daily | Read daily evidence | No |
| POST | /v1/daily | Save one daily evidence entry | Yes |
| GET | /v1/summaries | Read summary cards | No |
| POST | /v1/deliveries/toggle | Toggle one known weekly deliverable | Yes |
| GET | /v1/proposals | Read pending proposals | No |
| GET | /v1/proposals/challenge | Issue a short authorization challenge | No |
| POST | /v1/proposals/apply | Apply selected proposals after biometric authorization | Yes |
| GET | /v1/chat/history | Read recent chat history | No |
| POST | /v1/chat/send | Start a chat turn | Yes, asynchronous |
| POST | /v1/chat/interrupt | Interrupt the active chat turn | Yes |
| GET | /v1/events | Authenticated typed Server-Sent Events stream | No |

### Request safety

- API version mismatch is rejected.
- Write requests carry a base revision.
- The Host recomputes the current repository revision before writing.
- Known write operations use idempotency keys and replay protection where applicable.
- Weekly, daily, and proposal writes are restricted to approved Markdown paths and managed sections.
- A stale revision returns a conflict rather than silently overwriting newer content.
- Proposal application additionally requires a short-lived authorization challenge signed by the paired device.

## 11. Security and Privacy Model

### Identity and transport

- The iPhone accepts HTTPS Host endpoints only; plain HTTP is rejected.
- Pairing uses a six-digit, five-minute code with a five-attempt limit.
- On iPhone, the device signing key is generated through Secure Enclave P-256 when available and stored as a device-only Keychain item.
- Each authenticated request includes device ID, timestamp, nonce, signature, method, path, and body hash.
- Requests outside a 60-second timestamp window are rejected.
- Nonces are retained to prevent replay and expire from the replay cache after five minutes.
- Paired devices can be revoked from the Host.
- Proposal writes require a separate 90-second authorization challenge and biometric confirmation on the iPhone.

### Local ownership and file protection

- The Host binds to 127.0.0.1:43817.
- Tailscale Serve is the user-controlled HTTPS exposure layer.
- The short-lived Host session token and Codex lease are stored under the user Application Support directory with restrictive permissions and are not committed.
- The Codex lease prevents two StudyRocket components from owning the same app-server session.
- The iPhone never receives a Codex token and never writes Markdown directly.
- Original PDFs, credentials, private keys, and personal secrets must not be committed.
- The repository does not contain a license grant or a hosted service agreement; distribution and deployment require owner approval.

### Privacy boundary

The application does not add external telemetry. Runtime diagnostics use local crash reports, debug logs, and local performance sampling. If Tailscale Serve is enabled, network reachability is governed by the user’s tailnet and Tailscale configuration.

## 12. Data and Write Semantics

### Source of truth

The repository is authoritative. Typical managed files include:

- PROFILE.md for the profile and planning constraints.
- 工作台/下周计划.md for weekly schedule, deliveries, and buffer rules.
- 工作台/每日记录/YYYY-MM.md for daily evidence.
- 工作台/航线/ for course, research, graduate-recommendation, and lifestyle routes.
- 智库/ for source material; original PDFs are kept outside Git.

### Desktop writes

The desktop editor keeps changes in memory until the user clicks Save or uses the documented save shortcut. External changes are detected through loaded-file hashes. The app asks the user to reload and compare instead of silently overwriting.

### Academic chat proposals

1. Codex produces a structured proposal.
2. The app displays affected files, candidate content, and reasons.
3. The user selects the changes to apply.
4. The app checks allowed paths and the base SHA-256 revision.
5. A backup is created under:

   ~/Library/Application Support/NCU StudyRocket/Backups/

6. The selected Markdown files are written atomically.

Skill changes are intentionally narrower: only the eight existing repository SKILL.md files may be proposed after a repeated, evidence-based workflow pattern and explicit confirmation. YAML, scripts, app source, global skills, PDFs, and generated PDF text are outside that write path.

### Mobile writes

The iPhone sends structured requests to the Host. The Host checks API version, device signature, revision, allowed path, idempotency, and any required biometric authorization before writing. A failed check leaves the repository unchanged.

## 13. Chat Reliability and Performance Design

The chat transcript is deliberately treated as a high-risk SwiftUI surface:

- ChatTranscriptState isolates transcript mutations from draft and connection state.
- ChatHistoryLoadState distinguishes loading, loaded-empty, loaded-history, and failed-with-retained-history.
- Connection generations and task cancellation reject stale results after page changes or reconnects.
- History is published only when revision or content changes.
- Stream deltas update the current turn while preserving message IDs.
- Host and mobile consume typed SSE events; a single history refresh is used only as reconciliation.
- Timestamp space is reserved at a fixed height; hover changes opacity rather than layout.
- Scroll state publishes only when near-bottom state changes.
- Initial load scrolls once without animation; manual return-to-latest may animate.
- While the user reads older content, stream deltas do not force the viewport to the bottom.
- The Debug fixture provides a reproducible long-history and streaming workload.

The current product behavior keeps the latest 20 turns. This is a deliberate bound, not a pagination implementation.

## 14. Testing and Verification

### Fast checks

~~~bash
cd apps/NCUStudyRocket
./Scripts/test_markdown.sh
swift build
swift run NCUStudyRocketTests

cd ../NCUStudyRocketShared
swift run StudyRocketSharedChecks
~~~

The chat core checks cover reducer terminal states, retryable errors, proposal routing, scroll policy, duplicate revision suppression, retained history after failures, coalesced scroll requests, and stable streaming item IDs.

### Release acceptance

~~~bash
cd apps/NCUStudyRocket
swift build -c release
./Scripts/install_app.sh
codesign --verify --deep --strict "/Applications/NCU StudyRocket.app"
~~~

Recommended manual acceptance:

1. Load a real history containing long text, tables, and code blocks.
2. Scroll rapidly up and down for at least 60 seconds while a stream is active.
3. Leave and return to the chat page repeatedly.
4. Resize the window while history and streaming content are visible.
5. Expand process messages and use return-to-latest.
6. Disconnect Host SSE, confirm retained history and visible error state, then reconnect.
7. Confirm no crash report, blank transcript, duplicate message, forced bottom jump, or uncontrolled memory growth.

### Mobile acceptance

Full Xcode 26 acceptance must include:

- iOS build and code signing.
- Physical-device installation.
- Pairing code expiry and failed-attempt handling.
- HTTPS-only endpoint rejection.
- Keychain/Secure Enclave identity persistence.
- Tailscale Serve connectivity.
- Offline snapshot and draft recovery.
- Foreground SSE reconnect and background SSE release.
- Face ID challenge success, cancellation, expiry, and replay rejection.
- Revision conflict and atomic-write behavior.
- Local notification authorization and delivery.

## 15. Operations Runbook

### Normal startup

1. Open the repository and verify AGENTS.md and PROFILE.md.
2. Start the desktop app.
3. If mobile access is needed, start StudyRocket Host manually.
4. Wait for repository binding, Codex lease, and dynamic-tool self-check to succeed.
5. Enable mobile connectivity and pair only the intended device.

### Normal shutdown

1. Save or discard any open Markdown edits.
2. Stop mobile connectivity from the Host menu.
3. Quit StudyRocket Host.
4. Quit the desktop app.

No LaunchAgent, login item, or hidden listener should be created by the documented scripts.

### Recovery

| Symptom | Action |
| --- | --- |
| Desktop shows no repository | Rebind a directory containing AGENTS.md and PROFILE.md |
| Chat history is loading | Wait for the current connection generation; do not launch a second app-server |
| Host says Codex is busy | Stop the other StudyRocket/Codex owner and retry |
| Mobile is offline | Use the cached snapshot, check Tailscale Serve, then refresh |
| Pairing code expired | Generate a new code in the Host menu |
| Device lost or replaced | Revoke the old device and pair again |
| Proposal conflict | Reload the snapshot and generate a new proposal |
| Markdown editor reports external change | Reload and compare; do not force overwrite |
| App needs rebuilding | Run the test script before install; close the old app first |

## 16. Release and Change Management

The repository currently uses a direct Git workflow:

~~~bash
git status --short
git diff --check
git add -A
git commit -m "Describe the change"
git push
~~~

Before a release or shared-device deployment:

- Review the staged file list.
- Confirm that no PDF, token, credential, Keychain export, Xcode user state, or build cache is staged.
- Run Markdown, desktop, Shared, and relevant Host checks.
- Build and verify the release bundle.
- Validate mobile protocol compatibility; the API version is currently 1.
- Keep desktop and Host protocol changes synchronized with the mobile client.

There is no automated CI or published binary release pipeline in this repository at present. The current install scripts create locally signed development bundles.

## 17. Known Limitations

- The system is single-user and single-repository oriented.
- There is no cloud database, account service, organization admin console, or multi-tenant authorization model.
- The desktop app requires the local Codex installation and existing login/session configuration.
- The Host is optional and does not replace the desktop Markdown workflow.
- iPhone support requires iOS 26 and full Xcode 26 for final device acceptance.
- Tailscale is an external prerequisite for remote tailnet access; StudyRocket does not configure it.
- The Host API is a versioned companion protocol, not a public internet API.
- The latest 20 chat turns are retained by product policy; historical pagination is not implemented.
- Mobile notifications and macOS reminders are independent local systems.
- No notarized DMG, PKG, App Store build, TestFlight build, or signed enterprise distribution artifact is published by the repository.

## 18. Documentation Map

| Need | Document |
| --- | --- |
| Repository rules and ownership | AGENTS.md |
| User profile and constraints | PROFILE.md |
| iPhone-specific setup | apps/NCUStudyRocketMobile/README.md |
| Desktop source and tests | apps/NCUStudyRocket/ |
| Shared protocol source | apps/NCUStudyRocketShared/ |
| Official school documents | 智库/学校文件/ |
| Searchable generated PDF text | PDF提取文本/ |

## 19. License and Use

No open-source license is declared in this repository. Until a license is added, treat the code, content, visual assets, and documentation as private project materials and obtain permission before redistribution.

---

# NCU StudyRocket — English Reference

## 1. Executive Summary

NCU StudyRocket is a local-first academic workspace for the NCU Biomedical Data Sciences / Data Science and Big Data Technology joint-program context. It combines a Markdown repository, a native macOS desktop app, a dedicated Codex academic task, an optional macOS Host, and an iPhone SwiftUI companion.

The repository is the system of record. The desktop app reads and edits Markdown with explicit save semantics. Academic chat produces reviewable proposals instead of directly mutating files. The optional Host is the only Mac-side bridge for iPhone access and the only mobile-side component allowed to perform controlled writes. The iPhone never runs Codex and never receives a Codex credential.

This is a single-user, single-repository, local-first system. It is not a multi-tenant SaaS platform, hosted database, or enterprise identity service.

## 2. Product Surfaces

| Surface | Platform | Responsibility |
| --- | --- | --- |
| StudyRocket desktop | macOS 14+ | Workspace browsing, Markdown editing, chat, reminders |
| StudyRocket Host | macOS 14+ | Optional iPhone bridge, pairing, lease, SSE, validated writes |
| StudyRocket Mobile | iOS 26+ | Snapshot UI, chat, drafts, controlled writes, local notifications |
| StudyRocket Shared | macOS/iOS | Shared DTOs, signatures, protocol and lease checks |
| Codex | Existing local installation | Dedicated academic-assistant task execution |

The desktop app does not start a server, create a database, or create a persistent background service. The Host is opt-in and starts its loopback API only after readiness checks.

## 3. Design Principles

- Markdown remains authoritative.
- Writes require explicit user intent.
- File updates are revision-aware and atomic.
- Mobile access is least-privilege and Host-mediated.
- Academic facts stay local unless the user deliberately enables a user-controlled Tailscale path.
- Streaming and scroll state must degrade visibly rather than produce a blank transcript.
- There is no silent LaunchAgent, login item, telemetry pipeline, or hidden listener.

## 4. System Architecture

~~~mermaid
flowchart LR
    Repo[(Markdown repository)]
    Desktop[macOS desktop app]
    Codex[Local Codex academic task]
    Host[Optional StudyRocket Host]
    Mobile[iPhone companion]
    Tailnet[Tailscale Serve HTTPS]
    Shared[Shared DTOs and signing]

    Desktop -->|explicit read/write| Repo
    Desktop -->|stdio fallback or Host SSE| Codex
    Desktop -.->|optional local session| Host
    Mobile -->|HTTPS signed requests| Tailnet
    Tailnet --> Host
    Mobile --> Shared
    Host --> Shared
    Host -->|lease-protected fixed task| Codex
    Host -->|validated atomic writes| Repo
    Host -->|typed SSE| Mobile
~~~

### Runtime modes

**Desktop without Host:** the desktop app uses the local Codex stdio path and does not expose a network listener.

**Desktop with Host:** when the optional Host is ready, the desktop app can use the Host-owned fixed academic task through a short-lived local session. A shared Codex lease prevents two owners from starting competing app-server sessions.

**iPhone with Host:** the iPhone reaches the Host through a Tailscale Serve HTTPS address. The Host owns the Mac-side Codex session and all repository writes initiated by mobile.

## 5. Repository Layout

~~~text
.
├── AGENTS.md                         # Operating rules and ownership boundaries
├── PROFILE.md                        # User profile; required for personalized planning
├── README.md                         # Bilingual product and operations documentation
├── 工作台/                            # Active plans and evidence
├── 保研/                              # Graduate-recommendation planning
├── 答疑/                              # Academic Q&A archive
├── 智库/                              # Source documents and official materials
├── PDF提取文本/                       # Generated searchable PDF text
└── apps/
    ├── NCUStudyRocket/                # macOS app, Host, core, tests
    ├── NCUStudyRocketMobile/          # iPhone SwiftUI app and Xcode project
    └── NCUStudyRocketShared/          # Shared protocol package
~~~

The iPhone boundary is apps/NCUStudyRocketMobile/. The Mac Host boundary is apps/NCUStudyRocket/Sources/StudyRocketHost/. Shared contracts live in apps/NCUStudyRocketShared/. The macOS desktop implementation lives in apps/NCUStudyRocket/Sources/NCUStudyRocket/.

## 6. Requirements

### Desktop

- macOS 14 or newer.
- A Swift toolchain compatible with the package manifests.
- ChatGPT’s bundled Codex executable at /Applications/ChatGPT.app/Contents/Resources/codex.
- A bound repository containing AGENTS.md and PROFILE.md.
- Existing local Codex login/session configuration.

### Host and iPhone

- macOS 14+ for the Host.
- Full Xcode 26 and the iOS 26 SDK for signing and physical-device validation.
- A development-configured iPhone.
- Tailscale and a user-managed tailnet if the phone connects through Serve.

CommandLineTools is useful for selected SwiftPM checks but cannot complete final iPhone signing or device acceptance.

## 7. Desktop Quick Start

~~~bash
cd apps/NCUStudyRocket
./Scripts/test_markdown.sh
./Scripts/install_app.sh
~~~

The installed bundle is /Applications/NCU StudyRocket.app. The script builds a local release bundle, ad-hoc signs it, verifies it, and copies it into Applications. It does not produce a notarized DMG or distribution-signed installer.

Build-only workflow:

~~~bash
cd apps/NCUStudyRocket
swift build
swift build -c release
./Scripts/build_app.sh release
~~~

Debug stress fixture:

~~~bash
cd apps/NCUStudyRocket
./Scripts/build_app.sh debug
open -n ".build/NCU StudyRocket.app" --args --chat-stress-fixture
~~~

The fixture generates 20 turns and 60 messages with long text, tables, code blocks, and a continuous stream. It never connects to the real academic task.

## 8. Host and iPhone Setup

Build and install the optional Host:

~~~bash
cd apps/NCUStudyRocket
./Scripts/build_host_app.sh
./Scripts/install_host_app.sh
~~~

The Host bundle is installed as /Applications/StudyRocket Host.app. After launch, explicitly start mobile connectivity from the menu bar. Readiness is ordered:

1. Bind the repository.
2. Acquire the single Codex lease.
3. Resume the fixed academic task.
4. Validate the studyrocket dynamic-tool contract.
5. Expose the API only after the checks succeed.

The Host listens on 127.0.0.1:43817. The user configures Tailscale Serve when remote tailnet access is required. StudyRocket does not start Tailscale or modify its network configuration.

Pairing:

1. Open apps/NCUStudyRocketMobile/NCUStudyRocketMobile.xcodeproj in full Xcode 26.
2. Select a development team and an iOS 26 iPhone.
3. Start the Host and enable mobile connectivity.
4. Enter the Host HTTPS address and the one-time pairing code on the iPhone.
5. Confirm the device in the Host menu.
6. Validate health, snapshot, chat, SSE, and controlled write workflows.

The pairing code is six digits, valid for five minutes, and limited to five failed attempts.

Mobile validation boundary:

The authoritative mobile build is the iOS target in full Xcode 26 at apps/NCUStudyRocketMobile/NCUStudyRocketMobile.xcodeproj. The Mobile package includes iOS-only SwiftUI APIs and is not a supported macOS command-line acceptance target. Use Xcode for compilation, signing, device installation, Face ID, notifications, background/foreground behavior, and Tailscale acceptance. The platform-neutral Shared package can be checked with:

~~~bash
swift run --package-path apps/NCUStudyRocketShared StudyRocketSharedChecks
~~~

## 9. API Contract

The current API version is 1 and the default Host port is 43817.

| Method | Endpoint | Purpose |
| --- | --- | --- |
| GET | /v1/health | Readiness and repository status |
| POST | /v1/pair | Pair a device with the five-minute code |
| GET | /v1/snapshot | Read the combined workspace snapshot |
| GET/POST | /v1/week | Read or apply the weekly plan |
| GET/POST | /v1/daily | Read or save daily evidence |
| GET | /v1/summaries | Read summary cards |
| POST | /v1/deliveries/toggle | Toggle a known deliverable |
| GET | /v1/proposals | Read pending proposals |
| GET | /v1/proposals/challenge | Issue short proposal authorization |
| POST | /v1/proposals/apply | Apply selected proposals |
| GET | /v1/chat/history | Read recent chat history |
| POST | /v1/chat/send | Start an asynchronous chat turn |
| POST | /v1/chat/interrupt | Interrupt the active turn |
| GET | /v1/events | Authenticated typed SSE stream |

All device requests after bootstrap are signed. Write requests carry a base revision, are checked against the current repository, and reject stale content instead of overwriting it. Proposal application additionally requires the short-lived authorization challenge.

## 10. Security and Privacy

- iPhone endpoints must use HTTPS.
- Pairing codes expire after five minutes and fail after five wrong attempts.
- iPhone identity uses a Secure Enclave P-256 signing key when available, stored in a device-only Keychain item.
- Requests include device ID, timestamp, nonce, signature, method, path, and body hash.
- Timestamps outside a 60-second window and replayed nonces are rejected.
- Paired devices can be revoked.
- Proposal authorization challenges expire after 90 seconds and require biometric confirmation.
- Host binds only to 127.0.0.1:43817; Tailscale Serve is user-controlled.
- Host session tokens and Codex leases are short-lived local files with restrictive permissions.
- The iPhone never receives a Codex token and never writes Markdown directly.
- No external telemetry is added by the application.
- Credentials, private keys, original PDFs, and Xcode user state must not be committed.

If the user enables Tailscale Serve, the resulting network exposure is governed by the user’s tailnet policy and Tailscale configuration. This repository does not provide a hosted security perimeter.

## 11. Data and Write Semantics

Markdown files are authoritative. Typical managed paths include PROFILE.md, 工作台/下周计划.md, 工作台/每日记录/YYYY-MM.md, and route files under 工作台/航线/.

Desktop editing stays in memory until Save. External file changes are detected through loaded-file hashes. Academic chat produces a structured proposal, displays affected files and reasons, checks allowed paths and SHA-256 revision, creates a backup under ~/Library/Application Support/NCU StudyRocket/Backups/, and writes selected files atomically after confirmation.

Mobile actions are structured Host requests. The Host checks protocol version, device authentication, revision, allowed path, idempotency, and biometric authorization where required. A failed check leaves the repository unchanged.

Original PDFs are excluded from Git and should be backed up privately. PDF提取文本/ is generated searchable text and should not be hand-edited.

## 12. Chat Reliability and Performance

The transcript is a high-risk SwiftUI surface and has dedicated safeguards:

- Isolated ChatTranscriptState.
- Explicit loading, loaded-empty, loaded-history, and failed-with-retained-history states.
- Connection generations and cancellation checks for stale async results.
- Stable message IDs during streaming and completion.
- Typed SSE deltas with one reconciliation refresh instead of full polling.
- Fixed timestamp height and no custom bubble-width measurement.
- Cached completed Markdown and lightweight streaming text.
- Stable table fallback for fast-scrolling transcripts.
- Coalesced scroll requests and no forced bottom jump while reading old content.
- A Debug-only long-history fixture for repeatable performance testing.

The transcript intentionally keeps the latest 20 turns. Historical pagination is not currently implemented.

## 13. Testing

~~~bash
cd apps/NCUStudyRocket
./Scripts/test_markdown.sh
swift build
swift run NCUStudyRocketTests

cd ../NCUStudyRocketShared
swift run StudyRocketSharedChecks
~~~

Coverage includes chat reducer terminal states, retryable errors, proposal routing, scroll policy, duplicate revision suppression, retained history after failure, scroll-request coalescing, and stable streaming item IDs.

Release acceptance:

~~~bash
cd apps/NCUStudyRocket
swift build -c release
./Scripts/install_app.sh
codesign --verify --deep --strict "/Applications/NCU StudyRocket.app"
~~~

Recommended manual acceptance includes real long histories, 60 seconds of active streaming and fast scroll, page leave/return, window resizing, process expansion, return-to-latest, Host SSE disconnect/reconnect, duplicate-message checks, and crash-report review.

Mobile acceptance must cover physical-device signing, pairing expiry, HTTPS rejection, Keychain/Secure Enclave persistence, Tailscale Serve, offline cache/drafts, SSE lifecycle, Face ID challenge flows, revision conflicts, atomic writes, and local notifications.

## 14. Operations Runbook

### Startup

1. Verify AGENTS.md and PROFILE.md.
2. Start the desktop app.
3. If mobile access is required, start StudyRocket Host manually.
4. Wait for repository binding, Codex lease, and dynamic-tool self-check.
5. Enable mobile connectivity and pair only the intended device.

### Shutdown

1. Save or discard open Markdown edits.
2. Stop mobile connectivity.
3. Quit the Host.
4. Quit the desktop app.

The documented scripts do not create a LaunchAgent, login item, hidden listener, or permanent background process.

### Recovery table

| Symptom | Action |
| --- | --- |
| Repository not found | Rebind a directory containing AGENTS.md and PROFILE.md |
| Codex lease busy | Stop the other StudyRocket/Codex owner |
| Mobile offline | Use the cache, check Tailscale Serve, refresh |
| Pairing expired | Generate a new code |
| Device replaced | Revoke the old device and pair again |
| Proposal conflict | Reload and regenerate the proposal |
| External Markdown change | Reload and compare instead of forcing overwrite |
| Chat error | Keep retained history visible, then reconnect |

## 15. Release Management

~~~bash
git status --short
git diff --check
git add -A
git commit -m "Describe the change"
git push
~~~

Before release, inspect the staged file list and confirm that no PDF, credential, private key, Keychain export, Xcode user state, or build cache is included. Keep desktop, Host, Shared, and Mobile protocol changes synchronized. The repository currently has no automated CI or published binary release pipeline; scripts create locally signed development bundles.

## 16. Limitations

- Single user and single repository.
- No cloud database, SaaS account service, multi-tenant authorization, or organization console.
- Desktop depends on the local Codex installation and session.
- Host is optional and does not replace the desktop Markdown workflow.
- iPhone requires iOS 26 and full Xcode 26 for final acceptance.
- Tailscale is an external user-managed prerequisite.
- Host API is a versioned companion protocol, not a public internet API.
- Latest 20 chat turns are retained; pagination is not implemented.
- macOS reminders and iPhone notifications are independent local systems.
- No notarized DMG, PKG, App Store, TestFlight, or signed enterprise artifact is published.

## 17. Documentation Map

| Need | Document |
| --- | --- |
| Repository rules | AGENTS.md |
| User profile | PROFILE.md |
| iPhone setup | apps/NCUStudyRocketMobile/README.md |
| Desktop, Host, and tests | apps/NCUStudyRocket/ |
| Shared protocol | apps/NCUStudyRocketShared/ |
| Official school documents | 智库/学校文件/ |
| Generated searchable PDF text | PDF提取文本/ |

## 18. License

No open-source license is declared. Until a license is added, treat the code, content, assets, and documentation as private project materials and obtain permission before redistribution.
