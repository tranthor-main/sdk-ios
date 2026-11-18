# Try the iOS SDK on your iPhone

Maintainer runbook for running the example app on a physical device. Customers do not need it; see the [README](../README.md) to integrate the SDK.

The example uses the local Swift package and iOS 15 or later. Xcode 27 and XcodeGen 2.46 were used to verify the simulator flow. A free Apple Account (Apple ID / Personal Team) is sufficient for this events-only app. The physical-device signing, installation, Airplane Mode and dashboard steps below require a human and were not run during development.

The example includes local notification and image previews. Scroll to **Push preview**, allow notifications, then tap **Preview notification with image** and immediately go Home. Expand the banner to see its bundled test image; tap it to check the SDK's `Push Opened` event. This works with a free Personal Team and does not send through APNs. Remote push from Tranthor to the phone requires a paid app-publisher team; Tranthor registers the iPhone from the SDK's `Installation Registered` event and sends through APNs (see the [push guide](push.md)). Customers receiving notifications do not need a developer membership. The embedded Notification Service Extension adds remote images only after its exact CDN hosts are configured; see the [push guide](push.md#remote-images-and-the-badge-1).

## Prepare Xcode and the phone

1. Install Xcode and its iOS support, open it once and finish the first-launch setup. Install XcodeGen if necessary: `brew install xcodegen`.
2. Open **Xcode > Settings > Accounts (Apple Accounts in Xcode 27)**, add your Apple Account and sign in. A free account appears as a **Personal Team**. Do not put account passwords, team IDs or write keys into source files or shared logs.
3. Connect the iPhone with a cable, unlock it, and accept **Trust This Computer** on the iPhone (enter its passcode). In **Xcode > Open Developer Tool > Device Hub**, select the phone and wait for device preparation to finish. Xcode may need to download/mount its Developer Disk Image (DDI).
4. On iOS 16 and later, open **Settings > Privacy & Security > Developer Mode**, enable it, restart and confirm **Enable** after restart. If the setting is missing, first connect the phone to Xcode. [Apple's Developer Mode instructions](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device) cover this sequence. iOS 15 has no Developer Mode switch.
5. From the repository root, run:

   ```sh
   scripts/generate-example.sh
   open Examples/TranthorExample/TranthorExample.xcodeproj
   ```

   Generation copies `Config/Local.xcconfig.example` to ignored `Config/Local.xcconfig` if needed. Edit **Local.xcconfig** locally: set `DEVELOPMENT_TEAM` to your Personal Team's identifier and replace `PRODUCT_BUNDLE_IDENTIFIER` with a unique reverse-domain identifier. The checked-in `com.example.tranthor.ios-example` is a placeholder. Find the team identifier in Xcode's Accounts/team details (or your Apple developer account); never send the edited file to others. Keep the same bundle ID for repeated runs. The Personal Team limit is **10 App IDs per seven days**, so repeatedly inventing new IDs can exhaust it. [Apple documents the account limits and seven-day provisioning expiry](https://developer.apple.com/help/account/basics/about-your-developer-account).
6. Select the **TranthorExample** scheme and your connected iPhone as the run destination. Under the app target's **Signing & Capabilities**, confirm automatic signing and your Personal Team. Press **Cmd-R**. If prompted for an untrusted developer on the phone, open **Settings > General > VPN & Device Management**, select the developer profile and trust it, then launch again. Keep the phone unlocked during install/launch.

The generated `.xcodeproj` is ignored. Edit `project.yml` for shared project changes; edit `Local.xcconfig` only for local signing. Generation preserves that local configuration. The app uses HTTPS by default. Its only ATS exception is `NSAllowsLocalNetworking`; a local-network permission description explains LAN mock access. No blanket HTTP exception or push entitlement is present.

## Run from a script

Prefer the device UDID from `devicectl`; exact names can contain typographic apostrophes that are easy to mistype. Start in the repository root:

```sh
xcrun devicectl list devices
scripts/run-on-device.sh --help
scripts/run-on-device.sh --dry-run "$DEVICE_UDID"
scripts/run-on-device.sh "$DEVICE_UDID"
```

Set `DEVICE_UDID` locally to the UDID shown by `devicectl` (do not check it in). The script resolves only a physical iPhone, checks the local signing placeholders, builds with `-allowProvisioningUpdates`, installs through `devicectl` and launches. The resolver diagnoses reported pairing, trust, lock and Developer Mode problems and warns when DDI preparation is needed; Xcode supplies provisioning diagnostics. An unsupported phone OS requires a compatible Xcode. Xcode's provisioning command needs your signed-in account; it cannot create one for you. Build output may include your local signing identity, so redact it before sharing.

A free Personal Team profile expires **seven days after issuance**; rebuild/reinstall to renew. Apple also limits free accounts to three devices and three installed apps per device. Remote APNs notifications require the paid Apple Developer Program. The optional TranthorPush module and example can preview local notifications with a free account; remote APNs needs the paid program and a Tranthor workspace with mobile push enabled. The shared example has no enabled push entitlement. See the [push guide](push.md) for simulator injection and the separate optional paid-team entitlement setup. [Apple's capability matrix](https://developer.apple.com/help/account/reference/supported-capabilities-ios) describes program availability.

## Configure and find your test events

Use a disposable test user, for example `ios-example-yourname-date`. In your Tranthor workspace **Settings**, find the app's **write key**. Type it only into the app's secure **Write key** field. Do not put it in Terminal, launch arguments, screenshots, tickets or logs. Keep the default host `https://api.tranthor.com` for a normal workspace; tap **Configure**, enter the disposable user ID and tap **Identify**. The human performs these HTTPS requests; automated verification uses only the local mock.

Manually entered keys are stored in device-only Keychain storage; the host is stored in local preferences. A saved key auto-configures the SDK on relaunch, restoring identity, consent and pending events. **Reconfigure** shuts down the old instance without flushing, then restores its durable namespace. Use the same workspace/host while events are pending: changing credentials can deliver those pending events to the new workspace. Opt out to deliberately discard pending events before switching workspaces. Reset identity changes identity only and does not delete the write key or previously queued events.

Track, burst, Page and Screen attach `properties` with `liveTest: true`, the per-launch UUID `runId`, and `source: "ios-example"`. Identify has no properties argument in the public v1 API, so the same tags appear in its **traits and context**, as approved for this example. Set Identify first to associate later events with the disposable user. Anonymous-to-user stitching is not available in v1; earlier anonymous events remain anonymous.

Open the Tranthor dashboard **Events** page and filter by the exact **userId** you identified. Look for **iOS Example Tagged Event**, `liveTest`, `runId` and `source`. Allow for dashboard refresh/processing latency. The live panel shows public identity and consent, the last flush result and terminal error callbacks (event count, attempts, error). It deliberately shows no queue count because v1 exposes none. Accepted-call log entries mean local acceptance, not server delivery. **View log > Copy** copies the last 200 lines; keys and raw event bodies are never logged. A successful Flush settles pending SDK delivery; an empty or opted-out Flush also succeeds, so inspect the Events page for ingestion.

The dashboard Settings labels, filter and deletion flow need human verification against the deployed workspace. To clean up, locate the disposable user's profile in the workspace's users/customer list, open its actions and choose **Delete / erase user** (including associated events where offered), then confirm. Check the Events filter afterward. If your role lacks deletion permission, ask a workspace administrator to erase that user and any tagged anonymous events; do not delete unrelated users. Resetting the SDK identity is not server-side erasure. Tap **Forget key** to delete the saved Keychain item and clear the key field; Keychain items can survive app deletion.

Offline retention is bounded to about **15.5 seconds per batch** of immediately failing network attempts, plus any transport timeout. The SDK has no reachability gate: after five retries it discards the failed batch and reports it. A longer outage loses events. Persistence across restarts retains only events that are still queued or in flight when the process ends. Test short outages and restart recovery separately.

## Device checklist

- **First event:** Identify, **Track (no auto flush)**, Flush. Expect Flush succeeded and one tagged track in Events for the disposable user.
- **Burst:** leave N at 25, tap Track burst, then Flush. Expect 25 tracks (batches of up to five) under the same run ID. SDK timestamps/message IDs should stay stable when a batch retries.
- **Short outage / retry:** check that **Flush interval: 500 ms** is shown (turn **Slow flush** OFF) before this test. Enable the app's “Simulate offline” instruction toggle. Turn Airplane Mode on and disable Wi-Fi **first**, then tap Track, then turn Airplane Mode off and reconnect **within about 10 seconds**. The orange network-unreachable banner appears while offline. Do not tap Flush: check that the SDK retry delivers the tagged event. The example never auto-flushes on reconnect (the log says so). The instruction toggle never changes host/transport; an available route does not guarantee server reachability.
- **Relaunch recovery (separate test):** enable Airplane Mode and disable Wi-Fi, Track one or two events, then force-quit promptly after acceptance, before retry exhaustion. Relaunch promptly, reconnect and Flush. Saved configuration restores the same durable namespace and the still-pending items with original run ID/stamps; later events use the new launch run ID. Force quit is not a background flush guarantee. A restart resets the retry attempt count, but does not recover already-discarded batches.
- **Consent:** offline, enqueue events, then tap Opt out. Expect retries cancelled and pending events discarded; Flush succeeds without a request. New calls are discarded until Opt in. Relaunch to check persisted consent, then Opt in, Track and Flush. Discarded events produce no error callback.
- **Background flush:** Enable **Slow flush (60 s)**, tap **Track (no auto flush)** once, and press Home immediately. Confirm in the dashboard that the event arrives within seconds, rather than after 60 s. The SDK observes real app lifecycle notifications and obtains a short UIKit background task to flush. Check Events afterward. The OS can expire the task; this is not continuous background execution. The UI test uses the 60 s interval and verifies delivery within 10 s of Home. Actual UIKit background-task ending, stale expiry-token rejection and device time-budget expiry remain manual-device-only checks.
- **Reset:** note both IDs, tap Reset identity. Expect no current user ID and a new anonymous ID. Identify the same disposable test user again before continuing.
- **Error observation:** during an extended offline period, terminal failures eventually appear with count and attempts, and Flush reports failure. This intentionally tests data discard at exhaustion. Start a fresh tagged event after reconnecting.
- **Local notification preview:** scroll to Push preview, request permission and tap Allow, then Preview local notification. Expect a foreground observation and the SDK's `Push Received` event. To test opened, schedule and return Home before the two-second preview fires, then tap it. This is local iOS handling, not a test of APNs or of push delivery from Tranthor. Opt out suppresses new owned observations; it does not revoke OS notification permission.

## Simulator and automated local checks

These commands require no Apple Account or signing identity:

```sh
scripts/run-on-simulator.sh
scripts/test-example-simulator.sh
scripts/test-simulator.sh
```

The launch script boots the available **iPhone 17** by name, generates/builds/installs the app and opens Simulator (Device Hub in Xcode 27). Enter credentials in the app if you choose to test a workspace manually. Simulator networking follows the Mac; the app's instruction toggle does not simulate transport failure.

For a non-secret local fixture, start the unchanged mock in a separate Terminal:

```sh
node conformance/server/cli.cjs --port 43189
```

Then launch the example from another Terminal:

```sh
TRANTHOR_WRITE_KEY=conformance-fixture scripts/run-on-simulator.sh --host http://127.0.0.1:43189 --key-from-env
```

Stop the server with Ctrl-C. `--key-from-env` is opt-in and intended for mock fixtures. `TRANTHOR_HOST` and `TRANTHOR_WRITE_KEY` launch overrides are read only when present, take precedence over saved values and are never persisted from the launch environment. `TRANTHOR_FLUSH_INTERVAL_MS=60000` (or `--TRANTHOR_FLUSH_INTERVAL_MS 60000`) overrides the interval for checklist automation. The visible Slow flush toggle persists only its Boolean in UserDefaults and reconfigures the SDK; the key stays in Keychain. Equivalent app launch arguments are `--TRANTHOR_HOST URL` and `--TRANTHOR_WRITE_KEY VALUE`; use them only for non-secret fixtures since arguments can appear in process lists. Editing a field manually makes its new value eligible for persistence. The UI-test script uses an isolated SDK namespace, starts a mock on a free loopback port, forwards `TEST_RUNNER_TRANTHOR_HOST` to the test process, and always kills the server. The test then sets app launch environment and resets the mock with `/control/reset`, backgrounds the app with a 60 s interval, and asserts one tagged ingestion within 10 s through `/control/requests`.

## Optional physical-device conformance forwarding — unverified

The vendored mock binds **127.0.0.1 only**. On an iPhone, 127.0.0.1 is the phone itself, so the host mock needs a separate LAN forwarder. Do not change the mock server. One optional approach uses `socat` on the Mac (not an app dependency):

```sh
brew install socat
node conformance/server/cli.cjs --port 43189
```

In a second Terminal on the same Mac, on a trusted local Wi-Fi network:

```sh
MAC_LAN_IP=$(ipconfig getifaddr en0)
socat "TCP-LISTEN:43190,bind=$MAC_LAN_IP,reuseaddr,fork" TCP:127.0.0.1:43189
```

`en0` must be the Mac's active LAN interface; choose the correct interface if it is not. Set the phone test host to `http://<Mac LAN IP>:43190`, allow the app's Local Network prompt and any macOS firewall prompt, and stop both processes with Ctrl-C afterward. This forwarder exposes the mock control API on that interface; use only a trusted test network and no real credentials. A physical conformance test host additionally needs signing and test-plan `CONFORMANCE_HOST` configuration; `scripts/test-simulator.sh` targets Simulator only. The forwarder command and physical conformance setup are **unverified**, not part of the verified one-script device example flow.
