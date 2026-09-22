#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/.build/StudyRocket Host.app"
"$ROOT/Scripts/build_host_app.sh" >/dev/null
rm -rf "/Applications/StudyRocket Host.app"
cp -R "$APP" "/Applications/StudyRocket Host.app"
if [[ "${STUDYROCKET_NO_LAUNCH:-0}" != "1" ]]; then
  open "/Applications/StudyRocket Host.app"
fi
echo "Installed /Applications/StudyRocket Host.app"
