#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d "${TMPDIR:-/tmp}/heads-down-checks.XXXXXX")
trap 'rm -rf "$work"' EXIT
sources=()
while IFS= read -r -d '' file; do
  sources+=("$file")
done < <(find app/HeadsDown -name '*.swift' ! -name HeadsDownApp.swift -print0)
xcrun swiftc -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macosx15.0" \
  "${sources[@]}" app/tests/CoverContinuityChecks.swift -o "$work/checks"
"$work/checks"
