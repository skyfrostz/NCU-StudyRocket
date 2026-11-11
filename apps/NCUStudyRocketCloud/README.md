# StudyRocket Cloud

A single-writer academic Markdown service. The cloud repository is authoritative;
clients submit explicit revisions or file hashes and keep offline work as drafts.
The model receives read/search/proposal tools, never a shell or a write handle.

## Build and run

Build this package with Swift 6.4 or a compatible pinned toolchain. `Package.resolved`
pins the actual dependency graph. Compile on a build host; the runtime does not need
Xcode, Codex, Python, a model runtime, Redis, or a separate database service.

```
swift build -c release -j 2
StudyRocketCloud init --repository /data/repository --state /data/state --manifest /import/manifest.json
StudyRocketCloud serve --repository /data/repository --state /data/state --host 127.0.0.1 --port 43818
StudyRocketCloud pair-code --state /data/state
```

Supply `DEEPSEEK_API_KEY` only through the service environment. The provider URL is
fixed to DeepSeek's official API. Requests use `deepseek-flash`, thinking enabled,
high reasoning, max 16,384 output tokens, and at most 12 tool rounds / 8 calls per
round. Serialized input (including tool schemas) is conservatively limited to
48,000 UTF-8 bytes, reserving 16K output within a 64K context policy; this is not
measured model tokenization. Full PROFILE, AGENTS and preferences enter each run.
The personal archive is read in full on its first use, then at most two 24KB
chunks are summarized by the same provider into source/hash/stage-bound session
context. These calls count against the 12-round limit. Derived context is cached
by source hash in SQLite, is never an academic fact or visible chat message, and
relevant original sections remain readable in chunks. Budget exhaustion produces
an explicit failed terminal state rather than silently dropping required files.
Complete `reasoning_content` stays in memory and is returned
on subsequent tool rounds; it is not displayed, imported, or persisted as visible
history. Public search/fetch use the separate official tools endpoints.

HTTPS termination, request body limits, resource limits and
systemd supervision are configured by the deployment layer. Bind to loopback behind
that proxy. Never expose the old Mac local-session token on a public endpoint.

## Contract

Existing v1 snapshot/week/daily/facts/toggle/chat/proposal/signature DTOs remain.
`HealthResponse.backend` is `cloud`; `repositoryID` is a durable UUID, not a path
hash. Both clients share one durable conversation. New DTOs live in Shared's
`CloudProtocol.swift`:

- `GET /v1/files/manifest`: readable file paths, SHA-256, byte counts and revision.
- `POST /v1/files/read`: `{path}` → `{path,hash,content}`.
- `POST /v1/files/commit`: repository ID, original `WriteMetadata`, and file CAS
  changes. A null `baseHash` creates a file; a nonnull hash must match.
- `GET /v1/operations/{UUID}`: durable operation state.
- `GET /v1/history?after=0&limit=100&query=...`: complete visible history, paginated
  by stable SQLite sequence (max 200). `cursor` aliases `after`.
- `POST /v1/history/import`: idempotent batch of at most 200 archived messages.
- `GET /v1/versions?after=0&limit=50`: committed file versions (max 100).
- `POST /v1/versions/read`: `{id,path}` → read-only committed file content.
- `GET /v1/events`: SSE `id` is a durable monotonic cursor. Reconnect with
  `Last-Event-ID` or `after`. Expired cursors receive `resync`; fetch snapshot and
  chat history. Authentication/revocation is checked for each live stream.

Dates retain v1 JSONEncoder's numeric seconds since 2001-01-01. Signatures retain
P256 raw format, method, URL path (without query), timestamp, nonce and body hash.
Use a fresh signature/nonce but the same operation ID when retrying one intent.
JSON object ordering does not affect the idempotency payload hash. Confirmed
proposal retries bind proposal IDs, revision and API version; a consumed challenge
is not needed again to retrieve an already-committed result.

Pair codes expire in five minutes, allow five attempts, and are consumed in SQLite.
`revoke --state PATH --device UUID` removes authorization without deleting content.
No plaintext API key or client private key is stored in the cloud database.

## Durability

`CloudStore` serializes academic reads/writes. Domain changes execute in a bounded
staging copy using Shared `AcademicWriteService`; changed bytes then enter one
journal. SQLite runs WAL + FULL sync. Before replacing authority files the service
persists old/new bytes, operation intent and exact response. File replacement and
parent directories are fsynced. A crash rolls the prepared journal forward before
opening the HTTP listener; external modifications matching neither version stop
recovery. Success, proposal consumption and snapshot event are one SQLite commit.

