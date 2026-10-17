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
        let environment = GCSFCommandEnvironment(
            home: home,
            mountSingleVolume: { url, bundleID, options, completion in
                calls.withLock { $0.append(MountCall(url: url, bundleID: bundleID, options: options)) }
                completion(URL(fileURLWithPath: "/Volumes/GCSFTest"), nil)
            },
            unmount: { _ in }
        )
        let positional = GCSFCommandLine.execute(["mount", "-s", "Work", "/tmp/mount"], environment: environment)
        #expect(positional.code == 2)
        #expect(calls.withLock { $0.isEmpty })
        let missing = GCSFCommandLine.execute(["umount", "-s", "Work"], environment: environment)
        #expect(missing.code != 0)
        #expect(missing.err.contains("no stored URL"))
        let failed = GCSFCommandEnvironment(
            home: home,
            mountSingleVolume: { _, _, _, completion in
                completion(nil, NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "identity unavailable"]))
            },
            unmount: { _ in }
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
        let unmounting = GCSFCommandEnvironment(
            home: home,
            mountSingleVolume: { _, _, _, _ in },
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

    @Test func loginStaysUnimplemented() {
        let environment = GCSFCommandEnvironment(home: scratchHome(), mountSingleVolume: { _, _, _, _ in }, unmount: { _ in })
        let login = GCSFCommandLine.execute(["login"], environment: environment)
        #expect(login.code == 1)
        #expect(login.err == "login: not implemented\n")
        #expect(GCSFCommandLine.execute(["logout"], environment: environment).err == "logout: not implemented\n")
        #expect(GCSFCommandLine.execute(["list"], environment: environment).code == 1)
        #expect(GCSFCommandLine.execute(["verify"], environment: environment).code == 1)
    }
}

private struct MountCall: Equatable {
    var url: URL
    var bundleID: String
    var options: [String]
}

private func scratchHome() -> URL {
    URL(fileURLWithPath: "/Users/josh/d/gcsf/.work/tmp/f1-home-\(UUID().uuidString)", isDirectory: true)
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
