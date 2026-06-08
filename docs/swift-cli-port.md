# Swift CLI port

Status: in progress (branch `swift-cli-port`).

## Goal

Replace the `bin/amaran` zsh dispatcher and its inline Python heredocs with a
native Swift CLI binary. The iPad backup importer stays in Python and is out of
scope.

## Decisions

- **Architecture.** A Swift CLI owns argument parsing, all `state.json`
  read/write/validate, output formatting, the launchd daemon management, and the
  daemon/app client. `bin/amaran` becomes a thin shim that `exec`s the built
  binary (exporting `AMARAN_ROOT` so the binary can find `BluetoothProbe.app` and
  the `scripts/` helpers).
- **Shared core + Unix socket.** One SwiftPM package. An `AmaranCore` library is
  shared by both the CLI and the `BluetoothProbe` app. The daemon transport moves
  from a TCP socket on `127.0.0.1` to a `0700` Unix domain socket. `daemon.json`
  shrinks to `{pid, socket_path, started_at}`.
- **Port now.** `scene-store` and `discover-existing-mesh` move into Swift on
  `AmaranCore`.
- **No Python at all (final decision).** The `ui` (Textual) command is dropped;
  encrypted-backup decryption is ported to Swift via CommonCrypto. After cutover
  there is zero Python in the project.
- **`sidus-import`: fully native**, including encrypted backups
  (`IosBackupDecrypt`: keybag parse, PBKDF2 + RFC-3394 unwrap + AES-CBC). Crypto
  primitives are RFC-vector tested; the end-to-end encrypted path needs
  verification against a real encrypted backup.
- **Output parity.** `--json` field names and structure stay stable (the TUI and
  any scripts parse it). Human-readable text may be cleaned up.
- **Build.** SwiftPM + swift-argument-parser (first Swift package dependency in
  the repo). `scripts/build-bluetooth-probe` becomes `swift build` + bundle
  assembly + codesign.
- **TDD.** Every unit lands test-first.

## Target repo shape (end state)

```
Package.swift
Sources/
  AmaranCore/            shared lib (CLI + app both depend on it)
    StateModel.swift     Codable: mesh / fixtures / runtime / scenes / source
    StateStore.swift     atomic 0600 load/save (write atomic + chmod 0600)
    Validation.swift     state-install / doctor rules, address chooser
    ControlSpec.swift    on/off/intensity/cct/gm/raw grammar
    Capabilities.swift   MAC norm, labels, selector match, CCT clamp per family
    Composition.swift    composition data page-0 element count
    Hex.swift            hex encode/decode
    DaemonProtocol.swift Codable request/response payloads
  amaran/                CLI executable (argument-parser, commands, daemon client)
  BluetoothProbe/        app executable (existing native_*.swift refactored onto
                         AmaranCore + Unix socket listener)
scripts/build-bluetooth-probe   -> swift build + bundle + codesign
bin/amaran                      -> shim: exec the built amaran binary
```

## Authoritative sources for the port (preserve behavior)

- `native_mesh_state.swift` — state schema, validation rules, atomic write,
  MAC normalization, runtime source-address selection.
- `native_mesh_config.swift` — `compositionDataPage0` (element count derivation).
- `native_mesh_crypto.swift` — hex encode/decode.
- `scripts/amaran_capabilities.py` — capabilities, selector match, CCT clamp.
- `bin/amaran` Python heredocs — `doctor`/`list`/`state-join`/`state-install`
  output and validation.
- Daemon wire contract — `bin/amaran` (`~line 592`) + `bluetooth_probe.swift`.

## state.json schema (v1)

Top level: `schema_version` (1), `synced_at`, `source`, `mesh`, `fixtures`,
`runtime`, optional `scenes`.

- `mesh`: `uuid`, `net_key` (16-byte hex), `app_key` (16-byte hex),
  `fixtures_ordered_list` ("[]"), `scenes_ordered_list` ("[]"), `update_time`,
  `state` (0).
- `fixtures[]`: `uuid`, `mac_address`, `code`, `name`, `node_address`
  (1..0x7fff), `device_key`/`device_uuid` (16-byte hex, optional for
  control-only), `composition_data` (hex), `element_count` (1..255, optional),
  `update_time`, `state`, plus optional `friendly_name`, `mac_address_source`,
  version strings, `control_only`, `capabilities`.
