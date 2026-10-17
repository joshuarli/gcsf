import Foundation
import Testing

@testable import GCSFCore

struct ConfigTests {
    @Test func roundTripPreservesSettings() throws {
        let container = try scratch("round-trip")
        defer { remove(container) }
        let original = DriveSettings(
            debug: true,
            mountCheck: false,
            cacheMaxSeconds: 3,
            cacheMaxItems: 4,
            cacheStatfsSeconds: 5,
            syncIntervalSeconds: 6,
            mountOptions: ["ro", "fsname=GCSF"],
            authorizeUsingCode: false,
            renameIdenticalFiles: true,
            addExtensionsToSpecialFiles: true,
            skipTrash: true,
            clientSecret: "{\"installed\":{\"client_id\":\"cid\",\"client_secret\":\"csec\"}}",
            authPort: 9091,
            readOnly: true,
            sessions: ["home", "work"]
        )
        try DriveSettingsStore.save(original, container: container)
        let loaded = try DriveSettingsStore.load(container: container)
        #expect(loaded == original)
        #expect(DriveSettingsStore.fileURL(container: container).lastPathComponent == RuntimeBoundary.configFileName)
    }

    @Test func missingKeysUseRustDefaults() throws {
        let container = try scratch("defaults")
        defer { remove(container) }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let partial = Data("{\"debug\":true,\"mountOptions\":[\"ro\"]}".utf8)
        try partial.write(to: DriveSettingsStore.fileURL(container: container))
        let loaded = try DriveSettingsStore.load(container: container)
        #expect(loaded.debug == true)
        #expect(loaded.mountOptions == ["ro"])
        #expect(loaded.mountCheck == true)
        #expect(loaded.cacheMaxSeconds == 10)
        #expect(loaded.cacheMaxItems == 10)
        #expect(loaded.cacheStatfsSeconds == 100)
        #expect(loaded.syncIntervalSeconds == 10)
        #expect(loaded.authorizeUsingCode == true)
        #expect(loaded.renameIdenticalFiles == false)
        #expect(loaded.addExtensionsToSpecialFiles == false)
        #expect(loaded.skipTrash == false)
        #expect(loaded.authPort == 8081)
        #expect(loaded.readOnly == false)
        #expect(loaded.clientSecret == nil)
        #expect(loaded.sessions == [])
        let encoded = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(loaded)) as? [String: Any]
        let keys = Set(encoded?.keys.map { $0 } ?? [])
        #expect(keys.isDisjoint(with: ["refresh_token", "access_token", "token", "tokens"]))
    }

    @Test func legacyTomlKeepsClientSecretAndRustDefaults() throws {
        let basic = "{\"installed\":{\"client_id\":\"cid\",\"client_secret\":\"csec\"}}"
        let raw = "{\"installed\":{\"client_id\":\"cid\",\"client_secret\":\"se'cret\\\\path\"}}"
        let toml = """
        # kept comment
        debug = true
        sync_interval = 15
        mount_options = [
            "fsname=GCSF",
            "allow_root",
        ]
        skip_trash = true
        auth_port = 9090
        client_secret = \"\"\"
        \(basic)\"\"\"
        """
        let settings = try LegacyConfigParser.settings(toml: toml)
        #expect(settings.debug == true)
        #expect(settings.syncIntervalSeconds == 15)
        #expect(settings.mountOptions == ["fsname=GCSF", "allow_root"])
        #expect(settings.skipTrash == true)
        #expect(settings.authPort == 9090)
        #expect(settings.clientSecret == basic)
        #expect(settings.mountCheck == true)
        #expect(settings.cacheMaxSeconds == 10)
        #expect(settings.cacheMaxItems == 10)
        #expect(settings.cacheStatfsSeconds == 100)
        #expect(settings.authorizeUsingCode == true)
        #expect(settings.renameIdenticalFiles == false)
        #expect(settings.addExtensionsToSpecialFiles == false)
        #expect(settings.readOnly == false)
        #expect(settings.sessions.isEmpty)
        let literal = "client_secret = '''\n\(raw)'''\n"
        let fromRaw = try LegacyConfigParser.settings(toml: literal)
        #expect(fromRaw.clientSecret == raw)
        let escaped = try LegacyConfigParser.settings(toml: "client_secret = \"a\\nb\"\n")
        #expect(escaped.clientSecret == "a\nb")
    }

    @Test func migrationMovesTheFirstRefreshTokenAndIsIdempotent() async throws {
        let legacy = try scratch("migrate-legacy")
        let container = try scratch("migrate-container")
        defer {
            remove(legacy)
            remove(container)
        }
        let secret = "{\"installed\":{\"client_id\":\"cid\",\"client_secret\":\"csec\"}}"
        let toml = """
        debug = false
        mount_options = ["fsname=GCSF", "allow_root"]
        client_secret = \"\"\"
        \(secret)\"\"\"
        """
        try toml.write(to: legacy.appending(path: "gcsf.toml"), atomically: true, encoding: .utf8)
        let alpha = """
        [
          {
            "scopes": ["https://www.googleapis.com/auth/drive"],
            "token": {"access_token": "access-should-stay-behind", "refresh_token": ""}
          },
          {
            "scopes": ["https://www.googleapis.com/auth/drive"],
            "token": {"access_token": "access-should-stay-behind", "refresh_token": "refresh-alpha"}
          }
        ]
        """
        let zeta = """
        {"tokens":[{"scopes":[],"token":{"access_token":"access-zeta","refresh_token":"refresh-zeta"}}]}
        """
        try alpha.write(to: legacy.appending(path: "alpha"), atomically: true, encoding: .utf8)
        try zeta.write(to: legacy.appending(path: "zeta"), atomically: true, encoding: .utf8)
        try Data("notes".utf8).write(to: legacy.appending(path: "notes.txt"))
        try FileManager.default.createDirectory(at: legacy.appending(path: "subdir"), withIntermediateDirectories: true)
        let tokens = MemoryTokens()
        let migrated = try await LegacyMigration.migrate(legacyDirectory: legacy, container: container, tokens: tokens)
        #expect(migrated.clientSecret == secret)
        #expect(migrated.mountOptions == ["fsname=GCSF", "allow_root"])
        #expect(migrated.sessions == ["alpha", "zeta"])
        #expect(migrated.cacheStatfsSeconds == 100)
        #expect(migrated.authPort == 8081)
        #expect(await tokens.snapshot() == ["alpha": "refresh-alpha", "zeta": "refresh-zeta"])
        #expect(await tokens.storeCalls() == ["alpha", "zeta"])
        #expect(!FileManager.default.fileExists(atPath: legacy.appending(path: "alpha").path))
        #expect(!FileManager.default.fileExists(atPath: legacy.appending(path: "zeta").path))
        #expect(FileManager.default.fileExists(atPath: legacy.appending(path: "gcsf.toml").path))
        #expect(FileManager.default.fileExists(atPath: legacy.appending(path: "notes.txt").path))
        let configText = try String(contentsOf: DriveSettingsStore.fileURL(container: container), encoding: .utf8)
        #expect(!configText.contains("refresh-alpha"))
        #expect(!configText.contains("refresh-zeta"))
        #expect(!configText.contains("access-should-stay-behind"))
        #expect(!configText.contains("access-zeta"))
        let again = try await LegacyMigration.migrate(legacyDirectory: legacy, container: container, tokens: tokens)
        #expect(again.sessions == ["alpha", "zeta"])
        #expect(again.clientSecret == secret)
        #expect(await tokens.snapshot() == ["alpha": "refresh-alpha", "zeta": "refresh-zeta"])
        #expect(await tokens.storeCalls() == ["alpha", "zeta"])
    }

    @Test func failedStoreLeavesTheLegacySession() async throws {
        let legacy = try scratch("fail-store-legacy")
        let container = try scratch("fail-store-container")
        defer {
            remove(legacy)
            remove(container)
        }
        try "debug = false\n".write(to: legacy.appending(path: "gcsf.toml"), atomically: true, encoding: .utf8)
        let body = """
        [{"scopes":["https://www.googleapis.com/auth/drive"],"token":{"refresh_token":"refresh-alpha","access_token":"access-alpha"}}]
        """
        try body.write(to: legacy.appending(path: "alpha"), atomically: true, encoding: .utf8)
        try body.replacingOccurrences(of: "refresh-alpha", with: "refresh-zeta").write(
            to: legacy.appending(path: "zeta"),
            atomically: true,
            encoding: .utf8
        )
        let tokens = MemoryTokens()
        await tokens.fail(["zeta"])
        await #expect(throws: MemoryTokenError.rejected) {
            try await LegacyMigration.migrate(legacyDirectory: legacy, container: container, tokens: tokens)
        }
        #expect(!FileManager.default.fileExists(atPath: legacy.appending(path: "alpha").path))
        #expect(FileManager.default.fileExists(atPath: legacy.appending(path: "zeta").path))
        #expect(await tokens.snapshot() == ["alpha": "refresh-alpha"])
    }

    @Test func readBackMismatchLeavesTheLegacySession() async throws {
        let legacy = try scratch("mismatch-legacy")
        let container = try scratch("mismatch-container")
        defer {
            remove(legacy)
            remove(container)
        }
        try "read_only = false\n".write(to: legacy.appending(path: "gcsf.toml"), atomically: true, encoding: .utf8)
        let body = """
        [{"scopes":[],"token":{"refresh_token":"refresh-alpha"}}]
        """
        try body.write(to: legacy.appending(path: "alpha"), atomically: true, encoding: .utf8)
        let tokens = LyingTokens()
        await #expect(throws: LegacyMigrationError.notVerified("alpha")) {
            try await LegacyMigration.migrate(legacyDirectory: legacy, container: container, tokens: tokens)
        }
        #expect(FileManager.default.fileExists(atPath: legacy.appending(path: "alpha").path))
    }

    @Test func emptyRefreshTokenIsNotDeleted() async throws {
        let legacy = try scratch("empty-refresh-legacy")
        let container = try scratch("empty-refresh-container")
        defer {
            remove(legacy)
            remove(container)
        }
        try "debug = false\n".write(to: legacy.appending(path: "gcsf.toml"), atomically: true, encoding: .utf8)
        let body = """
        [{"scopes":["https://www.googleapis.com/auth/drive"],"token":{"refresh_token":""}}]
        """
        try body.write(to: legacy.appending(path: "alpha"), atomically: true, encoding: .utf8)
        let tokens = MemoryTokens()
        await #expect(throws: LegacyMigrationError.missingRefreshToken("alpha")) {
            try await LegacyMigration.migrate(legacyDirectory: legacy, container: container, tokens: tokens)
        }
        #expect(FileManager.default.fileExists(atPath: legacy.appending(path: "alpha").path))
        #expect(await tokens.storeCalls().isEmpty)
    }

    @Test func unsupportedTomlFailsLoudly() async throws {
        let legacy = try scratch("bad-toml")
        let container = try scratch("bad-toml-container")
        defer {
            remove(legacy)
            remove(container)
        }
        try "session_name = \"work\"\n".write(to: legacy.appending(path: "gcsf.toml"), atomically: true, encoding: .utf8)
        let tokens = MemoryTokens()
        await #expect(throws: LegacyConfigError.unsupportedKey("session_name")) {
            try await LegacyMigration.migrate(legacyDirectory: legacy, container: container, tokens: tokens)
        }
        #expect(!FileManager.default.fileExists(atPath: DriveSettingsStore.fileURL(container: container).path))
        #expect(throws: LegacyConfigError.unsupportedSyntax(line: 1)) {
            try LegacyConfigParser.settings(toml: "[profile]\ndebug = true\n")
        }
        #expect(throws: LegacyConfigError.unsupportedSyntax(line: 1)) {
            try LegacyConfigParser.settings(toml: "debug = 'true'\n")
        }
        #expect(throws: LegacyConfigError.unsupportedSyntax(line: 1)) {
            try LegacyConfigParser.settings(toml: "mount_options = [1]\n")
        }
        let absent = try scratch("missing-toml")
        defer { remove(absent) }
        await #expect(throws: LegacyConfigError.missingFile) {
            try await LegacyMigration.migrate(legacyDirectory: absent, container: container, tokens: tokens)
        }
    }
}

private actor MemoryTokens: RefreshTokenStore {
    private var values: [String: String] = [:]
    private var calls: [String] = []
    private var failures: Set<String> = []

    func fail(_ names: Set<String>) {
        failures = names
    }

    func load(session: String) async throws -> String? {
        values[session]
    }

    func store(session: String, refreshToken: String) async throws {
        calls.append(session)
        if failures.contains(session) {
            throw MemoryTokenError.rejected
        }
        values[session] = refreshToken
    }

    func remove(session: String) async throws {
        values[session] = nil
    }

    func snapshot() -> [String: String] {
        values
    }

    func storeCalls() -> [String] {
        calls
    }
}

private enum MemoryTokenError: Error, Equatable {
    case rejected
}

private final class LyingTokens: RefreshTokenStore, @unchecked Sendable {
    func load(session: String) async throws -> String? {
        "not-the-refresh"
    }

    func store(session: String, refreshToken: String) async throws {}

    func remove(session: String) async throws {}
}

private func scratch(_ name: String) throws -> URL {
    let root = URL(fileURLWithPath: "/Users/josh/d/gcsf/.work/tmp/d2", isDirectory: true)
        .appending(path: name, directoryHint: .isDirectory)
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}
