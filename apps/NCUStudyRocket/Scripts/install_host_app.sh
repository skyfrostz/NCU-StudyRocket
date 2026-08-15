#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/.build/StudyRocket Host.app"
"$ROOT/Scripts/build_host_app.sh" >/dev/null
rm -rf "/Applications/StudyRocket Host.app"
cp -R "$APP" "/Applications/StudyRocket Host.app"
open "/Applications/StudyRocket Host.app"
echo "Installed /Applications/StudyRocket Host.app"
