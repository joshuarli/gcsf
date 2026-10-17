# GCSF Native Swift / FSKit Rewrite — Campaign

**Status.** Ready to execute. Preflight completed Fri Oct 16 2026; the foundation is proven by real code (see Baseline). Runtime mount and extension-registration gates are **parked** on this machine: it has no signing identity (see Decisions → Owner-decided 1).

**Goal.** Replace the Rust/macFUSE GCSF with a native Swift 6.4 / FSKit macOS 27 app that mounts a Google Drive account at a POSIX path. One repository, one top-level `make`, Swift 6 language mode with complete concurrency checking, no Rust, no FUSE, no third-party runtime. The scope is exactly "mount my Drive": no extra workflows.

**Deliverables.**

1. `gcsf` CLI: `login`, `logout`, `list`, `verify`, `mount`, `umount`.
2. `GCSFCore` Swift package: URLSession Drive client, PKCE OAuth + Keychain, new Swift config format with migration from the legacy TOML, durable SQLite metadata index, bounded disk-backed read cache, safe writeback (staging + resumable upload + conflict), changes-feed sync, filesystem engine.
3. `GCSFExtension.appex`: native FSKit `UnaryFileSystemExtension` on the V3 `FSVolume.Handler` protocol family, served from `GCSFCore`, one volume per `gdrive://<session>` URL resource.
4. `GCSFHost.app`: minimal headless host bundling the extension.
5. Offline verification: mock-driven engine and fault-injection tests, plus the ported 16-category integration harness driven through the FSKit handler API.
6. Root `Makefile` with the target table in Reference.
7. Rust/Cargo/FUSE removed; README and docs rewritten.
8. Final owner manual verification (`M1`, last; see Sequence).

**Ceiling on this machine.** Deliverables 3 and 5 are built and compile-verified, but their real runtime gates (kernel mount, extension registration) cannot pass without a signing identity carrying `com.apple.developer.fskit.fsmodule` and `com.apple.developer.fskit.mount`. No item claims a successful runtime mount. The executor is fully self-sufficient up to the last step using the existing test suite ported to mocks.

## Charter

- **Decide, log the call, and keep going.** Within the execution grant (Execution boundary), decide and proceed without waiting for approval. A plan does not grant permission; park an item that needs authority outside the grant and run until every deliverable is met or every remaining item is parked.
- **Hard stops** (each parks the item, never the campaign): an irreversible or outside-the-repo action; a boundary the doc forbids; a loop that cannot check anything. **Pushing is always forbidden.**
- **Fix on the way what is egregious**, in its own commit, to stated thresholds: a command over 2 minutes that is on the item loop; a regression of more than 1.5× against the Baseline numbers; a test red on the Baseline that blocks the item. Record anything else seen and leave it.
- **Parity before optimization.** Every reference behavior gets a test that fails if it is wrong before any performance work.
- **Keep bookkeeping minimal.** No provenance, checksums, or pinned hashes.
- **Run wide.** Lanes are grouped by the files they own (see Sequence). Budget **≤3 GiB peak RSS per lane** and **≤10 GiB total** of build artifacts and caches (58 GiB free on `/System/Volumes/Data`). Start P1 at 4 lanes, read peak memory once their first builds finish, then widen to 5 if headroom allows. Never swap or OOM.
- **Worktrees and working state live under `.work/` in this repo, never `/tmp`.** Lane worktree `.work/wt/<lane>`; scratch `.work/tmp`, with `TMPDIR` pointed there for commands that spill large files. `.work/` stays ignored via `.git/info/exclude`. Follow `orchestrate`'s worktree lifecycle; retain a worktree at closeout only when clean, named in the handoff, and allowed by the closeout guard.
- **Every commit is a Conventional Commit**, scope = workstream (`engine`, `drive`, `cache`, `fskit`, `verify`, `docs`, `build`). The item ID goes in the body, never the subject.
- **Code comments never cite this doc.** Write no comment a name, type, test, or lint could carry.
- **Two loop speeds.** An item ends on the narrowest check that covers it. A phase ends on the checks for the areas it touched. The full suite runs at the end of P1, P2, and P4, each with its reason.
- **Time-box a failing item** at 5 attempts, then park it with a finding and continue with the next independent item.

