import Foundation

public struct DriveSettings: Codable, Sendable, Equatable {
    public var debug: Bool
    public var mountCheck: Bool
    public var cacheMaxSeconds: UInt64
    public var cacheMaxItems: UInt64
    public var cacheStatfsSeconds: UInt64
    public var syncIntervalSeconds: UInt64
    public var mountOptions: [String]
    public var authorizeUsingCode: Bool
    public var renameIdenticalFiles: Bool
    public var addExtensionsToSpecialFiles: Bool
    public var skipTrash: Bool
    public var clientSecret: String?
    public var authPort: UInt16
    public var readOnly: Bool
    public var sessions: [String]

    public init(
        debug: Bool = false,
        mountCheck: Bool = true,
        cacheMaxSeconds: UInt64 = 10,
        cacheMaxItems: UInt64 = 10,
        cacheStatfsSeconds: UInt64 = 100,
        syncIntervalSeconds: UInt64 = 10,
        mountOptions: [String] = [],
        authorizeUsingCode: Bool = true,
        renameIdenticalFiles: Bool = false,
        addExtensionsToSpecialFiles: Bool = false,
        skipTrash: Bool = false,
        clientSecret: String? = nil,
        authPort: UInt16 = 8081,
        readOnly: Bool = false,
        sessions: [String] = []
    ) {
        self.debug = debug
        self.mountCheck = mountCheck
        self.cacheMaxSeconds = cacheMaxSeconds
        self.cacheMaxItems = cacheMaxItems
        self.cacheStatfsSeconds = cacheStatfsSeconds
        self.syncIntervalSeconds = syncIntervalSeconds
        self.mountOptions = mountOptions
        self.authorizeUsingCode = authorizeUsingCode
        self.renameIdenticalFiles = renameIdenticalFiles
        self.addExtensionsToSpecialFiles = addExtensionsToSpecialFiles
        self.skipTrash = skipTrash
        self.clientSecret = clientSecret
        self.authPort = authPort
        self.readOnly = readOnly
        self.sessions = sessions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        debug = try container.decodeIfPresent(Bool.self, forKey: .debug) ?? false
        mountCheck = try container.decodeIfPresent(Bool.self, forKey: .mountCheck) ?? true
        cacheMaxSeconds = try container.decodeIfPresent(UInt64.self, forKey: .cacheMaxSeconds) ?? 10
        cacheMaxItems = try container.decodeIfPresent(UInt64.self, forKey: .cacheMaxItems) ?? 10
        cacheStatfsSeconds = try container.decodeIfPresent(UInt64.self, forKey: .cacheStatfsSeconds) ?? 100
        syncIntervalSeconds = try container.decodeIfPresent(UInt64.self, forKey: .syncIntervalSeconds) ?? 10
        mountOptions = try container.decodeIfPresent([String].self, forKey: .mountOptions) ?? []
        authorizeUsingCode = try container.decodeIfPresent(Bool.self, forKey: .authorizeUsingCode) ?? true
        renameIdenticalFiles = try container.decodeIfPresent(Bool.self, forKey: .renameIdenticalFiles) ?? false
        addExtensionsToSpecialFiles = try container.decodeIfPresent(Bool.self, forKey: .addExtensionsToSpecialFiles) ?? false
        skipTrash = try container.decodeIfPresent(Bool.self, forKey: .skipTrash) ?? false
        clientSecret = try container.decodeIfPresent(String.self, forKey: .clientSecret)
        authPort = try container.decodeIfPresent(UInt16.self, forKey: .authPort) ?? 8081
        readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        sessions = try container.decodeIfPresent([String].self, forKey: .sessions) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(debug, forKey: .debug)
        try container.encode(mountCheck, forKey: .mountCheck)
        try container.encode(cacheMaxSeconds, forKey: .cacheMaxSeconds)
        try container.encode(cacheMaxItems, forKey: .cacheMaxItems)
        try container.encode(cacheStatfsSeconds, forKey: .cacheStatfsSeconds)
        try container.encode(syncIntervalSeconds, forKey: .syncIntervalSeconds)
        try container.encode(mountOptions, forKey: .mountOptions)
        try container.encode(authorizeUsingCode, forKey: .authorizeUsingCode)
        try container.encode(renameIdenticalFiles, forKey: .renameIdenticalFiles)
        try container.encode(addExtensionsToSpecialFiles, forKey: .addExtensionsToSpecialFiles)
        try container.encode(skipTrash, forKey: .skipTrash)
        try container.encodeIfPresent(clientSecret, forKey: .clientSecret)
        try container.encode(authPort, forKey: .authPort)
        try container.encode(readOnly, forKey: .readOnly)
        try container.encode(sessions, forKey: .sessions)
    }

