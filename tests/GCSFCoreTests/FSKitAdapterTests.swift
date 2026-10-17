import Darwin
import Foundation
import FSKit
import ObjectiveC
import Synchronization
import Testing
@testable import GCSFCore

@Suite struct FSKitAdapterTests {
    @Test func loadResourceReturnsOneNamedVolumePerSession() async throws {
        let system = GCSFFileSystem { _ in ScriptedEngine() }
        let mine = FSGenericURLResource(url: try #require(DriveVolumeAddress.url(session: "MySession")))
        let other = FSGenericURLResource(url: try #require(DriveVolumeAddress.url(session: "Other")))
        let options = FSKitObjects.options()
        let first = try await loadedVolume(system, resource: mine, options: options)
        let second = try await loadedVolume(system, resource: mine, options: options)
        let third = try await loadedVolume(system, resource: other, options: options)
        #expect(first === second)
        #expect(first !== third)
        #expect(first.session == "MySession")
        #expect(first.name.string == "MySession")
        #expect(third.name.string == "Other")
        let replies = Mutex(0)
        system.loadResource(resource: FSGenericURLResource(url: URL(fileURLWithPath: "/tmp/not-gdrive")), options: options) { volume, error in
            replies.withLock { $0 += 1 }
            #expect(volume == nil)
            #expect(error != nil)
        }
        try await waitUntil { replies.withLock { $0 } == 1 }
        #expect(replies.withLock { $0 } == 1)
    }

    @Test func probeRecognizesOnlyGDriveURLs() {
        let system = GCSFFileSystem { _ in ScriptedEngine() }
        let once = Mutex(0)
        system.probeResource(resource: FSGenericURLResource(url: tryURL("gdrive://Work")), replyHandler: { result, error in
            once.withLock { $0 += 1 }
            #expect(error == nil)
            #expect(result?.result == .usable)
            #expect(result?.name == "Work")
        })
        #expect(once.withLock { $0 } == 1)
        system.probeResource(resource: FSGenericURLResource(url: URL(fileURLWithPath: "/tmp/disk")), replyHandler: { result, error in
            once.withLock { $0 += 1 }
            #expect(error == nil)
            #expect(result?.result == .notRecognized)
        })
        #expect(once.withLock { $0 } == 2)
    }

    @Test func openGrantsNoCacheForEveryMode() async throws {
        let volume = try await activatedVolume()
        let root = try await rootItem(volume)
        let context = FSKitObjects.context()
        for mode in [FSVolume.DataCacheMode.none, .readWithCache, .readWriteWithCache] {
            let opened = try await volume.open(root, modes: [.read], cacheMode: mode, context: context)
            #expect(FSKitObjects.grantedCoherency(opened) == FSVolume.KernelCacheCoherencyType.noCache.rawValue)
        }
        let upgraded = try await volume.upgrade(root, cacheMode: .readWriteWithCache, context: context)
        #expect(FSKitObjects.grantedCoherency(upgraded) == FSVolume.KernelCacheCoherencyType.noCache.rawValue)
        let erased = volume as Any
        #expect(erased is FSVolume.Handler)
        #expect(erased is FSVolume.ReadWriteHandler)
        #expect(erased is FSVolume.XattrHandler)
        #expect(erased is FSVolume.DataCacheHandler)
        #expect((volume as Any) is FSVolume.OpenCloseHandler == false)
        #expect((volume as Any) is FSVolume.Operations == false)
    }

    @Test func lookupRunsOffTheCallbackTaskAndReusesTheItem() async throws {
        let engine = ScriptedEngine()
        engine.lookupImpl = { name, parent in
            #expect(FSKitCallbackTask.isServingCallback == false)
            #expect(parent == AttributeMapping.rootInode)
            return EngineItem(inode: Inode(rawValue: 9), name: name, kind: .file)
        }
        engine.attributesImpl = { inode in
            attributes(inode, kind: inode == AttributeMapping.rootInode ? .directory : .file, size: 4)
        }
        let volume = GCSFVolume(session: "Work", engine: engine, readOnly: false)
        _ = try await volume.activateVolume(options: FSKitObjects.options())
        let root = try await rootItem(volume)
        let context = FSKitObjects.context()
        let first = try await volume.lookupItem(named: FSFileName(string: "Notes"), in: root, context: context)
        let second = try await volume.lookupItem(named: FSFileName(string: "Notes"), in: root, context: context)
        let firstItem = try #require(FSKitObjects.object(first, "_foundItem", GCSFItem.self))
        let secondItem = try #require(FSKitObjects.object(second, "_foundItem", GCSFItem.self))
        #expect(firstItem === secondItem)
        #expect(firstItem.inode == Inode(rawValue: 9))
        #expect(engine.calls().contains("lookup"))
    }

    @Test func readCopiesOnlyIntoTheDestination() async throws {
        var destination = [UInt8](repeating: 0, count: 4)
        let copied = destination.withUnsafeMutableBytes { buffer in
            AttributeMapping.copy(Data("abcdef".utf8), into: buffer, limit: 10)
        }
        #expect(copied == 4)
        #expect(destination == Array("abcd".utf8))
        let engine = ScriptedEngine()
        engine.readImpl = { inode, offset, length in
            #expect(inode == Inode(rawValue: 9))
            #expect(offset == 2)
            #expect(length == 6)
            return Data("abcdef".utf8)
        }
        engine.attributesImpl = { attributes($0, kind: .file, size: 6) }
        let volume = try await fileVolume(engine)
        let file = try await fileItem(volume)
        let read = try await volume.read(from: file, at: 2, length: 6, into: FSKitObjects.buffer())
        #expect(FSKitObjects.unsigned(read, "_actuallyRead") == 0)
    }

    @Test func writeRenameRemoveAndXattrCallTheEngine() async throws {
        let engine = ScriptedEngine()
        engine.attributesImpl = { inode in
            attributes(inode, kind: inode == AttributeMapping.rootInode ? .directory : .file, size: 3)
        }
        engine.writeImpl = { _, bytes, offset in
            #expect(bytes == Data("xyz".utf8))
            #expect(offset == 1)
            return bytes.count
        }
        engine.renameImpl = { inode, _, _, _, toName, _ in
            EngineItem(inode: inode, name: toName, kind: .file)
        }
        engine.xattrImpl = { _, _ in Data("id".utf8) }
        engine.namesImpl = { _ in ["user.gcsf.id"] }
        let volume = try await fileVolume(engine)
        let file = try await fileItem(volume)
        let root = try await rootItem(volume)
        let context = FSKitObjects.context()
        let written = try await volume.write(contents: Data("xyz".utf8), to: file, at: 1)
        #expect(FSKitObjects.unsigned(written, "_actuallyWritten") == 3)
        _ = try await volume.renameItem(
            file,
            inDirectory: root,
            named: FSFileName(string: "Notes"),
            to: FSFileName(string: "Moved"),
            inDirectory: root,
            overItem: nil,
            context: context
        )
        _ = try await volume.removeItem(file, named: FSFileName(string: "Moved"), from: root, context: context)
        let value = try await volume.xattr(named: FSFileName(string: "user.gcsf.id"), of: file, context: context)
        let data = try #require(FSKitObjects.object(value, "_value", NSData.self)) as Data
        #expect(data == Data("id".utf8))
        _ = try await volume.setXattr(named: FSFileName(string: "user.gcsf.id"), to: Data("new".utf8), on: file, policy: .mustReplace, context: context)
        #expect(engine.calls().contains("write"))
        #expect(engine.calls().contains("rename"))
        #expect(engine.calls().contains("remove"))
        #expect(engine.calls().contains("setXattr"))
    }

    @Test func readOnlyWriteDoesNotCallTheEngine() async throws {
        let engine = ScriptedEngine()
        engine.attributesImpl = { attributes($0, kind: .file, size: 1) }
        let volume = GCSFVolume(session: "Work", engine: engine, readOnly: true)
        _ = try await volume.activateVolume(options: FSKitObjects.options())
        let root = try await rootItem(volume)
        let context = FSKitObjects.context()
        engine.lookupImpl = { name, _ in EngineItem(inode: Inode(rawValue: 9), name: name, kind: .file) }
        let found = try await volume.lookupItem(named: FSFileName(string: "Notes"), in: root, context: context)
        let file = try #require(FSKitObjects.object(found, "_foundItem", GCSFItem.self))
        #expect(await thrownPOSIX {
            _ = try await volume.write(contents: Data([1]), to: file, at: 0)
        } != nil)
        #expect(engine.calls().contains("write") == false)
    }

