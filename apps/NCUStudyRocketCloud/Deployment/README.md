# Cloud deployment and cutover

This directory contains deployment tools, not academic material. Run exports from the
actual user's checkout, including allowed untracked and uncommitted Markdown. Never
substitute a Git clone for the data export. Outputs and credentials stay outside Git.

## Build and validate

1. Run `build_linux.sh /absolute/artifact-directory` on the build machine. It uses the
   pinned Ubuntu 24.04 amd64 Swift image and copies the required Swift runtime libraries.
2. Run `IntegrationTests/cloud_acceptance.py --binary /absolute/StudyRocketCloud` on each
   target platform, plus the backup and skill-specific acceptance scripts. These use
   synthetic temporary repositories only.
3. Run `export_workspace.py --source SOURCE --destination FRESH_DIRECTORY`; retain the
   returned repository UUID on subsequent cutover exports using `--repository-id`.
4. Run `export_history.py --codex-home CODEX_HOME --repository SOURCE --destination FRESH_DIRECTORY`.
   Only source-tagged academic conversations and visible user/assistant text are exported.
   Review `history-manifest.json`: missing nonempty sources block a claim of complete history.
   Source timestamps, IDs, per-source counts and hashes allow repeatable verification.

## Server isolation

- Application: `/opt/studyrocket/cloud/releases/RELEASE`; `current` points to one verified release.
- Data: `/var/lib/studyrocket/cloud/{repository,state,backups}`; owner `studyrocket`, private permissions.
- Secret: `/etc/studyrocket/cloud.env`, root:root mode 0600; never copy it into artifacts or backups.
- Listener: `127.0.0.1:43818`; systemd unit enforces the specified memory/CPU budgets.
- Nginx: a new `studyrocket.soulcourse.cn.conf` only. Use `/www/server/nginx/sbin/nginx -t`
  and its `-s reload`; do not replace SoulCourse's virtual host, certificate or port 1309.
- ACME public challenge files: `/var/lib/studyrocket-acme`; they are outside the private
  service home so the Nginx worker can read them without broadening data permissions.
- Separate certificate lineage: `/etc/letsencrypt/live/studyrocket-soulcourse-cn`.

Copy release files as root-owned, and data as service-owned. Verify SHA256SUMS and `ldd`
on the destination before switching `current`. Initialize the repository with the
exported manifest, import history twice and verify the second import adds zero messages.
Generate pairing codes with `sudo bash /opt/studyrocket/cloud/current/Deployment/admin.sh pair-code`.
This uses the service user and a readable working directory; do not create root-owned
pairing files or run the service user's Foundation CLI while inheriting `/root` as cwd.
Until cutover passes, expose only authenticated read routes and public health via Nginx;
reject public mutations and pairing with 503. Preview data is not yet authoritative.

## Backups and observation

`backup.py` runs the cloud CLI's locked filesystem/SQLite snapshot, checks the source
file manifest and SQLite `quick_check`, then hashes the whole backup and publishes
`verified-backup.json`. It retains 30 days of successful snapshots. The service timer
runs at 03:30 Asia/Shanghai; Mac downloads a verified snapshot independently of its mirror.
The restore tool accepts either the server's `verified-backup.json` or the Mac's
`_download-receipt.json` format. Both undergo the same file inventory, checksum,
repository identity and SQLite checks; the server need not survive to restore a Mac copy.

Run `observe.py --output PRIVATE_LOG --seconds 86400` as a bounded systemd observation
process. It records service cgroups, available memory, swap and both health endpoints
without message contents. Acceptance requires at least 50 representative requests,
no OOM or persistent swapping, cloud peak target ≤300 MiB, system available memory
≥350 MiB and no material SoulCourse degradation. A short run is not a 24-hour pass.

## Restore rehearsal: a new directory only

`restore_backup.py` does not stop services, change `current`, overwrite a live tree,
remove a cloud marker, start a writer or open the public mutation gate. It checks
`verified-backup.json`, every checksum and byte count, the inner file manifest,
SQLite `quick_check`, the database's repository UUID and the absence of a prepared
transaction. It rejects symbolic links (including path ancestors), unexpected files,
path traversal and an existing destination. Use canonical paths; on macOS `/tmp`
and `/var` may be aliases, so obtain their physical paths first.

From the verified release's `Deployment/` tooling directory, choose one completed
backup and a **new** recovery directory. Replace the example values with the verified
backup ID and repository UUID; the parent must already exist and be private:

