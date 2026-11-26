# Contributing

Thank you for helping improve the SDK. Open an issue before starting a large change. Keep pull requests focused, add or update a test for each behaviour change, and update `CHANGELOG.md` and the docs when public behaviour changes.

## Requirements

- Xcode 16 or later for `swift build` and the unit and host conformance tests (Swift 6 language mode, strict concurrency)
- Node.js 20 or later, for the conformance mock server
- Python 3, for the script tests
- XcodeGen (`brew install xcodegen`), for the simulator and example tests
- For the simulator scripts and the example app tests: Xcode 27, because the scripts select the iOS 27.0 simulator runtime and an `iPhone 17` device on it (`TRANTHOR_SIMULATOR_NAME` changes the device name, not the runtime)

## Build and test

```sh
swift build
scripts/test-unit.sh          # unit tests on macOS, with -warnings-as-errors; skips the conformance run
scripts/test-host.sh          # conformance suite on macOS against the mock server
scripts/test-simulator.sh     # conformance suite in an iOS simulator, including the lifecycle scenario
scripts/test-example-simulator.sh   # example app model and UI tests in a simulator
```

`scripts/test-unit.sh` and `scripts/test-host.sh` need no simulator and are what CI runs. Both accept the usual `swift test` flags; for a thread-sanitizer run use `scripts/test-unit.sh --sanitize=thread` and `TRANTHOR_TSAN=1 scripts/test-host.sh`. Test runs are time-bounded by `scripts/run-bounded.py`; XCTest buffers its output, so the last test name printed does not say which test hung.

`swift test` with no filter fails the conformance test unless `CONFORMANCE_HOST` is set (or `CONFORMANCE_ALLOW_SKIP=1`), because it needs the mock server.

## Conformance suite

The scenarios in `Tests/ConformanceTests/Fixtures` are the delivery contract: they pin batching, retries, persistence, consent and identity linking, and the runner fails if the SDK's requests differ. `conformance/PROTOCOL.md` is the specification and `conformance/server` is the dependency-free mock server. The runner validates every scenario against the schema, then checks each request the SDK makes. Do not edit scenarios or the schema by hand to make a change pass; open an issue if you think the contract is wrong. To adopt a newer suite, take it from the shared conformance suite's release and:

1. Replace the whole `Tests/ConformanceTests/Fixtures/scenarios` directory with the release's `scenarios`, so scenarios the new suite dropped do not keep running. Replace `scenario.schema.json` and `VERSION` beside it.
2. Replace `conformance/PROTOCOL.md` and these files in `conformance/server`: `cli.cjs`, `index.cjs`, `identity.cjs`, `server.test.cjs` and `identity.test.cjs`.
3. Remove ticket numbers and the names of private repositories from the copied text, as the existing files do.
4. Run `scripts/test-unit.sh` and `scripts/test-host.sh`, and name the suite version in the commit message.

Run one scenario while still validating all of them:

```sh
CONFORMANCE_SCENARIO=retry-500-doubling scripts/test-simulator.sh
```

The simulator script starts the mock on a free loopback port and forwards its address to the tests as `TEST_RUNNER_CONFORMANCE_HOST`. The lifecycle scenario posts the real UIKit background notification in a minimal test host; it does not move the host into the background, so real background time and suspension need a device.

## Example app

```sh
scripts/generate-example.sh      # generates the Xcode project (ignored by git)
scripts/run-on-simulator.sh      # builds and opens the example in a simulator
```

To run it on a phone, follow the maintainer runbook in [docs/device-testing.md](docs/device-testing.md). Local signing settings live in `Config/Local.xcconfig`, which is ignored; never commit write keys, team IDs or device identifiers.

## Not covered by automated tests

These need a person and a device: signing, protected-file reads before first unlock, real background time and expiry, Airplane Mode behaviour, and remote APNs delivery.
