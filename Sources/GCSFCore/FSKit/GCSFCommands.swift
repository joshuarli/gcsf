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

    public init(
        home: URL,
        mountSingleVolume: @escaping @Sendable (URL, String, [String], @escaping @Sendable (URL?, (any Error)?) -> Void) -> Void,
        unmount: @escaping @Sendable (URL) throws -> Void
    ) {
        self.home = home
        self.mountSingleVolume = mountSingleVolume
        self.unmount = unmount
    }

    public static func live(unmount: @escaping @Sendable (URL) throws -> Void) -> GCSFCommandEnvironment {
        GCSFCommandEnvironment(
            home: FileManager.default.homeDirectoryForCurrentUser,
            mountSingleVolume: { url, bundleID, options, completion in
                let resource = FSGenericURLResource(url: url)
                FSClient.shared.mountSingleVolume(
                    resource: resource,
                    bundleID: bundleID,
                    options: options,
                    completionHandler: completion
                )
            },
            unmount: unmount
        )
    }
}

public enum GCSFCommandLine {
    public static let help = """
    usage: gcsf <command>

    commands:
      login
      logout
      list
      verify
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
        case "login", "logout", "list", "verify":
            guard rest.isEmpty else {
                return GCSFCommandResult(code: 2, out: "", err: help + "\n")
            }
            return GCSFCommandResult(code: 1, out: "", err: "\(command): not implemented\n")
        case "mount":
            return mount(rest, environment: environment)
        case "umount":
            return umount(rest, environment: environment)
        default:
            return GCSFCommandResult(code: 2, out: "", err: help + "\n")
        }
    }

    private static let mountUsage = """
    usage: gcsf mount -s <session>
    the OS returns the mount URL

    """

    private static let umountUsage = """
    usage: gcsf umount -s <session>

    """

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
}
