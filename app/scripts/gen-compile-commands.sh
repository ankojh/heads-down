#!/bin/bash
# Writes compile_commands.json at the repo root so SourceKit-LSP (editors, linters) type-checks the
# app's Swift files as one module instead of one file at a time. Editor tooling only; xcodebuild
# does not use it. Re-run after adding or removing Swift files.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo"
sdk="$(xcrun --show-sdk-path --sdk macosx)"
find app/HeadsDown -name '*.swift' | sort | python3 -c '
import json, sys
repo, sdk = sys.argv[1], sys.argv[2]
files = [repo + "/" + line.strip() for line in sys.stdin if line.strip()]
args = ["swiftc", "-module-name", "HeadsDown", "-swift-version", "5",
        "-target", "arm64-apple-macos15.0", "-sdk", sdk, *files]
print(json.dumps([{"directory": repo, "file": f, "arguments": args} for f in files], indent=1))
' "$repo" "$sdk" > compile_commands.json
echo "wrote $repo/compile_commands.json"
