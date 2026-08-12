#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
APP="$ROOT/.build/NCU StudyRocket.app"
"$ROOT/Scripts/build_app.sh" >/dev/null
rm -rf "/Applications/NCU StudyRocket.app"
cp -R "$APP" "/Applications/NCU StudyRocket.app"
open "/Applications/NCU StudyRocket.app"
echo "Installed /Applications/NCU StudyRocket.app"