- `runtime`: `iv_index` (0..0xffffffff), `source_address` (1..0x7fff),
  `telink_source_address` (1..0x7fff), `sequence_next` (0..0x00fffffe),
  `updated_at`, optional `last_reserved_by`.
- `scenes`: `{ name: { captured_at, fixtures: [{ node_address, name,
  mac_suffix, intensity?, cct?, gm?, sleep_mode? }] } }`.

Write pattern: create parent dir `0700`, write atomically, `chmod 0600`. JSON is
pretty-printed, sorted keys, trailing newline.

## Daemon contract (after Unix-socket change)

- Socket: Unix domain socket at a `0700` path; `daemon.json` =
  `{pid, socket_path, started_at}`.
- Framing: one compact-JSON request + `\n`; response is JSON until first `\n`.
- Actions: `ping`, `control {spec,state_path,timeout,node_id?}`,
  `control_sequence {specs[],...}`, `status {...}`, `shutdown`.
- Auto-start when no daemon: spawn the app in `--daemon` mode, poll ~5s.
- Fallback when daemon disabled/unavailable: direct one-shot app launch.
- launchd: label `dev.local.bluetooth-probe`, `bootstrap`/`bootout`/`enable`,
  logs via `log show/stream --predicate 'subsystem == "dev.local.bluetooth-probe"'`.

## Command coverage

- Pure logic: `doctor`, `list`, `fixture rename/clear-name`, `state-join`,
  `state-install`, all `scene *`.
- Daemon/app client: `probe`, `status`, `identify`, `on`, `off`, `intensity`,
  `cct`, `gm`, `monitor`, `discover`, every `*-test` / `config-*-test`, and
  `daemon start/status/stop/logs/install/uninstall`.
- Delegate to Python: `ui` -> `amaran-tui`, `sidus-import` -> `sidus-backup-import`.

## Phases

1. `Package.swift` + `AmaranCore`: state model, store, validation, control spec,
   capabilities, composition, hex. Unit tests. **(done — 59 tests, 8 suites)**
2. **Build consolidation (done).** App sources moved to `Sources/BluetoothProbe`;
   added a SwiftPM `BluetoothProbe` executable target depending on `AmaranCore`
   (Swift 5 language mode for the legacy native code); `build-bluetooth-probe`
   now does `swift build` + copy into the signed `.app` + codesign (bundle id and
   ad-hoc designated requirement preserved so TCC permission persists). No runtime
   behavior change. `npm run test:mesh` repathed; all tests green.
   - Deferred to phase 3: the TCP -> Unix-socket transport flip (the listener and
     the new Swift client must change in lockstep and are testable together).
   - Deferred (later careful refactor): unifying the app's internal
     `NativeMeshState` onto `AmaranCore.StateModel`. Both read the same on-disk
     format (now covered by `AmaranCore` round-trip tests), so this is cleanup,
     not a correctness blocker, and should be verified against hardware.
3. Swift daemon client + the TCP -> Unix-socket transport flip + launchd +
   `daemon *`.
   - **Done:** `AmaranCore.DaemonProtocol` (Codable request/response + line
     framing). App listener flipped from TCP to a Unix domain socket
     (`NWParameters.tcp` + `requiredLocalEndpoint = .unix`); `daemon.json` is now
     `{pid, socket_path, started_at}`; socket is `0600` under the `0700` dir;
     removed on shutdown. The transitional Python client in `bin/amaran` switched
     to `AF_UNIX` in lockstep. Verified on hardware: `daemon start`,
     `status --node big` (full BLE path), `daemon stop`, and metadata cleanup.
   - **Done:** `amaran` executable + `AmaranCLI` library (swift-argument-parser);
     `DaemonClient` (POSIX AF_UNIX, framing via `DaemonProtocol`, ping,
     auto-start; tested against an in-process socket server); `CLIEnvironment`
     (path/env resolution mirroring the zsh defaults); `LaunchAgent` (plist gen +
     launchctl install/uninstall/stop); `daemon start/status/stop/logs/install/
     uninstall`. Verified live: `start`/`status --json`/`stop`. 78 tests, 14 suites.
