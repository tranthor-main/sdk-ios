# Push notifications

`TranthorPush` registers the device with Tranthor and reports what customers do with each push. It builds on `TranthorSDK`: registrations and reports travel through the SDK's event queue, under its identity and consent, so they survive offline periods and relaunches. It never prompts for permission, swizzles, assigns the notification delegate or opens a link; those stay yours.

## Set up

1. **Capability.** Add Push Notifications to the app target. Remote push needs a paid Apple Developer Program membership; a free account supports only local previews.
2. **Environment.** Pass the APNs environment the build is signed with: `.development` for Xcode and Simulator builds, `.production` for TestFlight and the App Store. It is never inferred, and a wrong value makes Apple reject the token.
3. **Create the instance** after configuring the SDK and keep it for the app's lifetime:

```swift
import TranthorSDK
import TranthorPush

let sdk = try await TranthorSDK.configure(Configuration(writeKey: "<your write key>"))
let push = try await TranthorPush(
    configuration: PushConfiguration(bundleIdentifier: Bundle.main.bundleIdentifier!, environment: .development),
    sdk: sdk)
```

4. **Ask for permission and forward the token** on every launch. `PushAuthorization.request()` shows the prompt; you call `registerForRemoteNotifications()`:

```swift
func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Task { try? await push.registerDeviceToken(deviceToken) }
}
```

After the permission request returns, call `try await push.refreshPermission()`. The permission is also re-read when the app becomes active, and registered again only if it changed.

5. **Forward notification callbacks** (below).

Identity and consent belong to the SDK. `identify`, `reset`, `optOut` and `optIn` on `TranthorSDK` keep the registration in step; there is nothing to call on `TranthorPush`. `shutdown()` stops the push instance only.

## What is sent

A device is registered only while a customer is signed in. Before the first `identify` the token is held on the device and nothing is sent. All of these are ordinary events with a `userId`:

| Event | When | Properties |
| --- | --- | --- |
| `Installation Registered` | A token and a signed-in customer exist; again when the token, owner, permission, app version, OS version or SDK version changes, and once per app start. | `platform`, `appId`, `environment`, `token`, `permissionState`, `appVersion`, `osVersion`, `sdkVersion` |
| `Installation Removed` | The token, app or environment changes; on `reset()`; on `optOut()`. | `platform`, `appId`, `environment`, `token` |
| `Push Received` | A push was presented while the app was in the foreground. | `deliveryId` |
| `Push Opened` | The customer tapped the notification. | `deliveryId` |
| `Push Dismissed` | The customer dismissed it. | `deliveryId` |

iOS reports a push as received only while the app is in the foreground, so `Push Received` undercounts. `optOut()` leaves one `Installation Removed`, delivered even while opted out, so Tranthor stops pushing to the phone. The token is stored in the SDK's private state file until it is delivered, and is replaced by `"<redacted>"` in what `onError` receives.

## Forward notifications

Call `handle(_:interaction:)` from your `UNUserNotificationCenterDelegate`. Copy `userInfo` into a `PushNotification` before starting a Task. It returns false for a payload that is not a Tranthor push, so another SDK can handle it.

```swift
nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                        withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
    let payload = PushNotification(userInfo: response.notification.request.content.userInfo)
    let action = response.actionIdentifier
    let interaction: PushInteraction = action == UNNotificationDismissActionIdentifier
        ? .dismissed : .opened(actionIdentifier: action)
    let link = payload?.url.flatMap(URL.init(string:))
    completionHandler()
    Task { @MainActor in
        if let link, link.scheme == "https" || link.scheme == "myapp" { router.open(link) } // your own allow-list
        _ = try? await push.handle(payload, interaction: interaction)
    }
}

nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
    let payload = PushNotification(userInfo: notification.request.content.userInfo)
    completionHandler([.banner, .sound, .badge]) // .badge is needed for the badge +1
    Task { _ = try? await push.handle(payload, interaction: .foreground) }
}
```

`PushNotification` gives you `deliveryID`, `imageURL`, `incrementsBadge`, `url` (the tap link) and `data` (the template's custom string values). The `url` comes from a push, so check it before opening it. Duplicate interactions are reported once.

## The dismiss category

iOS reports a dismissal only for a notification whose category was registered with `customDismissAction`. The server always sends the category `TRANTHOR_PUSH`; `TranthorPush` registers it at start and whenever the app becomes active, next to your categories. `setNotificationCategories(_:)` replaces the whole set, so register your categories before creating `TranthorPush`, or call `await push.registerNotificationCategory()` right after replacing them. A `TRANTHOR_PUSH` category you register yourself is left alone.

## Remote images and the badge +1

Add the `TranthorPushService` product to a Notification Service Extension target (iOS 15 or later, Application Extension API Only) and subclass the extension:

```swift
import TranthorPushService

final class NotificationService: TranthorNotificationServiceExtension {
    override var allowedImageHosts: Set<String> { ["images.example.com"] }
    override var appGroupIdentifier: String? { "group.com.example.app" } // for the badge +1
}
```

**Images.** The server sends an alert with `mutable-content: 1` and `tranthor.imageUrl`. Only HTTPS URLs on the exact hosts in `allowedImageHosts` (host names only, no scheme or port) are fetched, with no redirects, credentials, write key or token. PNG, JPEG and GIF up to 5 MiB and 16 million pixels are accepted, with a 10 second timeout. Any failure shows the text without the image. With no allowed hosts, no image is shown. If another SDK already owns your extension, keep a `TranthorRichPush` in it instead and forward to it first: it returns false, without calling the handler, for pushes it does not handle.

**Badge.** APNs takes an absolute badge number, so the server sends `tranthor.badge: "increment"` and the extension adds one to a count kept in the App Group container, which an extension cannot read from the icon. To use it:

1. Enable the same App Group on the app and the extension and return it from `appGroupIdentifier`.
2. Change the icon badge only through `TranthorBadge.set(_:appGroupIdentifier:)` (or `clear`), which updates the icon and the stored count together. If other code sets the badge, call `TranthorBadge.synchronize(_:appGroupIdentifier:)` with the new number.
3. Return `.badge` from `willPresent`, or a push received in the foreground does not move the icon.

The badge applies even when the image fails or the host is invalid. It changes only when the extension runs, which iOS does for remote alerts with `mutable-content: 1`; notifications the customer clears do not lower it. If the count cannot be stored, `TranthorBadge.set` still sets the icon and throws `TranthorBadgeError.counterUnavailable`.

## Try it without a server push

The example app can schedule a local notification, which exercises the delegate and the events without APNs. To inject a remote payload into a running Simulator:

```sh
node conformance/server/cli.cjs --port 43189
TRANTHOR_WRITE_KEY=conformance-fixture scripts/run-on-simulator.sh --host http://127.0.0.1:43189 --key-from-env
scripts/send-simulator-push.sh --fixture full   # also: preview, badge, rich
```

Simulator injection bypasses APNs, signing and the server. For a real device run, copy `Config/Push.entitlements.example` to `Config/Push.entitlements`, set `TRANTHOR_PUSH_ENTITLEMENTS` and `TRANTHOR_APNS_ENVIRONMENT` in `Config/Local.xcconfig`, and follow [device-testing.md](device-testing.md).

## Privacy

The push token is sent to Tranthor and stored on the device as described above. Declare it, the user ID and push interactions in your app's privacy details. The SDK adds no tracking prompt. Do not log tokens or message contents.
