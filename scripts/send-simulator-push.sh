#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
usage() {
  echo 'Usage: scripts/send-simulator-push.sh [--device NAME] [--bundle-id ID] [--payload FILE | --fixture preview|rich|badge|full]'
  echo 'Injects a local simulator push; bypasses APNs and needs no Apple Account or write key.'
  echo 'Enable notifications in the example first. Use your configured bundle ID if changed.'
}
name=${TRANTHOR_SIMULATOR_NAME:-iPhone 17}
bundle=com.example.tranthor.ios-example
payload=Examples/TranthorExample/Fixtures/preview.apns
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; name=$2; shift 2 ;;
    --bundle-id) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; bundle=$2; shift 2 ;;
    --payload) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; payload=$2; shift 2 ;;
    --fixture)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      case "$2" in
        preview) payload=Examples/TranthorExample/Fixtures/preview.apns ;;
        rich|badge|full) payload=Examples/TranthorExample/Fixtures/$2-preview.apns ;;
        *) usage >&2; exit 2 ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ -f "$payload" ]] || { echo 'Payload file does not exist.' >&2; exit 2; }
id=$(xcrun simctl list devices available --json | /usr/bin/python3 -c '
import json,sys
matches=[d for runtime,ds in json.load(sys.stdin)["devices"].items() if "iOS-27-0" in runtime for d in ds if d["name"]==sys.argv[1] and d["state"]=="Booted"]
if len(matches)!=1: sys.exit("Expected exactly one booted named simulator on iOS 27.0; launch the example first.")
print(matches[0]["udid"])
' "$name")
xcrun simctl push "$id" "$bundle" "$payload"
echo 'Simulator notification injected. This does not verify APNs or push delivery from Tranthor.'
