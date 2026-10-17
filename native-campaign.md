# GCSF Native Swift / FSKit Rewrite — Campaign

**Status.** Ready to execute. Preflight completed Fri Oct 16 2026. The foundation is the typechecked probe at `dev/probes/FSKitProbe.swift` (see Baseline). Runtime mount and extension registration stay parked on this machine. It has no signing identity (see Decisions → Owner-decided 1).

**Completion.** The autonomous campaign ends **implementation-complete, runtime-unverified**. That status means the tree builds, the offline suites pass, and the Rust sources are gone from the work tree. It does not mean GCSF has mounted a filesystem. A strict-concurrency typecheck shows that the extension matches the SDK interfaces. It does not show lifecycle, POSIX behavior, kernel cache coherency, or a successful Drive write. Production-complete requires a passing `M1` and a clear `M2`. A failed `M1` check reopens the implementation item that owns the failure. `P3` does not start until that mount works.

**Goal.** Replace the Rust and macFUSE GCSF with a native Swift 6.4 / FSKit macOS 27 app that serves one Google Drive account as a volume. One repository, one top-level `make`, Swift 6 language mode with complete concurrency checking, no Rust, no FUSE, no third-party runtime. The scope is exactly "mount my Drive": no extra workflows.

**Deliverables.**

1. `gcsf` CLI: `login`, `logout`, `list`, `verify`, `mount`, `umount`. `mount` takes a session and prints the URL that FSKit returns. It does not take a mount directory.
2. `GCSFCore` Swift package: URLSession Drive client, PKCE OAuth and Keychain, new Swift config format with migration from the legacy TOML, durable SQLite metadata index, bounded disk-backed read cache, safe writeback (staging, resumable upload, fail-closed conflict), changes-feed sync, filesystem engine.
3. `GCSFExtension.appex`: native FSKit `UnaryFileSystemExtension` on the V3 `FSVolume.Handler` protocol family, served from `GCSFCore`, one volume per `gdrive://<session>` URL resource.
4. `GCSFHost.app`: minimal headless host bundling the extension.
5. Offline verification at two levels. Level 1 is the engine against `FakeDrive`. Level 2 is `DriveClient` against controlled HTTP fixtures. Level 3, the signed FSKit mount, is specified and left unverified.
6. Root `Makefile` with the target table in Reference.
7. A local tag `legacy-rust` on the last commit that still contains the Rust tree, then Rust, Cargo, and FUSE removed from the work tree. README and docs rewritten.
8. Owner runtime verification (`M1`) and the fix cycle it opens (`M2`). See Sequence. The executor stops before `M1`.

**Ceiling on this machine.** Deliverables 3 and 5 are built and compile-verified. Their runtime gates (kernel mount, extension registration, Keychain sharing, container access) cannot pass without a signing identity carrying `com.apple.developer.fskit.fsmodule` and `com.apple.developer.fskit.mount`. No item claims a successful runtime mount.

## Charter

- **Decide, log the call, and keep going.** Within the execution grant (Execution boundary), decide and proceed without waiting for approval. A plan does not grant permission. Park an item that needs authority outside the grant. Run until every autonomous deliverable is met or every remaining item is parked.
- **Hard stops** (each parks the item, never the campaign): an irreversible or outside-the-repo action; a boundary the doc forbids; a loop that cannot check anything. **Pushing is always forbidden.**
- **Fix on the way what is egregious**, in its own commit, to stated thresholds: a command over 2 minutes that is on the item loop; a regression of more than 1.5× against the Baseline numbers; a test red on the Baseline that blocks the item. Record anything else seen and leave it.
- **Parity before optimization.** Every reference behavior gets a test that fails if it is wrong before any performance work. `P3` stays behind a successful `M1`.
- **Keep bookkeeping minimal.** No provenance, checksums, or pinned hashes.
- **Schedule by dependency readiness.** Start a lane when its prerequisites have landed and its files are free. The memory caps are **≤3 GiB peak RSS per lane** and **≤10 GiB total** of build artifacts and caches (58 GiB free on `/System/Volumes/Data`). Do not start a lane to fill a count. Never swap or OOM.
- **Worktrees and working state live under `.work/` in this repo, never `/tmp`.** Lane worktree `.work/wt/<lane>`. Scratch `.work/tmp`, with `TMPDIR` pointed there for commands that spill large files. `.work/` stays ignored via `.git/info/exclude`. Follow `orchestrate`'s worktree lifecycle. Retain a worktree at closeout only when clean, named in the handoff, and allowed by the closeout guard.
- **Every commit is a Conventional Commit**, scope = workstream (`engine`, `drive`, `cache`, `fskit`, `verify`, `docs`, `build`). The item ID goes in the body, never the subject.
- **Code comments never cite this doc.** Write no comment a name, type, test, or lint could carry.
- **Two loop speeds.** An item ends on the narrowest check that covers it. A phase ends on the checks for the areas it touched. The full suite runs at the end of P1, P2, and P4, each with its reason.
- **Time-box a failing item** at 5 attempts, then park it with a finding and continue with the next independent item.

## Decisions

### Owner-decided (Fri Oct 16 2026)

1. **Signing: no identity available.** All runtime mount and extension-registration gates are parked. The campaign delivers buildable code and offline verification only. It must not claim runtime success. Unblocking prerequisite, named for the owner: an Apple Development identity plus macOS App Development provisioning profiles granting `com.apple.developer.fskit.fsmodule` (extension) and `com.apple.developer.fskit.mount` (mounting client).
2. **Live Drive tests: parked.** Implement `make test-live` and its docs, but never run against a real Drive. Run only when the owner explicitly authorizes it later against an isolated folder.
3. **Config: new Swift-native format.** Replace the TOML config with a new Swift-native format and migrate existing settings. Reuse the **same OAuth `client_id` and `client_secret` the user's existing config carries** so existing refresh tokens keep working. Refresh tokens are bound to the issuing client, so a different client would force full re-authentication. Move only the refresh token into the Keychain.
4. **Google-native documents: read-only, no import workflow.** Writes to exported Docs, Sheets, Slides, Drawings, and Sites fail with a clear read-only error. No Drive import or convert-on-write. This is a deliberate change from the Rust behavior and it is the intended contract.

