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
round. The context window defaults to the official `deepseek-flash`
`context_window` of 1,048,576 tokens (input plus output), verified through the
provider's model metadata on 2026-11-12. Output remains capped at 16,384 tokens,
with another 2,048 tokens reserved for protocol overhead. The optional
`STUDYROCKET_MODEL_CONTEXT_TOKENS` environment variable can lower the window to
19,456–1,048,576 tokens; invalid or larger values stop startup. This configuration
is a capacity bound, not a claim that a full-window workload has been load-tested.
Full PROFILE, AGENTS and preferences enter each run exactly once per source hash.
The system context includes the server's current Asia/Shanghai date/time and
the absolute Monday–Sunday range, so relative requests such as “this Saturday”
cannot take their current date from imported history. This text participates in
the same input budget as all other system instructions.
The personal archive is read in full on its first use. Sources up to 48KB retain
their existing 24KB chunks; larger sources are divided into at most two balanced
UTF-8-safe chunks. Each complete bootstrap request must fit the configured input
budget. These chunks are summarized by the same provider into source/hash/stage-bound session
context. These calls count against the 12-round limit. Derived context is cached
by source hash in SQLite, is never an academic fact or visible chat message, and
relevant original sections remain readable in chunks. The archive retains its
two-call bootstrap limit but no separate 48KB source rejection. Existing per-file,
per-result, response-size, tool-round and
Linux memory-admission limits remain in force. Budget exhaustion produces
an explicit failed terminal state rather than silently dropping required files.
Complete `reasoning_content` stays in memory and is returned
on subsequent tool rounds; it is not displayed, imported, or persisted as visible
history. Public search/fetch use the separate [official tools endpoints](https://api-docs.deepseek.com/guides/search/).

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

Fault-injection acceptance uses synthetic temporary repositories. Live provider
acceptance uses an isolated copy of approved material and keeps test messages and
mutations out of the authoritative repository and conversation. The independent black-box
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

The initial prior-conversation window uses serialized UTF-8 bytes, including tool
schemas, as a conservative token bound and reserves initial space for tools.
After a completed provider response reports valid integer `prompt_tokens`,
`completion_tokens` and consistent `total_tokens`, the next request may instead
use that measured input plus the complete serialized UTF-8 bytes of every new
assistant/tool message and 256 tokens per new message for framing. Missing or
invalid usage never grants extra space: the last valid measurement still charges
all later messages, or the initial byte bound applies. Counts are emitted as
structured `model_usage` service log records with only fixed labels and numeric
usage/configuration values; no source text, reasoning, identities or credentials
are logged. The parser accepts a final usage frame with empty `choices`.

At later tool rounds only older visible-history messages may be removed to regain
space. Removed history is not speculatively deducted from measured token usage.
The current request, mandatory references, current tool results and full current
reasoning are never trimmed. The model is told to search omitted older history;
required input beyond the configured model window fails with `context_budget`.
Historical and future daily-ledger month paths and content participate in snapshot
revision hashing, so two edits based on one old revision cannot overwrite each
other silently. `read_file` and `read_skill` apply a 12,000-byte bound to each
serialized page before advancing contiguous read offsets or granting the full
source hash. Both expose `offset`, `nextOffset` and `complete`; a repeated complete
read of an unchanged hash returns an explicit reference to the original still in
context. `propose_changes` accepts either full `content` or 1–16 exact `edits`
(`oldText`/`newText`). Edits must match uniquely, require the same complete-read
and fresh-hash checks, and register a full proposal through the existing
confirmation path. The HTTP v1 DTO and the user's confirmation remain unchanged.
