#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
mkdir -p .build
swiftc -parse-as-library Sources/NCUStudyRocket/Models.swift Scripts/MarkdownChecks.swift -o .build/markdown-checks
.build/markdown-checks