### Prescribed

- **Mount mechanism.** The CLI calls `FSClient.shared.mountSingleVolume(resource:bundleID:options:completionHandler:)` (`FSClient.h:36-53`). The resource is an `FSGenericURLResource` whose URL is `gdrive://<session>` (`FSResource.h:392`). The options array is the `mount_XXX` strings the header documents. The call does not take a mount-point argument. The system creates the mount point under `/Volumes/` and the completion handler returns that URL. `gcsf mount -s <session>` prints the URL and persists it on the session. `gcsf umount -s <session>` passes that persisted URL to `umount(8)`. A positional mount directory is a usage error. `FSVolume.name` is the session name. The SDK does not say that this name becomes the directory under `/Volumes`. Treat any such mapping as a hypothesis until `M1` prints the returned URL. This mount path needs `com.apple.developer.fskit.mount` on the mounting client, which is parked with decision 1. Reason: it is the only SDK-provided mount path for a generic-URL module.
- **Extension metadata.** Info.plist `EXAppExtensionAttributes`: `EXExtensionPointIdentifier = com.apple.fskit.fsmodule`, `FSSupportsGenericURLResources = true`, `FSSupportsBlockResources = false`, `FSSupportsPathURLs = false`, `FSSupportedSchemes = ["gdrive"]`, `FSShortName = gcsf`. Model on the installed FTP module (`/System/Library/ExtensionKit/Extensions/com.apple.fskit.ftp.appex/Contents/Info.plist`). Reason: it is the OS's own generic-URL FSKit shape.
- **Entry point.** Use `UnaryFileSystemExtension`. `FileSystemExtension` (full FSKit) is `@available(macOS, unavailable)` in SDK 27.0. Reason: verified in the SDK.
- **Handler protocols.** Conform to `FSVolume.Handler`, `FSVolume.ReadWriteHandler`, `FSVolume.XattrHandler`, and `FSVolume.DataCacheHandler`. `FSVolume.Operations` is deprecated and must not be used. `DataCacheHandler` supplies its own open and close. Do not also conform to `FSVolume.OpenCloseHandler`. Reason: `FSVolume.h:472`, `FSVolumeDataCacheHandler.h:115-171`, and the proven probe. Kernel cache below sets the policy. `O2` may relax it only after `M1`.
- **Kernel cache.** A volume that does not conform to `DataCacheHandler` can still be cached by the kernel, and the extension cannot control that cache (`FSVolumeDataCacheHandler.h:112-113`). Remote Drive changes make that a correctness problem. Conform to `DataCacheHandler` and grant `FSVolume.KernelCacheCoherencyType.noCache` from every `open`. The header allows `noCache` for `DataCacheMode.none`, `readWithCache`, and `readWriteWithCache` (`FSVolumeDataCacheHandler.h:84-90`). On a remote content change, call `FSVolume.setCacheState` with `invalidate`. On a remote delete or permission loss, call it with `revoke`. `setCacheState` returns `ENOTSUP` unless the volume conforms to `DataCacheHandler` (`FSVolume.h:1819-1820`). Granting `noCache` is the initial policy. `O2` may grant a more permissive type only after `M1`, and only with a measurement that remote changes stay visible. Kernel obedience to `noCache` is level 3 and stays unverified here.
- **Security and storage boundary.** The CLI, the host, and the sandboxed extension are separate signed processes. `F0` freezes their shared contract in `docs/runtime-contract.md` before `D2` stores a credential and before `C2` stores a durable file. The contract names: one Keychain access group shared by all three targets; the data-protection keychain (`kSecUseDataProtectionKeychain`) unless the SDK shows the extension cannot read it, in which case `F0` parks credential migration; the entitlement set on each target (`keychain-access-groups`, `com.apple.security.network.client` on the process that calls Drive, the two FSKit entitlements, and an app group if the container is shared); the single directory that holds the SQLite index, the writeback journal, staged bytes, the disk cache, and the config. The extension is the process that serves the mount, so it must be able to open that directory and the refresh token. The CLI must be able to open the same directory during migration. `F0` checks that the access-group string and the container path are the same in every target's entitlements and in code. A runtime read from the extension is parked with decision 1. `D2` does not invent a second location.
- **Durability and conflict.** The index and the writeback journal share one state machine. The states are `staged` (bytes on disk, journal entry not durable), `journaled` (intent durable, Drive has not acknowledged it), `committed` (Drive acknowledged this revision), and `conflicted` (the remote head moved, staged bytes kept, the original file not overwritten). Crash recovery reconciles the journal with the SQLite index in that vocabulary. `staged` with no journal entry is deleted. `journaled` resumes an upload session if one exists, otherwise revalidates the head revision. `committed` drops the staged bytes and the index stores the acknowledged revision. `conflicted` keeps the staged bytes and does not upload over the original file. `FSVolume.Handler.synchronize` succeeds only when every dirty item is `committed` or an uploaded conflict copy has reached `committed`. Apple's header says that after `synchronize` returns, FSKit assumes pending I/O and metadata have been sent to the backing resource (`FSVolume.h:438-441`). A durable local journal is not that assumption. When Drive is unreachable and any item is `staged`, `journaled`, or `conflicted` but not yet uploaded, `synchronize` throws and the bytes stay in the journal. The errno is an executor choice, logged. Drive v3 `files.update` does not document a compare-and-swap, and `If-Match` is not a claim this campaign accepts from secondary reports. A precondition header may ship only after a level 2 fixture shows the client sends it and, after the owner authorizes `make test-live`, a live check shows Drive rejects the stale write. Until that live check passes, revalidation is best-effort. On a mismatched head revision, do not update the original file. Preserve the staged bytes, create a new Drive file under a deterministic conflict name, and upload the staged bytes there. Record the conflict on the index row.
- **Metadata index.** SQLite via the system `libsqlite3` (no wrapper dependency). Reason: stable inodes, parent and child lookup, and crash recovery need durable relational state. The system supplies it.
- **Xcode project committed directly.** Reason: owner asked. XcodeGen and tuist are not installed.
- **Preserve** the CLI commands other than the mount directory, the config dir and session names, the `user.gcsf.*` xattr namespace, the Google export MIME map and synthetic extensions, Trash and `skip_trash`, and drive-id ordering for the initial duplicate suffix. Reason: these are the compatibility baseline.
- **Duplicate names, once assigned, stay put.** When a new file appears whose Drive ID sorts earlier than an existing sibling with the same base name, the existing user-facing name does not change. The new file takes the next suffix. Suffixes persist in the index and survive restart. This differs from `recalculate_duplicate_suffixes_for_parent` (`src/gcsf/file_manager.rs:550`), which re-sorts and can move the unsuffixed name. The probe for this behavior is an `E2` test.
- **Parity register** built as `reference-parity` describes, at `docs/parity.md`. `V` is the only editor. Other lanes expose behavior through test names.

