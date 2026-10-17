# Native tree

The product is implementation-incomplete. Nothing here has mounted a volume. A signed mount has not been demonstrated.

## Commands

`gcsf --help` lists `setup`, `login`, `logout`, `list`, `verify`, `mount`, and `umount`.

`gcsf setup` opens `https://console.cloud.google.com/apis/library/drive.googleapis.com` and prints the steps that create a Desktop OAuth client for `https://www.googleapis.com/auth/drive`. `gcsf setup <client.json>` reads that downloaded file, checks that it is an installed Desktop client, and saves it as `DriveSettings.clientSecret`. A missing config is created with `authPort` 0. An existing config keeps its other fields, including session names. A Web client document and the shipped shared client are refused and exit 1. Extra arguments exit 2.

`gcsf login` opens the Google sign-in page for the session `default`. `gcsf login <session>` uses that name instead. It loads `config.json` from the group container for that home. When the file is missing and the legacy config directory contains `gcsf.toml`, it migrates that directory first. When no client document exists, it uses the shipped Drive client. It then runs the OAuth login, adds the session name to `DriveSettings.sessions`, and saves. It does not print the refresh token or the access token. Success exits 0. Two arguments are a usage error and exit 2.

`gcsf logout <session>` deletes the refresh token and removes the session name. A missing session exits 1.

`gcsf list` takes no arguments. It prints session names, one per line, sorted.

`gcsf verify <session>` loads the refresh token and refreshes it. Success exits 0. A missing session or token exits 1. It does not print the token.

`gcsf mount -s <session>` calls `mountSingleVolume`, prints the returned URL on success, and prints the error and exits 1 on failure. No successful mount has been demonstrated. A positional mount directory is a usage error and exits 2.

`umount -s` unmounts the stored URL.

`make doctor` still does not open System Settings unless `OPEN_SETTINGS=1`.

`make mount`, `make umount`, `make smoke`, and `make test-live` print that they are parked and exit 1.

## Build

`make build` runs `swift build`, then `xcodebuild` for the `GCSFHost` scheme with code signing disabled.

`make doctor` prints the OS, Xcode, Swift, SDK, architecture, code-signing identities, installed FSKit extensions, and the access group. It does not open System Settings unless `OPEN_SETTINGS=1`. That variable is the only path that calls `openFileSystemExtensionsSettings`. The runtime contract parks that path along with mounting and extension registration. `make doctor` also exits 1 unless the host is macOS 27, Xcode 27, Swift 6.4, and arm64.

## Config and credentials

Config will be `config.json` in the group container named in [docs/runtime-contract.md](runtime-contract.md). The encoding is JSON.

Refresh tokens are keychain items, not files. When `config.json` is missing and the legacy directory contains `gcsf.toml`, login migrates that client document. When no client document exists, login writes the shipped Drive client. The access group, the container, and the index, journal, cache, and staging paths are in the runtime contract. This page does not restate them.

## Google-native documents

Google-native documents are read-only. Docs, Sheets, Slides, Drawings, and Sites are in that set. There is no import workflow.

## Writes

`GCSFEngine` applies POSIX operations on the index. With no journal attached, a write stays in the process and does not upload. `SQLiteWritebackJournal` stages bytes, resumes an upload, and on a moved head revision writes a conflict copy instead of updating the original file. `synchronize` throws `EIO` while a dirty item is still unuploaded. A local journal alone is not success. Race-free overwrite is not claimed.

The states are `staged`, `journaled`, `committed`, and `conflicted`.

The appex builds `LiveSession`, which opens the index, the journal, and Drive from the group container. A missing `config.json` or refresh token fails with `ENXIO` and creates no files. The first write of an existing file copies that file into the staging directory in 64 KiB chunks. No change-feed loop is started. No mount has been demonstrated.

## Names

Duplicate suffixes, once assigned, stay put when an earlier Drive id appears. The index stores the assigned suffix. It does not recompute one.

## Mount

Runtime mount needs the two FSKit entitlements and is parked. The extension entitlement file holds `com.apple.developer.fskit.fsmodule`. The CLI entitlement file holds `com.apple.developer.fskit.mount`. Both are the contract a signature must carry. An unsigned build does not carry them, and it is not a mount.