## Decisions

### Owner-decided (Fri Oct 16 2026)

1. **Signing: no identity available.** All runtime mount and extension-registration gates are parked. The campaign delivers buildable code and offline verification only and must not claim runtime success. Unblocking prerequisite, named for the owner: an Apple Development identity plus macOS App Development provisioning profiles granting `com.apple.developer.fskit.fsmodule` (extension) and `com.apple.developer.fskit.mount` (mounting client).
2. **Live Drive tests: parked.** Implement `make test-live` and its docs, but never run against a real Drive. Run only when the owner explicitly authorizes it later against an isolated folder.
3. **Config: new Swift-native format.** Replace the TOML config with a new Swift-native format and migrate existing settings. Reuse the **same OAuth `client_id`/`client_secret` the user's existing config carries** so existing refresh tokens keep working; refresh tokens are bound to the issuing client, so a different client would force full re-authentication. Move only the refresh token into the Keychain.
4. **Google-native documents: read-only, no import workflow.** Writes to exported Docs/Sheets/Slides/Drawings/Sites fail with a clear read-only error. No Drive import/convert-on-write. This is a deliberate change from the Rust behavior and it is the intended contract.

### Prescribed

- **Mount mechanism.** The CLI mounts via `FSClient.shared.mountSingleVolume(resource:bundleID:options:)` (`FSClient.h`; V3 / macOS 27), passing an `FSGenericURLResource(url:)` whose URL is `gdrive://<session>` (`FSResource.h:392`). The system mounts under `/Volumes/`. `gcsf umount` uses `umount(8)` for the mount path. This requires the `com.apple.developer.fskit.mount` entitlement on the mounting client — parked with decision 1. Reason: it is the only SDK-provided mount path for a generic-URL module. Reverse only if a narrower documented path replaces it.
- **Extension metadata.** Info.plist `EXAppExtensionAttributes`: `EXExtensionPointIdentifier = com.apple.fskit.fsmodule`, `FSSupportsGenericURLResources = true`, `FSSupportsBlockResources = false`, `FSSupportsPathURLs = false`, `FSSupportedSchemes = ["gdrive"]`, `FSShortName = gcsf`. Model on the installed FTP module (`/System/Library/ExtensionKit/Extensions/com.apple.fskit.ftp.appex/Contents/Info.plist`). Reason: it is the OS's own generic-URL FSKit shape.
- **Entry point.** Use `UnaryFileSystemExtension`. `FileSystemExtension` (full FSKit) is `@available(macOS, unavailable)` in SDK 27.0. Reason: verified in the SDK.
- **Handler protocols.** Conform to the V3 `FSVolume.Handler` family (`FSVolume.Handler`, `FSVolume.ReadWriteHandler`, `FSVolume.XattrHandler`, `FSVolume.OpenCloseHandler`; `FSVolume.DataCacheHandler` only per `O2`). `FSVolume.Operations` is deprecated and must not be used. Reason: `FSVolume.h:472` and the proven probe.
- **Metadata index.** SQLite via the system `libsqlite3` (no wrapper dependency). Reason: stable inodes, parent/child lookup, and crash recovery need durable relational state; the system supplies it.
- **Xcode project committed directly.** Reason: owner asked; XcodeGen/tuist are not installed.
- **Preserve** the CLI commands and flags, config dir + session names, the `user.gcsf.*` xattr namespace, the Google export MIME map and synthetic extensions, the duplicate-name policy (`rename_identical_files`, drive-id ordering), and Trash/`skip_trash` semantics. Reason: these are the compatibility baseline.
- **Parity register** built as `reference-parity` describes, at `docs/parity.md`.