### Delegated

Executor decides inside the bound and logs the call:

- Config file encoding (plist or JSON) inside the new format. The owner chose "new format", not the encoding.
- Cache block size, read-ahead depth, and eviction limits. All bounded and configurable.
- The conflict-copy file name pattern, and the errno `synchronize` throws while bytes are uncommitted.
- Concrete Swift module and target names below the fixed `GCSFCore`, `gcsf-cli`, `GCSFTestSupport`.
- Bounded concurrency widths, page sizes, and queue depths.

## Baseline

**Toolchain and host.** macOS 27.0 (26A428). Xcode 27.0 (27A266a). Swift 6.4 (swiftlang-6.4.0.34.1). SDK MacOSX27.0. arm64 (MacBookPro18,3, 10 cores, 32 GiB RAM, 58 GiB free).

**Loop timings (measured in preflight).**

| Check | Time |
|---|---|
| Single-file full-FSKit-conformance `swiftc -typecheck` | 0.42 s |
| SwiftPM cold build (1 target + 1 test target) | 18.8 s |
| SwiftPM warm no-op `swift build` | 2.5 s |
| SwiftPM incremental (1 file touched) | 0.6 s |
| `swift test` (1 test) | 5.4 s |

Target: keep the per-item loop under 30 s. The loop is not the bottleneck. No P0 loop-repair item is needed.

**Reference (the Rust implementation being replaced), at `f1828ce`.** `cargo test` → **52 passed, 0 failed** (unit tests: drive-facade write and read semantics, file-manager duplicate suffixes, filesystem xattrs, mount options, read-only). `tests/integration/test_filesystem_operations.sh` defines 16 categories (`test_file_creation` through `test_drive_xattrs`, lines 253–1020) with a 64 MiB sequential-read limit of 5 s. It needs a live mount and Drive and was not run. The reference has no recorded performance numbers. `O1` records offline numbers and, after `M1`, end-to-end numbers, in separate tables.

**Known failures on the baseline.** None. The Rust suite is green. The Swift tree does not exist yet. There are no pre-existing reds the executor should discount.

**Foundation proof.** `dev/probes/FSKitProbe.swift` is a complete `UnaryFileSystemExtension` `@main` plus a full `FSVolume.Handler`, `ReadWriteHandler`, and `XattrHandler` conformance. It typechecks clean under `swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -sdk <MacOSX27.0.sdk> -target arm64-apple-macos27.0` in 0.42 s. This confirms the V3 handler protocols exist, are Swift-callable, and that FSKit's Objective-C completion handlers auto-import as `async throws` Swift methods. `F0` starts the extension target from this file. The probe is interface evidence. It is not a mount.

## Sequence

A lane starts when its prerequisites have landed and no other lane owns its files. P1 is a dependency graph, not a five-wide fan-out. `D2` waits on the `F0` security contract and on `D1`. `C2` waits on `C1`. `V1`'s proof waits on the engine and client items it maps. `F1` waits on `V0` for `FakeDrive` and does not wait on OAuth.

| WS | Owns |
|---|---|
| **E** Engine and Index | `Sources/GCSFCore/Model/`, `Index/`, `Engine/`, `Tests/GCSFCoreTests/IndexTests.swift`, `EngineTests.swift` |
| **D** Drive, Auth and Config | `Sources/GCSFCore/Drive/`, `Auth/`, `Config/`, `Tests/GCSFCoreTests/DriveClientTests.swift`, `AuthTests.swift`, `ConfigTests.swift` |
| **C** Cache, Writeback and Sync | `Sources/GCSFCore/Cache/`, `Writeback/`, `Sync/`, `Tests/GCSFCoreTests/CacheTests.swift`, `WritebackTests.swift`, `SyncTests.swift` |
| **F** FSKit, Host, CLI and Build | `Sources/GCSFCore/Contract/`, `Sources/GCSFCore/FSKit/`, `Sources/gcsf-cli/`, `Extension/`, `GCSF.xcodeproj/`, `Makefile`, `docs/runtime-contract.md` |
| **V** Verification | `Sources/GCSFTestSupport/`, `Tests/GCSFCoreTests/ParityTests.swift`, `tests/integration/`, `docs/parity.md` |

`Package.swift` is edited by `F0` only. `docs/parity.md` is edited by `V` only. `docs/runtime-contract.md` is edited by `F0` only. A later lane that needs a new contract method appends it, logs the addition, and keeps existing methods source-compatible.

### P0 — Ground (F, then V)