    private enum CodingKeys: String, CodingKey {
        case debug
        case mountCheck
        case cacheMaxSeconds
        case cacheMaxItems
        case cacheStatfsSeconds
        case syncIntervalSeconds
        case mountOptions
        case authorizeUsingCode
        case renameIdenticalFiles
        case addExtensionsToSpecialFiles
        case skipTrash
        case clientSecret
        case authPort
        case readOnly
        case sessions
    }
}

public enum ContainerFiles {
    public static func config(_ container: URL) -> URL {
        container.appending(path: RuntimeBoundary.configFileName, directoryHint: .notDirectory)
    }

    public static func index(_ container: URL) -> URL {
        container.appending(path: RuntimeBoundary.indexFileName, directoryHint: .notDirectory)
    }

    public static func journal(_ container: URL) -> URL {
        container.appending(path: RuntimeBoundary.journalFileName, directoryHint: .notDirectory)
    }

    public static func staged(_ container: URL) -> URL {
        container.appending(path: RuntimeBoundary.stagedDirectoryName, directoryHint: .isDirectory)
    }

    public static func cache(_ container: URL) -> URL {
        container.appending(path: RuntimeBoundary.cacheDirectoryName, directoryHint: .isDirectory)
    }
}

public enum DriveSettingsError: Error, Equatable, Sendable {
    case missing
    case malformed
}

public enum DriveSettingsStore {
    public static func fileURL(container: URL) -> URL {
        ContainerFiles.config(container)
    }

    public static func load(container: URL) throws -> DriveSettings {
        let url = fileURL(container: container)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DriveSettingsError.missing
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DriveSettingsError.malformed
        }
        do {
            return try JSONDecoder().decode(DriveSettings.self, from: data)
        } catch {
            throw DriveSettingsError.malformed
        }
    }

    public static func save(_ settings: DriveSettings, container: URL) throws {
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: fileURL(container: container), options: .atomic)
    }
}

public enum LegacyConfigError: Error, Equatable, Sendable {
    case missingFile
    case unsupportedSyntax(line: Int)
    case unsupportedKey(String)
    case invalidValue(String)
    case duplicateKey(String)
}

public enum LegacyMigrationError: Error, Equatable, Sendable {
    case missingRefreshToken(String)
    case notVerified(String)
}

public enum LegacyConfigParser {
    public static func settings(toml: String) throws -> DriveSettings {
        var parser = LegacyTomlParser(toml)
        return try driveSettings(from: parser.parse())
    }
}

public enum LegacyMigration {
    public static func migrate(
        legacyDirectory: URL,
        container: URL,
        tokens: any RefreshTokenStore
    ) async throws -> DriveSettings {
        let tomlURL = legacyDirectory.appending(path: "gcsf.toml", directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: tomlURL.path) else {
            throw LegacyConfigError.missingFile
        }
        let toml = try String(contentsOf: tomlURL, encoding: .utf8)
        var settings = try LegacyConfigParser.settings(toml: toml)
        if FileManager.default.fileExists(atPath: DriveSettingsStore.fileURL(container: container).path) {
            settings.sessions = try DriveSettingsStore.load(container: container).sessions
        }
        let sessions = try legacySessions(in: legacyDirectory)
        settings.sessions = Array(Set(settings.sessions + sessions.map(\.name))).sorted()
        try DriveSettingsStore.save(settings, container: container)
        for session in sessions.sorted(by: { $0.name < $1.name }) {
            switch try refreshToken(in: session.url) {
            case .notSession:
                continue
            case .missing:
                throw LegacyMigrationError.missingRefreshToken(session.name)
            case let .token(refresh):
                try await tokens.store(session: session.name, refreshToken: refresh)
                let stored = try await tokens.load(session: session.name)
                guard stored == refresh else {
                    throw LegacyMigrationError.notVerified(session.name)
                }
                try FileManager.default.removeItem(at: session.url)
            }
        }
        return try DriveSettingsStore.load(container: container)
    }
}

private struct LegacySessionFile {
    var name: String
    var url: URL
}