### Delegated

Executor decides inside the bound and logs the call:

- Config file encoding (plist or JSON) inside the new format — owner chose "new format", not the encoding.
- Cache block size, read-ahead depth, eviction limits, and staging/journal layout; all bounded and configurable.
- Concrete Swift module and target names below the fixed `GCSFCore`, `gcsf-cli`, `GCSFTestSupport`.
- Bounded concurrency widths, page sizes, and queue depths.

## Baseline

**Toolchain and host.** macOS 27.0 (26A428); Xcode 27.0 (27A266a); Swift 6.4 (swiftlang-6.4.0.34.1); SDK MacOSX27.0; arm64 (MacBookPro18,3, 10 cores, 32 GiB RAM, 58 GiB free).

**Loop timings (measured in preflight).**

| Check | Time |
|---|---|
| Single-file full-FSKit-conformance `swiftc -typecheck` | 0.42 s |
| SwiftPM cold build (1 target + 1 test target) | 18.8 s |
| SwiftPM warm no-op `swift build` | 2.5 s |
| SwiftPM incremental (1 file touched) | 0.6 s |
| `swift test` (1 test) | 5.4 s |

Target: keep the per-item loop under 30 s. The loop is not the bottleneck; no P0 loop-repair item is needed.

**Reference (the Rust implementation being replaced), at `f1828ce`.** `cargo test` → **52 passed, 0 failed** (unit tests: drive-facade write/read semantics, file-manager duplicate suffixes, filesystem xattrs, mount options, read-only). `tests/integration/test_filesystem_operations.sh` defines 16 categories (`test_file_creation` … `test_drive_xattrs`, lines 253–1020) with a 64 MiB sequential-read limit of 5 s; it needs a live mount and Drive and was not run. The reference has no recorded performance numbers; `O1` establishes the native-tree baseline at the end of P2 and then measures.

**Known failures on the baseline.** None. The Rust suite is green; the Swift tree does not exist yet. There are no pre-existing reds the executor should discount.

**Foundation proof.** `.work/tmp/fskit_probe.swift` is a complete `UnaryFileSystemExtension` `@main` plus a full `FSVolume.Handler` + `ReadWriteHandler` + `XattrHandler` conformance. It typechecks clean under `swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -sdk <MacOSX27.0.sdk> -target arm64-apple-macos27.0` in 0.42 s. This confirms the V3 handler protocols exist, are Swift-callable, and that FSKit's Objective-C completion handlers auto-import as `async throws` Swift methods. The probe is the starter for the extension target.

## Sequence

Workstreams own disjoint files so lanes never coordinate:

| WS | Owns |
|---|---|
| **E** Engine & Index | `Sources/GCSFCore/Model/`, `Index/`, `Engine/` |
| **D** Drive, Auth & Config | `Sources/GCSFCore/Drive/`, `Auth/`, `Config/` |
| **C** Cache, Writeback & Sync | `Sources/GCSFCore/Cache/`, `Writeback/`, `Sync/` |
| **F** FSKit, Host, CLI & Build | `Sources/GCSFCore/FSKit/`, `Sources/gcsf-cli/`, `Extension/`, `GCSF.xcodeproj/`, `Makefile` |
| **V** Verification | `Sources/GCSFTestSupport/`, `Tests/`, `tests/integration/` |

`Package.swift` and `docs/parity.md` are the only shared files; `F0` pre-declares all targets and directory stubs so lanes never edit `Package.swift`, and each lane appends only its own `Tests/GCSFCoreTests/<Workstream>*Tests.swift`.

### P0 — Ground (2 lanes: F, V)