- **`F0` Scaffold, contracts, and build loop.** Owns `Package.swift`, `Sources/GCSFCore/Contract/**`, the other `Sources/**` stubs, `GCSF.xcodeproj/**`, `Extension/**`, `Makefile`, `.gitignore`, `docs/runtime-contract.md`. Does: SwiftPM package (`GCSFCore` lib, `gcsf-cli` exe, `GCSFTestSupport` lib) targeting macOS 27 in Swift 6 mode with complete concurrency. Xcode project committed directly with a host app and an FSKit appex. Start the appex from `dev/probes/FSKitProbe.swift`. Info.plist keys and entitlements come from Decisions → Prescribed, including the security boundary. Makefile with `build`, `doctor`, and `clean` functional and the rest declared. Freeze `DriveBackend`, the engine surface the adapter calls, `MetadataStore`, the cache, the writeback journal, and the adapter methods `C3` uses to invalidate or revoke a cached item in `Sources/GCSFCore/Contract/`. The journal protocol uses the four durability states. Write `docs/runtime-contract.md` with the access group, the keychain class, the container path, and which process reads each store. `make doctor` prints OS, Xcode, Swift, SDK, arch, the code-signing state, and `FSClient.shared.installedExtensions`. It does not open System Settings. `make doctor OPEN_SETTINGS=1` is the only path that calls `openFileSystemExtensionsSettings`. Proof: `make build` compiles the extension target with `CODE_SIGNING_ALLOWED=NO`. `swift build` succeeds. `make doctor` exits without launching an app. The access-group string in the three targets matches the contract doc.
- **`V0` Offline harness seam.** Owns `Sources/GCSFTestSupport/**`. Prereq: `F0`. Leaves `Tests/GCSFCoreTests/{Index,Engine,DriveClient,Auth,Config,Cache,Writeback,Sync,Adversarial}Tests.swift` for the lanes that own them. Does: deterministic `FakeDrive` conforming to `DriveBackend` (an in-memory Drive v3 subset), fixtures, and fault-injection switches (401, refresh failure, 403 and 429, 5xx, pagination edges, malformed metadata, timeouts, partial download, redirect, 308, indeterminate completion, cancellation). `FakeDrive` is level 1. It is not an HTTP fixture and it is not a kernel. Proof: `swift test` runs a FakeDrive round-trip.

### P1 — Parity

**E**

- **`E1` Durable index and identity.** Owns `Sources/GCSFCore/Model/**`, `Index/**`, `Tests/GCSFCoreTests/IndexTests.swift`. Prereq: `F0`. Does: SQLite schema (inode and Drive-id bijection, parent and child, name, assigned duplicate suffix, MIME, size, times, checksums, head revision, durability state, trashed, owner). Stable inodes across restart. Stable root. No inode reuse that aliases another live object. Deterministic enumeration order matching `src/gcsf/file_manager.rs:550` for a single snapshot. Cookies and verifier. Invalidation. Recovery from stale or missing rows. Single `MetadataStore` actor. The stored suffix is the user-facing name. Loading the index does not re-sort suffixes. Proof: index tests, including restart stability.
- **`E2` Engine semantics.** Owns `Sources/GCSFCore/Engine/**`, `Tests/GCSFCoreTests/EngineTests.swift`. Prereq: `E1`, `V0`. Does: lookup, attributes, xattrs, enumerate, create, rename, remove, and readlink with POSIX errno mapping. The engine calls `DriveBackend`. `user.gcsf.*` xattrs per `src/gcsf/filesystem.rs`. Export MIME map, synthetic extensions, and unexportable placeholders per `src/gcsf/file.rs:128` and `src/gcsf/drive_facade.rs`. Initial duplicate suffix by drive-id order, then the stability rule in Decisions → Prescribed, including a test that inserts a lexically earlier Drive ID beside an existing file. Trash and `skip_trash` per `src/gcsf/file_manager.rs:52,236`. Read-only `EROFS` per `src/gcsf/filesystem.rs:39`. Special dirs (My Drive, Trash, Shared with me). Proof: engine tests. `V` records the rows in `docs/parity.md`.

**D**

- **`D1` Drive REST client and models.** Owns `Sources/GCSFCore/Drive/**` (including the `DriveBackend` conformance, not the protocol file), `Tests/GCSFCoreTests/DriveClientTests.swift`. Prereq: `F0`. Does: URLSession client. Small Codable DTOs. Explicit query params and field masks. `files.list`, `get`, `create`, `update`, `delete`, and `export`. Content download. Multipart and resumable upload. `changes.getStartPageToken` and `list`. `about.get`. Pagination. 401 refresh hook. 403, 404, 409, 429, and 5xx mapping. Bounded backoff with jitter and respect for server retry instructions. Redirect policy that never forwards the bearer token cross-origin. Cancellation. Bounded buffering and streaming. Tests are level 2: a local HTTP fixture server, real `URLSession`, real request URLs, real response parsing. `FakeDrive` does not satisfy this item. Proof: fixture tests for pagination, 401 refresh, 308 recovery, indeterminate upload, redirect, and retry.
- **`D2` OAuth, Keychain, and config.** Owns `Sources/GCSFCore/Auth/**`, `Config/**`, `Tests/GCSFCoreTests/AuthTests.swift`, `ConfigTests.swift`. Prereq: `F0` (the runtime contract is frozen), `D1`. Does: PKCE authorization-code flow with cryptographic state over a loopback redirect, system browser, request ported from `src/gcsf/auth.rs:47`. Refresh token stored in the keychain class and access group from `docs/runtime-contract.md`. `TokenManager` actor with single-flight refresh. The new Swift config format plus TOML migration that reads the existing config's `client_id` and `client_secret` (`src/main.rs:406`, `src/gcsf/config.rs:35`) and session files (`src/gcsf/config.rs:128`). Config, index, journal, and cache paths come from the runtime contract. One-time session migration that is idempotent, verifies before deleting legacy credentials, and never logs secrets. CLI `login`, `logout`, `list`, and `verify`. Proof: migration idempotency, refresh single-flight, config round-trip, and a test that the Keychain query uses the contracted access group. A cross-process read by the extension is parked with decision 1.

