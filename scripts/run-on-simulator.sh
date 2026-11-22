#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
usage() { echo 'Usage: scripts/run-on-simulator.sh [--host URL] [--key-from-env]'; echo 'Only --key-from-env forwards TRANTHOR_WRITE_KEY (use a non-secret mock fixture). Real keys belong in the app.'; }
launch_host=
forward_key=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; launch_host=$2; shift 2 ;;
    --key-from-env) forward_key=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
if $forward_key && [[ -z "${TRANTHOR_WRITE_KEY:-}" ]]; then echo 'TRANTHOR_WRITE_KEY must be set for --key-from-env.' >&2; exit 2; fi
scripts/generate-example.sh
simulator_name=${TRANTHOR_SIMULATOR_NAME:-iPhone 17}
scripts/prepare-simulator.sh
sim_id=$(xcrun simctl list devices available --json | /usr/bin/python3 -c 'import json,sys; ds=[d for runtime, group in json.load(sys.stdin)["devices"].items() if "iOS-27-0" in runtime for d in group if d["name"]==sys.argv[1]]; assert len(ds)==1, "Expected exactly one selected iOS 27.0 simulator"; print(ds[0]["udid"])' "$simulator_name")
developer_dir=$(xcode-select -p)
if [[ -d "$developer_dir/Applications/Simulator.app" ]]; then
  open -a "$developer_dir/Applications/Simulator.app" --args -CurrentDeviceUDID "$sim_id"
else
  # Xcode 27 moved Simulator into Device Hub.
  open -a "$developer_dir/../Applications/DeviceHub.app"
fi
# Signed to run locally (no team needed): an unsigned simulator app cannot save the typed key to the Keychain.
xcodebuild -project Examples/TranthorExample/TranthorExample.xcodeproj -scheme TranthorExample \
  -destination "platform=iOS Simulator,id=$sim_id" -derivedDataPath DerivedData/Example -collect-test-diagnostics never CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build
app=DerivedData/Example/Build/Products/Debug-iphonesimulator/TranthorExample.app
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
xcrun simctl install "$sim_id" "$app"
# Prevent accidental inheritance. simctl removes SIMCTL_CHILD_ when launching.
unset SIMCTL_CHILD_TRANTHOR_HOST SIMCTL_CHILD_TRANTHOR_WRITE_KEY
if [[ -n "$launch_host" ]]; then export SIMCTL_CHILD_TRANTHOR_HOST="$launch_host"; fi
if $forward_key; then export SIMCTL_CHILD_TRANTHOR_WRITE_KEY="$TRANTHOR_WRITE_KEY"; fi
xcrun simctl launch --terminate-running-process "$sim_id" "$bundle_id"
echo "Example installed and launched on $simulator_name. Enter a workspace key only in the secure app field."
