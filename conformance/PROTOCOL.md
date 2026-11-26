# Tranthor SDK conformance protocol, version 1

This is the language-neutral contract for the thin native SDKs. `VERSION`
versions the suite. In this repository the scenarios, `scenario.schema.json` and
`VERSION` live in `Tests/ConformanceTests/Fixtures`, and the mock server in
`conformance/server`. MUST denotes a required behavior for
an adapter declaring the relevant capability. The JSON scenarios are executable
examples of this contract, not a server implementation or proof of production
ingestion. No fake clock, Node bridge in a mobile SDK, or shared runtime is required.

## Ingestion and queue behavior

The transport MUST POST to `{host}/api/public/apps/batch`, with
`Content-Type: application/json` (media type compared case-insensitively,
parameters such as charset ignored) and the configured `writeKey` **verbatim** as the
`Authorization` header. `writeKey` is a complete header value, normally
`Basic <base64(secretKeyId:secretKeyValue)>`; do not base64 it again or prepend
another scheme. The current server decodes the second space-separated token,
requires a UUID key id, and ignores the scheme word. Its schema description says
Bearer while its example and key validator describe Basic. The mock uses a
non-secret fixture and does not authenticate it.

The body is `{ "batch": [items], "context"?: {...} }`. The core emits only
`batch`; wrappers may supply context. Each item has `type` equal to `identify`,
`track`, `page`, or `screen`, a nonempty `messageId`, a `timestamp`, and `userId`
or `anonymousId`. Identify preserves `traits`; track requires `event` and can
carry `properties`, `files`, and `context`; page/screen can carry `name`,
`properties`, and `context`. Caller parameters are preserved. Every scenario call
supplies an identity. Outside the optional `identity-link` capability (see
[Identity linking](#identity-linking-identity-link)) the suite does not specify
identity generation or stitching.

Assign a fresh messageId and an ISO 8601 UTC timestamp in exactly
`YYYY-MM-DDTHH:mm:ss.SSSZ` format when the SDK method is called. Stamping may
happen asynchronously within the call-time band specified below. Honor caller-
provided messageId and timestamp. The public event API of every SDK MUST accept
optional messageId, timestamp and context overrides on identify, track and
page; track MUST also accept files. The adapter passes them through the public
API. The core scenario `caller-overrides` checks these overrides. A retry
MUST keep the same messageId and timestamp (and event order and payload); do not
restamp on send. The server requires messageId but permits a missing timestamp;
call-time stamping is an SDK requirement. Server idempotency is incomplete:
stable messageIds do not guarantee duplicate-free storage.

Defaults: batch size 5, flush interval 500 ms from the **first** queued event,
5 retries after the first attempt, base retry delay 500 ms. Hitting the batch
size MUST start delivery of the full batch. Whether a trailing partial batch is
sent in the same cycle or left for the next trigger is implementation-defined;
no scenario may depend on that choice. Informatively, the JS core drains every
queued batch in the same cycle. A partial queue is delivered by the interval or
explicit flush. Each request contains at most the configured batch size. There
MUST be at most one ingestion request in flight; batches MUST be sent in queue
order. An explicit flush settles after the in-flight cycle
and every queued batch have been attempted, or at the first batch that exhausts
its retries (remaining batches stay queued); it reports failure if any batch
failed terminally after the call began, including a failure of a cycle already
in flight when it was called. Automatic flushes report failures through the error callback without an uncaught completion error;
explicit flush reports failure in the platform idiom (error return, thrown error,
or failed callback). This is what `rejected` means. Empty flush succeeds without
a request. Scenarios may flush during an in-flight cycle, including retry backoff.

Retry network failures without a usable HTTP status, 408, 425, 429, and 500–599.
Other statuses are terminal, including 400, 401, and 403. Two identity-token answers are held instead: `403 identity_not_verified`, only when identity is in use, and the identity 503s; the write-key 403s stay terminal (see [Identity tokens](#identity-tokens-identity-token)). The reference transport
treats any 2xx as success. A 3xx MUST be a non-retryable HTTP failure and
MUST NOT be followed. For URLSession, use a default or ephemeral session with the
redirect delegate `urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`
and call `completionHandler(nil)`. Background URLSession configurations always
follow redirects and cannot satisfy this requirement; see the
[Apple redirect documentation](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession%28_%3Atask%3Awillperformhttpredirection%3Anewrequest%3Acompletionhandler%3A%29).
For OkHttp use `followRedirects(false).followSslRedirects(false)`.
Retry-After MUST be honoured on ANY retryable response that carries it (429,
503, etc.). It raises the delay to max(backoff, Retry-After), capped at 30 s; it
MUST never replace the backoff or be added to it. After the first attempt,
retry delay number `n` (zero based) is
`min(30000, max(baseDelay * 2^n, retryAfterMs))` milliseconds. With defaults this
is 500, 1000, 2000, 4000, 8000 ms. A transport MUST parse Retry-After as
[RFC 9110 delay-seconds](https://www.rfc-editor.org/rfc/rfc9110.html#section-10.2.3) only (`1*DIGIT`, ASCII `[0-9]+`), multiplied by 1000.
HTTP-date values are out of scope; signs, fractions, exponents, hex and whitespace
are invalid and ignored by the executor. The mock server and scenario validator
reject scripts containing them. The 30 s Retry-After cap is **verified from
source, not exercised by a scenario**: a real-time boundary check would take
over 30 seconds, too slow for this suite.
Backoff begins after an attempt fails, not when its request arrives at the server.

On terminal failure, remove the failed batch and invoke the error callback once
with its events and `attempts` equal to the number of requests made for that
batch. A non-retryable status stops retrying immediately: a 500 then a 400 gives
`attempts = 2`. It MUST NOT prevent batches queued behind it from being sent.
A non-retryable rejection is reported by explicit flush after the remaining
batches have been attempted. An exhausted retryable batch stops that explicit
flush cycle; subsequent queued batches remain for the next interval, whose timer MUST be re-armed. Without the
`durable-queue` capability the exhausted failed batch itself is discarded; retention of later queued batches is
exercised by `interval-after-retries-exhausted`. Long-backoff retention after exhaustion
(including the 30 s Retry-After cap) is **verified from source, not exercised by a scenario**:
waiting through that boundary is too slow.

### Durable queue (suite 1.2.0)

An adapter declaring `durable-queue` never discards a batch because its retries were exhausted:

- The exhausted batch stays at the head of the queue with its original stamps. No batch queued behind it is
  sent before it. The error callback is NOT invoked for it; an explicit flush still reports the failure.
- After an exhausted cycle the SDK pauses automatic delivery. The first pause is 30 s and each further
  consecutive exhausted cycle doubles it, up to 5 minutes. During the pause the interval timer, a newly queued
  event and a full batch MUST NOT start an attempt. A delivered batch resets the pause.
- An explicit flush starts an attempt cycle at once, pause or not. So does a return from the background to
  the foreground for adapters that also declare `lifecycle`. The pause is not persisted, so a restarted SDK starts without one.
- Events are discarded only by a non-retryable response, by opt-out, or when the queue is full (oldest first,
  reported through the error callback with `attempts` 0).

The pause lengths are **verified by the implementation's own tests with a controlled clock, not by a scenario**. The
scenarios cover retention, ordering, the absence of the error callback, and that no attempt starts during the
pause. Scenarios that describe the discard rule carry `"unless": ["durable-queue"]`. Callback exceptions do not change delivery.
The core also rejects unserializable input before queueing with attempts 0;
that behavior is outside the JSON-only scenarios.

For JavaScript configuration, positive integers are required for batchSize and
flushIntervalMs, with invalid values falling back to defaults. Finite retries
are floored and clamped to zero; finite baseDelay is clamped to zero. Missing or
nonfinite values use defaults. Native SDKs MUST validate configuration with the
same fallbacks, or document any differences in their README. This configuration
note is not scenario-tested; scenario configuration supplies valid values.

## Scenario format

All files in `scenarios/*.json` MUST validate against `scenario.schema.json`
(JSON Schema draft 7). IDs MUST be globally unique. Validate **all** files before
filtering by capabilities. Unknown fields are rejected, except JSON payload
maps and expected partial payload fields. Each file contains:

| Field | Meaning |
| --- | --- |
| `id`, `description` | Stable machine id and human explanation. |
| `capabilities` | All capabilities required to execute the scenario. |
| `unless` | Optional. Capabilities that replace this scenario: an adapter declaring any of them reports `skip` with the reason `superseded by <capability>`. |
| `config` | SDK settings: required writeKey; optional batchSize, flushIntervalMs, baseDelay, retries, hostSuffix. Omitted settings use SDK defaults. hostSuffix is a trailing-slash test input appended to host. |
| `server.responses` | Scripted responses, consumed once per ingestion request in arrival order. After exhaustion, return 204. |
| `steps` | Sequential operations described below. The last step in the shipped scenarios is an assertion. |

Response entries may have `location` (literal Location header for redirect tests).
They have `status` (integer 200–599), optional `delayMs` (0–30000),
optional `retryAfter` (delay-seconds header string matching `[0-9]+`), or `drop: true` to destroy the
socket after the body is read. Drop takes precedence over status. Delay applies
before responding or dropping. A response requires a status unless drop is true.
All scripted header values MUST match `^[\x20-\x7e]*$`.

| Step | Adapter/runner action |
| --- | --- |
| `emit` | Call the named SDK `method` with `data`; an optional `identityToken` `{ref, sub, ttlSeconds, valid?}` is minted first (see [Identity tokens in scenarios](#identity-tokens-in-scenarios)) and handed to `identify` beside `data`; record local wall-clock before/after invoking the method using the unique `call` label. Do not await transport here. |
| `wait` | Wait `ms` using real timers. |
| `flush` | Await SDK flush; capture its failure without terminating the scenario. If `rejected` is present, assert the result matches. A flush that does not settle within 5 seconds FAILS the scenario, even if rejected is omitted. |
| `assert` | Poll requests/callbacks for up to timeoutMs (default 3000), then observe for observeMs (default 100), take a fresh snapshot and verify expect. Never flush just to make an assertion pass. |
| `restart` | Stop the old SDK, cancel its timers/transport, destroy in-memory state, recreate against the same persistent store and config. Await durable writes before shutdown; preserve queued and unacknowledged retry events. Do not re-emit calls or reset the server. |
| `background` | Deliver the declared SDK background/lifecycle source and await scheduling needed for automatic flush. Do not substitute a runner flush when an OS hook exists; the public-method exception is defined below. |
| `optOut` | Call the real SDK opt-out API, await completion, stop collection and clear pending events. Cancel in-flight retries and discard their events permanently; discarded events MUST NOT invoke the error callback. Flush while opted out MUST resolve without a request. Later calls are no-ops until optIn. Consent MUST persist across restart. |
| `optIn` | Call the real SDK opt-in API and await completion; resume collection. The `consent` capability covers both operations. |
| `anonymousId` | Read the SDK's stored anonymousId through its public API (after every preceding call has taken effect) and bind it to `ref`; see [Identity linking](#identity-linking-identity-link). Requires `identity-link`. |

`restart` MUST construct a new SDK instance on the same durable storage location
(same app container, database file or namespace), after stopping the old instance
and dropping all its in-memory state. Each scenario begins with empty durable
storage; only restarts within that scenario reuse it. Await pending durable writes
before shutdown. Restored events MAY be sent at start-up, at the next interval
tick, or at an explicit flush; they MUST still be sent exactly once with their
original messageId and timestamp and MUST NOT be lost. Exactly once here means
one restored queue entry per original event, subject to the retry policy above,
not a guarantee of server idempotency. A restored failed batch keeps those stamps;
its attempt counter starts again, and callback `attempts` counts only requests
made by the new instance. Restart scenarios use restartBetween to identify the
new instance as sender, without requiring a particular restore timer policy or
a rejection from a flush made after a restored batch has already completed.
The adapter's callback observations remain cumulative for the scenario. Restart does not simulate process death.

`background` MUST trigger the SDK's real lifecycle hook. Native adapters MUST
deliver the real OS lifecycle notification or callback the SDK observes. A public
background/flush method is allowed ONLY where the platform exposes no observable
hook; the adapter MUST declare lifecycleSource: "public-method" and document
that platform limitation in its declaration documentation. Otherwise it MUST
declare lifecycleSource: "os-hook". Queued events MUST reach the server within 2000 ms of that trigger. The flush MUST NOT wait for a
retry backoff longer than the platform background time limit; the scenario never
backgrounds during backoff. A timer alone cannot satisfy the background scenario.

Optional `label` on restart/background/optOut/optIn records operation start/end
on the adapter clock. Labels and emit call names share a unique namespace.

`expect.requests` is the exact list of recorded requests, in order; each `batch`
is an exact ordered list of `{ "call": "a", "fields"?: {...} }` references.
The item MUST contain the original call data and corresponding type: each key of
the original data MUST appear with a deeply equal value; extra item keys are
allowed. `fields` are additional recursive subset checks. Unexpected optional
SDK metadata is permitted; an identity field absent from the input MUST stay absent in these
fixtures, except for the `identity-link` identify rule below. An item may carry
`anonymousIdRef` (identity-link scenarios only) to compare its anonymousId with a
named stored value. Arrays and scalar fields are compared exactly. Optional `method`,
`path`, lower-case `headers`, and body `context` expectations are checked too.

For every referenced item, check a nonempty string messageId. Generated IDs
must differ between distinct calls. Generated timestamps MUST be parseable UTC
strings in exactly `YYYY-MM-DDTHH:mm:ss.SSSZ` format (three fractional digits and
trailing Z), between beforeMs − 50 and afterMs + 50 on the adapter's own clock.
This permits asynchronous stamping within that inclusive band. Caller timestamps
are compared verbatim. Repeated call references, across requests and assertion
checkpoints, MUST have identical messageId and timestamp. This also checks
retention after restart without prescribing an ID generator.

`expect.errors` is the exact ordered callback list. Each entry has `attempts`,
`eventCalls` in order, and optionally `status` (HTTP code or null for network).
Compare callback events to wire items by **messageId and type only**, in order;
platform callback objects need not reproduce wire encoding. `status` MUST be null
for non-HTTP errors, including timeout, TLS failure and dropped connections. Adapters map platform-specific error types to these fields.

Optional `expect.delays` entries have `from` (zero-based request index or call
or operation label), `to` (request index), `minMs`, `maxMs`. A request time is `receivedAtMs`;
a call/operation time is its beforeMs converted to the server clock. The delta MUST be within the inclusive band. Upper
bounds include room for slow CI; lower bounds permit only small scheduling and
clock-resolution error. The 500 retry scenario uses 300/600/1200 ms and non-overlapping
request-to-request bands 285–560, 585–900 and 1185–1600 ms, so a constant-delay
retry cannot pass even when an adapter declares only `core`. The Retry-After case
uses a standard one-second header. The interval case omits flushIntervalMs to
check the default 500 ms, submits its second event after 350 ms, and permits
480–750 ms from the first call, distinguishing a timer reset on each event.
Before EACH scenario, the adapter MUST estimate a server-minus-adapter clock
offset using three `GET /control/time` samples: record local before/after times,
subtract their midpoint from `nowMs`, and use the median of the three differences.
Add that offset to call/operation times and round down to integer milliseconds
for request timing bands. Timestamp checks
use adapter-local time without conversion. An adapter may alternatively assert
only request-to-request deltas; it MUST NOT silently skip call-based expectations
in shipped scenarios (supply an equivalent timing check). JS declares `nowMs()`
as its local clock. `expect.restartBetween` entries `{label, from?, to?}` require
at least one request index. When `from` is present, the labeled restart MUST
begin at or after that request; when `to` is present, it MUST finish at or before
that request. If both are present, `from < to`. Boundaries are inclusive on the
calibrated server clock at millisecond resolution (request from <= restart
start and restart end <= request to). A `{label, to: 0}` expectation proves that
queued, never-attempted events first reach the server after restart completes;
flushing them during shutdown cannot satisfy it. The queued-restart scenario
delays the first response by 80 ms so a shutdown flush that awaits delivery
cannot hide inside the inclusive millisecond boundary.
Network time is included in request-to-request deltas; scripted delays must be
accounted for when adding timing scenarios. The full reference run takes seconds,
well below 60 seconds on normal CI. No fake clock is required.

Labels must be unique, payload and error references must name a preceding emit,
and timing sources may also name a preceding labeled operation. Timing indices must reference existing requests with minMs <= maxMs. An assert first
polls until request and error counts are at least expected; polling does not
excuse extra records. Exact counts are checked after the observation window.
Scenarios are isolated and sequential: dispose the adapter before resetting
the server; use a fresh durable store per scenario but retain it across restart.

Runner expectation semantics:

| Expectation | Normative comparison/result |
| --- | --- |
| `headers` | Names MUST be lower-case. Compare content-type by case-insensitive media type, ignoring parameters; every other expected header is compared exactly. Extra headers are allowed. |
| Original call data | Every original key is present in the item with a deeply equal value (including nested objects and arrays); extra item keys are allowed. |
| `fields`, body `context` | Recursive object subset checks; arrays and scalars compare exactly. |
| Absent identity | Absent from the input means absent from the item, except that an adapter declaring `identity-link` MUST send, on an identify with a `userId` and no `anonymousId`, an `anonymousId` equal to the stored anonymousId read right after that call. |
| `anonymousIdRef`, `anonymousId` step | The first use of a ref binds a nonempty string; later uses MUST be equal; two refs MUST NOT hold the same value. |
| `restartBetween` | Inclusive boundaries on the calibrated server clock at integer millisecond resolution. |
| Flush timeout | Failure to settle within 5 seconds FAILS the scenario, regardless of whether `rejected` is specified. |
| Summary counts | `validated`, `passed`, `failed`, `skipped`, `xfailed` are numbers. |
| Summary `knownFailures` | List of scenario IDs (strings), not declaration objects. |
| Summary `lifecycleSource` | `"os-hook"` or `"public-method"` when declared; null when absent. |

### Identity tokens in scenarios

Scenarios use these additions, all requiring `identity-token` (except `config.appId`, which requires `app-id`).
A JWT in a JSON file would expire, so tokens are minted by the mock server at run time and named by `ref`.

- `server.identity.mode`: `"required"` or `"monitor"`; absent means off. See the mock server section.
- `config.identity.provider`: the scripted provider. Its presence means the adapter configures an
  `identityTokenProvider`; it answers one entry per call, in order, and `null` once the entries are spent. An
  entry is `{ "result": "token", "ref", "sub", "ttlSeconds", "valid"? }` (mint now and return it),
  `{ "result": "null" }`, `{ "result": "error" }` (throw) or `{ "result": "hang" }` (never answer); `delayMs`
  waits first. `config.identity.providerTimeoutMs` and `providerBackoffMs` scale the two timings (a hold lasts the backoff).
- `emit.identityToken`: `{ ref, sub, ttlSeconds, valid? }`. `ttlSeconds` is relative to now: 3600 is fresh, 30
  is inside the 60 s renewal window. `valid: false` signs with a secret the mock does not know.
- `expect.requests[].identityTokens`: the exact list of tokens (by `ref`) in the body field; an absent field and an
  empty list both mean none.
- `expect.providerCalls`: the exact ordered list of user ids the provider was called with.
- `expect.notices`: the exact ordered list of diagnostic notices (`{ kind, count?, reason? }`, each listed field
  compared). Notices are not errors: they are not in `expect.errors`. An adapter maps its callback's notice type
  to `{ kind, count, reason }`. Kinds: `events-dropped`, `events-unverified`, `identity-refused`, `identity-unavailable`.
- `config.appId` and `expect.requests[].headers` check `x-tranthor-app-id`.

The transport reports the two response headers to the core on a 2xx. The runner also checks, on every scenario, that no minted token appears inside any event or error report and that no
item carries an `identityToken` key. Refs are unique within a scenario. Adapters pass the scripted provider and the
minted token to the SDK through their own public API (the JS adapter's `createAdapter` receives
`identityTokenProvider`, and `emit(method, data, { identityToken })`).

## Adapter contract and capabilities

An adapter is an **in-process test** (XCTest, an instrumented Android or JVM
unit test, or a Node test) reading the scenario files and driving the real SDK.
It MUST talk to the mock server ONLY through its HTTP control API. CI starts
the mock server using
`node conformance/server/cli.cjs --port <fixed>` and supplies its URL externally.
The adapter and scenario runner import no server internals; harness unit tests
may import them to test the server and assertion logic. The adapter MUST
configure the real SDK, use its real queue and HTTP transport,
collect callback results, execute the steps, and apply the expectations above.
Do not recreate queue/retry logic in an adapter or fabricate recorded requests.
The reference JS interface is `createAdapter({host, config})` returning
`emit(method, data)`, `flush() -> {rejected}`, an `errors` array, and `dispose()`; an adapter that declares
`identity-token` also exposes a `notices` array;
mobile adapters additionally implement the named mobile steps. An adapter that
declares `identity-link` also implements `anonymousId()`, returning the SDK's
stored anonymousId through its public API. `dispose` cancels
timers and transport and removes per-scenario storage after the final assertion.

Declare a nonempty string `name`, `capabilities` using only the names below,
`suiteVersion` matching the pinned suite VERSION,
and `knownFailures` before running. The optional `lifecycleSource` field is
`"os-hook"` or `"public-method"`; adapters declaring `lifecycle` MUST supply it.
The runner MUST report it in the summary. `knownFailures` is a versioned
per-adapter list of `{id, reason, tracking}` entries (scenario ID, nonempty reason, issue/reference).
Unknown or duplicate IDs, unknown capability names, missing/empty names, and
knownFailures for scenarios that the declared capabilities would skip MUST
fail suite loading.
An executed listed scenario that fails is reported `xfail`; if it passes it MUST
be reported `fail` (unexpected pass), making CI fail until the entry is removed.
Missing capabilities still report skip. This is the adoption path for existing
SDKs (including web and Node) that do not yet conform: declare real capabilities
and track known failures without changing observations to make them pass. The JS
reference reads `suiteVersion` directly from `Tests/ConformanceTests/Fixtures/VERSION` and declares
`knownFailures: []`. That file is the single source of truth for suite versions.
Run a scenario only if **all**
its required capabilities are declared; otherwise report skip and list missing
capabilities. A scenario whose `unless` names a declared capability is also reported skip; that field is fixed
by the suite, never by the adapter. Apart from that, a declared capability cannot turn a failed scenario into a
skip. A known failure for a scenario that `unless` skips MUST fail suite loading.
CI must fail on schema errors or any failure. Emit one JSON line per scenario
with `{id, result: "pass"|"fail"|"skip"|"xfail", reason?}` and a final summary containing
`adapter`, `capabilities`, `suiteVersion`, `knownFailures`, `validated`,
`passed`, `failed`, `skipped`, `xfailed`, `lifecycleSource`; exit nonzero
when failed > 0 or the suite cannot load. CI owners should require their intended
capabilities so mobile checks cannot silently disappear through misdeclaration.

| Capability | Requirement |
| --- | --- |
| `core` | Call payloads, identity/stamps, batching, real timers, flush, retry policy and failure callbacks. |
| `transport` | Real wire path/headers, base-URL normalization and Retry-After parsing. |
| `persistence` | Queued events and an unacknowledged retry batch survive restart with the same stamps. |
| `lifecycle` | Background signal automatically flushes queued events. |
| `consent` | Persistent optOut, queue/retry cancellation, and optIn collection recovery. |
| `identity-link` | Stored identity: identify(userId) carries the stored anonymousId, and a user change rotates it first (suite 1.1.0). |
| `durable-queue` | An exhausted retryable batch is kept and retried later instead of discarded (suite 1.2.0). |
| `identity-token` | Identity tokens: the provider, the per-user token cache, tokens sent with each batch, and the 403/503 rules (suite 1.3.0). |
| `app-id` | The configured `appId` is sent as `x-tranthor-app-id` on every ingestion request (suite 1.3.0). |

Storage medium is an implementation choice; retention and retry recovery follow
the normative restart rules above. Process-death testing remains out of scope.

## Identity linking (`identity-link`)

Added in suite 1.1.0 for server-side identity stitching. An
SDK that stores identity declares `identity-link`. An adapter declaring it MUST
satisfy all of the following:

1. The SDK stores an anonymousId and the userId of the last identify.
2. `identify` with a nonempty `userId` and no caller `anonymousId` sends the
   stored anonymousId in that event. This links the visitor's earlier anonymous
   events to the user.
3. If a nonempty userId is already stored and the new `userId` differs from it,
   the SDK MUST first replace the stored anonymousId with a fresh one. The event
   then carries the new value. A second user on the same device therefore never
   inherits the first user's anonymous history. The first identify after
   anonymous use (no stored userId), and an identify that repeats the stored
   userId, keep the stored anonymousId.
4. A caller-supplied `anonymousId` is sent verbatim and wins for that event.
   It is not stored. A user change still rotates the stored anonymousId as in rule 3.
5. The new userId and a rotated anonymousId are persisted together, and both
   survive `restart`. Reset/logout APIs are outside this suite.
6. An empty or absent `userId` is not a user. It is not stored, links nothing
   and never rotates. (Scenario data cannot express `""`; SDK unit tests cover it.)

Rule 2 replaces the absence rule only for `anonymousId` on identify items whose
input has a non-empty `userId` and no `anonymousId`. Every other item keeps the
absence rule. This includes track, page and screen, and identify calls without a
`userId`. Every scenario call supplies a caller identity. This suite therefore
does not specify whether a wrapper adds the stored anonymousId to events
**without** caller identity (for example an implicit track after identify). The runner checks rule 2 on every scenario, including the 1.0
`known-identify`, `caller-overrides` and `timestamp-call-time`. After each emit it
reads `anonymousId()`; the item's anonymousId MUST equal that value. The scenarios
`identify-links-anonymous-id`, `identify-rotates-on-user-change` (with
`persistence`) and `explicit-anonymous-id-wins` use `anonymousId` steps and
`anonymousIdRef` to check rules 2–5 across calls and restart.

Loading MUST reject an `anonymousId` step or an `anonymousIdRef` in a scenario
that does not require `identity-link`. It MUST also reject an `anonymousIdRef` on
a call whose input supplies an `anonymousId`, because the original-data check
already covers that value.

## Identity tokens (`identity-token`)

Added in suite 1.3.0 and corrected in 1.4.0. An **identity token** is an HS256 JWT that the
customer's own backend signs for one user id (`sub`). It proves to Tranthor that an SDK event really comes from
that user. The server checks it; the SDK holds no secret and MUST NOT verify a token. It reads `exp` only to
schedule a renewal and to stop attaching a token the server would refuse anyway, never to trust it. A token is
never logged, never stored inside an event, never put in an error report or notice, and never attached for a user
id other than its own.

### Configuration and API

- `identityTokenProvider`: an optional function `userId -> token or nothing`, asynchronous where the platform
  allows. Returning nothing (null) means "no token for this user".
- `identify` accepts an optional `identityToken` for its `userId`. The SDK stores it in the token cache and sends it
  beside the events, never inside the identify event. In the scenarios it is passed by the adapter, not in `data`.
- `appId` (capability `app-id`): sent by the **transport** as the header `x-tranthor-app-id` on every request. A
  core that only passes it through (the JavaScript core) does not send it. Mobile SDKs default it to the bundle id
  or package name; web SDKs do not send it (browsers are matched by `Origin`).
- Test knobs: `identityProviderTimeoutMs` (default 20000) and `identityProviderBackoffMs` (default 60000). An
  adapter MUST expose them so scenarios run in real time with scaled values. The defaults are **verified by the
  implementation's own tests with a controlled clock, not by a scenario**, like the durable-queue pause lengths.
  There is no separate hold setting: a hold for a missing token lasts the provider backoff.

### Token cache

A map `userId -> { token, exp }` held in memory. `exp` is read by decoding the JWT payload without verifying it;
a token whose `exp` cannot be read is kept and attached until the server refuses it. An entry is kept while its
user is the **current user** or still has events queued or in flight, and is removed after that. The current user
is the user of the last `identify`; before any identify, the first user seen on an event. A logout API ends the
current user, and the outgoing user's token stays until their queued events have been sent. Web SDKs keep the cache
in memory only; native SDKs persist it only with the same protection as their queue, never in a shared keychain
that survives reinstall.

### Sending a batch

1. For each distinct `userId` in the batch, attach that user's cached token until `exp` + 120 s: the server accepts
   a token that long after `exp`, so a signed-out user's queued events are not dropped needlessly. Tokens go in the
   body as `identityTokens: [..]`, one per user, in the order the users first appear in the batch. The field is
   omitted when there is no token.
2. If the current user is in the batch and has no token with at least 60 s left (a token renews ahead of time),
   call the provider and wait at most 20 s. Whatever happens, then send the batch with the tokens it has: the
   server decides.
3. **A broken provider never delays delivery** means exactly this: a provider that throws or returns nothing never
   delays a send; a provider that hangs delays a send by at most the 20 s timeout, once, and is then not called
   again for 60 s. **Provider failure** (an error, a timeout or no token) starts that 60 s backoff.
4. **At most 10 users per request, when identity is in use.** The server considers at most 10 tokens per request.
   When identity is in use (a provider is configured, or an identity token has ever been passed to `identify` in this install; in memory only for the web), a batch takes the longest prefix of the queue that holds
   at most 10 distinct `userId` values (and at most the batch size); the next batch takes the following events, in
   queue order. An SDK that never uses identity tokens keeps its batching exactly as before. An SDK that persists state
   remembers "identity in use" across restarts with that state; on the web it is remembered only in memory.

### What the server does with anonymous events, and what the SDK must surface

In `required` mode the server answers 204 to a request, but it **silently drops** the anonymous events (no `userId`)
that could change a customer: an anonymous `identify` (traits), `Installation Registered`, `Installation Removed`,
`TRSubscriptionChange`, `DFSubscriptionChange`, and the push claims `Push Received`, `Push Opened` and
`Push Dismissed`. Other anonymous events (`track`, `page`, `screen`) are stored. There is no error, so an app that
registers its installation or push token before sign-in loses that event unnoticed. The server counts the dropped
events in the response header `x-tranthor-dropped-events`. That count is not only these anonymous drops: the server
also adds events it dropped for being oversized (over 64 KB), **in every mode**. The notice wording MUST therefore be
neutral: "The server dropped N events" (optionally: "in Required mode this includes anonymous events that could
change a customer"), never "N anonymous events"; in `monitor` mode it sets `x-tranthor-unverified-events`
for events that would fail.

The SDK MUST read both headers on a 2xx response (the transport hands the counts to the core) and, when a count is
not zero, report one **notice** per response through its error or diagnostic callback, with no token and no user
id in the message. A notice has no events and has a `kind`: `events-dropped` or `events-unverified`, with the
`count`. The docs of every SDK MUST say: in Required, register push (and send the identify that carries traits) after sign-in.

### Token limits

The server refuses a token longer than 2,048 bytes and one whose lifetime (`exp` minus `iat`) is more than 7 days
(reasons `malformed` and `lifetime`). A token the backend signs must stay inside both limits; the mock enforces
the same two limits. The server also drops any single event whose serialized size is larger than 64 KB (the limit is per event, not for the batch), in every mode, and counts it in
`x-tranthor-dropped-events`; the mock does the same.

### Token audience

`aud` is optional in a token. The server refuses a token whose `aud` is present and not equal to the app id the
request sends in `x-tranthor-app-id` (for a browser, the `Origin`), with `reason: audience`. Every SDK's docs MUST
tell the developer: if your backend sets `aud`, it must equal the app id (bundle id, package name, or the `appId`
you configured); otherwise the server answers `reason: audience`. The SDK cannot fix this (see the unfixable reasons).

### Server answers

| Answer | Rule |
| --- | --- |
| `403` with `code: "identity_not_verified"` (body `{ message, code, reason?, userIds? }`) | Key off `code` and `userIds` only. `reason` is for the developer: today `missing`, `malformed`, `unknown_key`, `signature`, `expired`, `not_yet_valid`, `lifetime`, `audience` or `workspace`. Treat the list as open. See the rules below. |
| `403` with `code` `write_key_origin_not_allowed` or `write_key_app_not_allowed`, or no code | Terminal, as before: the batch is dropped and reported. It is a configuration error. |
| `503` with `code` `identity_settings_unavailable` or `identity_secrets_unavailable` (and `Retry-After: 30`) | Never a drop and not counted against the retry budget: **hold** the batch for `Retry-After` (30 s when absent, at least 1 s, at most 5 minutes; a longer value is capped, not clamped to 30 s) and report an `identity-unavailable` notice. |

**Identity in use.** Identity is in use when a token provider is configured OR an identity token has ever been
supplied through `identify` in this install: remembered durably where the SDK persists state, in memory only for the
web. It does NOT depend on the token cache being non-empty at that moment, because a refusal deletes the cached
token. The rules below apply to a `403 identity_not_verified` only when identity is in use. When it has **never**
been in use, the old rule holds: the 403 is terminal, reported through the error callback and the batch dropped.
A `503 identity_settings_unavailable` / `identity_secrets_unavailable` is held for every app, in use or not: it is a
server outage and never a reason to drop.

**On `403 identity_not_verified` (identity in use):**

1. Remove the cache entries for the listed `userIds` (all users in the batch when none are listed).
2. Remove the items of every listed user who is **not** the current user, report them through the error callback
   once (status 403, message `identity not verified`, `attempts` the number of requests that carried them) and send
   the rest.
3. If the current user is listed, renew through the provider (unless it is in its 60 s backoff) and send again,
   **once**. A refusal that renewing cannot fix MUST NOT loop: if the token just obtained from the provider for a
   user in this send (before the send or after the first refusal) is refused again, stop renewing for this send,
   report an `identity-refused` notice with the server's `reason`, then hold. The reasons `lifetime`, `malformed`,
   `audience`, `workspace`, `unknown_key` and `signature` cannot be fixed by the SDK; the notice message says so
   (the developer's signing code is wrong, not the SDK).
4. If no token can be had, **hold** the batch and report an `identity-refused` notice (with the server's `reason`).
   The items of the held batch that belong to other users (and anonymous items) are sent separately first, in one
   request, so one user's missing token does not keep their events back. Events queued behind the held batch still
   wait for it; that limit is deliberate.
5. A `403 identity_not_verified` for a batch with no `userId` to act on (anonymous events only: nothing to renew,
   drop or hold) MUST NOT be sent again in a tight loop. Treat it as a failed send: report an `identity-refused`
   notice and apply the queue's normal retry backoff and budget.

**An `Installation Removed` for a signed-in or just signed-out user is never dropped for lack of a valid token.** In
Required the server refuses an unverified removal with a 403, and dropping it would leave the phone registered and
receiving push after the person opted out. If it is refused and one renewal does not fix it, keep it parked, retry it
on the same hold timer as other holds (60 s) and on the next launch, and report each failed attempt as a **notice**
(the push token redacted), never through the error callback: nothing was dropped, and the error callback is for data
the SDK gave up on. It stays until it is delivered or until the app signs the same user in again (the registration
then supersedes it). The previous-user rule does not apply to it: a removal is not removed from a batch as "a
previous user's item". The SDKs never create an anonymous removal. If an anonymous sensitive event is nevertheless
sent, the server drops it silently with a 204 in Required; the SDK learns that only from the
`x-tranthor-dropped-events` count and cannot retry what it cannot identify, so there is no guarantee for it. The
JavaScript core sends no removals and has no special code for them; the scenario
`identity-token-removal-refused-twice-stays-queued` shows the hold behaviour a removal relies on.

**Hold.** The batch stays at the head of the queue with its original events, order and stamps. Automatic delivery
pauses: the interval timer, a new event and a full batch do not start an attempt. A hold for a missing token
retries after the provider backoff (60 s), and each failed attempt reports a notice. An explicit flush ends the
pause, tries again at once, and reports failure. The queue is bounded while a batch is held (the JavaScript core:
1000 events); beyond that the oldest are dropped and reported with `attempts` 0. A timer used for a hold MUST NOT
keep a short-lived process alive on platforms that have that concept (for Node, an `unref`'d timer).

A held batch is the one place where this suite keeps a batch without `durable-queue`: only for the identity cases
above. Any other 503, and any other 403, follows the status rules in [Ingestion and queue behavior](#ingestion-and-queue-behavior).

## Mock server and HTTP control API

Node 22 or newer is used by CI and the reference runner (built-in fetch). The
server itself needs only Node built-in modules and no package installation:

```sh
node conformance/server/cli.cjs --port 43189
```

The server binds **only `127.0.0.1`**, never all interfaces. Port defaults to zero;
zero asks the OS for an unused port. Stdout has one JSON startup line such as
`{"port":43210,"host":"http://127.0.0.1:43210"}`. Startup errors go to stderr
and exit nonzero. SIGINT/SIGTERM close timers and sockets. Use one server per
suite run; concurrent runners need separate instances.

| Request | Result (JSON unless ingestion) |
| --- | --- |
| `POST /control/reset` | 200 `{ "ok": true }`; send `{}` with Content-Type application/json. Clears records, response script and cursor, cancels delayed responses. Stop previous adapter work first. |
| `POST /control/script` with `{ "responses": [...] }` | 200 `{ "ok": true }`; atomically replaces script and resets cursor, preserves records. Invalid JSON/entries return 400 without changing the script. |
| `GET /control/time` | 200 `{ "nowMs": <Unix epoch milliseconds> }` on the server clock; never recorded as ingestion. |
| `GET /control/requests` | 200 `{ "requests": [...] }`; arrival-ordered snapshot of ingestion requests only. |
| `POST /control/identity` with `{ "mode": "off" \| "monitor" \| "required" }` | 200. Sets the identity mode for ingestion; reset returns it to `off`. Unknown modes return 400. |
| `POST /control/identity/token` with `{ sub, ttlSeconds, valid? }` | 200 `{ "token": "<jwt>" }`: an HS256 JWT for `sub` with `exp` = now + `ttlSeconds` and a unique `jti`, signed with the published fixture secret (or an unknown one when `valid` is false). |
| `POST /api/public/apps/batch` | Reads JSON, records it and consumes a script entry. Scripted empty-body status or socket drop; exhausted script returns 204. Invalid JSON/oversize body returns 400 and still consumes one entry. |

Identity modes (suite 1.3.0). The mock reads the `x-tranthor-identity-token` header and the body field
`identityTokens`, considers at most 10 tokens (header first, then the body list in order) and never answers 400 for their
count or length. An `identityTokens` that is not an array of strings is a 400 without a code in every mode. In `required`
mode a request with any item whose `userId` has no valid token for that user fails with `403`
`{ message, code: "identity_not_verified", reason, userIds }` (`reason` is the first failure: `missing`, `signature`,
`expired`, ...; `userIds` the distinct users without a valid token, at most 50). That verdict is the server's own answer:
it does not consume a scripted response. Otherwise the next scripted response applies. The protocol allows one ingestion request in flight; with two in flight, which scripted entry each gets when one of them receives a verdict is undefined, and scenarios must not rely on it. In `monitor` mode nothing is rejected and
`x-tranthor-unverified-events` counts the items that would fail. In `required` mode the mock also drops the anonymous sensitive
events listed above with a 204 and the count in `x-tranthor-dropped-events`; an unknown or non-HS256 `alg` fails as `signature`. Scripted response entries may carry `body`, a JSON object
sent with `Content-Type: application/json`, to script the `write_key_*` 403s and the identity 503s. The mock does not model
audiences, `kid` or secret rotation; it is not an auth test.

Control POSTs MUST have media type application/json (case-insensitive, parameters
allowed); otherwise they return 415 without mutating state.

Each record has zero-based `index`, Unix epoch `receivedAtMs` captured at arrival,
`method`, exact `path`, lower-case Node `headers`, and parsed `body`. A body not
yet complete is null; malformed input adds `parseError`. JSON bodies are limited
to 1 MiB. Unknown routes/methods return 404. Control requests are not ingestion
records. Script reservation follows arrival order, independently of completion
or response delay. Do not use this server as an auth/schema/production-server
test: it deliberately accepts arbitrary parsed JSON payloads.

## Simulator and emulator base URLs

Adapters MUST accept an externally supplied host including port; never hardcode
the production host or a fixed mock port. Configure SDK host before construction
and remove trailing slashes before appending the ingestion path. A host is the
origin, not a URL already containing `/api/public/apps/batch`.

Host CI reaches the control API through `http://127.0.0.1:<port>`. The in-process
adapter uses the same device-reachable origin for control and ingestion. An iOS simulator
MUST use `http://127.0.0.1:<port>` (not localhost); the standard Android emulator uses
`http://10.0.2.2:<port>` to reach the host's loopback interface. Android localhost
would refer to the emulator itself. Enable local HTTP only in the conformance test app's
platform configuration (ATS/local networking or Android cleartext test config).
A physical Android device needs `adb reverse tcp:<port> tcp:<port>` and uses
127.0.0.1 on-device. A physical iOS device needs the host's LAN address and an
explicit host proxy/tunnel forwarding to this loopback-only server; it cannot
reach the host via adb reverse. The mock MUST continue binding only 127.0.0.1. Host/emulator routing and lifecycle APIs
must be validated in each native repository's CI; this JS suite cannot prove them.

## Suite 1.x scope

The 1 MiB mock body limit, SDK 413 handling, large `files`, and
subscribe/unsubscribe are out of scope for suite 1.x. The mock's
size guard is infrastructure protection, not an SDK conformance requirement.

## Native CI examples

These are host CI sketches; replace schemes, simulator IDs and Gradle tasks with
the native repository's test target. Tests receive CONFORMANCE_HOST and scenario
paths through that repository's test configuration (including XCTest launch
environment or instrumentation arguments). JVM tests use 127.0.0.1; emulator
instrumentation uses 10.0.2.2 for both control API and ingestion.

```yaml
# GitHub macOS runner: iOS simulator
runs-on: macos-latest
steps:
  - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
  - uses: actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020 # v4
    with:
      node-version: 22
  - run: |
      node conformance/server/cli.cjs --port 43189 &
      server_pid=$!
      trap 'kill "$server_pid"' EXIT
      curl --retry 20 --retry-connrefused --retry-delay 1 --fail http://127.0.0.1:43189/control/time
      CONFORMANCE_HOST=http://127.0.0.1:43189 xcodebuild test -scheme Conformance -destination 'platform=iOS Simulator,id=<simulator-id>'
```

```yaml
# GitHub Ubuntu runner: JVM tests and an Android emulator started by CI
runs-on: ubuntu-latest
steps:
  - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
  - uses: actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020 # v4
    with:
      node-version: 22
  - run: |
      node conformance/server/cli.cjs --port 43189 &
      server_pid=$!
      trap 'kill "$server_pid"' EXIT
      curl --retry 20 --retry-connrefused --retry-delay 1 --fail http://127.0.0.1:43189/control/time
      CONFORMANCE_HOST=http://127.0.0.1:43189 ./gradlew test
      # CI installs the Android SDK/system image and creates this AVD first.
      emulator -avd conformance -no-window -no-audio -no-boot-anim &
      adb wait-for-device
      until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = 1 ]; do sleep 1; done
      ./gradlew connectedAndroidTest -Pandroid.testInstrumentationRunnerArguments.conformanceHost=http://10.0.2.2:43189
```

Neither adapter nor runner imports or calls server internals; harness unit tests
may import them. Concurrent jobs MUST use
separate ports via CONFORMANCE_PORT or separate hosts.

## Suite changelog

- **1.6.0**
  - Scenario expectations tightened and one scenario's event corrected, from review of the native SDKs: `identity-token-403-renews-and-retries` observes 500 ms (retry exactly once); `identity-token-503-unavailable-is-held-not-dropped` lower bound 985 ms; `identity-token-provider-timeout` upper bound 800 ms; `identity-token-removal-refused-twice-stays-queued` uses `properties.token` and checks the hold delays; `identity-token-token-supplied-once-is-held-after-refusal` also checks a later event and no provider call; `identity-token-write-key-403s-are-terminal` runs with identity in use.
  - Text: the 10-user cut follows "identity in use" (a provider, or a token ever passed to `identify`), not the cache; the removal guarantee covers identified removals only and says what the SDK can and cannot know about a silently dropped anonymous one; failed removals are notices, never errors; the token limits and the 64 KB event drop are documented.
  - Mock: counts events over 64 KB in `x-tranthor-dropped-events` in every mode; script entries keep arrival order in Required (a malformed body consumes one, an identity verdict gives its entry back).
  - Internal ticket, design record and private repository references removed from the suite files.
- **1.5.1**
  - Wording only: under the `Installation Removed` rule a refused, parked removal is reported as a notice on each failed attempt (push token redacted), not through the error callback. The scenario `identity-token-removal-refused-twice-stays-queued` already asserts empty errors and notices. No schema or scenario change.
- **1.5.0**
  - Behaviour change, replaces what each SDK did: a `403 identity_not_verified` holds the current user's batch only when identity is in use (provider configured, or a token ever supplied through `identify`); otherwise it is reported and dropped as before. A `503 identity_settings_unavailable` / `identity_secrets_unavailable` is held for every app, in use or not, because it is a server outage.
  - An `Installation Removed` is never dropped for lack of a valid token: parked, retried on the hold timer and at next launch, each failed attempt reported as a notice (not through the error callback, because nothing was dropped) with the push token redacted. This replaces any earlier rule that a refused removal is reported and dropped.
  - Adds scenarios `identity-token-never-in-use-403-is-dropped`, `identity-token-token-supplied-once-is-held-after-refusal` and `identity-token-removal-refused-twice-stays-queued`; `identity-token-refusal-without-user-backs-off` now configures a provider so identity is in use.
- **1.4.1**
  - Wording only: the `x-tranthor-dropped-events` notice is neutral because the count includes oversized events in every mode; the token audience rule is documented. `identity-token-anonymous-drop-is-surfaced` has a corrected description. No schema change.
- **1.4.0**
  - Review fixes before native SDKs pin it. Adds the scenario field `expect.notices` and the diagnostic notice (`events-dropped`, `events-unverified`, `identity-refused`, `identity-unavailable`).
  - The mock drops anonymous sensitive events in Required (204, `x-tranthor-dropped-events`) and gives a non-HS256 `alg` the reason `signature`.
  - Adds scenarios `identity-token-anonymous-drop-is-surfaced`, `identity-token-monitor-unverified-is-surfaced`, `identity-token-unfixable-refusal-does-not-loop`, `identity-token-refusal-without-user-backs-off` and `identity-token-held-batch-sends-other-users`. Existing 1.3.0 identity scenarios gain notices.
  - Removes the `holdMs` knob: a hold lasts the provider backoff. A 503 hold honours Retry-After up to 5 minutes. A cached token is attached until `exp` + 120 s. The 10-users cut applies only when identity is in use.
  - Changed rules: see Identity tokens. Adapters declaring `identity-token` must surface response-header counts and refusals as notices.
- **1.3.0**
  - Adds the optional `identity-token` and `app-id` capabilities.
  - Adds mock-server identity modes (`/control/identity`, `/control/identity/token`) and scripted response bodies.
  - Adds the scenario fields `server.identity`, `config.identity`, `config.appId`, `emit.identityToken`, `expect.requests[].identityTokens` and `expect.providerCalls`.
  - Adds twelve scenarios: `identity-token-matching-user-only`, `identity-token-mixed-user-batch`, `identity-token-expiring-token-renewed-before-send`, `identity-token-provider-timeout`, `identity-token-provider-backoff`, `identity-token-403-renews-and-retries`, `identity-token-403-drops-previous-user-items`, `identity-token-403-holds-batch-for-current-user`, `identity-token-write-key-403s-are-terminal`, `identity-token-503-unavailable-is-held-not-dropped`, `identity-token-ten-users-per-request` and `app-id-header`.
  - Unlike 1.1.0 and 1.2.0 the JS reference declares both capabilities and passes them.
  - For adapters that don't declare them, every earlier scenario keeps its meaning.

- **1.2.0**
  - Adds the optional `durable-queue` capability and the scenario field `unless`.
  - Adds five scenarios: `durable-exhausted-batch-retained`, `durable-exhausted-batch-keeps-order`, `durable-exhausted-dropped-connection`, `durable-exhausted-pause` and `durable-exhausted-batch-survives-restart`.
  - Marks `retries-exhausted`, `interval-after-retries-exhausted` and `retry-dropped-connection-exhausted` with `"unless": ["durable-queue"]`.
  - For adapters that don't declare `durable-queue`, every earlier scenario keeps its meaning.
- **1.1.0**
  - Adds the optional `identity-link` capability, the `anonymousId` step, and the `anonymousIdRef` item matcher.
  - Adds three scenarios: `identify-links-anonymous-id`, `identify-rotates-on-user-change` and `explicit-anonymous-id-wins`.
  - Adapters declaring `identity-link` must send the stored anonymousId on the 1.0 identify scenarios.
  - For adapters that don't declare it, 1.0 scenarios keep their meaning.
- **1.0.0**
  - Initial suite.
