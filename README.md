# TranthorSDK for iOS

Send events from an iOS app to [Tranthor](https://tranthor.com): identify customers, track what they do, and (optionally) register the device for push notifications. Events are stored on disk, sent in batches and retried, so none are lost while the device is offline or the app is closed.

## Requirements

- iOS 15 or later (macOS 12 or later is supported for tests)
- Swift 6.0 or later, Xcode 16 or later
- A Tranthor workspace write key

## Installation

Add the package with Swift Package Manager:

```swift
.package(url: "https://github.com/tranthor-main/sdk-ios.git", from: "0.2.1")
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
| `identify(userId:identityToken:traits:)` | Signs a customer in, stores their traits, and hands over their identity token (see Verified identity). |
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

## Verified identity

Tranthor can refuse events from an app that cannot prove who its customer is. The workspace owner chooses the mode: **Off** accepts everything, **Monitor** accepts everything and counts events without a valid token, **Required** rejects events for a user ID that has no valid token. A token is a JWT that *your own backend* signs for one user ID; the SDK never holds a secret and never verifies a token.

```swift
let sdk = try await TranthorSDK.configure(Configuration(
    writeKey: "<your write key>",
    identityTokenProvider: { userId in try await MyBackend.identityToken(for: userId) }))   // String?, nil for none

try await sdk.identify(userId: "u_42", identityToken: tokenFromSignIn)   // optional: the provider can supply it instead
```

- **Where the token goes.** `identify(userId:identityToken:)` keeps the token for that user. Tokens are sent in the request body beside the events (one per user in the request), never inside an event, and a token is only ever sent for its own user.
- **Renewal.** Before a request that holds the current user's events, a token with less than 60 seconds left (or none) is renewed through `identityTokenProvider`. The provider is given 20 seconds. Whatever it does, the request is then sent with the tokens the SDK has: the server decides. A provider that throws or returns `nil` never delays delivery; one that hangs delays a request by at most the timeout, once, and is then not called for 60 seconds. A token keeps being sent for a short time after it has expired, so a signed-out user's queued events still go out.
- **When the server refuses a token**, the SDK renews through the provider and sends the same batch again, once. A previous user's events (someone who signed out) are removed and reported once through `onError` (message `identity not verified`); the current user's events are never dropped. If no token can be had, or the new one is refused too, the batch stays on the device, in order, and is tried again after 60 seconds (or at once by `flush()`). Each such attempt calls `onNotice` with kind `identity-refused` and the server's `reason`. The reasons `lifetime`, `malformed`, `audience`, `workspace`, `unknown_key` and `signature` mean the code that signs your tokens is wrong; renewing cannot fix them (the list of reasons is open). A refused write key is a configuration error: that batch is dropped and reported as before. A push `Installation Removed` (sign-out or opt-out) is the exception: it is never dropped for lack of a token, because the phone would keep receiving push. The provider is asked for that user's token once; if that does not help, the removal stays queued, is reported through `onNotice` on each failed attempt (it carries no push token), not through `onError` because nothing was given up, and is tried again after 60 seconds and at the next launch, until it is delivered or the same user signs in again, which registers the phone anew.
- **When the server cannot read its identity settings**, the batch is kept and tried again after the delay the server asks for (30 seconds if it names none, at most 5 minutes), without using up retries. This holds for every app, whether or not it uses identity tokens, because it is a server outage and never a reason to drop events. `onNotice` gets `identity-unavailable`.
- **Other users are not stuck behind a held batch, within limits.** When a batch is held for the current user's token, the events of other users and anonymous events *in that batch* are sent first. Events queued *behind* the held batch wait for it, because the queue keeps its order: they are sent when the hold ends (after 60 seconds, or at once on `flush()`, on a new token for the user, or when a different user identifies), and while a batch is held the queue keeps at most 1,000 events: the oldest events that can go are dropped (ordinary events before a push registration or removal) and reported through `onError` with `attempts` 0.
- **Storage.** Tokens are saved in the state file, next to the queue, with the same file protection (`completeUntilFirstUserAuthentication`) and excluded from backups. They are not in the Keychain, so a reinstall never brings an old token back. A token is dropped once its user is no longer current and has nothing queued (opting out also ends the current user), or once the server would no longer accept it; this is checked at start too. `reset()` keeps the outgoing user's token until their queued events, such as the push `Installation Removed`, are sent. A token is never logged and never appears in an event, an error or a notice.
- **Anonymous events in Required.** In Required the server can drop events from a customer who is not signed in, without an error. The SDK calls `onNotice` with `events-dropped` and the count of events the server dropped (`events-unverified` in Monitor). **In Required, identify the customer, with a token, before you register push or send traits.** See [docs/push.md](docs/push.md).
- **App ID and `aud`.** Every request carries the app's ID: the bundle identifier, or `appId` from the configuration. A write key restricted to certain apps needs it. The `aud` claim of a token is optional; if your backend sets it, it must equal that app ID, otherwise the server answers with the reason `audience`.
- **No provider.** An app that never configures `identityTokenProvider` and never passes an `identityToken` to `identify` behaves as before: a refused batch is reported to `onError` and dropped. Once a token has been passed, identity stays in use for good (the SDK remembers it), even after a refusal has emptied the token cache.

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
| `identityTokenProvider` | none | `(String) async throws -> String?`: a fresh identity token for a user ID, or `nil`. See Verified identity. |
| `appId` | bundle identifier | Sent with every request. An empty value uses the default. An SDK created inside an app extension sends the extension's bundle identifier unless you set `appId` to the app's. |
| `onNotice` | none | Called with a `Notice` for what is not an error: events the server dropped or could not verify, a refused token, unreadable identity settings. Carries no token or user ID. |

A second instance with the same namespace and directory throws `TranthorError.namespaceInUse`. If the disk cannot be read or written, `configure` throws `TranthorError.storeTemporarilyUnavailable`; try again later.

## Delivery

Events are sent as `POST /api/public/apps/batch`, one request at a time. A 2xx response is success. Network errors and the statuses 408, 425, 429 and 5xx are retried with doubling delays (or the server's `Retry-After`, honoured up to 30 seconds); any other status fails the batch at once. The exceptions are the identity answers described under Verified identity: when identity tokens are in use, a refused token holds the current user's batch on the device (only a signed-out user's events are removed), and an app that does not use them keeps the ordinary failure; an answer that the server cannot read its identity settings holds the batch for every app. Redirects are refused. Each event gets a `messageId` and a UTC timestamp when it is queued, and keeps them across retries and relaunches.

A batch whose retries run out is not discarded. It stays at the head of the queue with its original `messageId`s and timestamps, and `onError` is not called; an explicit `flush()` still throws the failure. Automatic delivery then pauses for 30 seconds, and for twice as long after each further failed cycle (60 s, 120 s, 240 s, then 5 minutes at most). During the pause the interval timer, new events and a full batch do not start an attempt. `flush()` and the app returning from the background attempt at once, a delivered batch resets the pause to 30 seconds, and a restarted app starts without a pause: its first attempt comes at the normal flush interval. Events are discarded only when the server rejects the batch with another status, on `optOut()`, or when the queue is full (the oldest go first and are reported with `attempts` 0).

When the app goes to the background, queued events are sent in a background task, with one attempt per batch instead of waiting out a retry delay. State is stored with file protection `completeUntilFirstUserAuthentication` and excluded from backups.

## Push notifications

`TranthorPush` and `TranthorPushService` are optional. See [docs/push.md](docs/push.md). If your workspace requires verified identity, register push only after the customer has signed in and been identified.

## Current limits

- Events are kept while offline, up to `maxQueueSize`; beyond that the oldest are dropped.
- Events are stored unencrypted in the app's container, one small file per event.
- There is no compression, alias, group or subscription API, and no automatic screen tracking.
- If the app is killed after a request succeeds but before the result is saved, those events are sent again with the same `messageId`.
- The SDK collects a user ID, the push token (as a device ID) and product interaction. Add anything you put in traits and properties to your own privacy declarations. Privacy manifests are included.

## Example app and contributing

`Examples/TranthorExample` is a SwiftUI app that exercises every call. To build it or test the package, see [CONTRIBUTING.md](CONTRIBUTING.md). Report vulnerabilities as described in [SECURITY.md](SECURITY.md).

## License

Use of the SDK is covered by the [Tranthor SDK License](LICENSE): you may include it in your apps to connect them to Tranthor, and may not redistribute it on its own or use it with other services.