private enum LegacyRefresh {
    case notSession
    case missing
    case token(String)
}

private func legacySessions(in directory: URL) throws -> [LegacySessionFile] {
    let urls = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: []
    )
    var sessions: [LegacySessionFile] = []
    for url in urls {
        let name = url.lastPathComponent
        if name == "gcsf.toml" {
            continue
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            continue
        }
        switch try refreshToken(in: url) {
        case .notSession:
            continue
        case .missing, .token:
            sessions.append(LegacySessionFile(name: name, url: url))
        }
    }
    return sessions
}

private func refreshToken(in url: URL) throws -> LegacyRefresh {
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        return .notSession
    }
    guard let json = try? JSONSerialization.jsonObject(with: data) else {
        return .notSession
    }
    let entries: [Any]
    if let array = json as? [Any] {
        entries = array
    } else if let object = json as? [String: Any], let tokens = object["tokens"] as? [Any] {
        entries = tokens
    } else {
        return .notSession
    }
    if entries.isEmpty {
        return .notSession
    }
    var records: [[String: Any]] = []
    for entry in entries {
        guard let record = entry as? [String: Any],
            record["scopes"] is [Any],
            record["token"] is [String: Any]
        else {
            return .notSession
        }
        records.append(record)
    }
    for record in records {
        guard let token = record["token"] as? [String: Any] else {
            return .notSession
        }
        if let refresh = token["refresh_token"] as? String, !refresh.isEmpty {
            return .token(refresh)
        }
    }
    return .missing
}

private enum TomlValue {
    case bool(Bool)
    case int(UInt64)
    case string(String)
    case array([String])
}

private func driveSettings(from pairs: [String: TomlValue]) throws -> DriveSettings {
    var settings = DriveSettings()
    for (key, value) in pairs {
        switch key {
        case "debug":
            settings.debug = try boolValue(value, key)
        case "mount_check":
            settings.mountCheck = try boolValue(value, key)
        case "cache_max_seconds":
            settings.cacheMaxSeconds = try intValue(value, key)
        case "cache_max_items":
            settings.cacheMaxItems = try intValue(value, key)
        case "cache_statfs_seconds":
            settings.cacheStatfsSeconds = try intValue(value, key)
        case "sync_interval":
            settings.syncIntervalSeconds = try intValue(value, key)
        case "mount_options":
            guard case let .array(options) = value else {
                throw LegacyConfigError.invalidValue(key)
            }
            settings.mountOptions = options
        case "authorize_using_code":
            settings.authorizeUsingCode = try boolValue(value, key)
        case "rename_identical_files":
            settings.renameIdenticalFiles = try boolValue(value, key)
        case "add_extensions_to_special_files":
            settings.addExtensionsToSpecialFiles = try boolValue(value, key)
        case "skip_trash":
            settings.skipTrash = try boolValue(value, key)
        case "client_secret":
            settings.clientSecret = try stringValue(value, key)
        case "auth_port":
            let port = try intValue(value, key)
            guard port <= UInt64(UInt16.max) else {
                throw LegacyConfigError.invalidValue(key)
            }
            settings.authPort = UInt16(port)
        case "read_only":
            settings.readOnly = try boolValue(value, key)
        default:
            throw LegacyConfigError.unsupportedKey(key)
        }
    }
    return settings
}

private func boolValue(_ value: TomlValue, _ key: String) throws -> Bool {
    guard case let .bool(bool) = value else {
        throw LegacyConfigError.invalidValue(key)
    }
    return bool
}

private func intValue(_ value: TomlValue, _ key: String) throws -> UInt64 {
    guard case let .int(int) = value else {
        throw LegacyConfigError.invalidValue(key)
    }
    return int
}

private func stringValue(_ value: TomlValue, _ key: String) throws -> String {
    guard case let .string(string) = value else {
        throw LegacyConfigError.invalidValue(key)
    }
    return string
}

private struct LegacyTomlParser {
    private let bytes: [UInt8]
    private var index = 0
    private var line = 1

    init(_ text: String) {
        var text = text
        if text.hasPrefix("\u{feff}") {
            text.removeFirst()
        }
        bytes = Array(text.utf8)
    }

