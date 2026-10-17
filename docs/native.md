# Native tree

The product is implementation-incomplete. Nothing here has mounted a volume. A signed mount has not been demonstrated.

## Commands

`gcsf --help` lists `login`, `logout`, `list`, `verify`, `mount`, and `umount`.

`login`, `logout`, `list`, and `verify` are not implemented. With no extra arguments each prints `<command>: not implemented` and exits 1. Extra arguments are a usage error.

`mount` accepts only `-s <session>`. A positional directory is rejected. A valid invocation does not call the FSKit mount API. It prints `runtime mount is parked` and exits 1.

`umount` accepts only `-s <session>`. A positional argument is rejected. A valid invocation prints `runtime umount is parked` and exits 1. It does not unmount a volume.

`make mount`, `make umount`, `make smoke`, and `make test-live` print that they are parked and exit 1.

## Build

`make build` runs `swift build`, then `xcodebuild` for the `GCSFHost` scheme with code signing disabled.

`make doctor` prints the OS, Xcode, Swift, SDK, architecture, code-signing identities, installed FSKit extensions, and the access group. It does not open System Settings unless `OPEN_SETTINGS=1`. That variable is the only path that calls `openFileSystemExtensionsSettings`. The runtime contract parks that path along with mounting and extension registration. `make doctor` also exits 1 unless the host is macOS 27, Xcode 27, Swift 6.4, and arm64.

## Config and credentials

Config will be `config.json` in the group container named in [docs/runtime-contract.md](runtime-contract.md). The encoding is JSON.

The OAuth client document is migrated, not replaced. Refresh tokens are keychain items, not files.

`login` is not implemented, so this tree does not run session migration. The access group, the container, migration, and the index, journal, cache, and staging paths are in the runtime contract. This page does not restate them.

## Google-native documents

Google-native documents are read-only. Docs, Sheets, Slides, Drawings, and Sites are in that set. There is no import workflow.

## Writes

The write contract is not implemented. `Engine` is empty, and the extension `synchronize` returns without a Drive acknowledgement.

Under that contract, `fsync` succeeds only after Drive has acknowledged the bytes. A local journal is not success. Conflicts keep the staged bytes and write a new file. Race-free overwrite is not claimed.

`DurabilityState` names `staged`, `journaled`, `committed`, and `conflicted`. The runtime contract defines those states and does not implement the transitions.

## Names

Duplicate suffixes, once assigned, stay put when an earlier Drive id appears. The index stores the assigned suffix. It does not recompute one.

## Mount

Runtime mount needs the two FSKit entitlements and is parked. The extension entitlement file holds `com.apple.developer.fskit.fsmodule`. The CLI entitlement file holds `com.apple.developer.fskit.mount`. Both are the contract a signature must carry. An unsigned build does not carry them, and it is not a mount.