**C**

- **`C1` Bounded read cache.** Owns `Sources/GCSFCore/Cache/**`, `Tests/GCSFCoreTests/CacheTests.swift`. Prereq: `F0`, `V0`. Does: range reads through `DriveBackend`. The cache does not open its own `URLSession`. Block and chunk caching. Disk-backed caching for large content. Sequential read-ahead. Coalescing of overlapping reads. Cancellation. Explicit eviction limits. Content-revision validation. Memory bounded independently of remote file size. This replaces the whole-file LRU at `src/gcsf/drive_facade.rs:42,648`. The larger-than-RAM proof uses a virtual or sparse fixture. The fixture reports a size larger than RAM and does not allocate those bytes. It stays inside the 10 GiB scratch budget. Proof: a random 64 KiB read against that fixture, plus partial-download and eviction-bound tests.
- **`C2` Writeback.** Owns `Sources/GCSFCore/Writeback/**`, `Tests/GCSFCoreTests/WritebackTests.swift`. Prereq: `C1`. Does: the durability state machine in Decisions → Prescribed, shared with the index. Disk-backed staging. Create, overwrite, append, truncate, and random writes. Rename, move, and delete. Resumable upload with committed-offset recovery and session query on indeterminate state. Best-effort head-revision revalidation. On mismatch, conflict-copy and no update of the original file. `synchronize` fails while any dirty item is uncommitted, including when the network is down. Crash recovery for each state. This replaces the download-modify-upload path at `src/gcsf/drive_facade.rs:960,1088` and keeps rollback of a failed local staging attempt. Level 1 tests drive the state machine through `FakeDrive`. Level 2 upload bytes stay in `D1`. Proof: kill during `staged`, resume from `journaled`, mismatch becomes `conflicted` without an update of the original, and `synchronize` throws while an item is `journaled`.
- **`C3` Change-feed sync.** Owns `Sources/GCSFCore/Sync/**`, `Tests/GCSFCoreTests/SyncTests.swift`. Prereq: `E1`, `V0`, `F0`. Does: apply `changes.list` pages through `DriveBackend`. The HTTP shape of `changes.list` is `D1`. Advance a persisted checkpoint only after changes are durably applied to the index. Remote rename, move, delete, trash, content, metadata, and permission loss. Replayed or duplicate events. Missing or rejected page tokens. A dirty local write is not invalidated out from under the journal. On a remote content change or delete of a clean item, ask the FSKit adapter to `invalidate` or `revoke` as Decisions → Kernel cache requires. Bounded, cancellable, and nonblocking. Proof: sync tests, including a remote change beside a `journaled` local write. The kernel dropping cached bytes is level 3.

**F**

- **`F1` FSKit adapter, host, and CLI mount.** Owns `Sources/GCSFCore/FSKit/**`, `Sources/gcsf-cli/**`, `Extension/**`, `GCSF.xcodeproj/**`, `Makefile`. Prereq: `F0`, `V0`. Does: an `FSVolume` subclass conforming to the handler protocols in Decisions → Prescribed, including `DataCacheHandler` granting `noCache`, and not conforming to `OpenCloseHandler`. Item registry. Async bridging with exactly-once callbacks, no network on callback threads, no locks across suspension points, no borrowed buffers escaping. Lifecycle and unmount with in-flight requests. `loadResource` returns one volume per `gdrive://<session>`, named with the session name. The host app bundles the extension. `gcsf mount -s <session>` calls `mountSingleVolume`, prints the returned URL, and persists it. `gcsf umount -s <session>` unmounts that URL. The adapter is developed against `FakeDrive` and the frozen contracts. It does not wait for `D2`. Proof: `make build`. Extension sources typecheck under `-swift-version 6 -strict-concurrency=complete`. **Runtime mount, registration, and the real mount URL are parked** (decision 1).

**V**

- **`V1` Offline parity register.** Owns `docs/parity.md`, `Tests/GCSFCoreTests/ParityTests.swift`, `tests/integration/**`, `Sources/GCSFTestSupport/**`. Prereq for the proof: `V0`, `E2`, `D1`, `C2`, `C3`. Work may start as soon as `V0` and `E1` have landed. Does: map every reference behavior, the 16 categories plus the 52 unit-test behaviors at `f1828ce`, to a test that fails if it is wrong. Level 1 tests call the engine and `FakeDrive`. They do not claim kernel enumeration. `enumerateDirectory` receives an `FSDirectoryEntryPacker` from FSKit. An in-process packer does not establish `readdir`. Those rows are level 3 and marked unverified. Level 2 rows point at `D1`'s HTTP fixtures. `V` is the only editor of `docs/parity.md`. Other lanes do not write it. Proof: `swift test` green, and the register marks each row as level 1, level 2, or level 3 unverified.

### Test levels

| Level | What a passing test establishes | When it runs |
|---|---|---|
| 1. Engine and `FakeDrive` | File semantics, identities, suffix stability, journal recovery, conflict state | Autonomous, in process |
| 2. `DriveClient` and HTTP fixtures | `URLSession` request shape, response parsing, retries, redirects, 308 handling | Autonomous, in process |
| 3. Signed FSKit mount | Kernel lifecycle, POSIX behavior, `FSDirectoryEntryPacker` enumeration, real cache invalidation, the URL `mountSingleVolume` returns | After decision 1, under `M1` |

Level 1 and level 2 are the offline campaign. Neither level is a stand-in for level 3. Do not add a mock of FSKit's kernel objects to promote a row from level 3 to level 1.

### P2 — Hardening (E, C, V, docs)