- **`F0` Scaffold and build loop.** Owns `Package.swift`, `Sources/**` stubs, `GCSF.xcodeproj/**`, `Extension/Info.plist`, `Extension/*.entitlements`, `Makefile`, `.gitignore`. Does: SwiftPM package (`GCSFCore` lib, `gcsf-cli` exe, `GCSFTestSupport` lib) targeting macOS 27 in Swift 6 mode with complete concurrency; Xcode project committed directly with a host app and an FSKit appex target carrying the Info.plist keys and entitlements from Decisions → Prescribed; Makefile with `build`/`doctor`/`clean` functional and the rest declared; the `DriveBackend` protocol stubbed in `Sources/GCSFCore/Drive/DriveBackend.swift`; every module directory pre-declared. Proof: `make build` compiles the extension target with `CODE_SIGNING_ALLOWED=NO`; `swift build` succeeds; `make doctor` prints OS/Xcode/Swift/SDK/arch, the code-signing state, and `FSClient.shared.installedExtensions` plus `openFileSystemExtensionsSettings`.
- **`V0` Offline harness seam.** Owns `Sources/GCSFTestSupport/**`, `Tests/**` skeleton. Prereq: `F0`. Does: deterministic `FakeDrive` conforming to `DriveBackend` (an in-memory Drive v3 subset), fixtures, and fault-injection switches (401, refresh failure, 403/429, 5xx, pagination edges, malformed metadata, timeouts, partial download, redirect, 308, indeterminate completion, cancellation). Proof: `swift test` runs a FakeDrive round-trip.

### P1 — Parity (5 lanes: E, D, C, F, V)

**E**

- **`E1` Durable index and identity.** Owns `Sources/GCSFCore/Model/**`, `Index/**`, `Tests/GCSFCoreTests/IndexTests.swift`. Prereq: `F0`. Does: SQLite schema (inode↔Drive-id bijection, parent/child, name, MIME, size, times, checksums, head revision, trashed, owner); stable inodes across restart; stable root; no inode reuse that aliases another live object; deterministic enumeration order matching `src/gcsf/file_manager.rs:550`; cookies and verifier; invalidation; recovery from stale or missing rows; single `MetadataStore` actor. Proof: index tests including restart stability and determinism.
- **`E2` Engine semantics.** Owns `Sources/GCSFCore/Engine/**`, `Tests/GCSFCoreTests/EngineTests.swift`, `docs/parity.md` rows. Prereq: `E1`, `D1`. Does: lookup/attributes/xattrs/enumerate/create/rename/remove/readlink with POSIX errno mapping; `user.gcsf.*` xattrs per `src/gcsf/filesystem.rs`; export MIME map, synthetic extensions, and unexportable placeholders per `src/gcsf/file.rs:128` and `src/gcsf/drive_facade.rs`; duplicate-name policy (`rename_identical_files`, drive-id ordering, stable across restart via the index) per `src/gcsf/file_manager.rs:550`; Trash and `skip_trash` per `src/gcsf/file_manager.rs:52,236`; read-only `EROFS` per `src/gcsf/filesystem.rs:39`; special dirs (My Drive, Trash, Shared with me). Proof: engine tests and parity rows; every behavior fails if wrong.

**D**

