#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/generate-conformance.sh
scripts/prepare-simulator.sh
simulator_name=${TRANTHOR_SIMULATOR_NAME:-iPhone 17}
# An explicitly supplied prefixed/unprefixed host uses an external mock server.
# Otherwise reserve a free loopback port by starting the owned mock on port 0.
server_log=
server_pid=
cleanup() {
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  if [[ -n "$server_log" ]]; then rm -f "$server_log"; fi
}
trap cleanup EXIT INT TERM
if [[ ${TEST_RUNNER_CONFORMANCE_HOST+x} ]]; then
  host=$TEST_RUNNER_CONFORMANCE_HOST
elif [[ ${CONFORMANCE_HOST+x} ]]; then
  host=$CONFORMANCE_HOST
else
  server_log=$(mktemp -t tranthor-mock)
  node conformance/server/cli.cjs --port 0 >"$server_log" &
  server_pid=$!
  for ((n=0; n<100; n++)); do
    [[ -s "$server_log" ]] && break
    kill -0 "$server_pid" 2>/dev/null || { cat "$server_log"; exit 1; }
    sleep 0.1
  done
  host=$(node -e 'const fs=require("node:fs"); process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1],"utf8").trim().split("\n")[0]).host)' "$server_log")
fi
[[ "$host" == http://127.0.0.1:* ]] || { echo 'CONFORMANCE_HOST must be a nonempty http://127.0.0.1:<port> mock origin.' >&2; exit 1; }
for ((n=0; n<100; n++)); do
  if curl --silent --fail "$host/control/time" >/dev/null; then break; fi
  sleep 0.1
done
curl --silent --fail "$host/control/time" >/dev/null
# Xcode forwards TEST_RUNNER_* to the simulator test process, removing the prefix.
# Verified by the runner requiring CONFORMANCE_HOST and executing all 39 scenarios (suite 1.1.0).
export TEST_RUNNER_CONFORMANCE_HOST="$host"
if [[ -n "${CONFORMANCE_SCENARIO:-}" ]]; then export TEST_RUNNER_CONFORMANCE_SCENARIO="$CONFORMANCE_SCENARIO"; fi
python3 scripts/run-bounded.py 300 xcodebuild -project TestSupport/ConformanceHost.xcodeproj -scheme Conformance \
  -destination "platform=iOS Simulator,name=$simulator_name" -derivedDataPath DerivedData/Conformance -collect-test-diagnostics never \
  -parallel-testing-enabled NO test
