# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

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
