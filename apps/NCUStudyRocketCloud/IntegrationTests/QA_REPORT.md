# Independent cloud QA — 2026-11-11

This report uses synthetic fixtures only. No application was installed, no production server was contacted, and no real academic Markdown was edited by this QA task.

## Executed checks

| Check | Command / evidence | Result |
| --- | --- | --- |
| Shared baseline | `swift run --scratch-path /tmp/studyrocket-cloud-qa-shared StudyRocketSharedChecks` in Shared package | Passed signing, DTO, lease, descriptor, local-save-history and task-linkage checks |
| Mobile baseline | `swift test --scratch-path /tmp/studyrocket-cloud-qa-mobile` in Mobile package | 58 tests passed |
| Independent signing client | OpenSSL-generated P-256 raw public key/signature verified by a temporary CryptoKit Swift program | Passed |
| Mobile stable repository migration | `swift test --scratch-path /tmp/studyrocket-cloud-qa-mobile --filter MobileCloudMigrationTests` | 4 passed after fixing uncertain-chat endpoint migration; includes archived chat bytes |
| HTTP harness syntax | `python3 -m py_compile apps/NCUStudyRocketCloud/IntegrationTests/cloud_acceptance.py` | Passed; not equivalent to HTTP acceptance |
| Cloud integration acceptance | `python3 apps/NCUStudyRocketCloud/IntegrationTests/cloud_acceptance.py --binary /tmp/studyrocket-cloud-qa-server-binary` | **27/27 independently passed in 30.096 seconds** on the earlier candidate artifact identified below; includes real HTTP streaming parser |
| Completed-backup download | `python3 apps/NCUStudyRocketCloud/IntegrationTests/backup_download_acceptance.py --binary /tmp/studyrocket-cloud-qa-server-binary` | Independently passed: authentication, reconstructed chunk hashes/lengths, traversal, symlink, wrong repository, no available backup |
| Dedicated skill-update flow | `python3 apps/NCUStudyRocketCloud/IntegrationTests/skill_update_acceptance.py --binary /tmp/studyrocket-cloud-qa-server-binary` | Independently passed all 5 cases: explicit confirmation/replay, insufficient evidence, changed YAML, script fence, crash recovery |

All three cloud suites above were independently executed against macOS Debug binary SHA-256 `d296a2558ff9ea28eee30fa13fd599be11f41db94bf621701d509d54dd010ff5`, including the dedicated skill journal and backup repository-identity check. This identifies the tested artifact; it is not a Linux release checksum. The earlier candidate full-suite log is `/tmp/studyrocket-cloud-independent-final27.log`.

## Findings returned to owning implementation agents

1. Same operation ID must hash canonical JSON, not incidental encoded key order. Revised; reordered JSON key replay passes after restart.
2. Staging must retain original bytes before applying edits and compare them under the commit lock. Revised; stale-hash and concurrent-client CAS tests pass.
3. Committing the operation receipt and publishing its durable snapshot event must be one SQLite transaction. Revised; crash and SSE replay tests pass.
4. Pairing must obtain the stable repository UUID after authenticated pairing. Public health intentionally omits it. Client source was revised.
5. Same stable UUID at a new endpoint must retain both fact IDs and uncertain chat request IDs. A persisted-chat endpoint mismatch was reproduced, fixed and retested successfully.
6. Re-pair and cross-repository migration must not delete old queues without a verified durable archive. Exact draft/fact archive bytes and archive failure behavior passed.
7. macOS Foundation enumerates `/private/var/...` while normalizing the root to `/var/...`; raw prefix-length slicing returned an empty manifest and caused false successful empty writes. Independently reproduced, fixed by consistently normalizing both sides, and all 14 initial HTTP cases passed using the default macOS temporary directory.
8. A separate state directory must not allow a second writer for the same repository. Added repository-level lock; a second process is rejected in the runtime test.
9. Fresh nested directories need their parent directory entries fsynced. A durable directory-creation helper was added after source review; no physical storage failure was simulated.
10. Agent task cleanup needs a matching run ID so an old completion cannot clear a new cancellation handle. Source was revised after reentrancy review.
11. A clean premature HTTP EOF previously looked like a successful model response. The parser now requires a finish reason and `[DONE]`; an actual loopback HTTP peer confirms premature EOF fails while preserving visible partial text.
12. Migration exports include Markdown references beneath the eight existing skills. The server initially allowed only each `SKILL.md`; its read-only allowlist was aligned with the exporter after review.