- **`H1` Adversarial matrix.** Owns `Tests/GCSFCoreTests/AdversarialTests.swift`. May append fault switches in `Sources/GCSFTestSupport/**`. Does: tests and POSIX error mapping for empty files, multi-gigabyte files represented by the sparse fixture, sparse writes and truncation, Unicode normalization, duplicate names, case-fold collisions, very long names, path traversal, root protection, interrupted enumeration, concurrent rename and lookup, delete-while-open, disconnect during writeback, network down at mount and after mount, remote edit during local edit, process kill during write, abrupt restart, repeated mount and unmount at the engine boundary, cache corruption recovery, quota exhaustion, and revoked credentials. The larger-than-RAM cases use the `C1` sparse fixture. Proof: the added tests fail if the behavior regresses.
- **`H2` Contract changes and docs.** Owns `README.md` and `docs/**` except `docs/parity.md` and `docs/runtime-contract.md`. Does: write up the config-format change, the Google-native read-only contract, the secrets and Keychain move, the shared access group and container, session migration, cache and staging locations, the four durability states, conflict copies, unmount behavior, the mount-URL CLI, and limitations. Name the signing prerequisite. Remove obsolete Linux, Rust, and macFUSE instructions. Proof: `mdtool check README.md docs` clean. The reviewer reads the contract list in Execution boundary.

### P3 — Optimization (after `M1`, not part of the autonomous campaign)

The executor does not start `P3`. It starts after `M1`'s mount, POSIX exercise, and unmount have succeeded. Offline measurements and end-to-end measurements go in separate tables. An offline number does not establish mount or network performance.

- **`O1` Benchmark and measure.** Owns `benchmarks/**`, `docs/performance.md`. Does: measure the workloads that the signed mount can actually run (root and large-directory listing, metadata lookup, small-file open, cold and warm sequential read, random read from a large file, many small writes, large sequential write, partial overwrite, sync, concurrent ops, unmount with and without dirty state). Record latency, request count, bytes, peak RSS, cache hit rate, disk-cache consumption, and DB size. Optimize only demonstrated bottlenecks. Any engine-only benchmark from the unmounted tree is labeled offline and kept in its own table. Run time-based gates only when `perf-gate-ready` exits 0. If the host stays busy, state "perf gate deferred: host busy" and do not count it as a pass. Proof: `docs/performance.md` with the two tables separated.
- **`O2` More permissive kernel caching, only if measured.** Prereq: `O1` on a signed mount. Does: keep `DataCacheHandler`. Try a coherency type more permissive than `noCache` only when a real workload improves and a remote change is still visible after invalidation. Do not add `OpenCloseHandler`. If the measurement is absent or the remote change stays stale, leave `noCache` in place. Proof: the measurement, or a decision-log line that `noCache` stays.

### P4 — Close (1–2 lanes)

- **`X1` Tag the legacy tree, then remove it.** Owns the repo root, `.github/**`, `Cargo.*`, `rust-toolchain.toml`, `sample_config.toml`, `src/**`. Does: create a local annotated tag `legacy-rust` on the current HEAD while the Rust tree is still in that commit. Record the tag name and SHA in the decision log and in the final report. Do not push the tag. Then delete Rust, Cargo, macFUSE and FUSE references, legacy CI, and the stale `target/` tree from the work tree. Git still has the reference implementation at `legacy-rust`. Migrate anything deliberately kept. `make clean` removes generated build products only. It does not delete the SQLite index, the journal, staged bytes, conflict copies, Keychain items, or the tag. `X1` does not run a clean that removes those. Verify a clean checkout builds with `make`. Run the full suite. Run `ultrareview` and fix its P1 and P2 findings. Write the final report (build and test commands, parity results with test levels, remaining limitations, the parked signing prerequisite). The report's status line is implementation-complete, runtime-unverified. Proof: the tag resolves to a tree that still contains `src/gcsf/`. `git ls-files` on HEAD shows no Rust, Cargo, or FUSE. Clean-checkout `make` and the full suite pass.

### P5 — Owner runtime verification (`M1`, then `M2`)

The executor stops before `M1`. It leaves `make doctor`, the instructions, and "For the owner afterwards" ready. It does not wait on `M1`.

- **`M1` Real Drive, real mount.** The owner supplies a signing identity with the two entitlements, builds, and runs `gcsf login`, `gcsf list`, and `gcsf verify`. The owner runs `gcsf mount -s <session>` and records the URL the command prints. The owner exercises POSIX operations on that URL, including a remote change becoming visible, a conflicting write producing a conflict copy, `synchronize` failing while offline with a dirty file, and unmount. The owner cleans up. This is the first step that may touch a real Drive. A failed check reopens the owning item: mount URL or lifecycle reopens `F1`; extension auth or container access reopens `F0` and `D2`; stale bytes reopens `C3` and `F1`; a lost or overwritten remote write reopens `C2`.
- **`M2` Signed-runtime fix cycle.** For each failed `M1` check, fix the reopened item and rerun that check. `M2` ends when every `M1` check that the owner attempted has passed, or when the owner parks one with a named SDK or account limit. The tree is not production-complete while a failed check is open. `P3` waits until `M1` has succeeded.

## Acceptance

The executor's last autonomous step is `X1`. Nothing in the autonomous table waits on a person. `M1` and `M2` are owner-run. `P3` waits on a successful `M1`.

| # | Deliverable | Proof |
|---|---|---|
| 1 | CLI | `swift build`, then `.build/debug/gcsf --help`. `login`, `list`, `verify`, and `logout` covered by offline tests. `mount` and `umount` compile, reject a positional directory, and are parked at runtime |
| 2 | `GCSFCore` | `swift test`. Level 1 FakeDrive suites and level 2 HTTP fixture suites green |
| 3 | FSKit extension | `make build`. Extension sources typecheck under `-swift-version 6 -strict-concurrency=complete`. The typecheck is interface evidence |
| 4 | Host app | `make build` produces `GCSFHost.app` embedding `GCSFExtension.appex` |
| 5 | Offline verification | `swift test` green. `docs/parity.md` lists level 1 and level 2 rows as tested and level 3 rows as unverified |
| 6 | Makefile | `make` and `make doctor` succeed. `make doctor` does not open System Settings. Target table present |
| 7 | Legacy removal | Local tag `legacy-rust` points at the Rust tree. `git ls-files` on HEAD shows no `Cargo.*`, `src/**` Rust, or FUSE or macFUSE references |
| 8 | Owner verification | `M1`, then `M2`. Not a step the executor marks done |

