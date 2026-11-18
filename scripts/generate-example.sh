#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f Config/Local.xcconfig ]]; then
  cp Config/Local.xcconfig.example Config/Local.xcconfig
  echo 'Created ignored Config/Local.xcconfig with empty signing team and placeholder bundle identifier.'
fi
xcodegen_bin=${XCODEGEN_BIN:-$(command -v xcodegen || true)}
if [[ -z "$xcodegen_bin" ]]; then xcodegen_bin=/opt/homebrew/bin/xcodegen; fi
[[ -x "$xcodegen_bin" ]] || { echo 'Install XcodeGen: brew install xcodegen' >&2; exit 1; }
"$xcodegen_bin" generate --spec Examples/TranthorExample/project.yml