## Agent-loop evidence

- A guessed correct hash without a read in the same run cannot create a proposal. Unavailable process tools and path traversal remain denied.
- Fixture transcripts prove `reasoning_content`, function arguments and tool-call IDs survive unchanged into the next model request. Internal reasoning is absent from visible history.
- A 30-second simulated provider suspension is cancelled within 3 seconds; its interrupted terminal survives restart.
- Context, tool-round and truncated-output budgets produce distinct persisted failure codes rather than false completion.
- Replaying a completed chat request after a process restart returns the existing conversation, with exactly one user message and one answer.
- Four additional cases use a real loopback HTTP peer and the production AsyncHTTPClient parser: normal SSE completion; premature EOF preserving partial text as failed; cancellation during an open HTTP response; process kill followed by recovery of already-visible partial text without another provider request. The test endpoint is available only behind the test flag and receives no API key.
- These tests exercise HTTP transport and parsing locally. They do not claim live DeepSeek interoperability or Internet network behavior.

## Deployment / authority review

- Read-only review covered `export_workspace.py`, `backup.py`, `build_linux.sh`, the service unit and Mac/Host authority guards.
- The container build root and Swift runtime collection agree with the systemd `LD_LIBRARY_PATH`. Linux execution/resource evidence belongs to the deployment task.
- New Host write endpoints recheck the cloud marker inside the repository lock; proposal apply and Desktop Markdown/fact saves also recheck. The reported missing-file branch in `HabitProfileUpdater` was routed through the same guarded save path; its owning client agent reports the affected fixture passed.
- A previously installed and still-running old binary cannot enforce newly added marker policy. Cutover must stop or replace that old writer.
- Exporter path alias handling and backup verification against its original manifest/SQLite integrity were corrected by the deployment owner and reread in source. The backup wrapper now compares hashes/lengths with the snapshot manifest and runs SQLite `quick_check` before marking verification successful.

## Backup evidence

A backup was created while the fixture server was running, every copied Markdown hash/byte count was verified, then its SQLite image and repository were restored to a new state directory. Stable repository identity, file content, version history and a prior idempotent receipt survived restoration. A later unbacked-up edit was absent as expected.

## Evidence limits

- Controlled abrupt process exit and SIGKILL exercise recovery from application crashes. They do not simulate storage-controller failure or prove physical power-loss durability.
- Native UI, real iPhone pairing, foreground/background transitions, cellular switching, actual DeepSeek streaming/API availability and production Linux resource use require their own execution evidence.
- This report is updated during implementation; pending results must not be presented as successful acceptance.


## Post-review candidate verification (implementation owner)

The latest source adds historical/future daily-month revision coverage, byte-bounded
read delivery before proposal permission, authenticated legacy repository identity,
and dynamic older-history trimming. These are newer than the independent Debug
artifact above. The implementation owner ran **the same 27-case HTTP harness plus
all six targeted suites** against each complete macOS artifact below; every suite
passed. The baseline harness remains 27 cases, not 29; separate targeted scripts
are reported separately rather than inflating that count.

| Artifact | SHA-256 | Full harness | Additional suites |
| --- | --- | --- | --- |
| Post-review macOS Debug | `b7fc2d1254585e69dda1265e11690f0f6a7c06788fdd94b5fcd5e915bc93a664` | 27/27, 28.297 s | backup download, skill update, memory admission, background context, review regressions, history budget — all passed |
| Post-review macOS Release | `349ebc749f310ca2d6cf38ab482d41806277762e4646297496c88c1bc81d5e0c` | 27/27, 28.638 s | same six suites — all passed |

