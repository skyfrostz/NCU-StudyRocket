#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
swift build --build-system native --product NCUStudyRocket
BIN_PATH="$(swift build --build-system native --show-bin-path)"
CHECK_OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/NCUStudyRocket-seed-checks.XXXXXX")"
trap '/bin/rm -rf -- "$CHECK_OUTPUT"' EXIT INT TERM
# Exercise the real registration method without exposing test APIs in the app.
# The temporary copy changes access control only; all implementation stays intact.
python3 - "$CHECK_OUTPUT/StudyChat.swift" <<'PY'
import sys
from pathlib import Path
source = Path('Sources/NCUStudyRocket/StudyChat.swift').read_text()
for before, after in [
    ('    private var root: URL?', '    var root: URL?'),
    ('    private func registerProposal(', '    func registerProposal('),
]:
    assert source.count(before) == 1, f'Expected one test access point: {before}'
    source = source.replace(before, after)
Path(sys.argv[1]).write_text(source)
PY
OBJECTS=("$BIN_PATH/StudyRocketShared.build/"*.swift.o "$BIN_PATH/StudyRocketChatCore.build/"*.swift.o "$BIN_PATH/cmark_gfm.build/"*.c.o "$BIN_PATH/cmark_gfm_extensions.build/"*.c.o)
swiftc -parse-as-library -I "$BIN_PATH/Modules" \
  -I "$ROOT/.build/checkouts/swift-cmark/src/include" \
  -I "$ROOT/.build/checkouts/swift-cmark/extensions/include" \
  Sources/NCUStudyRocket/DesktopCloudBackup.swift Sources/NCUStudyRocket/DesktopCloudWorkspace.swift Sources/NCUStudyRocket/Models.swift "$CHECK_OUTPUT/StudyChat.swift" \
  Sources/NCUStudyRocket/StudyRocketHostClient.swift Sources/NCUStudyRocket/StudyRocketTheme.swift Sources/NCUStudyRocket/UserMessageLayout.swift \
  Sources/StudyRocketHost/HostSnapshotBuilder.swift Sources/StudyRocketHost/HostWriteService.swift Sources/StudyRocketHost/HostProposalStore.swift Sources/StudyRocketHost/LocalHostRepositoryPolicy.swift \
  Tests/LocalProposalSeedChecks.swift "${OBJECTS[@]}" -o "$CHECK_OUTPUT/LocalProposalSeedChecks"
mkdir -p "$CHECK_OUTPUT/home"
env CFFIXED_USER_HOME="$CHECK_OUTPUT/home" "$CHECK_OUTPUT/LocalProposalSeedChecks"
