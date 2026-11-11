#!/usr/bin/env bash
set -euo pipefail
# Run from a service-readable cwd. Inheriting /root through runuser can break
# Foundation's temporary-file operations even when the target path is writable.
if [[ "$(id -u)" != 0 ]]; then
  echo 'Run this command with sudo on the cloud server.' >&2
  exit 77
fi
case "${1:-}" in
  pair-code|revoke) ;;
  *) echo 'usage: admin.sh pair-code | admin.sh revoke --device UUID' >&2; exit 64 ;;
esac
cd /var/lib/studyrocket/cloud
exec runuser -u studyrocket -- env LD_LIBRARY_PATH=/opt/studyrocket/cloud/current/lib \
  /opt/studyrocket/cloud/current/StudyRocketCloud "$@" --state /var/lib/studyrocket/cloud/state
