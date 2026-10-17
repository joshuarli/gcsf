# Runtime contract

The CLI, `GCSFHost.app`, and `GCSFExtension.appex` are separate processes. They share one access group and one directory. They do not share a process. A running extension has not been shown to read the keychain or the container on this machine. That proof is parked until a signing identity exists.

## Identifiers

| Target | Bundle identifier |
|---|---|
| `GCSFHost.app` | `com.joshuarli.gcsf` |
| `gcsf` CLI | `com.joshuarli.gcsf.cli` |
| `GCSFExtension.appex` | `com.joshuarli.gcsf.extension` |

The Swift constant `RuntimeBoundary.sharedGroupIdentifier` is `group.com.joshuarli.gcsf`. That string is the keychain access group and the app group. It is the same literal in:

- `Host/GCSFHost.entitlements`
- `Extension/GCSFExtension.entitlements`
- `Sources/gcsf-cli/gcsf-cli.entitlements`

No team-id prefix is added. `make doctor` fails when those three arrays and the constant differ. The unsigned debug CLI does not carry the entitlement until it is signed. The file is the contract the signature must use.

## Keychain

Use the data-protection keychain. `SecItem.h` documents `kSecUseDataProtectionKeychain` as the macOS switch that makes `kSecAttrAccessGroup` apply. No FSKit header says an appex cannot read that keychain.

One generic-password item per session:

| Attribute | Value |
|---|---|
| `kSecClass` | `kSecClassGenericPassword` |
| `kSecUseDataProtectionKeychain` | true |
| `kSecAttrAccessGroup` | `group.com.joshuarli.gcsf` |
| `kSecAttrService` | `com.joshuarli.gcsf` (`RuntimeBoundary.keychainService`) |
| `kSecAttrAccount` | session name |
| `kSecAttrAccessible` | `kSecAttrAccessibleAfterFirstUnlock` |
| `kSecAttrSynchronizable` | false |
| value | refresh token |

The CLI creates the item on login, reads it on verify and refresh, and deletes it on logout. The extension reads and updates it while it serves a mount. The host has the access-group entitlement and does not read or write items.

## Container

One app group, the same string as the access group, so the extension and the CLI open one directory. The path is `RuntimeBoundary.groupContainerURL(home:)`:

`~/Library/Group Containers/group.com.joshuarli.gcsf`

When a signature is present, `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` with `group.com.joshuarli.gcsf` is the same directory. Do not invent a second location.

| Relative path | Creates | Reads | Deletes |
|---|---|---|---|
| `index.sqlite` | extension, on first mount if the file is absent | extension while mounted; CLI while migrating | nobody deletes the file |
| `writeback-journal.sqlite` | extension | extension | extension deletes journal rows; nobody deletes the file on logout |
| `staged/` | extension | extension | extension deletes a staged file after that item is `committed`; `conflicted` bytes stay |
| `cache/` | extension | extension | extension, when it evicts |
| `config.json` | CLI | CLI and extension | CLI |

The CLI creates the directory during login or migration if it is missing. The extension creates it if it is missing when a mount starts. Neither deletes the directory. `make clean` does not delete the directory, the files above, or keychain items.

The extension must be able to open this directory and the refresh token while it serves a mount. The CLI opens the same directory during migration. Neither of those reads has been proven from a running extension.

## Entitlements

| Entitlement | Host | Extension | CLI |
|---|---|---|---|
| `keychain-access-groups` = `group.com.joshuarli.gcsf` | yes | yes | yes |
| `com.apple.security.application-groups` = `group.com.joshuarli.gcsf` | yes | yes | yes |
| `com.apple.security.app-sandbox` | yes | yes | no |
| `com.apple.security.network.client` | no | yes | yes |
| `com.apple.developer.fskit.fsmodule` | no | yes | no |
| `com.apple.developer.fskit.mount` | no | no | yes |

The extension and the CLI call Drive, so they have the network client entitlement. The CLI is the mounting client. The extension is the file-system module. The host is headless and only embeds the appex. The CLI is not sandboxed; the app-group entitlement is what authorizes the container once the binary is signed.

## Config

The config file is `config.json` in the container. Its encoding is JSON.

## Durability

`DurabilityState` is `staged`, `journaled`, `committed`, and `conflicted`.

- `staged`: bytes are on disk and the journal entry is not durable.
- `journaled`: the intent is durable and Drive has not acknowledged it.
- `committed`: Drive acknowledged this revision.
- `conflicted`: the remote head moved, the staged bytes are kept, and the original file is not overwritten.

This file names the states. It does not implement the transitions.

## Parked

Runtime proof that the extension can read the keychain or the container is parked. Do not treat a successful unsigned build as that proof. Mounting, extension registration, and `make doctor OPEN_SETTINGS=1` are also parked.

## Decisions

- 2026-10-16 — Config file encoding is JSON. The file name is `config.json`. JSON is in the Swift standard library, so the new format does not add a parser, and Codable can round-trip migrated settings.
- 2026-10-16 — The data-protection keychain stays. `SecItem.h` documents `kSecUseDataProtectionKeychain` as the way to use `kSecAttrAccessGroup` on macOS, and no FSKit header shows that an appex cannot read that keychain. A runtime read from the extension is parked rather than replaced with a side channel.
- 2026-10-16 — One app group, identical to the keychain access group, is the shared directory. The extension and the CLI have no other container.