    @Test func hardLinksAndLocalSymlinkCreationAreUnsupported() async throws {
        let volume = try await activatedVolume()
        let root = try await rootItem(volume)
        let context = FSKitObjects.context()
        #expect(await thrownPOSIX {
            _ = try await volume.createLink(to: root, named: FSFileName(string: "hard"), in: root, context: context)
        } != nil)
        #expect(await thrownPOSIX {
            _ = try await volume.createSymbolicLink(
                named: FSFileName(string: "link"),
                in: root,
                attributes: FSItem.SetAttributesRequest(),
                linkContents: FSFileName(string: "target"),
                context: context
            )
        } != nil)
    }

    @Test func enumerationPlansDotsThenEngineCookies() {
        let page = EngineEnumeration(
            entries: [
                EngineDirectoryEntry(
                    name: "Notes",
                    item: EngineItem(inode: Inode(rawValue: 9), name: "Notes", kind: .file),
                    cookie: EngineDirectoryCookie(rawValue: 1)
                )
            ],
            verifier: 7,
            nextCookie: nil
        )
        let planned = AttributeMapping.plan(directory: 1, parent: 1, cookie: 0, includeDots: true, page: page)
        #expect(planned.map(\.name) == [".", "..", "Notes"])
        #expect(planned.map(\.nextCookie) == [1, 2, 3])
        #expect(AttributeMapping.engineCookie(from: 3, includeDots: true) == 1)
        let resumed = AttributeMapping.plan(directory: 1, parent: 1, cookie: 3, includeDots: true, page: page)
        #expect(resumed.map(\.name) == ["Notes"])
    }

    @Test func unmountWaitsForTheInFlightLookup() async throws {
        let engine = ScriptedEngine()
        engine.blockLookups = true
        engine.lookupImpl = { name, _ in
            EngineItem(inode: Inode(rawValue: 9), name: name, kind: .file)
        }
        engine.attributesImpl = { attributes($0, kind: .file, size: 0) }
        let volume = GCSFVolume(session: "Work", engine: engine, readOnly: false)
        _ = try await volume.activateVolume(options: FSKitObjects.options())
        let root = try await rootItem(volume)
        let context = FSKitObjects.context()
        nonisolated(unsafe) let operationContext = context
        let lookup = Task {
            _ = try await volume.lookupItem(named: FSFileName(string: "Notes"), in: root, context: operationContext)
        }
        await engine.waitUntilLookupBlocked()
        let finished = Mutex(false)
        let unmount = Task {
            await volume.unmount()
            finished.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(finished.withLock { $0 } == false)
        engine.releaseLookup()
        _ = try await lookup.value
        await unmount.value
        #expect(finished.withLock { $0 })
        #expect(await thrownPOSIX {
            _ = try await volume.lookupItem(named: FSFileName(string: "Notes"), in: root, context: context)
        } != nil)
    }

    @Test func kernelCachePortCallsSetCacheStateWithoutClaimingAnEffect() async throws {
        let volume = try await activatedVolume()
        await volume.invalidateCachedItem(AttributeMapping.rootInode)
        await volume.revokeCachedItem(AttributeMapping.rootInode)
        let attempts = volume.kernelCacheAttempts()
        #expect(attempts.count == 2)
        #expect(attempts.map(\.action) == [.invalidate, .revoke])
        #expect(attempts.allSatisfy { $0.calledSetCacheState && $0.kernelEffectVerified == false && $0.kernelErrorCode != nil })
    }

    @Test func replyFiresOnce() {
        let once = OnceReply<Int>()
        let hits = Mutex(0)
        once.send(1) { _ in hits.withLock { $0 += 1 } }
        once.send(2) { _ in hits.withLock { $0 += 1 } }
        #expect(hits.withLock { $0 } == 1)
    }

    @Test func mountRejectsAPositionalDirectoryAndPersistsOnlyAReturnedURL() throws {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let calls = Mutex<[MountCall]>([])
        let environment = commandEnvironment(
            home: home,
            mountSingleVolume: { url, bundleID, options, completion in
                calls.withLock { $0.append(MountCall(url: url, bundleID: bundleID, options: options)) }
                completion(URL(fileURLWithPath: "/Volumes/GCSFTest"), nil)
            }
        )
        let positional = GCSFCommandLine.execute(["mount", "-s", "Work", "/tmp/mount"], environment: environment)
        #expect(positional.code == 2)
        #expect(calls.withLock { $0.isEmpty })
        let missing = GCSFCommandLine.execute(["umount", "-s", "Work"], environment: environment)
        #expect(missing.code != 0)
        #expect(missing.err.contains("no stored URL"))
        let failed = commandEnvironment(
            home: home,
            mountSingleVolume: { _, _, _, completion in
                completion(nil, NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "identity unavailable"]))
            }
        )
        let denied = GCSFCommandLine.execute(["mount", "-s", "Work"], environment: failed)
        #expect(denied.code != 0)
        #expect(denied.out.isEmpty)
        #expect(denied.err.contains("identity unavailable"))
        let ledger = SessionMountLedger(home: home)
        #expect(try ledger.url(for: "Work") == nil)
        #expect(ledger.directory == RuntimeBoundary.groupContainerURL(home: home))
        let mounted = GCSFCommandLine.execute(["mount", "-s", "Work"], environment: environment)
        #expect(mounted.code == 0)
        #expect(mounted.out == "file:///Volumes/GCSFTest\n")
        #expect(calls.withLock { $0 } == [MountCall(url: try #require(DriveVolumeAddress.url(session: "Work")), bundleID: GCSFMount.extensionBundleIdentifier, options: [])])
        #expect(try ledger.url(for: "Work") == URL(fileURLWithPath: "/Volumes/GCSFTest"))
        #expect(ledger.directory.path.hasPrefix(home.path))
        let removed = Mutex(false)
        let unmounting = commandEnvironment(
            home: home,
            unmount: { url in
                #expect(url == URL(fileURLWithPath: "/Volumes/GCSFTest"))
                removed.withLock { $0 = true }
            }
        )
        let unmounted = GCSFCommandLine.execute(["umount", "-s", "Work"], environment: unmounting)
        #expect(unmounted.code == 0)
        #expect(removed.withLock { $0 })
        #expect(try ledger.url(for: "Work") == nil)
        let again = GCSFCommandLine.execute(["umount", "-s", "Work"], environment: unmounting)
        #expect(again.code != 0)
    }

    @Test func sessionCommandsLoginLogoutListAndVerify() throws {
        let home = scratchHome()
        let legacy = home.appending(path: "legacy", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let secret = "{\"installed\":{\"client_id\":\"cid\",\"client_secret\":\"csec\"}}"
        let toml = """
        client_secret = \"\"\"
        \(secret)\"\"\"
        """
        try toml.write(to: legacy.appending(path: "gcsf.toml"), atomically: true, encoding: .utf8)
        let beta = """
        [{"scopes":["https://www.googleapis.com/auth/drive"],"token":{"refresh_token":"refresh-beta","access_token":"access-beta"}}]
        """
        try beta.write(to: legacy.appending(path: "beta"), atomically: true, encoding: .utf8)
        let tokens = CommandMemoryTokens()
        let seen = Mutex<[URL]>([])
        let server = try CommandTokenServer { body in
            if body.contains("grant_type=refresh_token") {
                return (200, "{\"access_token\":\"access-verify\",\"expires_in\":30}")
            }
            return (200, "{\"access_token\":\"access-login\",\"refresh_token\":\"refresh-login\",\"expires_in\":60}")
        }
        defer { server.stop() }
        let environment = commandEnvironment(
            home: home,
            tokens: tokens,
            tokenEndpoint: server.endpoint,
            legacyConfigDirectory: legacy,
            openBrowser: { url in
                seen.withLock { $0.append(url) }
                await commandCallback(auth: url, code: "auth-code")
            }
        )
        let container = RuntimeBoundary.groupContainerURL(home: home)
        let absent = GCSFCommandLine.execute(["list"], environment: environment)
        #expect(absent.code == 0)
        #expect(absent.out.isEmpty)
        let settings = DriveSettings(
            clientSecret: secret,
            authPort: 0,
            sessions: ["zeta", "alpha"]
        )
        try DriveSettingsStore.save(settings, container: container)
        let noSession = GCSFCommandLine.execute(["login"], environment: environment)
        #expect(noSession.code == 2)
        #expect(seen.withLock { $0.isEmpty })
        #expect(server.count == 0)
        #expect(GCSFCommandLine.execute(["list", "extra"], environment: environment).code == 2)
        let listed = GCSFCommandLine.execute(["list"], environment: environment)
        #expect(listed.code == 0)
        #expect(listed.out == "alpha\nzeta\n")
        let missingToken = GCSFCommandLine.execute(["verify", "alpha"], environment: environment)
        #expect(missingToken.code == 1)
        #expect(server.count == 0)
        #expect(secretFree(missingToken))
        #expect(GCSFCommandLine.execute(["verify"], environment: environment).code == 2)
        let logged = GCSFCommandLine.execute(["login", "work"], environment: environment)
        #expect(logged.code == 0)
        #expect(secretFree(logged))
        #expect(tokens.snapshot() == ["work": "refresh-login"])
        let loaded = try DriveSettingsStore.load(container: container)
        #expect(loaded.sessions == ["alpha", "work", "zeta"])
        let configText = try String(contentsOf: DriveSettingsStore.fileURL(container: container), encoding: .utf8)
        #expect(configText.contains("refresh-login") == false)
        #expect(configText.contains("access-login") == false)
        #expect(configText.contains("refresh-beta") == false)
        #expect(FileManager.default.fileExists(atPath: legacy.appending(path: "beta").path))
        let urls = seen.withLock { $0 }
        #expect(urls.count == 1)
        #expect(urls.first?.host == "accounts.google.com")
        let verified = GCSFCommandLine.execute(["verify", "work"], environment: environment)
        #expect(verified.code == 0)
        #expect(secretFree(verified))
        #expect(server.count == 2)
        let loggedOut = GCSFCommandLine.execute(["logout", "work"], environment: environment)
        #expect(loggedOut.code == 0)
        #expect(tokens.snapshot()["work"] == nil)
        #expect(try DriveSettingsStore.load(container: container).sessions == ["alpha", "zeta"])
        #expect(GCSFCommandLine.execute(["logout", "work"], environment: environment).code == 1)
        #expect(GCSFCommandLine.execute(["logout"], environment: environment).code == 2)
        let gone = GCSFCommandLine.execute(["verify", "work"], environment: environment)
        #expect(gone.code == 1)
        #expect(secretFree(gone))
        #expect(server.count == 2)
        let again = GCSFCommandLine.execute(["list"], environment: environment)
        #expect(again.out == "alpha\nzeta\n")
    }

    @Test func loginMigratesWhenConfigIsMissing() throws {
        let home = scratchHome()
        let legacy = home.appending(path: "legacy", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        let early = Mutex(0)
        let withoutLegacy = commandEnvironment(
            home: home,
            legacyConfigDirectory: legacy,
            openBrowser: { _ in
                early.withLock { $0 += 1 }
            }
        )
        let blocked = GCSFCommandLine.execute(["login", "work"], environment: withoutLegacy)
        #expect(blocked.code == 1)
        #expect(early.withLock { $0 } == 0)
        let container = RuntimeBoundary.groupContainerURL(home: home)
        #expect(FileManager.default.fileExists(atPath: DriveSettingsStore.fileURL(container: container).path) == false)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let secret = "{\"installed\":{\"client_id\":\"cid\",\"client_secret\":\"csec\"}}"
        let toml = """
        debug = false
        auth_port = 0
        client_secret = \"\"\"
        \(secret)\"\"\"
        """
        try toml.write(to: legacy.appending(path: "gcsf.toml"), atomically: true, encoding: .utf8)
        let alpha = """
        [{"scopes":["https://www.googleapis.com/auth/drive"],"token":{"refresh_token":"refresh-alpha","access_token":"access-alpha"}}]
        """
        try alpha.write(to: legacy.appending(path: "alpha"), atomically: true, encoding: .utf8)
        let tokens = CommandMemoryTokens()
        let seen = Mutex<[URL]>([])
        let server = try CommandTokenServer { _ in
            (200, "{\"access_token\":\"access-login\",\"refresh_token\":\"refresh-login\",\"expires_in\":60}")
        }
        defer { server.stop() }
        let environment = commandEnvironment(
            home: home,
            tokens: tokens,
            tokenEndpoint: server.endpoint,
            legacyConfigDirectory: legacy,
            openBrowser: { url in
                seen.withLock { $0.append(url) }
                await commandCallback(auth: url, code: "auth-code")
            }
        )
        let logged = GCSFCommandLine.execute(["login", "work"], environment: environment)
        #expect(logged.code == 0)
        #expect(secretFree(logged))
        let loaded = try DriveSettingsStore.load(container: container)
        #expect(loaded.sessions == ["alpha", "work"])
        #expect(loaded.clientSecret == secret)
        #expect(loaded.authPort == 0)
        #expect(tokens.snapshot()["alpha"] == "refresh-alpha")
        #expect(tokens.snapshot()["work"] == "refresh-login")
        #expect(FileManager.default.fileExists(atPath: legacy.appending(path: "alpha").path) == false)
        #expect(FileManager.default.fileExists(atPath: legacy.appending(path: "gcsf.toml").path))
        let configText = try String(contentsOf: DriveSettingsStore.fileURL(container: container), encoding: .utf8)
        #expect(configText.contains("refresh-alpha") == false)
        #expect(configText.contains("access-alpha") == false)
        #expect(configText.contains("refresh-login") == false)
        #expect(configText.contains("access-login") == false)
        #expect(seen.withLock { $0.count } == 1)
        #expect(home.path.hasPrefix("/Users/josh/d/gcsf/.work/tmp/cli"))
    }
}

private struct MountCall: Equatable {
    var url: URL
    var bundleID: String
    var options: [String]
}

private func scratchHome() -> URL {
    URL(fileURLWithPath: "/Users/josh/d/gcsf/.work/tmp/cli", isDirectory: true)
        .appending(path: "home-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private func commandEnvironment(
    home: URL,
    tokens: any RefreshTokenStore = CommandMemoryTokens(),
    tokenEndpoint: URL = URL(string: "http://127.0.0.1:9/token")!,
    legacyConfigDirectory: URL? = nil,
    openBrowser: @escaping @Sendable (URL) async -> Void = { _ in },
    mountSingleVolume: @escaping @Sendable (URL, String, [String], @escaping @Sendable (URL?, (any Error)?) -> Void) -> Void = { _, _, _, _ in },
    unmount: @escaping @Sendable (URL) throws -> Void = { _ in }
) -> GCSFCommandEnvironment {
    GCSFCommandEnvironment(
        home: home,
        mountSingleVolume: mountSingleVolume,
        unmount: unmount,
        openBrowser: openBrowser,
        tokenEndpoint: tokenEndpoint,
        tokens: tokens,
        legacyConfigDirectory: legacyConfigDirectory ?? home.appending(path: "legacy", directoryHint: .isDirectory)
    )
}

private func secretFree(_ result: GCSFCommandResult) -> Bool {
    let text = result.out + result.err
    let forbidden = [
        "refresh-login",
        "access-login",
        "access-verify",
        "refresh-alpha",
        "access-alpha",
        "refresh-beta",
        "access-beta",
    ]
    return forbidden.allSatisfy { text.contains($0) == false }
}

private func commandCallback(auth: URL, code: String) async {
    let items = URLComponents(url: auth, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func value(_ name: String) -> String? {
        items.first { $0.name == name }?.value
    }
    guard let redirect = value("redirect_uri"), var components = URLComponents(string: redirect) else {
        return
    }
    components.queryItems = [
        URLQueryItem(name: "code", value: code),
        URLQueryItem(name: "state", value: value("state")),
    ]
    guard let url = components.url else { return }
    let session = URLSession(configuration: .ephemeral)
    defer { session.finishTasksAndInvalidate() }
    _ = try? await session.data(from: url)
}

private final class CommandMemoryTokens: RefreshTokenStore, @unchecked Sendable {
    private let values = Mutex<[String: String]>([:])

    func load(session: String) async throws -> String? {
        values.withLock { $0[session] }
    }

    func store(session: String, refreshToken: String) async throws {
        values.withLock { $0[session] = refreshToken }
    }

    func remove(session: String) async throws {
        values.withLock { $0[session] = nil }
    }

    func snapshot() -> [String: String] {
        values.withLock { $0 }
    }
}

private final class CommandTokenServer: @unchecked Sendable {
    let endpoint: URL
    private let lock = NSLock()
    private var listenFD: Int32
    private var hits = 0
    private let queue = DispatchQueue(label: "gcsf.test.command-token")
    private let respond: @Sendable (String) -> (Int, String)

    init(respond: @escaping @Sendable (String) -> (Int, String)) throws {
        self.respond = respond
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            Darwin.close(fd)
            throw POSIXError(.EIO)
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.bind(fd, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EIO)
        }
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.getsockname(fd, raw, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EIO)
        }
        listenFD = fd
        let port = UInt16(bigEndian: boundAddress.sin_port)
        endpoint = URL(string: "http://127.0.0.1:\(port)/token")!
        queue.async { [weak self] in
            self?.acceptLoop(fd)
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return hits
    }

    func stop() {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 {
            Darwin.close(fd)
        }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            serve(client)
            Darwin.close(client)
        }
    }

    private func serve(_ fd: Int32) {
        guard let body = try? readBody(fd) else { return }
        lock.lock()
        hits += 1
        let handler = respond
        lock.unlock()
        let (status, payload) = handler(body)
        var bytes = Data("HTTP/1.1 \(status) OK\r\nContent-Length: \(payload.utf8.count)\r\nConnection: close\r\nContent-Type: application/json\r\n\r\n".utf8)
        bytes.append(Data(payload.utf8))
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let wrote = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if wrote < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if wrote == 0 { return }
                sent += wrote
            }
        }
    }

    private func readBody(_ fd: Int32) throws -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            if data.count > 65_536 { throw POSIXError(.EIO) }
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base, raw.count)
            }
            if count <= 0 { throw POSIXError(.EIO) }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let marker = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw POSIXError(.EIO)
        }
        let header = String(decoding: data.subdata(in: 0..<marker.lowerBound), as: UTF8.self)
        var length = 0
        for line in header.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                length = Int(lower.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        var body = data.subdata(in: marker.upperBound..<data.count)
        while body.count < length {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base, raw.count)
            }
            if count <= 0 { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        if body.count > length {
            body = body.prefix(length)
        }
        return String(decoding: body, as: UTF8.self)
    }
}

