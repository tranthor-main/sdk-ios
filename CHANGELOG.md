# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Verified identity: `Configuration.identityTokenProvider` and `identify(userId:identityToken:)`. Identity tokens are kept with the state file, sent in the request body, renewed before they expire and after the server refuses one. A batch the server will not accept for lack of a token stays on the device and is tried again after 60 seconds, or at once on `flush()`, a new token for the user, or a different user. Events queued behind a held batch wait for it. See "Verified identity" in the README.
- `Configuration.appId` (default: the bundle identifier), sent with every request. An SDK created in an app extension sends the extension's bundle identifier unless `appId` is set.
- `Configuration.onNotice` and `Notice`: events the server dropped or could not verify, a refused token, unreadable identity settings.
- `DeliveryFailure.code`, `userIds` and `reason`, read from the server's error body.
- The conformance suite is now 1.6.0 (the `identity-token` and `app-id` scenarios).

### Changed

- `identify(userId:anonymousId:traits:messageId:timestamp:context:)` gained an `identityToken:` parameter after `userId:`. Calls that use argument labels are unaffected.
- An app that never configures a token provider and never passes an identity token handles a refused token exactly as before. The one exception is the outage hold below, which applies to every app.
- With tokens in use, a batch the server refuses for lack of a valid token for the current user is held instead of dropped, and at most 1,000 events are kept while it is held.
- A batch the server turns away because it cannot read its identity settings is now kept and sent again after the delay the server asks for, for every app, whether or not it uses identity tokens: it is a server outage, never a reason to drop events.
- When identity tokens are not in use and the server refuses a user, only that user's ordinary events are reported and dropped; other users' and anonymous events in the batch are sent as usual, and a queued push removal is kept and retried instead.
- A state file that has to be set aside keeps the pending removals and the installation record, and every event already queued counts as a signed-out user's.
- While a hold is active, the queue is trimmed in one place and an `Installation Removed` is never trimmed.
- A push `Installation Removed` is never dropped for lack of a token: each failed attempt is reported through `onNotice`, not `onError`, and it is tried again until it is delivered.

### Fixed

- Example app: tapping "Page" or "Screen" sent both a page and a screen event, because the two buttons share one form row. Each button now sends only its own event. The SDK itself is unchanged.
- Example app: "Page" and "Screen" each respond to a tap anywhere in their half of the row, not only on the word.
- Example app on the simulator: a typed write key is saved again, so the app configures itself on the next launch. The simulator scripts built the app unsigned, and an unsigned app cannot use the Keychain.

## [0.2.1] - 2026-11-18

### Changed

- The SDK is now covered by the Tranthor SDK License instead of the MIT License. You may include it in your apps to connect them to Tranthor; you may not redistribute it on its own or use it with other services. Versions 0.1.0 and 0.2.0 stay under the MIT License.

## [0.2.0] - 2026-11-18

### Changed

- Events are no longer discarded when their retries run out. A batch that could not be delivered (no connection, or a 408, 425, 429 or 5xx response) stays at the front of the queue with its original `messageId`s and timestamps, and is sent again later. `onError` is no longer called when retries run out, and `flush()` still throws the failure.
- After a batch runs out of retries, automatic delivery pauses: 30 seconds, then 60, 120, 240 and at most 5 minutes while delivery keeps failing. During the pause the interval timer, new events and a full batch do not start a request. `flush()` and the app returning from the background try at once, a delivered batch resets the pause, and a restarted app starts without one: its first attempt comes at the normal flush interval.
- Events are still discarded when the server rejects a batch with another status, on `optOut()`, and when the queue is full (the oldest go first and are reported to `onError` with `attempts` 0).
- Each queued event is now its own small file, so tracking an event no longer rewrites the whole queue. Events and identity from 0.1.0 are moved automatically the first time 0.2.0 starts; nothing needs to be done.

### Notes

- The state format changed. Going back to 0.1.0 after running 0.2.0 is not supported: 0.1.0 sets the new state file aside and starts with collection off until `optIn()`.

## [0.1.0] - 2026-11-18

First public release.

### Added

- `TranthorSDK`: identify customers, track events, and record page and screen views from an iOS 15+ app.
- Events are saved to disk before they are sent, delivered in batches, and retried with backoff, so they survive being offline and app relaunches. Queued events are sent when the app goes to the background.
- Anonymous IDs that link to the customer on `identify`, and rotate when a different customer signs in on the same device.
- `optOut()` and `optIn()`, remembered across launches.
- `Configuration` options for the host, batching, retries, context, storage location and queue size, and an `onError` callback for events that could not be delivered.
- `TranthorPush`: registers the device for push while a customer is signed in, and reports `Push Received`, `Push Opened` and `Push Dismissed`.
- `TranthorPushService`: a Notification Service Extension that attaches remote images from hosts you allow and applies the badge +1.
- `TranthorBadge` to keep the app icon badge and the extension's count in step.
- Privacy manifests for `TranthorSDK` and `TranthorPushService`.
- A SwiftUI example app and a conformance test suite for the delivery protocol.