Reproducible commands are `python3 IntegrationTests/<script>.py --binary <artifact>`.
Raw synthetic results are in `Evidence/post-review-macos-debug.log` and
`Evidence/post-review-macos-release.log`. Review regressions prove same-baseline
historical daily writes return 200 then 409; an 8000-emoji result is safely chunked
and cannot authorize a proposal until all bytes are delivered; a single oversized
combining Character cannot grant read permission. Legacy identity is absent from
public health and present only for signed clients. Three long-history/tool turns
retain the current request, full required profile and current reasoning while
trimming only prior history; an oversized current request fails explicitly, and
the following small request succeeds.

### Shared business checks on Linux and Apple

`StudyRocketSharedChecks` compiled and ran in the pinned Swift 6.4.2 Ubuntu 24.04
amd64 Docker image, using `/build/shared-checks` within the existing build volume.
The same business fixtures passed on macOS, including the new historical/future
month CAS case, signing, DTOs, timetable/planning and task linkage. The Mac-only
Codex process lease and local Git-save-history fixtures remain macOS-only; Linux
cloud uses its separately tested repository flock. The original Linux stdout
mentioned “lease” generically; the test runner now prints its explicit Mac skip.
Evidence: `Evidence/sharedchecks-linux-amd64.log`, `Evidence/sharedchecks-macos.log`.
No compilation occurred on the production server.

### Authorized live DeepSeek evidence — Linux candidate 1

This is a separate, explicitly authorized implementation-owner execution against
an isolated copy on the cloud server, **not** the final post-review artifact:
Linux candidate-1 SHA-256
`57a7c44f75d582b9fe4b9e185d45dc4c0d3d2c679a43e6e2457246b819a301b7`.
The primary conversation received no test prompts. Three consecutive real
`deepseek-flash` high-reasoning turns completed in 38.253 s, 6.064 s and 6.067 s.
The first includes initial personal-archive bootstrap, two academic-file reads,
`read_skill`, `web_search` and `web_fetch`; the second creates a temporary note
proposal; the third continues with note/week/skill reads. A first fetch returned a
provider error, after which the model retried an official article successfully
(result shape included content/title). Returned public URLs include
`https://www.ncu.edu.cn/` and `https://www.ncu.edu.cn/info/1008/1102.htm`.

The temporary note did not exist before confirmation. Signed confirmation and
lost-receipt replay both returned 200 and the exact proposed content was written
only in the copy. CAS/replay/stale checks returned 200/200/409. The 105 API requests
had median 11.97 ms and p95 603.88 ms (model waiting measured separately): 96×200,
3×202, 5×404 for absent backup snapshots, and one intended 409. Under a separate
systemd service with MemoryHigh=300 MiB, MemoryMax=384 MiB, no swap and CPUQuota=100%,
observed `/proc/PID/status` RSS/HWM peaked at 49,803,264 bytes (47.50 MiB); minimum
system MemAvailable was 807,030,784 bytes (769.64 MiB). These are observed samples,
not a guarantee of all future loads; cgroup shared-page accounting is not used as
a substitute for RSS. The largest observed serialized input was 46,111 bytes,
which motivated the subsequently tested dynamic-history fix.

The original 36 primary Markdown files still matched the isolated copy exactly;
primary history remained 455 messages. Both temporary services were stopped.
Remote private test state is retained for root-controlled evidence review; no
private content, reasoning or key was copied into this report. Sanitized metrics
and tool-name/argument-key evidence are in
`Evidence/live-provider-candidate1-20261111.json` and
`Evidence/live-provider-structure-candidate1-20261111.jsonl`. The reproducible live
driver/proxy require an explicitly prepared isolated `live-qa-*` directory and
`ALLOW_LIVE_QA` marker. Their destination is fixed to the official DeepSeek API;
credentials remain only in the server environment. Final Linux post-review
artifact testing, real-device use and the full 24-hour coexistence window remain
owned by the deployment/client tasks and are not implied by this candidate-1 run.
