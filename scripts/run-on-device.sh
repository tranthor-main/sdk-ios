#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
usage() {
  cat <<'HELP'
Usage: scripts/run-on-device.sh [--dry-run] <device-udid-or-name>
       scripts/run-on-device.sh --help
Requires an unlocked, trusted iPhone with Developer Mode enabled, an Apple Account
in Xcode Settings > Accounts (Apple Accounts in Xcode 27), and a unique bundle ID and Personal Team in
Config/Local.xcconfig. --dry-run prints the plan without contacting a device,
building, provisioning, installing or launching. Enter real write keys only in the app.
HELP
}
dry=false
selector=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --dry-run) dry=true; shift ;;
    --*) usage >&2; exit 2 ;;
    *) [[ -z "$selector" ]] || { usage >&2; exit 2; }; selector=$1; shift ;;
  esac
done
[[ -n "$selector" ]] || { usage >&2; exit 2; }
if $dry; then
  printf 'Dry run only; resolve physical iPhone %q to its UDID using devicectl list devices JSON.\n' "$selector"
  cat <<'PLAN'
1. scripts/generate-example.sh
2. Read Config/Local.xcconfig; require nonempty team and a unique bundle ID.
3. xcodebuild -project Examples/TranthorExample/TranthorExample.xcodeproj -scheme TranthorExample -destination 'platform=iOS,id=<resolved-udid>' -derivedDataPath DerivedData/ExampleDevice -collect-test-diagnostics never -allowProvisioningUpdates build
4. xcrun devicectl device install app --device <resolved-udid> DerivedData/ExampleDevice/Build/Products/Debug-iphoneos/TranthorExample.app
5. xcrun devicectl device process launch --device <resolved-udid> <bundle-id-from-built-Info.plist>
PLAN
  exit 0
fi
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/tranthor-device.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
if ! xcrun devicectl list devices --timeout 15 --json-output "$work_dir/devices.json" >"$work_dir/list.log" 2>&1; then
  echo 'Could not enumerate devices with devicectl.' >&2; exit 1
fi
if device_id=$(/usr/bin/python3 - "$work_dir/devices.json" "$selector" <<'PY'
import json,sys
with open(sys.argv[1]) as f: devices=json.load(f).get('result',{}).get('devices',[])
matches=[]
for d in devices:
 p=d.get('properties',{}); h=p.get('hardware',{}); old=d.get('hardwareProperties',{}); state=p.get('state',{}); dp=d.get('deviceProperties',{})
 if h.get('reality',old.get('reality'))!='physical' or h.get('deviceType',old.get('deviceType'))!='iPhone': continue
 udid=h.get('udid',old.get('udid')); name=state.get('name',dp.get('name'))
 if sys.argv[2] in (udid,d.get('identifier'),name): matches.append((udid,state,dp,p.get('connection',d.get('connectionProperties',{}))))
if not matches:
 print('No physical iPhone matches that UDID, CoreDevice identifier or exact name.',file=sys.stderr);sys.exit(3)
if len(matches)!=1:
 print('Multiple physical iPhones match: select a unique UDID or CoreDevice identifier.',file=sys.stderr);sys.exit(3)
udid,state,dp,connection=matches[0]
if not udid:
 print('The selected iPhone has no UDID in devicectl output.',file=sys.stderr);sys.exit(3)
def field(name):
 values=[state.get(name),dp.get(name),connection.get(name)]
 # Legacy deviceProperties exposes explicit strings; Xcode 27 state uses enum dictionaries.
 for value in values:
  if isinstance(value,str): return value
 for value in values:
  if isinstance(value,dict) and len(value)==1: return next(iter(value))
  if value is not None: return value
if field('pairingState') not in (None,'paired') or field('trustState') in ('untrusted','notTrusted') or field('isTrusted') is False:
 print('The iPhone is unpaired or untrusted: unlock it and accept Trust This Computer.',file=sys.stderr);sys.exit(3)
if field('lockState') == 'locked' or field('isLocked') is True:
 print('The iPhone is locked: unlock it before building or installing.',file=sys.stderr);sys.exit(3)
if field('developerModeStatus') == 'disabled':
 print('Developer Mode is disabled: enable it in Privacy & Security, restart and confirm Enable.',file=sys.stderr);sys.exit(3)
if field('ddiServicesAvailable') is False:
 print('Warning: Developer Disk Image services are unavailable; xcodebuild/devicectl may prepare them. If preparation fails, use Xcode Device Hub or update Xcode for this iOS version.',file=sys.stderr)
print(udid)
PY
); then
  :
else
  resolution_status=$?
  [[ "$resolution_status" != 3 ]] || exit 1
  echo 'No single physical iPhone matches that UDID or exact name. Check the cable, unlock/trust the phone, and use its name or UDID from xcrun devicectl list devices.' >&2
  exit 1
fi
scripts/generate-example.sh
# Check only presence; never echo the local signing values into script diagnostics.
if ! /usr/bin/python3 - Config/Local.xcconfig <<'PY'
import re,sys
with open(sys.argv[1]) as f: text=f.read()
def value(key):
 matches=re.findall(r'^\s*'+key+r'\s*=\s*([^\n]*)',text,re.M)
 return matches[-1].split('//')[0].strip() if matches else ''
team=value('DEVELOPMENT_TEAM'); bundle=value('PRODUCT_BUNDLE_IDENTIFIER')
sys.exit(0 if team and bundle and bundle!='com.example.tranthor.ios-example' and '$(' not in team+bundle else 1)
PY
then echo 'Local.xcconfig needs a Personal Team and unique bundle identifier; the placeholders cannot provision a phone.' >&2; exit 1; fi
# Xcode diagnoses unavailable Developer Mode, locked/untrusted devices and DDI preparation.
# Build output may contain your local signing identity; do not share it without redaction.
if ! xcodebuild -project Examples/TranthorExample/TranthorExample.xcodeproj -scheme TranthorExample \
  -destination "platform=iOS,id=$device_id" -derivedDataPath DerivedData/ExampleDevice -collect-test-diagnostics never -allowProvisioningUpdates build; then
  echo 'Device build/provisioning failed.' >&2; exit 1
fi
app=DerivedData/ExampleDevice/Build/Products/Debug-iphoneos/TranthorExample.app
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
if ! xcrun devicectl device install app --device "$device_id" "$app"; then
  echo 'Installation failed. Unlock the phone; check trust, Developer Mode and the provisioning profile.' >&2; exit 1
fi
# Do not inherit credential launch overrides; real device credentials are entered in the app.
unset DEVICECTL_CHILD_TRANTHOR_HOST DEVICECTL_CHILD_TRANTHOR_WRITE_KEY
if ! xcrun devicectl device process launch --device "$device_id" "$bundle_id"; then
  echo 'Launch failed. Unlock the phone and trust the developer profile under VPN & Device Management.' >&2; exit 1
fi
echo 'Example launched. Enter your workspace write key in the secure app field, Configure, then Identify a disposable test user.'
