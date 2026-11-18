#!/bin/bash
set -euo pipefail
# Select by name, never a checked-in UUID. A dedicated device can be named by CI.
name=${TRANTHOR_SIMULATOR_NAME:-iPhone 17}
devices=$(xcrun simctl list devices available --json)
selection=$(printf '%s' "$devices" | node -e '
const fs = require("node:fs");
const name = process.argv[1];
const data = JSON.parse(fs.readFileSync(0, "utf8"));
const devices = Object.entries(data.devices).filter(([runtime]) => runtime.includes("iOS-27-0"))
  .flatMap(([,devices]) => devices).filter(d => d.isAvailable && d.name === name);
if (devices.length !== 1) { console.error(`Expected one ${name} simulator on iOS 27.0; found ${devices.length}.`); process.exit(1); }
process.stdout.write(`${devices[0].udid}\n${devices[0].state}`);
' "$name")
id=${selection%%$'\n'*}
state=${selection#*$'\n'}
if [[ "$state" != Booted ]]; then xcrun simctl boot "$id"; fi
# xcodebuild can try to launch while a busy simulator is still bootstrapping.
xcrun simctl bootstatus "$id" -b
