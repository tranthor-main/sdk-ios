# TranthorSDK for iOS

Send events from an iOS app to [Tranthor](https://tranthor.com): identify customers, track what they do, and (optionally) register the device for push notifications. Events are stored on disk, sent in batches and retried, so none are lost while the device is offline or the app is closed.

## Requirements

- iOS 15 or later (macOS 12 or later is supported for tests)
- Swift 6.0 or later, Xcode 16 or later
- A Tranthor workspace write key

## Installation

Add the package with Swift Package Manager:

```swift
.package(url: "https://github.com/tranthor-main/sdk-ios.git", from: "0.2.0")
```

or add the URL in Xcode under Package Dependencies. Then add the products you use to your target:

| Product | Use |
| --- | --- |
| `TranthorSDK` | Events: identify, track, page, screen. |
| `TranthorPush` | Registers the device for push and reports opens and dismissals. Needs `TranthorSDK`. |
| `TranthorPushService` | For a Notification Service Extension: remote images and the badge +1. |

## Quick start

```swift
import TranthorSDK

let sdk = try await TranthorSDK.configure(Configuration(writeKey: "<your write key>"))
try await sdk.identify(userId: "customer-123", traits: ["plan": "trial"])
try await sdk.track(event: "Opened", properties: ["source": "app"])
try await sdk.screen(name: "Settings")
```

Create one instance and keep it for the app's lifetime. Calls return once the event is saved to disk, not when it is sent. Await each call to keep events in order.

## Methods

| Method | What it does |
| --- | --- |
| `identify(userId:traits:)` | Signs a customer in and stores their traits. |
| `track(event:properties:)` | Records something the customer did. |
| `page(name:properties:)`, `screen(name:properties:)` | Records a viewed page or screen. |
| `flush()` | Sends queued events now and returns when they are delivered. Throws the failure that ended delivery. |
| `reset()` | Signs the customer out and starts a new anonymous ID. Queued events keep their identity. |
| `optOut()`, `optIn()` | Stops or resumes collection. See Consent. |
| `shutdown()` | Stops without sending. Queued events stay on disk for the next instance. |
| `anonymousId`, `userId`, `isOptedOut` | Current identity and consent. |

Each event method also takes optional `userId`, `anonymousId`, `messageId`, `timestamp` and `context` arguments. Property and trait values are `JSONValue`, which accepts Swift literals. Numbers are `Double`: send integers above 2^53 as strings.

## Identity

Until `identify` is called, events carry a stored anonymous ID. `identify(userId:)` sends both IDs, so Tranthor can attribute earlier anonymous events to the customer. Later events carry only the `userId`. If a different user identifies on the same device, the anonymous ID is replaced first, so the new user does not inherit the previous user's history. An empty `userId` is ignored.

## Consent

`optOut()` discards queued events, stops all collection and survives relaunches until `optIn()`. A push token that was registered is still removed from Tranthor so no push arrives. If the stored consent is unreadable, collection stays off until `optIn()`.

## Configuration

Only `writeKey` is required. A numeric option that is not usable never stops the SDK; what happens to it is in the table.

| Option | Default | Meaning |
| --- | --- | --- |
| `writeKey` | required | The workspace write key. |
| `host` | `https://api.tranthor.com` | API origin. An unusable value makes `configure` throw `TranthorError.invalidHost`. |
| `batchSize` | 5 | Events per request; reaching it sends at once. A whole number above 0; zero, negative, fractional (for example 2.5) or non-finite values use the default. |
| `flushIntervalMs` | 500 | Milliseconds from the first queued event until a partial batch is sent. A whole number above 0; anything else uses the default. |
| `retries` | 5 | Retries after the first failed attempt. Fractional values are rounded down, negative values become 0, non-finite values use the default. |
| `baseDelay` | 500 | Milliseconds before the first retry; each retry doubles it, up to 30 s. Negative values become 0, non-finite values use the default. |
| `automaticContext` | true | Adds library, OS, device, app, locale and time zone to every event. Your `context` keys win. |
| `storageNamespace` | `default` | Separates the stored state of instances in one app. |
| `storageDirectory` | Application Support | Where state is stored. |
| `maxQueueSize` | 10,000 | Events kept; beyond it the oldest are dropped. Zero or less uses the default. |
| `onError` | none | Called with a `BatchFailure` (events, HTTP status, attempts) when the server rejects a batch or events are dropped. Running out of retries is not reported: those events are kept. Push tokens are redacted. |

A second instance with the same namespace and directory throws `TranthorError.namespaceInUse`. If the disk cannot be read or written, `configure` throws `TranthorError.storeTemporarilyUnavailable`; try again later.

## Delivery

Events are sent as `POST /api/public/apps/batch`, one request at a time. A 2xx response is success. Network errors and the statuses 408, 425, 429 and 5xx are retried with doubling delays (or the server's `Retry-After`, honoured up to 30 seconds); any other status fails the batch at once. Redirects are refused. Each event gets a `messageId` and a UTC timestamp when it is queued, and keeps them across retries and relaunches.

A batch whose retries run out is not discarded. It stays at the head of the queue with its original `messageId`s and timestamps, and `onError` is not called; an explicit `flush()` still throws the failure. Automatic delivery then pauses for 30 seconds, and for twice as long after each further failed cycle (60 s, 120 s, 240 s, then 5 minutes at most). During the pause the interval timer, new events and a full batch do not start an attempt. `flush()` and the app returning from the background attempt at once, a delivered batch resets the pause to 30 seconds, and a restarted app starts without a pause: its first attempt comes at the normal flush interval. Events are discarded only when the server rejects the batch with another status, on `optOut()`, or when the queue is full (the oldest go first and are reported with `attempts` 0).

When the app goes to the background, queued events are sent in a background task, with one attempt per batch instead of waiting out a retry delay. State is stored with file protection `completeUntilFirstUserAuthentication` and excluded from backups.

## Push notifications

`TranthorPush` and `TranthorPushService` are optional. See [docs/push.md](docs/push.md).

## Current limits

- Events are kept while offline, up to `maxQueueSize`; beyond that the oldest are dropped.
- Events are stored unencrypted in the app's container, one small file per event.
- There is no compression, alias, group or subscription API, and no automatic screen tracking.
- If the app is killed after a request succeeds but before the result is saved, those events are sent again with the same `messageId`.
- The SDK collects a user ID, the push token (as a device ID) and product interaction. Add anything you put in traits and properties to your own privacy declarations. Privacy manifests are included.

## Example app and contributing

`Examples/TranthorExample` is a SwiftUI app that exercises every call. To build it or test the package, see [CONTRIBUTING.md](CONTRIBUTING.md). Report vulnerabilities as described in [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).