    mutating func parse() throws -> [String: TomlValue] {
        var pairs: [String: TomlValue] = [:]
        while true {
            skipTrivia(newlines: true)
            if index >= bytes.count {
                return pairs
            }
            let startLine = line
            let key = try readKey()
            skipTrivia(newlines: false)
            guard consume(UInt8(ascii: "=")) else {
                throw LegacyConfigError.unsupportedSyntax(line: startLine)
            }
            skipTrivia(newlines: false)
            let value = try readValue()
            if pairs[key] != nil {
                throw LegacyConfigError.duplicateKey(key)
            }
            pairs[key] = value
            try finishLine()
        }
    }

    private mutating func readKey() throws -> String {
        let start = index
        guard index < bytes.count, isIdentStart(bytes[index]) else {
            throw LegacyConfigError.unsupportedSyntax(line: line)
        }
        index += 1
        while index < bytes.count, isIdent(bytes[index]) {
            index += 1
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func readValue() throws -> TomlValue {
        guard let byte = peek() else {
            throw LegacyConfigError.unsupportedSyntax(line: line)
        }
        if byte == UInt8(ascii: "\"") {
            return .string(try readQuoted())
        }
        if byte == UInt8(ascii: "'") {
            return .string(try readRaw())
        }
        if byte == UInt8(ascii: "[") {
            return .array(try readArray())
        }
        if byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") {
            return .int(try readInt())
        }
        if byte == UInt8(ascii: "t") || byte == UInt8(ascii: "f") {
            let word = try readKey()
            if word == "true" {
                return .bool(true)
            }
            if word == "false" {
                return .bool(false)
            }
            throw LegacyConfigError.unsupportedSyntax(line: line)
        }
        throw LegacyConfigError.unsupportedSyntax(line: line)
    }

    private mutating func readQuoted() throws -> String {
        if peek(1) == UInt8(ascii: "\""), peek(2) == UInt8(ascii: "\"") {
            index += 3
            return try readMultiline(delimiter: UInt8(ascii: "\""), escapes: true)
        }
        index += 1
        return try readBasicLine()
    }

    private mutating func readRaw() throws -> String {
        guard peek(1) == UInt8(ascii: "'"), peek(2) == UInt8(ascii: "'") else {
            throw LegacyConfigError.unsupportedSyntax(line: line)
        }
        index += 3
        return try readMultiline(delimiter: UInt8(ascii: "'"), escapes: false)
    }

    private mutating func readBasicLine() throws -> String {
        var collected: [UInt8] = []
        while let byte = peek() {
            if byte == UInt8(ascii: "\"") {
                index += 1
                return String(decoding: collected, as: UTF8.self)
            }
            if byte == 10 || byte == 13 {
                throw LegacyConfigError.unsupportedSyntax(line: line)
            }
            if byte == UInt8(ascii: "\\") {
                try appendEscape(&collected, allowLineTrim: false)
                continue
            }
            collected.append(byte)
            index += 1
        }
        throw LegacyConfigError.unsupportedSyntax(line: line)
    }

    private mutating func readMultiline(delimiter: UInt8, escapes: Bool) throws -> String {
        if peek() == 13 {
            index += 1
        }
        if peek() == 10 {
            index += 1
            line += 1
        }
        var collected: [UInt8] = []
        while index < bytes.count {
            if peek() == delimiter, peek(1) == delimiter, peek(2) == delimiter {
                index += 3
                return String(decoding: collected, as: UTF8.self)
            }
            let byte = bytes[index]
            if escapes, byte == UInt8(ascii: "\\") {
                try appendEscape(&collected, allowLineTrim: true)
                continue
            }
            if byte == 10 {
                line += 1
            }
            collected.append(byte)
            index += 1
        }
        throw LegacyConfigError.unsupportedSyntax(line: line)
    }

    private mutating func appendEscape(_ collected: inout [UInt8], allowLineTrim: Bool) throws {
        guard consume(UInt8(ascii: "\\")) else {
            throw LegacyConfigError.unsupportedSyntax(line: line)
        }
        guard let escaped = peek() else {
            throw LegacyConfigError.unsupportedSyntax(line: line)
        }
        if escaped == 13 || escaped == 10 {
            guard allowLineTrim else {
                throw LegacyConfigError.unsupportedSyntax(line: line)
            }
            if escaped == 13 {
                index += 1
            }
            if peek() == 10 {
                index += 1
            }
            line += 1
            while peek() == 32 || peek() == 9 {
                index += 1
            }
            return
        }
        index += 1
        switch escaped {
        case UInt8(ascii: "b"):
            collected.append(8)
        case UInt8(ascii: "t"):
            collected.append(9)
        case UInt8(ascii: "n"):
            collected.append(10)
        case UInt8(ascii: "f"):
            collected.append(12)
        case UInt8(ascii: "r"):
            collected.append(13)
        case UInt8(ascii: "\""):
            collected.append(UInt8(ascii: "\""))
        case UInt8(ascii: "\\"):
            collected.append(UInt8(ascii: "\\"))
        case UInt8(ascii: "u"):
            appendScalar(try readHex(count: 4), to: &collected)
        case UInt8(ascii: "U"):
            appendScalar(try readHex(count: 8), to: &collected)
        default:
            throw LegacyConfigError.unsupportedSyntax(line: line)
        }
    }

    private mutating func readHex(count: Int) throws -> UnicodeScalar {
        var number = 0
        for _ in 0..<count {
            guard let byte = peek() else {
                throw LegacyConfigError.unsupportedSyntax(line: line)
            }
            index += 1
            number <<= 4
            switch byte {
            case 48...57:
                number += Int(byte - 48)
            case 65...70:
                number += Int(byte - 65) + 10
            case 97...102:
                number += Int(byte - 97) + 10
            default:
                throw LegacyConfigError.unsupportedSyntax(line: line)
            }
        }
        guard let scalar = UnicodeScalar(number) else {
            throw LegacyConfigError.unsupportedSyntax(line: line)
        }
        return scalar
    }

    private func appendScalar(_ scalar: UnicodeScalar, to collected: inout [UInt8]) {
        collected.append(contentsOf: Array(String(scalar).utf8))
    }

    private mutating func readInt() throws -> UInt64 {
        let start = index
        while let byte = peek(), byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
            index += 1
        }
        if start == index {
            throw LegacyConfigError.unsupportedSyntax(line: line)
        }
        if let next = peek(), isIdent(next) || next == UInt8(ascii: ".") || next == UInt8(ascii: "_") {
            throw LegacyConfigError.unsupportedSyntax(line: line)
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        guard let value = UInt64(text) else {
            throw LegacyConfigError.unsupportedSyntax(line: line)
        }
        return value
    }

    private mutating func readArray() throws -> [String] {
        guard consume(UInt8(ascii: "[")) else {
            throw LegacyConfigError.unsupportedSyntax(line: line)
        }
        var items: [String] = []
        skipTrivia(newlines: true)
        if consume(UInt8(ascii: "]")) {
            return items
        }
        while true {
            let value = try readValue()
            guard case let .string(item) = value else {
                throw LegacyConfigError.unsupportedSyntax(line: line)
            }
            items.append(item)
            skipTrivia(newlines: true)
            if consume(UInt8(ascii: ",")) {
                skipTrivia(newlines: true)
                if consume(UInt8(ascii: "]")) {
                    return items
                }
                continue
            }
            guard consume(UInt8(ascii: "]")) else {
                throw LegacyConfigError.unsupportedSyntax(line: line)
            }
            return items
        }
    }

    private mutating func finishLine() throws {
        while let byte = peek() {
            if byte == 32 || byte == 9 || byte == 13 {
                index += 1
                continue
            }
            if byte == UInt8(ascii: "#") {
                index += 1
                while let next = peek(), next != 10 {
                    index += 1
                }
                continue
            }
            if byte == 10 {
                index += 1
                line += 1
                return
            }
            throw LegacyConfigError.unsupportedSyntax(line: line)
        }
    }

    private mutating func skipTrivia(newlines: Bool) {
        while let byte = peek() {
            if byte == 32 || byte == 9 || byte == 13 {
                index += 1
                continue
            }
            if byte == 10 {
                if !newlines {
                    return
                }
                index += 1
                line += 1
                continue
            }
            if byte == UInt8(ascii: "#") {
                index += 1
                while let next = peek(), next != 10 {
                    index += 1
                }
                continue
            }
            return
        }
    }

    private func peek(_ offset: Int = 0) -> UInt8? {
        let next = index + offset
        guard next >= 0, next < bytes.count else {
            return nil
        }
        return bytes[next]
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else {
            return false
        }
        index += 1
        return true
    }

    private func isIdentStart(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            || byte == UInt8(ascii: "_")
    }

    private func isIdent(_ byte: UInt8) -> Bool {
        isIdentStart(byte) || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
    }
}
