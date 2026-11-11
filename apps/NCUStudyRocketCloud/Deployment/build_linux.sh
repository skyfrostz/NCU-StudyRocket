#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../../.." && pwd)"
artifact_dir="${1:?usage: build_linux.sh ABSOLUTE_ARTIFACT_DIRECTORY}"
case "$artifact_dir" in /*) ;; *) echo 'Artifact directory must be absolute' >&2; exit 64 ;; esac
mkdir -p "$artifact_dir"
# The digest identifies the official Swift 6.4.2 Ubuntu 24.04 image.
build_image='swift:6.4.2-noble@sha256:bca121f6eb59fd80340d1296887b2698ed8f3eb9eca7d80c181f8af769dc7ee0'
docker run --rm --interactive --platform linux/amd64 --cpus 4 --memory 6g \
  --mount "type=bind,src=$task_root,dst=/source" \
  --mount "type=bind,src=$artifact_dir,dst=/artifact" \
  --mount type=volume,src=studyrocket-swift-linux-6-4-build,dst=/build \
  "$build_image" bash -s <<'BUILD'
set -euo pipefail
cd /source/apps/NCUStudyRocketCloud
swift build -c release --scratch-path /build --jobs 4
binary="$(swift build -c release --scratch-path /build --show-bin-path)/StudyRocketCloud"
install -m 755 "$binary" /artifact/StudyRocketCloud
mkdir -p /artifact/lib
# Bundle only the Swift runtime. Ubuntu 24.04 supplies glibc and common system
# libraries, so this does not replace the host loader or C runtime.
while IFS= read -r library; do
  case "$library" in
    /usr/lib/swift/*|/usr/local/swift/*)
      cp -L "$library" /artifact/lib/
      ;;
  esac
done < <(ldd "$binary" | awk '/=> \// {print $3}')
ldd "$binary" > /artifact/runtime-libraries.txt
swift --version > /artifact/toolchain.txt
cd /artifact
sha256sum StudyRocketCloud lib/* > SHA256SUMS
BUILD
printf '%s\n' "$build_image" > "$artifact_dir/build-image.txt"
python3 - "$task_root" "$artifact_dir" <<'PACKAGE'
from pathlib import Path
import hashlib
import json
import shutil
import sys
root, artifact = map(Path, sys.argv[1:])
package = root / 'apps/NCUStudyRocketCloud'
for name in ('Deployment', 'IntegrationTests'):
    shutil.copytree(package / name, artifact / name, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
sources = {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
           for base in (package / 'Sources', root / 'apps/NCUStudyRocketShared/Sources')
           for p in base.rglob('*.swift')}
(artifact / 'source-tree-sha256.json').write_text(json.dumps(sources, indent=2) + '\n')
with (artifact / 'SHA256SUMS').open('w') as checksums:
    for path in sorted(artifact.rglob('*')):
        if path.is_file() and path.name != 'SHA256SUMS':
            checksums.write(hashlib.sha256(path.read_bytes()).hexdigest() + '  '
                            + path.relative_to(artifact).as_posix() + '\n')
PACKAGE
