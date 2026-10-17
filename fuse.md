# Campaign: Make GCSF a one-command macOS FSKit build

**Status:** Ready. This campaign does not authorize OS-level installation or extension registration.

On macOS 26+, make `make` build GCSF and prove a synthetic filesystem mounts through macFUSE's FSKit backend. Direct GCSF mounts must enforce FSKit too. Keep Linux build and mount behavior working.

Deliverables:

1. A documented, thin Makefile interface for diagnosis, build, tests, smoke mount, Drive mount, unmount, and clean.
2. Central macOS runtime enforcement of FSKit, including compatibility and mount-path validation, with no fallback to the kernel backend.
3. A credential-free, non-destructive FSKit smoke test with truthful backend evidence and reliable cleanup.
4. Updated quickstart and diagnostics that do not instruct users to enable or load a kernel extension.
5. Regression coverage for the changed macOS behavior and preserved Linux behavior.

## Charter

- Work autonomously within the execution boundary. Make and log reversible implementation decisions, then continue. Park an item only when it needs an effect outside that boundary or a check that cannot run on the host.
- The source tree at the campaign start is the baseline. Do not overwrite pre-existing user changes. Keep all scratch and worktrees under `.work/`; set `TMPDIR="$PWD/.work/tmp"` for commands that spill data. Ensure `.work/` is ignored via `.git/info/exclude` before writing there.
- Make the two ready workstreams below run concurrently, with a floor of two lanes and a ceiling of three. Give each lane its own detached worktree at `.work/wt/<lane>`. Measure peak memory and load after the first build wave; keep at least 8 GiB available to the host and do not swap. Add a third lane only for a disjoint ready slice and within that limit. Replace or resume a stopped lane in the same turn. Start later slices as soon as their prerequisites land; integrate completed work while the next wave runs. Run checks concurrently only on disjoint worktrees and inputs.
- The owner has not authorized commits. Do not commit or push. Lanes hand off uncommitted diffs; the integrator reviews and applies each disjoint patch, then verifies the integrated tree. Remove only clean, reviewed worktrees; keep any worktree with uncommitted work and report its path.
- Keep each lane to its owned files. Rust runtime policy, CLI mount flow, and Rust tests form one workstream because they share `src/main.rs`, `src/gcsf/config.rs`, and `src/tests.rs`. The Makefile, its optional small POSIX helper, and README form the other. The smoke harness belongs to the runtime workstream if it needs Rust changes; otherwise it belongs to the build workstream. The integrator owns cross-stream changes and verification.
- Feature behavior and test parity precede optimization or polish. Record build time and release binary size at baseline and close; they do not gate parity. Do not add dependencies unless required for a feature; any proposed dependency must state and measure build-time and binary-size impact. Preserve Cargo.lock and the pinned Rust toolchain.
- If a focused command takes over two minutes, first narrow or speed the loop without weakening the check. For a failing item, establish the cause before retrying; allow at most three distinct, evidence-based hypotheses, then park it with the failed observation and continue with independent work. Never retry the same failure hoping for a pass.
- Fix plainly broken campaign-path behavior when encountered if it blocks an item. Otherwise record it and stay in scope. No formatter, commit, push, CI/workflow edit, credential use, Drive connection, privileged install, kernel extension load, Recovery Mode change, or destructive mount action.
- The campaign changes the macOS mount contract: macOS mounts become FSKit-only and require macOS 26+, macFUSE 5.4+, and a `/Volumes` mount point. Linux behavior and the existing public CLI remain compatible. Document the contract in README and tests.

## Decisions

### Owner-decided

None. The draft already fixes the product scope at macOS 26+, Apple Silicon and Intel, FSKit-only, `/Volumes`, no Google credentials for the default target, and no kernel-extension path.

### Prescribed

