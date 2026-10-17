import AppKit
import Foundation
import FSKit
import Synchronization

public enum GCSFMount {
    public static let extensionBundleIdentifier = "com.joshuarli.gcsf.extension"
}

public struct GCSFCommandResult: Equatable, Sendable {
    public var code: Int32
    public var out: String
    public var err: String

    public init(code: Int32, out: String, err: String) {
        self.code = code
        self.out = out
        self.err = err
    }
}

public struct GCSFCommandEnvironment: Sendable {
    public var home: URL
    public var mountSingleVolume: @Sendable (URL, String, [String], @escaping @Sendable (URL?, (any Error)?) -> Void) -> Void
    public var unmount: @Sendable (URL) throws -> Void
    public var openBrowser: @Sendable (URL) async -> Void
    public var tokenEndpoint: URL
    public var tokens: any RefreshTokenStore
    public var legacyConfigDirectory: URL

    public init(
        home: URL,
        mountSingleVolume: @escaping @Sendable (URL, String, [String], @escaping @Sendable (URL?, (any Error)?) -> Void) -> Void,
        unmount: @escaping @Sendable (URL) throws -> Void,
        openBrowser: @escaping @Sendable (URL) async -> Void,
        tokenEndpoint: URL,
        tokens: any RefreshTokenStore,
        legacyConfigDirectory: URL
    ) {
        self.home = home
        self.mountSingleVolume = mountSingleVolume
        self.unmount = unmount
        self.openBrowser = openBrowser
        self.tokenEndpoint = tokenEndpoint
        self.tokens = tokens
        self.legacyConfigDirectory = legacyConfigDirectory
    }

    public static func live(unmount: @escaping @Sendable (URL) throws -> Void) -> GCSFCommandEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return GCSFCommandEnvironment(
            home: home,
            mountSingleVolume: { url, bundleID, options, completion in
                let resource = FSGenericURLResource(url: url)
                FSClient.shared.mountSingleVolume(
                    resource: resource,
                    bundleID: bundleID,
                    options: options,
                    completionHandler: completion
                )
            },
            unmount: unmount,
            openBrowser: { url in
                await MainActor.run {
                    _ = NSWorkspace.shared.open(url)
                }
            },
            tokenEndpoint: OAuthDrive.tokenEndpoint,
            tokens: KeychainRefreshTokenStore(),
            legacyConfigDirectory: home.appending(path: ".config/gcsf", directoryHint: .isDirectory)
        )
    }
}

public enum GCSFCommandLine {
    public static let help = """
    usage: gcsf <command>

    commands:
      login <session>
      logout <session>
      list
      verify <session>
      mount -s <session>
      umount -s <session>
    """

    public static func execute(_ args: [String], environment: GCSFCommandEnvironment) -> GCSFCommandResult {
        if args.contains("--help") || args.contains("-h") || args == ["help"] {
            return GCSFCommandResult(code: 0, out: help + "\n", err: "")
        }
        guard let command = args.first else {
            return GCSFCommandResult(code: 2, out: "", err: help + "\n")
        }
        let rest = Array(args.dropFirst())
        switch command {
        case "login":
            return login(rest, environment: environment)
        case "logout":
            return logout(rest, environment: environment)
        case "list":
            return list(rest, environment: environment)
        case "verify":
            return verify(rest, environment: environment)
        case "mount":
            return mount(rest, environment: environment)
        case "umount":
            return umount(rest, environment: environment)
        default:
            return GCSFCommandResult(code: 2, out: "", err: help + "\n")
        }
    }

    private static let loginUsage = """
    usage: gcsf login <session>

    """

    private static let logoutUsage = """
    usage: gcsf logout <session>

    """

    private static let listUsage = """
    usage: gcsf list

    """

    private static let verifyUsage = """
    usage: gcsf verify <session>

    """

    private static let mountUsage = """
    usage: gcsf mount -s <session>
    the OS returns the mount URL

    """

    private static let umountUsage = """
    usage: gcsf umount -s <session>

    """

    private static func login(_ args: [String], environment: GCSFCommandEnvironment) -> GCSFCommandResult {
        guard let session = sessionArgument(args) else {
            return GCSFCommandResult(code: 2, out: "", err: loginUsage)
        }
        return run("login") {
            try await performLogin(session: session, environment: environment)
        }
    }

