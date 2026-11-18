#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
server_log=$(mktemp -t tranthor-host-mock)
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
  kill -0 "$server_pid" 2>/dev/null || exit 1
  sleep 0.1
done
host=$(node -e 'const fs=require("node:fs"); process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1],"utf8").trim().split("\n")[0]).host)' "$server_log")
[[ "$host" == http://127.0.0.1:* ]] || exit 1
curl --silent --fail "$host/control/time" >/dev/null
flags=(-Xswiftc -warnings-as-errors)
if [[ "${TRANTHOR_TSAN:-0}" == 1 ]]; then flags+=(--sanitize=thread); fi
CONFORMANCE_HOST="$host" python3 scripts/run-bounded.py 180 swift test "${flags[@]}" --filter ConformanceTests/testConformance