- **Require macFUSE 5.4.0 or later.** macFUSE 5.2 release notes add its FSKit mounting API to both libfuse and libfuse3; macFUSE 5.4.0 is the first release after the reported FSKit small-write corruption in 5.3.3. Reverse this only with upstream release evidence and a passing write/read regression on that release. Keep the pinned `fuser` patch unless a real macOS build and mount prove a smaller fix works.
- **Build the mount options centrally.** Current `Config::fuser_config` forwards custom options, while `main.rs::mount_gcsf` uses that one config for both `NullFs` and GCSF. Put backend policy at that shared boundary so Make and direct CLI invocation cannot diverge. Reject any user-supplied `backend` except one `backend=fskit`; emit one effective option. Reject contradictions clearly.
- **Treat selection and observed backend as different proofs.** `backend=fskit` in the effective config proves selection intent. The smoke test must separately inspect available macFUSE/macOS mount or unified-log evidence for the active FSKit extension. If no stable, documented evidence exists, report that only selection plus usable mount was confirmed; do not claim independent identity. The default `make` still fails when it cannot perform the required smoke mount.
- **Keep application read-only semantics explicit.** FSKit opens files read/write and implements only a subset of kernel mount options. Verify macOS behavior against current macFUSE documentation. Preserve GCSF's write rejection for `read_only`; do not claim the OS mount itself is read-only if the backend ignores `ro`.
- **Keep system preflight read-only.** `doctor` reports exact missing/incompatible components and the official signed installer / System Settings action needed. It never downloads, installs, approves, or loads privileged components.
- **Use the existing `NullFs` path first.** It already runs through `mount_gcsf` when `mount_check` is enabled. Reuse the filesystem implementation and share the production config path; add a separate mount lifecycle only if the existing path cannot provide safe smoke cleanup.
- **No recurring defect class is established by this bounded task.** Prevent this campaign's likely repeat mistakes with policy tests: backend options are unique and centralized, macOS paths are checked before mounting, and every mount error has no retry/fallback branch.

### Delegated

- Choose the smallest implementation and exact test names within the owned files. Log any judgment that changes user-visible diagnostics or tool behavior in the decision log.
- For backend identity, use an authoritative, reproducible macFUSE/macOS interface if one is available during implementation. The tie-break above governs if investigation does not establish one.
- Keep all new Rust dependencies out. If an external dependency appears indispensable, park that item for owner review; no runtime owner decision is left open to a lane.

## Baseline

Baseline commit: current `master` worktree at preflight; the tree was clean except the untracked `fuse.md` draft. No `AGENTS.md` exists in this repository. Host: macOS 27.0, arm64, 32 GiB RAM, 10 CPUs, 65 GiB free disk. `pkg-config --modversion fuse3` reports 3.18.2 and its libdir is `/usr/local/lib`; this alone does not prove the library is from the official macFUSE installer or linked into GCSF.

Verified current code:

- `Cargo.toml` pins the `harababurel/fuser` fork at `3d6a8eccea86b89036e1e021e83ba88540863fc1`; the current repository claims the patch selects libfuse3 on macOS.
- `src/gcsf/config.rs::fuser_config` forwards custom options and translates `ro`, but does not centrally select FSKit or reject conflicting backends.
- `src/main.rs::mount_gcsf` uses the same config for its `NullFs` precheck and actual mount. The mount precheck does not exercise basic file operations and only runs when `mount_check` is true.
- Existing `src/tests.rs::mount_options_tests` cover config defaults, custom options, ACL, and read-only option uniqueness; they do not enforce FSKit or invalid-path behavior.
- `src/main.rs` and `README.md` still recommend approving/loading `macfuse.kext` and `kmutil load`.
- The README's macOS setup requires Homebrew/osxfuse, not the requested signed macFUSE 5 installer and Makefile workflow.