    private static func logout(_ args: [String], environment: GCSFCommandEnvironment) -> GCSFCommandResult {
        guard let session = sessionArgument(args) else {
            return GCSFCommandResult(code: 2, out: "", err: logoutUsage)
        }
        return run("logout") {
            let container = RuntimeBoundary.groupContainerURL(home: environment.home)
            var settings: DriveSettings
            do {
                settings = try DriveSettingsStore.load(container: container)
            } catch let error as DriveSettingsError where error == .missing {
                throw SessionCommandError.missingSession
            }
            guard let index = settings.sessions.firstIndex(of: session) else {
                throw SessionCommandError.missingSession
            }
            try await environment.tokens.remove(session: session)
            settings.sessions.remove(at: index)
            try DriveSettingsStore.save(settings, container: container)
        }
    }

    private static func list(_ args: [String], environment: GCSFCommandEnvironment) -> GCSFCommandResult {
        guard args.isEmpty else {
            return GCSFCommandResult(code: 2, out: "", err: listUsage)
        }
        let container = RuntimeBoundary.groupContainerURL(home: environment.home)
        let settings: DriveSettings
        do {
            settings = try DriveSettingsStore.load(container: container)
        } catch let error as DriveSettingsError where error == .missing {
            return GCSFCommandResult(code: 0, out: "", err: "")
        } catch {
            return GCSFCommandResult(code: 1, out: "", err: "list: \(publicMessage(error))\n")
        }
        let out = settings.sessions.sorted().map { $0 + "\n" }.joined()
        return GCSFCommandResult(code: 0, out: out, err: "")
    }

    private static func verify(_ args: [String], environment: GCSFCommandEnvironment) -> GCSFCommandResult {
        guard let session = sessionArgument(args) else {
            return GCSFCommandResult(code: 2, out: "", err: verifyUsage)
        }
        return run("verify") {
            let container = RuntimeBoundary.groupContainerURL(home: environment.home)
            let settings: DriveSettings
            do {
                settings = try DriveSettingsStore.load(container: container)
            } catch let error as DriveSettingsError where error == .missing {
                throw SessionCommandError.missingSession
            }
            guard settings.sessions.contains(session) else {
                throw SessionCommandError.missingSession
            }
            guard let document = settings.clientSecret, document.isEmpty == false else {
                throw OAuthError.invalidClientDocument
            }
            let client = try OAuthClient(document: document)
            let stored = try await environment.tokens.load(session: session)
            guard let stored, stored.isEmpty == false else {
                throw OAuthError.missingRefreshToken
            }
            let manager = TokenManager(
                client: client,
                tokenEndpoint: environment.tokenEndpoint,
                tokens: environment.tokens
            )
            _ = try await manager.refresh(session: session)
        }
    }

    private static func performLogin(session: String, environment: GCSFCommandEnvironment) async throws {
        let container = RuntimeBoundary.groupContainerURL(home: environment.home)
        var settings = try await loadSettings(environment: environment)
        guard let document = settings.clientSecret, document.isEmpty == false else {
            throw OAuthError.invalidClientDocument
        }
        let client = try OAuthClient(document: document)
        _ = try await OAuthAuthorization.login(
            client: client,
            session: session,
            port: settings.authPort,
            tokenEndpoint: environment.tokenEndpoint,
            tokens: environment.tokens,
            openBrowser: environment.openBrowser
        )
        if settings.sessions.contains(session) == false {
            settings.sessions.append(session)
        }
        settings.sessions.sort()
        try DriveSettingsStore.save(settings, container: container)
    }

    private static func loadSettings(environment: GCSFCommandEnvironment) async throws -> DriveSettings {
        let container = RuntimeBoundary.groupContainerURL(home: environment.home)
        do {
            return try DriveSettingsStore.load(container: container)
        } catch let error as DriveSettingsError {
            guard error == .missing else { throw error }
        }
        let legacy = environment.legacyConfigDirectory
        let toml = legacy.appending(path: "gcsf.toml", directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: toml.path) else {
            throw DriveSettingsError.missing
        }
        return try await LegacyMigration.migrate(
            legacyDirectory: legacy,
            container: container,
            tokens: environment.tokens
        )
    }