- **`D1` Drive REST client and models.** Owns `Sources/GCSFCore/Drive/**` (incl. `DriveBackend.swift`), `Tests/GCSFCoreTests/DriveClientTests.swift`. Prereq: `F0`, `V0`. Does: URLSession client; small Codable DTOs; explicit query params and field masks; `files.list/get/create/update/delete/export`, content download, multipart and resumable upload, `changes.getStartPageToken/list`, `about.get`; pagination; 401 refresh hook; 403/404/409/429/5xx mapping; bounded backoff with jitter and respect for server retry instructions; redirect policy that never forwards the bearer token cross-origin; cancellation; bounded buffering and streaming. Proof: fixture tests for pagination, 401 refresh, 308 recovery, indeterminate upload, redirect, and retry.
- **`D2` OAuth, Keychain, and config.** Owns `Sources/GCSFCore/Auth/**`, `Config/**`, `Tests/GCSFCoreTests/AuthTests.swift`, `ConfigTests.swift`. Prereq: `D1`. Does: PKCE authorization-code flow with cryptographic state over a loopback redirect, system browser, request ported from `src/gcsf/auth.rs:47`; Keychain refresh-token storage; `TokenManager` actor with single-flight refresh; the new Swift config format plus TOML→new migration that reads the existing config's `client_id`/`client_secret` (`src/main.rs:406`, `src/gcsf/config.rs:35`) and session files (`src/gcsf/config.rs:128`); one-time session migration that is idempotent, verifies before deleting legacy credentials, and never logs secrets; CLI `login`/`logout`/`list`/`verify`. Proof: migration idempotency, refresh single-flight, and config round-trip tests.

**C**

- **`C1` Bounded read cache.** Owns `Sources/GCSFCore/Cache/**`, `Tests/GCSFCoreTests/CacheTests.swift`. Prereq: `D1`. Does: HTTP range reads; block/chunk caching; disk-backed caching for large content; sequential read-ahead; coalescing of overlapping reads; cancellation; explicit eviction limits; content-revision validation; memory bounded independently of remote file size. This replaces the whole-file LRU at `src/gcsf/drive_facade.rs:42,648`. Proof: a random 64 KiB read of a fixture larger than RAM completes without loading the whole file; partial-download and eviction-bound tests.
- **`C2` Writeback.** Owns `Sources/GCSFCore/Writeback/**`, `Tests/GCSFCoreTests/WritebackTests.swift`. Prereq: `C1`. Does: disk-backed staging with a durable journal; create/overwrite/append/truncate/random writes; rename/move/delete; resumable upload with committed-offset recovery and session query on indeterminate state; conflict detection that revalidates head revision before commit and preserves the local version instead of overwriting; honest `fsync`/flush semantics; crash recovery; never reports success before remote acknowledgement. This fixes the download-modify-upload path at `src/gcsf/drive_facade.rs:960,1088` and preserves its rollback-on-failure behavior. Proof: fault injection (308, indeterminate completion, kill during staging) and conflict and rollback tests.
- **`C3` Change-feed sync.** Owns `Sources/GCSFCore/Sync/**`, `Tests/GCSFCoreTests/SyncTests.swift`. Prereq: `E1`, `D1`. Does: `changes.list` pagination; advance a persisted checkpoint only after changes are durably applied; remote rename/move/delete/trash/content/metadata/permission-loss; replayed or duplicate events; missing or rejected page tokens; protection of dirty local writes from invalidation; bounded, cancellable, nonblocking. Proof: sync tests and a web-edit-during-local-write test.

**F**

- **`F1` FSKit extension, host, and CLI mount.** Owns `Sources/GCSFCore/FSKit/**`, `Sources/gcsf-cli/**`, `Extension/**`, `GCSF.xcodeproj/**`, `Makefile`. Prereq: `E1`, `C1`, `D2`. Does: an `FSVolume` subclass conforming to the V3 handler protocols from Decisions → Prescribed; item registry; async bridging with exactly-once callbacks, no network on callback threads, no locks across suspension points, no borrowed buffers escaping; lifecycle and unmount with in-flight requests; `loadResource` returning one volume per `gdrive://<session>`; the host app bundling the extension; `gcsf mount`/`umount` via `FSClient.shared.mountSingleVolume`; `make doctor` reporting module installed/enabled state and opening the Settings pane. Proof: `make build`; extension sources typecheck under `-swift-version 6 -strict-concurrency=complete`. **Runtime mount and registration are parked** (decision 1).

**V**

