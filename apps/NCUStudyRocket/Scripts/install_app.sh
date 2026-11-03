#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
APP="$ROOT/.build/NCU StudyRocket.app"
STUDYROCKET_PREVIEW=0 "$ROOT/Scripts/build_app.sh" release >/dev/null
rm -rf "/Applications/NCU StudyRocket.app"
cp -R "$APP" "/Applications/NCU StudyRocket.app"
# Finder and URL launches should resolve to the installed application, even after a build was opened.
REGISTRAR="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$REGISTRAR" ]]; then
  "$REGISTRAR" -u "$APP" >/dev/null 2>&1 || true
  "$REGISTRAR" -f "/Applications/NCU StudyRocket.app"
fi
if [[ "${STUDYROCKET_NO_LAUNCH:-0}" != "1" ]]; then
  open "/Applications/NCU StudyRocket.app"
fi
echo "Installed /Applications/NCU StudyRocket.app"