4. Pure-logic commands.
   - **Done:** `list` (verified against real state), `fixture rename/clear-name`
     (verified e2e incl. loss-free round-trip), `doctor` (byte-identical to the
     zsh/Python output, human and `--json`), `state-join` and `state-install`
     (`--json` byte-identical to Python; written state matches the app's
     `NativeMeshState` JSON format — Apple's `" : "` spacing, which the app
     already uses; the Python heredocs' `": "` is the outlier and is being
     deleted). 96 tests, 17 suites.
   - `scene list/show/delete` done (human identical to Python; `--json`
     structurally identical, modulo `75.0` vs `75` whole-number formatting).
   - **Phase 4 complete: 100 tests, 18 suites.** `scene capture/apply` move to
     phase 5 (they need the daemon).
5. BLE + diagnostic commands + `discover` + `scene capture/apply`.
   - **Core control done:** `ControlRunner` (daemon-or-one-shot routing),
     `StatusReport` (telink CCT parsing), `ControlSpecBuilder` (cct/gm status-merge
     + per-fixture clamp). Commands `on/off/intensity/status/cct/gm` verified live
     against a real fixture; `status` human + `--json` byte-identical to zsh.
     114 tests, 20 suites.
   - **Done:** `scene capture/apply` (verified live), `identify` (plan unit-tested),
     and the one-shot diagnostics `gatt-probe`/`probe`/`provision-scan`/`monitor`/
     `proxy-test`/`sig-onoff-test`/`control-test`/`status-test`/`config-*-test` via
     a shared `AppLauncher` (faithful `--json` = the app's `data`; concise human).
   - **Provisioning (ported, hardware-unverified):** `pair` (provision ->
     configure-with-retry -> verify), `provision-test`, `configure-test`,
     `provision-invite-test`, `config-node-reset-test` (with `--dry-run`/
     `--confirm-reset` guard), `join-capture`. These can't be exercised without an
     unprovisioned fixture + live provisioning, so they need hardware verification.
   - **`discover`: ported natively** (`DiscoverScan` + `--status-batch` one-shot).
     Range parse, runtime-source relocation, status mapping, and fixture add are
     unit-tested; only the live batch probe needs hardware. The Python helper's
     per-address fallback (app-missing only) is dropped. `scripts/discover-
     existing-mesh` is removed at cutover.
   - **All 34 commands now exist in the Swift CLI. 134 tests, 24 suites.**
6. No-Python: `ui` dropped; encrypted decrypt ported (`IosBackupDecrypt`,
   CommonCrypto, RFC-vector tested). Zero Swift->Python calls remain. 140 tests.
   - **`sidus-import` ported (option A):** native Swift owns parsing, candidate
     selection, address choice, and state build; extracted-container + unencrypted
     (`Manifest.db` via system `SQLite3`) paths are native; encrypted backups call
     the thin `scripts/sidus-decrypt-mesh` Python helper (only `iphone-backup-
     decrypt` stays). `--json` verified identical to the Python importer on an
     extracted container. The old `scripts/sidus-backup-import` is removed at
     cutover.
7. **Cutover (done).** `bin/amaran` is now a ~15-line shim (build-if-missing +
   exec the `amaran` binary, exports `AMARAN_ROOT`). Deleted all CLI Python:
   `scene-store`, `sidus-backup-import`, `sidus-decrypt-mesh`,
   `discover-existing-mesh`, `amaran-tui`, `amaran_capabilities.py`,
   `requirements-tui.txt`, and the obsolete `test-cli-wrapper`. `package.json`
   test gate is now `test:core` (swift test) + `test:mesh`. README updated;
   AGENTS.md/HANDOFF.md bannered. Verified: `./bin/amaran doctor/list` via the
   shim, `npm test` green.

## Known follow-ups
- Hardware-verify the provisioning flow (`pair`/`provision-test`/`configure-test`/
  `join-capture`/`config-node-reset-test`), the live `discover` batch probe, and
  the end-to-end encrypted-backup decrypt (crypto primitives are RFC-tested).
- `pair-test` (a zsh diagnostic alias of `pair`) was not carried over.
- A fuller AGENTS.md/HANDOFF.md rewrite, and an optional CLI integration smoke
  test to replace `test-cli-wrapper`.

## Verification

- `AmaranCore` unit tests (validation, address chooser, spec grammar, hex,
  capabilities, JSON round-trip).
- `--json` golden tests per command (stable contract).
- Live smoke test through the daemon (`ping`/`status`/`control`) before cutover.
- All tests use `--state-path /tmp/...`; the real state is never touched.