- **`V1` Offline parity harness and register.** Owns `tests/integration/**`, `Sources/GCSFTestSupport/**`, `Tests/**`, `docs/parity.md`. Prereq: `V0`, `F1`. Does: port the 16 categories of `tests/integration/test_filesystem_operations.sh` to macOS tools (`stat -f%z`, `xattr`, `md5 -q`; drop `fusermount`/`getfattr`), driving the real engine through the FSKit handler API in-process against `FakeDrive` with no kernel mount; keep the 64 MiB sequential-read limit; give every reference behavior — the 16 categories plus the 52 unit-test behaviors at `f1828ce` — a mock-driven test that fails if wrong; write the parity register mapping behavior→test. Proof: `swift test` green and the register complete.

### P2 — Hardening (up to 4 lanes: E, C, V, docs)

- **`H1` Adversarial matrix.** Owns `Tests/**`, `Sources/GCSFTestSupport/**`. Does: tests and POSIX error mapping for empty files, multi-gigabyte and larger-than-RAM files, sparse writes and truncation, Unicode normalization, duplicate names, case-fold collisions, very long names, path traversal, root protection, interrupted enumeration, concurrent rename and lookup, delete-while-open, disconnect during writeback, network down at mount and after mount, web-edit during local edit, process kill during write, abrupt restart, repeated mount/unmount, cache corruption recovery, quota exhaustion, and revoked credentials. Proof: the added tests fail if the behavior regresses.
- **`H2` Contract changes and docs.** Owns `README.md`, `docs/**`. Does: write up the config-format change, the Google-native read-only contract, the secrets/Keychain move, session migration, cache and staging locations, dirty-write recovery, unmount behavior, and limitations — naming the signing prerequisite for mounting. Remove obsolete Linux/Rust/macFUSE instructions. Proof: `mdtool check README.md docs` clean; reviewer reads the contract list in Execution boundary.

### P3 — Optimization (2 lanes)

- **`O1` Benchmark and measure.** Owns `benchmarks/**`, `docs/performance.md`. Does: measure engine-level workloads (root and large-directory listing, metadata lookup, small-file open, cold/warm sequential read, random read from a large file, many small writes, large sequential write, partial overwrite, sync, concurrent ops, unmount with and without dirty state) recording latency, request count, bytes, peak RSS, cache hit rate, disk-cache consumption, and DB size; optimize only demonstrated bottlenecks. Run time-based gates only when `perf-gate-ready` exits 0; if the host stays busy, state "perf gate deferred: host busy" and do not count it as a pass. Proof: `docs/performance.md` numbers against the P2-end baseline.
- **`O2` FSKit data cache, only if measured.** Adopt `FSVolume.DataCacheHandler` only if a measurement shows it preserves coherency and improves a real workload; otherwise drop it. Proof: the measurement or its absence.

### P4 — Close (1–2 lanes)

- **`X1` Remove the legacy tree and close.** Owns the repo root, `.github/**`, `Cargo.*`, `rust-toolchain.toml`, `sample_config.toml`, `src/**`. Does: delete Rust, Cargo, macFUSE/FUSE references, legacy CI, and the stale `target/` tree; migrate anything deliberately kept; verify a clean checkout builds with `make`; run the full suite; run `ultrareview` and fix its P1 and P2 findings; write the final report (build/test commands, parity results, measurements, remaining limitations, the parked signing prerequisite). Proof: `git ls-files` shows no Rust/Cargo/FUSE; clean-checkout `make` and the full suite pass.

### P5 — Owner manual verification (`M1`, absolute last, owner-run)

- **`M1` Real Drive and auth flow.** The owner supplies a signing identity with the two entitlements, builds, runs `gcsf login`, `gcsf list`, `gcsf verify`, mounts a real account at a POSIX path, exercises POSIX operations, unmounts, and cleans up. This is the only step that touches a real Drive. The executor stops before it, prepares `make doctor`, the instructions, and this document's "For the owner afterwards", and does not wait on it.

## Acceptance