Known baseline failures: none observed in the focused mount-options tests; the full suite was not run during preflight. Preflight loop timing: `cargo test --lib mount_options_tests:: -- --nocapture` completed in 1.36 s (5 tests, 47 filtered). `mdtool check --untracked fuse.md` completed in about 4.5 s before this rewrite and reported no findings. The loop has reusable `target/debug` artifacts. No release build or mount was run during preflight. At campaign start, capture baseline `cargo test --lib`, `cargo build --release --locked`, binary size, `pkg-config` resolution, and `otool -L` output; keep these as campaign log entries, not new state files. Before a time-based performance gate, require `perf-gate-ready` to exit 0; run it again with `-1` immediately after the measurement or discard the result. If readiness fails, defer the gate and report exactly `perf gate deferred: host busy`. Record build-lane peak memory with `/usr/bin/time -l` and enforce the 8 GiB host reserve; binary size and memory limits always run. Do not run a broad integration suite until its phase gate below.

## Sequence

### P0 — Ground

**G0 — establish baseline and tool loop** (both lanes; integrator owns measurements). Record known baseline reds, the commands above, release build duration and binary size, macFUSE version, `pkg-config --cflags --libs fuse3`, and actual release binary linkage from `otool -L`. Prove which library Cargo selected and its resolved install path; filename presence alone is insufficient. If macFUSE is absent/incompatible, continue compile-only and Linux work, mark host smoke unavailable, and keep the macOS acceptance item parked. Do not fabricate a passing runtime check.

Acceptance: baseline outputs and measured times appear in the campaign log; the focused Rust test completes in under 2 minutes; no test or build writes outside `.work/` except normal Cargo target artifacts.

### P1 — Feature completeness and parity

**F1 — Makefile, preflight, and quickstart** (build/docs lane; owns `Makefile`, optional `scripts/` helper, and README macOS sections). Implement `doctor`, `build`, `test`, `smoke-fskit`, `mount SESSION=personal`, `umount`, `clean`, and default `make`. Keep the Makefile thin and POSIX-compatible. Default `make` runs doctor, optimized locked build, static library/version verification, then smoke. `build` remains usable without FSKit runtime availability or credentials. `test` runs host-independent Rust and build/config regression tests; Linux `make test` must not require macFUSE. Reject invalid macOS `MOUNTPOINT` values before mount/unmount. Remove macOS kext approval/load instructions and replace the build quickstart with the four requested steps and official references.

Acceptance: `make -n` or equivalent demonstrates the documented target graph without effects; `make doctor` reports missing prerequisites clearly; `make build` builds `target/release/gcsf`; `make test` passes on Linux and macOS; shell checks cover missing/incompatible `pkg-config`, version checks, and resolved linkage. Default `make` exits nonzero if the runtime smoke cannot run.

**F2 — Central FSKit-only runtime policy** (runtime lane; owns `src/gcsf/config.rs`, `src/main.rs`, and `src/tests.rs`). Apply FSKit on macOS for all entry paths, before either synthetic or Drive mount. Check macOS 26+, macFUSE 5.4+, effective libfuse3 resolution, and `/Volumes` mountpoint before mounting. Preserve Linux config/mount behavior. Reject explicit conflicting backend values; keep exactly one `backend=fskit`. Do not retry through VFS/kernel extension. Map failures to actionable diagnostics for missing library, incompatible version, unregistered/disabled FSKit extension, permissions, and mount rejection. Keep macOS OS-level setup manual. Verify which `ro`/`rw` options FSKit honors and retain GCSF's application-level write rejection without claiming OS enforcement.

Acceptance: focused tests prove default macOS config, empty options, one and duplicate `backend=fskit`, conflicting backends, invalid macOS paths, missing/incompatible macFUSE, bad libfuse resolution, no fallback on mount failure, and Linux config parity. Tests fail if an explicit duplicate, conflict, or fallback is reintroduced.

