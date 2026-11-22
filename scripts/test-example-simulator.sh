#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/prepare-simulator.sh
simulator_name=${TRANTHOR_SIMULATOR_NAME:-iPhone 17}
# Node's port 0 binding reserves a free port without a selection/start race.
server_log=$(mktemp -t tranthor-mock)
server_pid=
cleanup() {
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  rm -f "$server_log"
}
trap cleanup EXIT INT TERM
node conformance/server/cli.cjs --port 0 >"$server_log" &
server_pid=$!
for ((n=0; n<100; n++)); do
  [[ -s "$server_log" ]] && break
  kill -0 "$server_pid" 2>/dev/null || { cat "$server_log"; exit 1; }
  sleep 0.1
done
host=$(node -e 'const fs=require("node:fs"); process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1],"utf8").trim().split("\n")[0]).host)' "$server_log")
[[ "$host" == http://127.0.0.1:* ]] || exit 1
for ((n=0; n<100; n++)); do
  if curl --silent --fail "$host/control/time" >/dev/null; then break; fi
  sleep 0.1
done
curl --silent --fail "$host/control/time" >/dev/null
# Xcode forwards TEST_RUNNER_* to the simulator test process, removing the prefix.
# The UI test requires TRANTHOR_HOST and verifies the ingestion request through the control API.
export TEST_RUNNER_TRANTHOR_HOST="$host"
scripts/generate-example.sh
# Signed to run locally (no team needed): an unsigned simulator app cannot save the typed key to the Keychain.
python3 scripts/run-bounded.py 300 xcodebuild -project Examples/TranthorExample/TranthorExample.xcodeproj -scheme TranthorExample \
  -destination "platform=iOS Simulator,name=$simulator_name" -derivedDataPath DerivedData/ExampleUITests -collect-test-diagnostics never \
  -parallel-testing-enabled NO CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