The service holds locks on both its state and repository, refusing a second writer.
A transaction lock also coordinates consistent admin backups. Partial visible
assistant text and SSE deltas are persisted together; a restarted active model run
is marked interrupted rather than automatically resent. Imported user/assistant
text is preserved separately from model protocol and never executed as instructions.

```
StudyRocketCloud history-import --state PATH --file visible-history.jsonl
StudyRocketCloud backup --repository PATH --state PATH --output NEW_DIRECTORY
```

History lines use `CloudArchivedMessage`: `id`, `sourceThreadID`, `role`, `text`,
`date`, `source:"codex-import"`. Stable IDs make repeated imports safe; different
content under an existing ID fails. A backup contains approved Markdown, a SQLite
`VACUUM INTO` snapshot and checksums. Keep the directory outside the live repository;
rotate/copy backups in deployment. A backup with prepared transactions is rejected
until the service has recovered them. Never copy a live SQLite file alone.

## Verification and boundaries

All acceptance uses synthetic temporary repositories. The independent black-box
suite lives in `IntegrationTests/cloud_acceptance.py`. Production must not enable
`--allow-test-failpoints` or `--test-model-fixture`. Test-only failpoints after journal
prepare / first rename deliberately terminate with exit 86 to exercise recovery.

No memory/performance budget is claimed from compilation. Measure the target Linux
binary with the deployment resource caps and actual SSE/client workload before
promoting it. Real HTTPS, device signing and DeepSeek API checks are separate from
fixture acceptance.

For the real SSE parser test only, `--allow-test-failpoints --test-upstream-url
http://127.0.0.1:PORT/chat/completions` accepts a local fake provider without
forwarding the production API credential. No other host or scheme is accepted.
A model fixture containing a personal archive must provide
`_test_background_summaries` (one string per 24KB chunk) in its first response;
fixture mode never calls the real provider for archive summarization.

Verified backup downloads use signed `GET /v1/backups/latest` and
`POST /v1/backups/read` with `backupID`, `path`, `offset`, `limit` (max 262144).
Only completed `state/../backups/*/verified-backup.json` receipts are exposed.
Responses carry bounded base64 chunks; clients must verify full-file byte counts
and SHA-256 after assembling to temporary files, then atomically publish the backup.
The receipt permits only the standalone SQLite snapshot, backup manifest, and
approved repository Markdown. Symlinks, traversal, live state and environment
files are excluded. The eight existing skills' Markdown references are read-only.

`propose_skill_update` retains the existing controlled skill flow. The agent must
read the target and source evidence in the current run, supply at least three
distinct dated quotations present in those files, and explain the workflow
improvement. Only the eight existing `SKILL.md` files qualify; YAML frontmatter
must remain byte-identical and the 300-line limit remains. Added script fences,
shebangs, script tags, shell substitutions, dated personal records and explicit
sensitive fields are rejected. The model is instructed to propose generic process
rules only; the user reviews the full diff and evidence before signed confirmation.
Ordinary file commits cannot write skills. Dedicated skill journal entries enforce
the same path/content boundary during crash recovery and consume the proposal with
the durable receipt. References remain read-only.

Before accepting a new model turn on Linux, admission checks `/proc/meminfo`
`MemAvailable` and the process's cgroup-v2 `memory.current`. Below 350 MiB
available or at/above 280 MiB cgroup use returns retryable HTTP 503
`memory_pressure`, without creating a turn. Existing idempotent receipts, file
reads, saved proposals and confirmation remain available. Accepted turns are not
killed by this policy; systemd resource limits remain the final bound. Test-only
CLI overrides `--test-memory-available-mib` / `--test-memory-current-mib` require
`--allow-test-failpoints`; there is no HTTP override.

The prior-conversation window is selected by the remaining serialized byte
budget, reserving initial space for tools. At later tool rounds only those older
visible-history messages may be removed to regain space. The current user request,
mandatory reference files, current tool results and full current reasoning are
never trimmed. The model is explicitly told to search older history; if these
required inputs alone exceed 48,000 bytes the turn fails with `context_budget`.
Historical and future daily-ledger month paths and content participate in snapshot
revision hashing, so two edits based on one old revision cannot overwrite each
other silently. `read_file` applies its 32,000-byte bound to the serialized tool
result before advancing read offsets or granting the proposal hash.