**F3 — Credential-free FSKit lifecycle probe** (runtime lane if Rust lifecycle changes are needed; otherwise build/docs lane; prerequisite F2). Use a collision-resistant mountpoint under `/Volumes` that the probe itself creates or verifies as unused. Mount the existing `NullFs` through the exact production configuration. Check mount success and real metadata/content operations, including write followed by read-back to catch short-write corruption. Correlate the mount with authoritative active-backend evidence where available; label weaker evidence accurately. Always unmount and remove only the directory created by the probe, including on assertion failure and handled interruption. Never touch an existing volume or request Drive credentials.

Acceptance: a real configured macOS host mounts, performs operations, unmounts, and exits zero; forced assertion failure and handled interruption leave no mounted probe and remove only probe-owned paths. If registration requires a user action, the error names System Settings → Privacy & Security and the macFUSE filesystem extension; no automatic kext path exists. Linux runs the non-OS subset and reports runtime smoke as unsupported rather than substituting another backend.

**P1 integration gate:** integrate F1/F2 as soon as each is reviewable, then start F3 while independent README/build integration continues. Run focused tests for each touched area. At the end of P1, run `cargo test --locked` and `make test` on both macOS and Linux where available. If one platform is unavailable, record its precise missing prerequisite and do not claim parity there.

### P2 — Hardening

**H1 — Close contract and failure coverage** (integrator, then disjoint lanes if available). Exercise every failure path using simulated command outputs or injected test seams, not privileged system changes. Confirm `make mount` passes through direct-binary enforcement, default `make` does not use credentials/network, `clean` removes only repository build outputs, and unmount only addresses the configured GCSF path. Review docs against actual command output and official references.

Acceptance: all named P1 policy/error/lifecycle tests pass; the no-fallback and safe-cleanup tests fail when their protections are deliberately removed; `mdtool check --untracked fuse.md` and Markdown target checks pass after final doc edits.

### P3 — Optimization and polish

**O1 — Optimize only measured build/probe bottlenecks** (integrator; only after P1 and P2 acceptance). Compare build time and release binary size with G0 under the same host/configuration. Optimize only a measured campaign-path regression greater than 2x baseline or a command exceeding 2 minutes. Do not add a dependency or make runtime performance claims in this campaign. Any measurement used to select a change needs at least five alternating baseline/candidate runs, median and range, correct outputs, and observed limiter. Run `perf-gate-ready` before and immediately after these timed runs as specified in G0. If host readiness prevents a fair comparison, defer it and do not call it a pass.

Acceptance: functional parity remains green; report baseline/candidate build time and binary size or explicitly state why the measurement was deferred. No performance claim is required.

### P4 — Close

**C1 — Cleanup and adversarial review.** Remove obsolete macOS kext troubleshooting helpers, duplicate policy paths, dead tests, and temporary artifacts after searching callers/docs/tests. Prove remaining paths are live. Review the final diff for contract changes and run `ultrareview` on the changed scope; fix P1/P2 findings. Run focused checks, then `cargo test --locked`, `make test`, `make build`, and on a configured macOS host the full default `make` smoke path. Do not run formatters, CI, or push. Leave changes uncommitted.

Acceptance: all deliverables either pass their named proof or are explicitly parked for a missing external prerequisite; no kext instructions or backend fallback remain; final report lists actual platform results and retained worktrees.

## Acceptance map

| Deliverable | Proof |
|---|---|
| One-command macOS build and diagnosis | `make doctor`, `make build`, and successful default `make` on a configured macOS host |
| Correct macFUSE/libfuse linkage | `pkg-config` version/cflags/libs plus `otool -L target/release/gcsf` and resolved library path |
| Runtime FSKit enforcement | Named Rust tests for configuration, paths, compatibility, error mapping, and no fallback; direct CLI mount uses same policy |
| Real synthetic filesystem lifecycle | `make smoke-fskit`; mount, metadata/content operation, short write/read-back, unmount, cleanup, and backend-evidence report |
| Linux preservation | `cargo test --locked`, `make test`, and `make build` on Linux without macFUSE |
| Documentation | `mdtool check --untracked fuse.md`; README quickstart and troubleshooting match targets and no kext steps |