private func tryURL(_ string: String) -> URL {
    URL(string: string)!
}

private func attributes(_ inode: Inode, kind: EngineItemKind, size: Int64) -> EngineAttributes {
    EngineAttributes(inode: inode, kind: kind, size: size, linkCount: 1, created: nil, modified: nil, mimeType: nil)
}

private func activatedVolume() async throws -> GCSFVolume {
    let engine = ScriptedEngine()
    engine.attributesImpl = { attributes($0, kind: .directory, size: 0) }
    let volume = GCSFVolume(session: "Work", engine: engine, readOnly: false)
    _ = try await volume.activateVolume(options: FSKitObjects.options())
    return volume
}

private func rootItem(_ volume: GCSFVolume) async throws -> GCSFItem {
    let activated = try await volume.activateVolume(options: FSKitObjects.options())
    return try #require(FSKitObjects.object(activated, "_rootItem", GCSFItem.self))
}

private func fileVolume(_ engine: ScriptedEngine) async throws -> GCSFVolume {
    if engine.lookupImpl == nil {
        engine.lookupImpl = { name, _ in EngineItem(inode: Inode(rawValue: 9), name: name, kind: .file) }
    }
    let volume = GCSFVolume(session: "Work", engine: engine, readOnly: false)
    _ = try await volume.activateVolume(options: FSKitObjects.options())
    return volume
}