```sh
task_backup=/var/lib/studyrocket/cloud/backups/REPLACE_WITH_VERIFIED_BACKUP_ID
task_recovery_parent=/var/lib/studyrocket/recovery
task_restore="$task_recovery_parent/REPLACE_WITH_NEW_REHEARSAL_NAME"
task_repository_uuid=REPLACE_WITH_EXPECTED_REPOSITORY_UUID

# Administrator prepares a private parent; run the restore with the data owner's account.
sudo install -d -o studyrocket -g studyrocket -m 700 "$task_recovery_parent"
sudo -u studyrocket python3 restore_backup.py \
  --backup "$task_backup" \
  --destination "$task_restore" \
  --expected-repository-id "$task_repository_uuid"
```

The output contains `repository/`, `state/cloud.sqlite`, the original snapshot
`manifest.json` and a new `restore-receipt.json` with the copied hashes. A copy or
verification failure leaves `RESTORE_INCOMPLETE`; do not serve that directory, and
retry into a different new destination after diagnosing the failure. No automatic
cleanup deletes the failed evidence or an existing directory.

To check process startup, select an unused **loopback-only** test port and run the
verified binary in the foreground. This is an isolated restored copy; the public
proxy continues to point to its original port. Do not supply a model credential:

```sh
sudo -u studyrocket env -u DEEPSEEK_API_KEY \
  LD_LIBRARY_PATH=/opt/studyrocket/cloud/current/lib \
  /opt/studyrocket/cloud/current/StudyRocketCloud serve \
  --repository "$task_restore/repository" --state "$task_restore/state" \
  --host 127.0.0.1 --port 43819
# In another terminal; stop the foreground rehearsal with Ctrl-C afterwards.
curl --fail http://127.0.0.1:43819/v1/health
```

Health is a startup check, not the complete acceptance. Inspect the restore receipt,
verify the expected original facts/history and pending proposals with an authenticated
read, and confirm the original operation receipt can be queried/replayed safely.
The reproducible synthetic check also exercises a real cloud snapshot, starts its
restored database and verifies the pairing and original idempotent receipt:

```sh
python3 ../IntegrationTests/restore_backup_acceptance.py \
  --binary /absolute/path/to/StudyRocketCloud
```

## Final cutover and rollback

1. Stop the previously installed Mac Host and close the old Desktop application. An old
   already-running binary does not understand the new cloud marker.
2. Freeze cloud public mutations, stop the cloud process, export the final source snapshot
   with the same UUID, verify source/bundle hashes and import any additional academic history.
   Do not replace data containing uncollected cloud writes with an older local snapshot.
3. Preserve phone queues before pairing. Upgrade clients, establish old-path-ID → stable UUID
   mapping, and verify archived draft/fact/chat IDs and original base revisions.
4. Test restore and rollback in a temporary repository. Only then remove the public mutation
   gate and enable the cloud as the authoritative writer. Cloud marker and guards prevent
   upgraded clients from starting a second local writer.
5. On rollback, first re-enable the public mutation gate and freeze/stop cloud writes. Collect
   a verified backup including all new cloud facts, versions, operation receipts and history.
   Restore and reconcile in a temporary directory; never blindly switch back to stale Mac files.
   The original Mac local save history and unresolved drafts/queues remain preserved.

For an actual rollback, the ordering is deliberate. First install and reload the
reviewed Nginx read-only gate (all non-GET/HEAD methods return 503), and confirm the
public gate before stopping anything. Keep that gate enabled throughout reconciliation:

```sh
sudo /www/server/nginx/sbin/nginx -t
sudo /www/server/nginx/sbin/nginx -s reload
# Only after the reviewed read-only gate is verified:
sudo systemctl stop studyrocket-backup.timer
sudo systemctl stop studyrocket-backup.service studyrocket-cloud.service
sudo -u studyrocket env LD_LIBRARY_PATH=/opt/studyrocket/cloud/current/lib \
  python3 backup.py
```

Use the freshly reported completed backup ID with `restore_backup.py` as above.
Do not select an older snapshot merely because it starts successfully. If backup
reports an unrecovered prepared transaction, leave the public gate closed and recover
that journal with the verified service before collecting another backup; never edit
SQLite state to bypass the check.

Promotion is intentionally a separate manual operation: retain both original live
`repository/` and `state/` together, reconcile all new cloud writes and client drafts,
then choose the verified restored pair or an explicitly reconciled local workspace.
Never replace only Markdown while discarding operation receipts, proposals or history.
If returning to local mode, do not remove the cloud marker or restart the old writer
until the cloud is stopped and the reconciled local copy is selected. Review ownership,
runtime paths, backup paths and device bindings before starting the selected writer.
Restart the backup timer only after its paths match that writer, and remove the public
read-only gate only after the complete cutover acceptance. The restore script performs
none of these live promotion steps.

Physical iPhone pairing, app confirmation and Mac-offline operation require actual device
evidence. Unsigned builds and health checks alone do not satisfy this acceptance step.