**Autonomous status when the table's proofs 1–7 pass:** implementation-complete, runtime-unverified.

**Parked, and no item claims them:** kernel mount of any volume; the URL `mountSingleVolume` will return; extension registration and enablement; a Keychain or container read from the running extension; kernel cache invalidation; `make smoke`; `make test-live`; any claim that a write cannot race another client. Unblocking prerequisite: decision 1's signing identity, plus an explicit owner authorization for `make test-live`.

`make test-live` never runs unless the owner authorizes it later against an isolated folder.

## Execution boundary

**Authorized:** edits to files in this repository; local commits on a feature branch or `master`; local Swift, SwiftPM, and Xcode builds; OS-managed build caches (SwiftPM and Xcode DerivedData) counted inside the 10 GiB budget; running offline and mock test suites; creating `.work/` worktrees and scratch; Keychain items in the single GCSF access group named by `docs/runtime-contract.md`, written only by the auth and migration code; creating the local `legacy-rust` tag; installing the local `.app` for registration experiments only if a signing identity later exists.

**Forbidden (park instead):** pushing to any remote; any real Google Drive read or write; running `make test-live`; requesting, creating, or installing signing identities or provisioning profiles; changing System Settings security or FSKit enablement; `make doctor` opening System Settings without `OPEN_SETTINGS=1`; adding third-party package dependencies; deleting anything outside this repo; reading or writing Keychain items outside the GCSF access group; deleting the index, journal, staged bytes, conflict copies, or the `legacy-rust` tag through `make clean`, `git clean`, or `X1`; touching other files under `~`.

**Contract changes made (for the owner):**

1. Config format changes from TOML to a new Swift-native format, with migration. The OAuth client identity is preserved.
2. Google-native documents become read-only. Writing to an export now fails instead of uploading exported bytes.
3. Refresh tokens move from the yup-oauth2 token file into the Keychain access group shared with the extension. The legacy file is kept until migration is verified.
4. `gcsf mount` no longer accepts a mount directory. It prints and stores the URL `mountSingleVolume` returns. The legacy command `gcsf mount <mount_directory> -s <session>` becomes a usage error.
5. An assigned duplicate suffix stays put when a lexically earlier Drive ID appears. Rust recalculation can rename the existing file. This campaign does not.
6. A successful `fsync` or `synchronize` means Drive has acknowledged the bytes, or an uploaded conflict copy. A durable local journal alone is not success.
7. Head-revision revalidation is best-effort. A detected mismatch keeps the staged bytes and writes a conflict copy. The campaign does not claim race-free overwrite.
8. Runtime mounting requires the two FSKit entitlements, which do not exist on this machine yet. The autonomous result is implementation-complete, runtime-unverified.

## Non-goals

Google import or convert-on-write. Sharing or permissions UI. Multi-user or additional shared-drive behavior beyond the existing baseline. Menubar app, SwiftUI, or any GUI beyond the minimal host. Linux or Windows. Faking a block device or disk image. Kernel caching more permissive than `noCache` before `O2` measures it on a signed mount. Live-Drive testing. Mounting before a signing identity exists. SQLite wrapper libraries. Any third-party runtime dependency. A standalone daemon. HTTP or TLS implemented by hand. An in-process FSKit mock that stands in for a kernel mount.

## Reference

**Architecture.**

```text
POSIX / Finder / CLI → Apple FSKit → GCSF FSKit extension
  → Engine (lookup, enumerate, attributes, xattrs, exports, policy)
      / Metadata Index (SQLite)   \ Content Cache (disk-backed blocks)
  → Drive service → Drive REST client → URLSession → Google Drive API v3
```

The CLI and the extension share the Keychain access group and the container in `docs/runtime-contract.md`. They do not share a process.

**Makefile targets.**

| Target | Purpose |
|---|---|
| `make` | Build all components, run offline tests, verify output (no credentials, no real Drive) |
| `make doctor` | Print toolchain, OS, SDK, arch, signing, entitlement, extension enablement, and mounted volumes. Does not open System Settings |
| `make doctor OPEN_SETTINGS=1` | `make doctor`, then `openFileSystemExtensionsSettings` |
| `make build` | Build the complete native product |
| `make test` | Level 1 and level 2 tests |
| `make smoke` | Register and mount the offline synthetic filesystem (parked without signing) |
| `make install` | Install the local app and CLI without modifying security policy |
| `make mount SESSION=<name>` | `gcsf mount -s <name>`. Prints and persists the returned URL |
| `make umount SESSION=<name>` | Unmount the URL persisted for that session |
| `make test-live` | Explicitly authorized real-Drive tests (never run unless authorized) |
| `make clean` | Remove generated build products. Leave the index, journal, staged bytes, conflict copies, Keychain items, and tags |

**Verified code map (the Rust reference being replaced).**

- `src/gcsf/drive_facade.rs:42` whole-file LRU content cache (not to be reproduced). `:648` `read`. `:960` `flush_inner` (download-modify-upload). `:1088` `upload_resumable`.
- `src/gcsf/file_manager.rs:550` duplicate-suffix recalculation (the new campaign keeps drive-id order for the first assignment and then stops renaming). `:34` drive-id map. `:52` `skip_trash`. `:236` `populate_trash`.
- `src/gcsf/filesystem.rs:39` `reject_if_readonly!` (`EROFS` at `:43`). Shutdown `EIO` at `:47`.
- `src/gcsf/file.rs:128` `EXTENSIONS` (Docs, Sheets, Slides, Drawings, and Sites export map).
- `src/gcsf/auth.rs:19` yup-oauth2 token format. `:47` `headless_login`.
- `src/gcsf/config.rs:35` `client_secret`. `:128` `token_file`.
- `src/main.rs:141` `Command` enum. `:406` `DEFAULT_CONFIG` with the shipped OAuth client. `:590` session listing. Mount usage is `GCSF mount [OPTIONS] <mount_directory>` with `-s` (`src/main.rs:54,87`). The native CLI drops `<mount_directory>`.
- `tests/integration/test_filesystem_operations.sh` 16 categories (lines 253–1020).
- `sample_config.toml:56` shipped client secret.
- `dev/probes/FSKitProbe.swift` typechecked FSKit starter.

