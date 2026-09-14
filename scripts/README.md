# Isolated backend integration fixture

`backend_fixture.py` starts the existing Rust `todex-agentd` executable on `127.0.0.1` with port `0` (the OS allocates a free port). It uses `daemon-run`, which skips the release updater. The host executable, backend repository, user configuration, login credentials and main app files are not modified.

All generated state lives in a new owner-private `/tmp/todex-mobile-fixture-*` directory: child-process HOME/CODEX_HOME/Claude and XDG directories, config, device key, logs, temporary files, a trusted workspace and a local Git repository. The launcher passes a small explicit child environment; it does not change the invoking shell's environment. Provider executables are absolute paths to temporary fake CLI launchers; Pi/Grok paths intentionally do not exist.

## Run

From the mobile repository:

```sh
python3 -B scripts/backend_fixture.py start
python3 -B scripts/backend_integration.py --fixture /private/tmp/todex-mobile-fixture-EXAMPLE
python3 -B scripts/backend_fixture.py status --fixture /private/tmp/todex-mobile-fixture-EXAMPLE
python3 -B scripts/backend_fixture.py stop --fixture /private/tmp/todex-mobile-fixture-EXAMPLE
```

Replace the example directory with `root` from `start`. To use another existing binary, pass `start --backend-binary /absolute/path/to/todex-agentd`. Python 3 and `/usr/bin/git` are required; no third-party Python dependencies are used. A restricted agent environment may require permission to bind/connect to loopback ports and spawn a real PTY.

The server stays running after verification. `stop` targets only the daemon recorded in that fixture's data directory and uses the backend's process-identity checks. Files remain available for inspection; no automatic deletion is performed. Rerunning verification creates additional synthetic conversations and a new local Git branch/commit. A failed verifier's recorded held conversations are cancelled at the start of the next run.

## Simulator handoff files

| File | Contents |
| --- | --- |
| `fixture.json` | HTTP/WS URL, PID, executable hash, temporary HOME/config/workspace paths, and IDs created during verification |
| `device.txt` | Base64url Ed25519 seed of the fixture device pre-enrolled in `data/devices.json`; owner-readable |
| `simulator-connection.json` | `serverURL`, `deviceSecret`, `encryption: none`, and `publicKey` for integration harnesses; not a promised app import format |
| `integration-report.json` | Pass/fail per check and observed HTTP status codes |
| `conversation-events.json` | Persisted Codex events returned by actual paginated REST replay |
| `logs/backend.log` | Rust daemon log |
| `logs/provider-wire.jsonl` | Synthetic backend-to-fake-CLI frames, including actual approval and interrupt responses |

Use the HTTP URL from `fixture.json`; requests are signed with the device seed from `device.txt`. An iOS simulator on this Mac can reach the loopback listener. A physical device cannot use this loopback URL. Keep `encryption` set to `none` for this fixture. The app's actual connection UI and Swift runtime have not been driven by the Python verifier.

## What is verified

The verifier uses actual HTTP and RFC 6455 WebSocket connections against the Rust process. It validates the handshake, masks client frames, handles ping/pong and continuation frames, applies bounded waits, and checks outcomes rather than treating an accepted command as completed work.

The 16 groups cover:

1. Plain-text health, backend version and transport policy.
2. Missing and incorrect HTTP auth.
3. Missing and incorrect WS auth.
4. Provider availability catalog.
5. Workspace save, canonical IDs, listing and automatic trust.
6. Model discovery after workspace trust.
7. Unicode/space/plus file paths, save/readback and stale-write 409 protection.
8. Actual local Git scan/status/workspace, branch creation and commit.
9. WS ping/result correlation.
10. Conversation creation/list/get/update/subscription.
11. REST prompt → WS permission event → REST approval → fake Codex receives the decision → output and completion.
12. WS prompt → confirmed running fake turn → REST cancel → native interrupt/completion and persisted cancellation.
13. Paginated REST event replay without sequence gaps, and a new WS subscription replaying after a cursor.
14. Fake Claude stream-json initialization, permission via WS, object-shaped text delta and completion.
15. Real `/bin/sh` PTY start/input/output/resize/stop in the temporary workspace. Output markers are split in the submitted command so terminal echo cannot satisfy the assertion.
16. Structured 400 malformed ID, 404 absent UUID, 403 workspace boundary, Unsupported native resume and 422 invalid patch errors.