A source inspection or config assertion alone is not proof of a real FSKit mount. Report `backend=fskit` option selection separately from independently observed active backend identity.

## Execution boundary

Authorized: repository-local edits, Cargo builds/tests, read-only host diagnostics, temporary directories and mounts created exclusively by the smoke probe under `/Volumes`, and clean unmount/removal of those probe-owned resources. No commits or pushes are authorized.

Not authorized: installing/updating macFUSE or Rust; approving/registering extensions; any System Settings or Recovery Mode security change; `sudo`, `kmutil`, kernel-extension loading, Drive login/access/network, touching a pre-existing mount, or destructive filesystem operations. If a mount requires manual FSKit extension registration, report the exact user action and park only the real runtime proof. The user can install macFUSE 5.4+ from the official signed installer and enable its FSKit extension in System Settings; the campaign must then resume without changing the product contract.

## Non-goals

- Linux feature work beyond proving existing build/config compatibility.
- Rebuilding or vendoring macFUSE, upgrading unrelated dependencies, changing the Rust toolchain, adding package managers/containers, or adding CI.
- Google authentication or Drive integration tests.
- Kernel-extension support, VFS fallback, installer automation, Recovery Mode changes, or changing the specified macOS 26+ support floor.
- Performance optimization before all feature, lifecycle, and parity checks pass.

## Reference and verified code map

The runtime reference is the current GCSF implementation at campaign start: existing `Config::fuser_config`, `mount_gcsf`, `NullFs`, Linux behavior, and README command contract. Preserve behavior outside the explicit macOS FSKit contract. The compatibility reference for FSKit limits and mount options is the [macFUSE FUSE Backends documentation](https://github.com/macfuse/macfuse/wiki/FUSE-Backends) and [Getting Started guide](https://github.com/macfuse/macfuse/wiki/Getting-Started). macFUSE [5.2 release notes](https://github.com/macfuse/macfuse/releases) describe `MFMount.framework` adoption by libfuse and libfuse3; [5.4.0 notes](https://github.com/macfuse/macfuse/releases/tag/macfuse-5.4.0) should be checked for the small-write fix before implementation. Preserve the pinned workaround associated with [fuser issue 752](https://github.com/cberner/fuser/issues/752). The requested [macFUSE 5.1.0 announcement](https://macfuse.github.io/2025/10/30/macfuse-5.1.0.html) is historical context, not the current minimum-version authority.

Verified source locations: `Cargo.toml` dependency and patch; `src/gcsf/config.rs::Config::mount_options`, `fuser_config`, `parse_mount_option`; `src/main.rs::mount_gcsf`, `print_mount_troubleshooting`, and mount command flow; `src/gcsf/filesystem.rs::NullFs`; `src/tests.rs::mount_options_tests`; README Requirements and Troubleshooting sections. Recheck locations at execution because line numbers can move.

## Decision log

- 2026-10-16 — Require macFUSE 5.4+ because FSKit is available through libfuse3 in current releases and 5.4 addresses the reported 5.3.3 short-write corruption; verify the release note and a content round-trip before relying on it.
- 2026-10-16 — Keep backend identity claims bounded by observed evidence because a successful mount and an option assertion do not prove which backend is active.
- 2026-10-16 — Keep extension installation and registration manual because they are privileged OS-level effects outside the repository task.

## Campaign log

- 2026-10-16 — Preflight verified the current config/mount/NullFs/test paths, found stale kext instructions in both README and runtime diagnostics, and ran the focused mount-options baseline: 5 passed in 1.36 s.
- Append one short line per phase end with lanes integrated, checks and elapsed times, failures/decisions, and parked proof.

## For the owner afterwards

Review the final diff and campaign report. No cherry-pick is needed for this in-place campaign; all repository changes remain uncommitted. Resume any parked macOS runtime proof after installing macFUSE 5.4+ and completing any required FSKit extension registration.