**Verified SDK facts (SDK MacOSX27.0).**

- `FSClient.h:36-53`. `mountSingleVolume(resource:bundleID:options:completionHandler:)` mounts under `/Volumes/` and returns the mount URL. No mount-point parameter. Options are `mount_XXX` strings. Needs `com.apple.developer.fskit.mount`. `openFileSystemExtensionsSettings` opens System Settings.
- `FSResource.h:392`. `FSGenericURLResource(url:)`. Scheme declared via `FSSupportedSchemes`.
- `FSKitDefines.h:51`. `FSKIT_API_AVAILABILITY_V3` = `API_AVAILABLE(macos(27.0))`.
- `FSVolume.h:240-249`. The module sets `FSVolume.name`. The header does not define the mount directory.
- `FSVolume.h:438-441`. After `synchronize` returns, FSKit assumes pending I/O and metadata have been sent to the resource.
- `FSVolume.h:472`. `FSVolume.Operations` deprecated with replacement `FSVolumeHandler`.
- `FSVolume.h:1259-1306`. `FSVolume.OpenCloseHandler` is a separate open and close lifecycle. Do not stack it on `DataCacheHandler`.
- `FSVolume.h:1819-1820`. `setCacheState` returns `ENOTSUP` unless the volume conforms to `DataCacheHandler`.
- `FSVolumeDataCacheHandler.h:84-90`. `noCache` is a legal grant for every `DataCacheMode`.
- `FSVolumeDataCacheHandler.h:112-113`. Without `DataCacheHandler`, the kernel may cache the volume and the extension has no control over that cache.
- `FSVolumeDataCacheHandler.h:115-171`. `DataCacheHandler` defines `open` and `close`.
- `FSUnaryFileSystem.h`. `probeResource`, `loadResource`, `unloadResource`.
- Installed OS modules `/System/Library/ExtensionKit/Extensions/com.apple.fskit.{ftp,msdos,exfat}.appex`. Authoritative Info.plist shapes. FTP is the generic-URL model.
- Xcode template `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Templates/Project Templates/macOS/Application Extension/File System Extension.xctemplate/`.

**Background references.** Upstream repositories to study: `ebreen/cloudmount` (native Swift FSKit filesystem over a remote backend), `indragiek/GHFS` (FSKit lifecycle, item registry, caching), `KhaosT/FSKitSample` (minimal). API docs: Apple FSKit, App Extension and ExtensionKit, Drive v3 files, changes, and about, resumable uploads. `FSGenericURLResource` needs `FSSupportsGenericURLResources = true` and `FSSupportsBlockResources = false`.

## Decision log

Append-only, one line per judgment call a reader would otherwise miss (the call and why). Seeded by preflight:

- 2026-10-16 — Mounting goes through `FSClient.mountSingleVolume`. It is the only SDK path for a generic-URL module.
- 2026-10-16 — Index is SQLite. The system library satisfies the durability requirement without a dependency.
- 2026-10-16 — Probe typechecked clean under strict concurrency. It is checked in at `dev/probes/FSKitProbe.swift` and is the extension starter.
- 2026-10-16 — Runtime gates parked. Acceptance does not claim a mount this machine cannot make.
- 2026-10-16 — `mountSingleVolume` returns the mount URL and takes no path. The CLI prints and persists that URL. A requested mount directory is rejected.
- 2026-10-16 — Autonomous completion is implementation-complete, runtime-unverified. `M1` failure reopens the owning item (`M2`). `P3` waits on a successful mount.
- 2026-10-16 — `F0` freezes Keychain access group, data-protection keychain, and the shared container before `D2` stores a token.
- 2026-10-16 — `DataCacheHandler` with `noCache` is the initial coherency policy. `OpenCloseHandler` is not also adopted. Permissive caching is `O2`, after `M1`.
- 2026-10-16 — Overwrite safety is best-effort revalidation plus a conflict copy. `synchronize` succeeds only after Drive has the bytes.
- 2026-10-16 — Assigned duplicate suffixes are stable across a newly appearing, lexically earlier Drive ID.
- 2026-10-16 — `X1` tags `legacy-rust` locally before deleting the Rust tree. `make clean` does not remove journal or staged state.
- 2026-10-17 — `F0` merged. Contracts widened before P1: optional Drive id on metadata, checksum and owner fields, and `truncate` on the engine. `D2` does not edit `Sources/gcsf-cli` while `F1` owns that directory.

## Campaign log

Append-only, one line per phase end.

## For the owner afterwards

- Read `docs/parity.md` for the behavior-to-test map and its level column. Level 3 rows are unverified.
- Read `docs/runtime-contract.md` for the access group and the container path before using a real account.
- Read `docs/performance.md` only after `P3`. Until then there are no end-to-end numbers.
- Review the contract changes in Execution boundary. The mount command, duplicate-name stability, `fsync` meaning, and conflict copies differ from the Rust tool.
- The local tag `legacy-rust` is the Rust implementation. It was not pushed.
- To mount Drive, provide a signing identity with `com.apple.developer.fskit.fsmodule` and `com.apple.developer.fskit.mount`, then run `M1`. Record the URL `gcsf mount` prints. A failed check reopens that item under `M2`. The tree is production-complete only after `M2` is clear.