Each deliverable and the command or test that proves it. Nothing here waits on a person except `M1`, which is explicitly owner-run and last.

| # | Deliverable | Proof |
|---|---|---|
| 1 | CLI | `swift build` then `.build/debug/gcsf --help`; `login/list/verify/logout` covered by offline tests; `mount/umount` compile and are parked at runtime |
| 2 | `GCSFCore` | `swift test` — unit, FakeDrive, and fault-injection suites green |
| 3 | FSKit extension | `make build`; extension sources typecheck under `-swift-version 6 -strict-concurrency=complete` |
| 4 | Host app | `make build` produces `GCSFHost.app` embedding `GCSFExtension.appex` |
| 5 | Offline verification | `swift test` green with the ported 16 categories driving the handler API; `docs/parity.md` complete |
| 6 | Makefile | `make` and `make doctor` succeed; target table present |
| 7 | Legacy removal | `git ls-files` shows no `Cargo.*`, `src/**` Rust, or FUSE/macFUSE references |
| 8 | Owner verification | `M1`, owner-run, last |

**Parked, cannot pass here** (no item claims them): kernel mount of any volume; extension registration/enablement; `make smoke`; `make test-live`. Unblocking prerequisite: decision 1's signing identity. The executor reports these as parked with the exact missing prerequisite.

`make test-live` never runs unless the owner authorizes it later against an isolated folder.

## Execution boundary

**Authorized:** edits to files in this repository; local commits on a feature or `master` branch; local Swift, SwiftPM, and Xcode builds; running offline and mock test suites; creating `.work/` worktrees and scratch; installing the local `.app` for registration experiments only if a signing identity later exists.

**Forbidden (park instead):** pushing to any remote; any real Google Drive read or write; running `make test-live`; requesting, creating, or installing signing identities or provisioning profiles; changing System Settings security or FSKit enablement; adding third-party package dependencies; deleting anything outside this repo; touching `~` outside the config directory and only through the migration with its safety steps.

**Contract changes made (for the owner):**

1. Config format changes from TOML to a new Swift-native format, with migration; the OAuth client identity is preserved.
2. Google-native documents become read-only; writing to an export now fails instead of uploading exported bytes.
3. Refresh tokens move from the yup-oauth2 token file into the Keychain; the legacy file is kept until migration is verified.
4. Runtime mounting requires the two FSKit entitlements, which do not exist on this machine yet.

## Non-goals

Google import/convert-on-write; sharing/permissions UI; multi-user or additional shared-drive behavior beyond the existing baseline; menubar app, SwiftUI, or any GUI beyond the minimal host; Linux or Windows; faking a block device or disk image; the FSKit data cache unless `O2` measures it beneficial; live-Drive testing; mounting before a signing identity exists; SQLite wrapper libraries; any third-party runtime dependency; a standalone daemon; HTTP or TLS implemented by hand.

## Reference

**Architecture.**

```text
POSIX / Finder / CLI → Apple FSKit → GCSF FSKit extension
  → Engine (lookup, enumerate, attributes, xattrs, exports, policy)
      / Metadata Index (SQLite)   \ Content Cache (disk-backed blocks)
  → Drive service → Drive REST client → URLSession → Google Drive API v3
```

**Makefile targets.**

| Target | Purpose |
|---|---|
| `make` | Build all components, run offline tests, verify output (no credentials, no real Drive) |
| `make doctor` | Toolchain, OS, SDK, arch, signing, entitlement, extension enablement, mounted volumes |
| `make build` | Build the complete native product |
| `make test` | Unit, mock integration, and concurrency tests |
| `make smoke` | Register and mount the offline synthetic filesystem (parked without signing) |
| `make install` | Install the local app/CLI without modifying security policy |
| `make mount SESSION=<name>` | Mount an authenticated session (`gdrive://<name>`) |
| `make umount` | Unmount cleanly |
| `make test-live` | Explicitly authorized real-Drive tests (never run unless authorized) |
| `make clean` | Remove generated local build artifacts |