private func fileItem(_ volume: GCSFVolume) async throws -> GCSFItem {
    let root = try await rootItem(volume)
    let found = try await volume.lookupItem(named: FSFileName(string: "Notes"), in: root, context: FSKitObjects.context())
    return try #require(FSKitObjects.object(found, "_foundItem", GCSFItem.self))
}

private func loadedVolume(_ system: GCSFFileSystem, resource: FSResource, options: FSTaskOptions) async throws -> GCSFVolume {
    try await withCheckedThrowingContinuation { continuation in
        system.loadResource(resource: resource, options: options) { volume, error in
            if let volume = volume as? GCSFVolume, error == nil {
                continuation.resume(returning: volume)
            } else {
                continuation.resume(throwing: error ?? POSIXError(.EIO))
            }
        }
    }
}

private func thrownPOSIX(_ body: () async throws -> Void) async -> POSIXError? {
    do {
        try await body()
        return nil
    } catch let error as POSIXError {
        return error
    } catch {
        return nil
    }
}

private func waitUntil(_ ready: @Sendable () -> Bool) async throws {
    for _ in 0..<50 {
        if ready() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(ready())
}

private enum FSKitObjects {
    static func alloc<T: NSObject>(_ type: T.Type) -> T {
        let raw = (type as NSObject.Type).perform(NSSelectorFromString("alloc")).takeRetainedValue()
        return unsafeDowncast(raw, to: T.self)
    }

    static func context() -> FSContext { alloc(FSContext.self) }
    static func options() -> FSTaskOptions { alloc(FSTaskOptions.self) }
    static func buffer() -> FSMutableFileDataBuffer { alloc(FSMutableFileDataBuffer.self) }

    static func object<T: AnyObject>(_ object: AnyObject, _ name: String, _ type: T.Type) -> T? {
        guard let ivar = class_getInstanceVariable(Swift.type(of: object), name) else { return nil }
        return object_getIvar(object, ivar) as? T
    }

    static func grantedCoherency(_ object: NSObject) -> Int {
        let ivar = class_getInstanceVariable(Swift.type(of: object), "_grantedCoherency")!
        return Unmanaged.passUnretained(object).toOpaque().advanced(by: ivar_getOffset(ivar)).load(as: Int.self)
    }

    static func unsigned(_ object: NSObject, _ name: String) -> UInt64 {
        let ivar = class_getInstanceVariable(Swift.type(of: object), name)!
        return Unmanaged.passUnretained(object).toOpaque().advanced(by: ivar_getOffset(ivar)).load(as: UInt64.self)
    }
}

private final class ScriptedEngine: FileSystemEngine, @unchecked Sendable {
    var lookupImpl: (@Sendable (String, Inode) async throws -> EngineItem)?
    var attributesImpl: (@Sendable (Inode) async throws -> EngineAttributes)?
    var readImpl: (@Sendable (Inode, Int64, Int) async throws -> Data)?
    var writeImpl: (@Sendable (Inode, Data, Int64) async throws -> Int)?
    var renameImpl: (@Sendable (Inode, Inode, String, Inode, String, Inode?) async throws -> EngineItem)?
    var xattrImpl: (@Sendable (String, Inode) async throws -> Data)?
    var namesImpl: (@Sendable (Inode) async throws -> [String])?
    var blockLookups = false

    private let log = Mutex<[String]>([])
    private let gate = Mutex(LookupGate())

    struct LookupGate {
        var release: CheckedContinuation<Void, Never>?
        var entered: CheckedContinuation<Void, Never>?
    }

    func calls() -> [String] { log.withLock { $0 } }

    func waitUntilLookupBlocked() async {
        await withCheckedContinuation { continuation in
            let already = gate.withLock { gate -> Bool in
                if gate.release != nil { return true }
                gate.entered = continuation
                return false
            }
            if already { continuation.resume() }
        }
    }

    func releaseLookup() {
        let continuation = gate.withLock { gate -> CheckedContinuation<Void, Never>? in
            let continuation = gate.release
            gate.release = nil
            return continuation
        }
        continuation?.resume()
    }

    func lookup(named name: String, in parent: Inode) async throws -> EngineItem {
        note("lookup")
        if blockLookups {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let entered = gate.withLock { gate -> CheckedContinuation<Void, Never>? in
                    gate.release = continuation
                    let entered = gate.entered
                    gate.entered = nil
                    return entered
                }
                if let entered {
                    Task { entered.resume() }
                }
            }
        }
        guard let lookupImpl else { throw POSIXError(.ENOENT) }
        return try await lookupImpl(name, parent)
    }

    func attributes(_ inode: Inode) async throws -> EngineAttributes {
        note("attributes")
        guard let attributesImpl else { throw POSIXError(.EIO) }
        return try await attributesImpl(inode)
    }

    func xattr(named name: String, of inode: Inode) async throws -> Data {
        note("xattr")
        guard let xattrImpl else { throw POSIXError(.ENOATTR) }
        return try await xattrImpl(name, inode)
    }

    func setXattr(named name: String, value: Data?, of inode: Inode) async throws {
        note("setXattr")
    }

    func xattrNames(of inode: Inode) async throws -> [String] {
        note("xattrNames")
        guard let namesImpl else { return [] }
        return try await namesImpl(inode)
    }

    func enumerate(directory: Inode, startingAt cookie: EngineDirectoryCookie) async throws -> EngineEnumeration {
        note("enumerate")
        return EngineEnumeration(entries: [], verifier: 1, nextCookie: nil)
    }

    func create(named name: String, kind: EngineItemKind, in parent: Inode) async throws -> EngineItem {
        note("create")
        return EngineItem(inode: Inode(rawValue: 10), name: name, kind: kind)
    }

    func rename(_ inode: Inode, fromParent: Inode, fromName: String, toParent: Inode, toName: String, replacing: Inode?) async throws -> EngineItem {
        note("rename")
        if let renameImpl {
            return try await renameImpl(inode, fromParent, fromName, toParent, toName, replacing)
        }
        return EngineItem(inode: inode, name: toName, kind: .file)
    }

    func remove(_ inode: Inode, named name: String, from parent: Inode) async throws {
        note("remove")
    }

    func readlink(_ inode: Inode) async throws -> String {
        note("readlink")
        return "target"
    }

    func read(_ inode: Inode, at offset: Int64, length: Int) async throws -> Data {
        note("read")
        guard let readImpl else { return Data() }
        return try await readImpl(inode, offset, length)
    }

    func write(_ inode: Inode, bytes: Data, at offset: Int64) async throws -> Int {
        note("write")
        guard let writeImpl else { return bytes.count }
        return try await writeImpl(inode, bytes, offset)
    }

    func truncate(_ inode: Inode, to length: Int64) async throws {
        note("truncate")
    }

    func synchronize() async throws {
        note("synchronize")
    }

    private func note(_ name: String) {
        log.withLock { $0.append(name) }
    }
}
