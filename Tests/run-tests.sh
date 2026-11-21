#!/bin/zsh
# Run DiskScope's test suite (swift-testing) and print line/function coverage.
#
#   Tests/run-tests.sh              all tests + coverage table
#   Tests/run-tests.sh --filter X   only tests matching X (passed through to `swift test`)
#
# Works with just the Command Line Tools: they ship Testing.framework outside the default
# search path and without the Foundation cross-import overlay, so both are handled here.
# With full Xcode selected (xcode-select), the extra flags are harmless.
set -euo pipefail
cd "$(dirname "$0")/.."

DEV="$(xcode-select -p)"
FLAGS=()
if [[ "$DEV" == *CommandLineTools* ]]; then
  F="$DEV/Library/Developer/Frameworks"
  FLAGS=(-Xswiftc -F -Xswiftc "$F" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays
         -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F")
fi

SCRATCH="${SCRATCH:-.build/test}"   # override to run several builds side by side
STATUS=0
swift test --scratch-path "$SCRATCH" --enable-code-coverage "${FLAGS[@]}" "$@" || STATUS=$?

PROFDATA="$SCRATCH/debug/codecov/default.profdata"
BIN="$SCRATCH/debug/DiskScopePackageTests.xctest/Contents/MacOS/DiskScopePackageTests"
[[ -f "$PROFDATA" && -f "$BIN" ]] || { echo "(no coverage data)"; exit $STATUS; }

echo
echo "== Coverage: logic =="
xcrun llvm-cov report "$BIN" -instr-profile "$PROFDATA" \
  Sources/DiskScope/{Scanner,FileNode,AppModel,Volumes,HiddenSpace,DuplicateFinder,DuplicatesModel,RemovalScript,CSV,ScanExport,ClaudeClient,DiskSummary,AskClaude,KeychainStore}.swift
echo
echo "== Coverage: UI (not unit-tested) =="
xcrun llvm-cov report "$BIN" -instr-profile "$PROFDATA" \
  Sources/DiskScope/{ContentView,Sidebar,ColumnBrowser,ListBrowser,Components,DiskScopeApp,Sunburst,DuplicatesView,ContentPreview,AskClaudeView}.swift
exit $STATUS
