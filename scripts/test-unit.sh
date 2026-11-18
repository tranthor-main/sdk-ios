#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/test-device-resolver.py
python3 scripts/run-bounded.py 120 swift test --skip testConformance -Xswiftc -warnings-as-errors "$@"
