# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

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