    private static func mount(_ args: [String], environment: GCSFCommandEnvironment) -> GCSFCommandResult {
        guard let session = parsedSession(args) else {
            return GCSFCommandResult(code: 2, out: "", err: mountUsage)
        }
        guard let url = DriveVolumeAddress.url(session: session) else {
            return GCSFCommandResult(code: 1, out: "", err: "mount: invalid session\n")
        }
        let ledger = SessionMountLedger(home: environment.home)
        let box = Mutex<(URL?, (any Error)?)?>(nil)
        let once = OnceReply<(URL?, (any Error)?)>()
        environment.mountSingleVolume(url, GCSFMount.extensionBundleIdentifier, []) { mounted, error in
            once.send((mounted, error)) { result in
                box.withLock { $0 = result }
            }
        }
        while box.withLock({ $0 == nil }) {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        let result = box.withLock { $0 }
        guard let mounted = result?.0, result?.1 == nil else {
            let message = (result?.1 as NSError?)?.localizedDescription ?? "mount failed"
            return GCSFCommandResult(code: 1, out: "", err: "mount: \(message)\n")
        }
        do {
            try ledger.store(mounted, for: session)
        } catch {
            return GCSFCommandResult(code: 1, out: "", err: "mount: failed to store \(mounted.absoluteString): \(error)\n")
        }
        return GCSFCommandResult(code: 0, out: mounted.absoluteString + "\n", err: "")
    }

    private static func umount(_ args: [String], environment: GCSFCommandEnvironment) -> GCSFCommandResult {
        guard let session = parsedSession(args) else {
            return GCSFCommandResult(code: 2, out: "", err: umountUsage)
        }
        let ledger = SessionMountLedger(home: environment.home)
        let stored: URL?
        do {
            stored = try ledger.url(for: session)
        } catch {
            return GCSFCommandResult(code: 1, out: "", err: "umount: \(error)\n")
        }
        guard let stored else {
            return GCSFCommandResult(code: 1, out: "", err: "umount: no stored URL for \(session)\n")
        }
        do {
            try environment.unmount(stored)
            try ledger.remove(session)
        } catch {
            return GCSFCommandResult(code: 1, out: "", err: "umount: \(error)\n")
        }
        return GCSFCommandResult(code: 0, out: "", err: "")
    }

    private static func parsedSession(_ args: [String]) -> String? {
        var session: String?
        var positionals: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "-s" {
                guard index + 1 < args.count, session == nil else { return nil }
                index += 1
                let value = args[index]
                if value.isEmpty { return nil }
                session = value
            } else if arg.hasPrefix("-") {
                return nil
            } else {
                positionals.append(arg)
            }
            index += 1
        }
        guard let session, positionals.isEmpty else { return nil }
        return session
    }

    private static func sessionArgument(_ args: [String]) -> String? {
        guard args.count == 1 else { return nil }
        let session = args[0]
        guard session.isEmpty == false, session.hasPrefix("-") == false else { return nil }
        return session
    }

    private static func run(
        _ command: String,
        _ body: @escaping @Sendable () async throws -> Void
    ) -> GCSFCommandResult {
        let box = Mutex<WaitResult?>(nil)
        let once = OnceReply<WaitResult>()
        Task {
            let result: WaitResult
            do {
                try await body()
                result = .success
            } catch {
                result = .failure(publicMessage(error))
            }
            once.send(result) { value in
                box.withLock { $0 = value }
            }
        }
        while box.withLock({ $0 == nil }) {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        switch box.withLock({ $0 }) {
        case .success:
            return GCSFCommandResult(code: 0, out: "", err: "")
        case .failure(let message):
            return GCSFCommandResult(code: 1, out: "", err: "\(command): \(message)\n")
        case nil:
            return GCSFCommandResult(code: 1, out: "", err: "\(command): failed\n")
        }
    }

    private static func publicMessage(_ error: Error) -> String {
        if let error = error as? DriveSettingsError {
            switch error {
            case .missing:
                return "missing config"
            case .malformed:
                return "malformed config"
            }
        }
        if let error = error as? OAuthError {
            switch error {
            case .invalidClientDocument:
                return "invalid client document"
            case .stateMismatch:
                return "state mismatch"
            case .missingCode:
                return "missing code"
            case .providerRejected:
                return "provider rejected the login"
            case .missingRefreshToken:
                return "missing refresh token"
            case .notStored:
                return "refresh token was not stored"
            case .tokenRejected(let status):
                return "token request failed (\(status))"
            case .malformedTokenResponse:
                return "malformed token response"
            case .timedOut:
                return "timed out"
            case .loopbackFailed:
                return "loopback failed"
            }
        }
        if let error = error as? LegacyMigrationError {
            switch error {
            case .missingRefreshToken(let session):
                return "missing refresh token for \(session)"
            case .notVerified(let session):
                return "refresh token was not stored for \(session)"
            }
        }
        if error is LegacyConfigError {
            return "invalid legacy config"
        }
        if error is SessionCommandError {
            return "missing session"
        }
        return "failed"
    }
}

private enum WaitResult: Sendable {
    case success
    case failure(String)
}

private enum SessionCommandError: Error {
    case missingSession
}
