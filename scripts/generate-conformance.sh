#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen_bin=${XCODEGEN_BIN:-$(command -v xcodegen || true)}
if [[ -z "$xcodegen_bin" ]]; then xcodegen_bin=/opt/homebrew/bin/xcodegen; fi
[[ -x "$xcodegen_bin" ]] || { echo 'Install XcodeGen: brew install xcodegen' >&2; exit 1; }
"$xcodegen_bin" generate --spec TestSupport/project.yml
