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
Other statuses are terminal, including 400, 401, and 403. The reference transport
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
flush cycle; subsequent queued batches remain for the next interval, whose timer MUST be re-armed. The exhausted failed
batch itself is discarded. Retention of later queued batches is exercised by
`interval-after-retries-exhausted`. Long-backoff retention after exhaustion
(including the 30 s cap) is **verified from source, not exercised by a scenario**:
waiting through that boundary is too slow. Callback exceptions do not change delivery.
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
| `emit` | Call the named SDK `method` with `data`; record local wall-clock before/after invoking the method using the unique `call` label. Do not await transport here. |
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
`emit(method, data)`, `flush() -> {rejected}`, an `errors` array, and `dispose()`;
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
capabilities. A declared capability cannot turn a failed scenario into a skip.
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
| `POST /api/public/apps/batch` | Reads JSON, records it and consumes a script entry. Scripted empty-body status or socket drop; exhausted script returns 204. Invalid JSON/oversize body returns 400 and still consumes one entry. |

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

- **1.1.0**
  - Adds the optional `identity-link` capability, the `anonymousId` step, and the `anonymousIdRef` item matcher.
  - Adds three scenarios: `identify-links-anonymous-id`, `identify-rotates-on-user-change` and `explicit-anonymous-id-wins`.
  - Adapters declaring `identity-link` must send the stored anonymousId on the 1.0 identify scenarios.
  - For adapters that don't declare it, 1.0 scenarios keep their meaning.
- **1.0.0**
  - Initial suite.