The HTTP version check does not invoke `/v2/providers/versions`: that endpoint also performs remote GitHub/npm/Pi version checks. CLI upgrades, Git pushes/PRs, device-pairing crypto/approval, encrypted WS, real AI services, cloud tasks, MCP tools and simulator UI automation are not exercised here. The Rust executable's SHA-256 is recorded so results are attributable to the exact existing binary, which may differ from a newer source checkout.

## Fake providers

`fake_provider.py` follows the backend's own test patterns in `src/provider/codex.rs`, `src/provider/codex/runtime.rs`, `src/server/websocket.rs`, and the Claude control exchange in `src/provider/claude.rs`. It simulates the provider protocol only; it never runs a requested tool or connects to a service.

- Normal prompts return `Fixture Codex: …` or `Fixture Claude: …`.
- Include `fixture:permission` to request an approval; the fixture returns a marker showing the decision received from the backend.
- Include `fixture:hold` to keep a turn open for cancellation. Codex emits a holding marker before waiting for interrupt.
- Codex model discovery returns `fixture-model`. Its schema export advertises no experimental live controls or queue support.
- The fixture understands native initialization, thread start/resume/fork, prompt, interrupt and simple compaction frames. The integration run verifies only the operations listed above.

Observed wire details: extension-less and unlisted file names receive `application/octet-stream` from the backend's preview classifier while still returning UTF-8 `text`, so the editable test fixture uses `.md`; Codex deltas are strings while Claude deltas contain `{type, text}`; native `turn/started` is consumed by the adapter instead of forwarded as a raw event. These are not Swift API decoding failures.

## Swift and simulator checks

From the repository root, with the fixture still running:

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
swift test --package-path Packages/TodexCore
TODEX_LIVE_FIXTURE=/private/tmp/todex-mobile-fixture-EXAMPLE/fixture.json \
  swift test --package-path Packages/TodexCore --filter RealtimeLiveTests
node scripts/test_renderer.cjs
scripts/run_session_tests.sh
python3 scripts/run_simulator_tests.py \
  --fixture /private/tmp/todex-mobile-fixture-EXAMPLE \
  --device SIMULATOR-UDID
```

Use `xcrun simctl list devices available` to choose an installed iPhone or iPad. `--fixture` takes the fixture **directory**. The runner builds with the selected Xcode, injects only the fixture port/device seed through an owner-private `.xctestrun`, deletes that temporary run configuration, and leaves an `.xcresult` inside the fixture directory. `--skip-build` reuses the latest build; use it only when the app and test sources have not changed.

`TODEX_LIVE_FIXTURE` for Swift's optional WebSocket tests takes the **fixture.json file**. To select a single UI case, pass e.g. `--only-testing TodexUITests/TodexUITests/testDarkAppearanceAndLargeText`.

The UI suite creates synthetic conversations, edits the fixture workspace's `README.md`, starts/stops a real PTY, and reads a loopback page and Git status. Run devices sequentially against one fixture to avoid concurrent edits to that file. Screenshots are XCTest attachments. No real model credentials are available to these fake providers.

`run_session_tests.sh` requires macOS 26+ and Swift 6.2+. It builds TodexCore and the real AppSession/LocalStore sources in a fresh temporary Swift package, runs 13 bounded regression scenarios with HTTP/Socket/Keychain substitutes, and removes its generated build and test data on exit. It needs network access to fetch dependencies; it does not depend on an earlier `/tmp` build or call a provider.

The one authorized real Codex request is documented separately in [real-provider-validation.md](../docs/real-provider-validation.md). It must not be rerun by this suite.