**Verified code map (the Rust reference being replaced).**

- `src/gcsf/drive_facade.rs:42` whole-file LRU content cache (not to be reproduced); `:648` `read`; `:960` `flush_inner` (download-modify-upload); `:1088` `upload_resumable`.
- `src/gcsf/file_manager.rs:550` duplicate-suffix recalculation; `:34` drive-id map; `:52` `skip_trash`; `:236` `populate_trash`.
- `src/gcsf/filesystem.rs:39` `reject_if_readonly!` (`EROFS` at `:43`); shutdown `EIO` at `:47`.
- `src/gcsf/file.rs:128` `EXTENSIONS` (Docs/Sheets/Slides/Drawings/Sites export map).
- `src/gcsf/auth.rs:19` yup-oauth2 token format; `:47` `headless_login`.
- `src/gcsf/config.rs:35` `client_secret`; `:128` `token_file`.
- `src/main.rs:141` `Command` enum; `:406` `DEFAULT_CONFIG` with the shipped OAuth client; `:590` session listing.
- `tests/integration/test_filesystem_operations.sh` 16 categories (lines 253–1020).
- `sample_config.toml:56` shipped client secret.

**Verified SDK facts (SDK MacOSX27.0).**

- `/Applications/Xcode.app/.../MacOSX27.0.sdk/System/Library/Frameworks/FSKit.framework/Headers/FSClient.h` — `mountSingleVolume(resource:bundleID:options:)` (V3) and `openFileSystemExtensionsSettings`; needs `com.apple.developer.fskit.mount`.
- `FSResource.h:392` — `FSGenericURLResource(url:)`; scheme declared via `FSSupportedSchemes`.
- `FSKitDefines.h:51` — `FSKIT_API_AVAILABILITY_V3` = `API_AVAILABLE(macos(27.0))`.
- `FSVolume.h:472` — `FSVolume.Operations` deprecated with replacement `FSVolumeHandler`.
- `FSUnaryFileSystem.h` — `probeResource`/`loadResource`/`unloadResource`.
- Installed OS modules `/System/Library/ExtensionKit/Extensions/com.apple.fskit.{ftp,msdos,exfat}.appex` — authoritative Info.plist shapes; FTP is the generic-URL model.
- Xcode template `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Templates/Project Templates/macOS/Application Extension/File System Extension.xctemplate/`.

**Background references.** Upstream repositories to study: `ebreen/cloudmount` (native Swift FSKit filesystem over a remote backend), `indragiek/GHFS` (FSKit lifecycle, item registry, caching), `KhaosT/FSKitSample` (minimal). API docs: Apple FSKit, App Extension and ExtensionKit, Drive v3 files/changes/about, resumable uploads. `FSGenericURLResource` needs `FSSupportsGenericURLResources = true` and `FSSupportsBlockResources = false`.

## Decision log

Append-only, one line per judgment call a reader would otherwise miss (the call and why). Seeded by preflight:

- 2026-10-16 — Mounting goes through `FSClient.mountSingleVolume`; it is the only SDK path for a generic-URL module.
- 2026-10-16 — Index is SQLite; the system library satisfies the durability requirement without a dependency.
- 2026-10-16 — Probe typechecked clean under strict concurrency; treated as the extension starter.
- 2026-10-16 — Runtime gates parked; acceptance rewritten so nothing claims a mount it cannot make.

## Campaign log

Append-only, one line per phase end.

## For the owner afterwards

- Read `docs/parity.md` (behavior→test map), `docs/performance.md` (measurements), and the final report.
- Cherry-pick or review the contract changes listed in Execution boundary before using it on a real account.
- To reach your actual goal — mounting your Drive — provide a signing identity with `com.apple.developer.fskit.fsmodule` and `com.apple.developer.fskit.mount`, then run `M1` yourself.
