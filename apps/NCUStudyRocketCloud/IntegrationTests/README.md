# Cloud independent acceptance

All data in this suite is synthetic. Each run creates an isolated temporary repository, state directory, credentials and loopback port. It never reads or writes the user's study documents and never contacts DeepSeek or a production server.

Run after building the server (Python 3 and OpenSSL are the only harness dependencies):

```sh
python3 apps/NCUStudyRocketCloud/IntegrationTests/cloud_acceptance.py \
  --binary /absolute/path/to/StudyRocketCloud
python3 apps/NCUStudyRocketCloud/IntegrationTests/backup_download_acceptance.py \
  --binary /absolute/path/to/StudyRocketCloud
python3 apps/NCUStudyRocketCloud/IntegrationTests/skill_update_acceptance.py \
  --binary /absolute/path/to/StudyRocketCloud
```

The optional remaining arguments are unittest case names, for example `Acceptance.test_crash_after_first_rename`. Every case owns and removes its own temporary fixture. Model-loop cases use the explicitly enabled test response fixture or an actual loopback HTTP peer; real API keys are removed from the child process environment.

The acceptance contract is observable behavior, rather than a duplicate of the implementation:

| Failure / boundary | Required observation |
| --- | --- |
| Missing / invalid authentication | Protected routes reject before revealing repository, history or pending proposals |
| Proposal registered, no confirmation | Original Markdown bytes stay identical, including after restart |
| Stale preview hash | Confirmation rejects; external change and other transaction files remain intact |
| Repeated operation ID and identical payload | Exactly one effect and a stable receipt, including after process restart |
| Same ID with a different payload | Conflict; no second effect |
| Crash after durable journal, before first rename | On restart transaction is consistently completed or rolled back; never silently lost |
| Crash after first of two files | On restart both files agree with the transaction outcome; replay is idempotent |
| Lost response followed by retry | Client can discover/replay the already committed result without duplicate record |
| Traversal, final symlink, intermediate symlink | Rejected without changing outside files |
| SSE reconnect with prior cursor | Durable missed events are replayed in order without regenerating a turn |
| Same repository moved / process restarted | Stable repository UUID and conversation identity |
| Imported historic conversation | Original visible message text/order survives restart; import replay does not duplicate it |
| Legacy offline queue + re-pair | Queue persists; unique targets migrate, ambiguous entries remain explicitly reviewable |
| Two clients race from the same base | One succeeds, the other conflicts; no silent last-writer overwrite |
| Second state directory for the same repository | A second process cannot become another writer |
| Live backup and isolated restore | File hashes, stable UUID, versions and prior operation receipts agree |
| Unread guessed hash / forbidden model tool | No proposal or file mutation |
| Reasoning and tool-call continuation | Internal fields preserved in the next provider request, absent from visible history |
| Provider wait cancellation | Prompt interrupted terminal, durable across restart |
| Context / tool / output budget | Explicit failure code; no false completed turn |
| Real HTTP SSE premature EOF | Failed terminal with visible partial text retained |
| Real HTTP cancellation / process kill | Prompt cancellation or durable partial recovery; never automatic provider resend |

The crash tests use test-only failpoints guarded by explicit test mode and temporary fixture configuration. A controlled process exit tests application-crash recovery. It is **not** evidence that the operating system or storage device has honored fsync during physical power loss; that claim additionally needs journal, SQLite and parent-directory durability review.

Client cache migration is exercised through the Mobile package's actual session tests, because HTTP tests cannot establish that an iPhone preserved a local queue. Native UI, device signing, actual cellular switching and foreground/background behavior remain separate device acceptance.

## Baseline review

The pre-cloud Host keeps `HostProposalStore.values`, `appliedReplays`, and write-service replay state in process memory. Its multi-file rollback catches Swift errors but cannot recover from process termination between renames. The pre-cloud Mobile `replaceClient` calls `clearRemoteHostState`, which deletes `pending-drafts.json`. These are explicit regression targets; old Host behavior is not accepted as the new durability contract.


## Targeted and live checks

The additional synthetic suites accept `--binary`:
`backup_download_acceptance.py`, `skill_update_acceptance.py`,
`memory_admission_acceptance.py`, `background_context_acceptance.py`,
`review_regression_acceptance.py`, and `history_budget_acceptance.py`.
They use only temporary data and fixture/loopback model responses.

`live_provider_acceptance.py` is a deliberately separate opt-in operator test for
an already running isolated service. It requires `--base` named `live-qa-*`, an
`ALLOW_LIVE_QA` marker, a non-primary `--port`, `--binary`, and the service `--pid`.
It performs three real model turns and over fifty ordinary API requests, writes
only its isolated repository, and logs only status/timing/resource metrics and
public URLs. The companion proxy binds loopback and has a fixed official provider
destination; its credential is read from the server environment and never logged.
A working directory readable by the service user is required for Linux Foundation
atomic writes (the driver changes into its isolated base). Do not run the live
script as part of ordinary automated tests or point it at the primary service.
