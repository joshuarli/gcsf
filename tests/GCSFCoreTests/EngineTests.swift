import Darwin
import Foundation
import Testing
import GCSFCore

@Suite struct EngineTests {
    @Test func reservedDirectoriesKeepTheirInodesAndNames() async throws {
        let harness = try await Harness.open()
        let root = try await harness.engine.attributes(Inode(rawValue: 1))
        let trash = try await harness.engine.lookup(named: "Trash", in: Inode(rawValue: 1))
        let shared = try await harness.engine.lookup(named: "Shared with me", in: Inode(rawValue: 1))
        #expect(root.inode == Inode(rawValue: 1))
        #expect(root.kind == .directory)
        #expect(trash == EngineItem(inode: Inode(rawValue: 2), name: "Trash", kind: .directory))
        #expect(shared == EngineItem(inode: Inode(rawValue: 3), name: "Shared with me", kind: .directory))
        let listing = try await harness.engine.enumerate(directory: Inode(rawValue: 1), startingAt: .start)
        #expect(listing.entries.map(\.item.inode.rawValue) == [2, 3])
        #expect(listing.entries.map(\.name) == ["Trash", "Shared with me"])
    }

    @Test func lookupUsesDisplayNameInsteadOfLowestBaseName() async throws {
        let harness = try await Harness.open()
        try await harness.insert(
            inode: 4,
            driveID: "later",
            name: "test.txt",
            suffix: "1"
        )
        try await harness.insert(
            inode: 5,
            driveID: "earlier",
            name: "test.txt",
            suffix: nil
        )
        let bare = try await harness.engine.lookup(named: "test.txt", in: Harness.root)
        let suffixed = try await harness.engine.lookup(named: "test.txt.1", in: Harness.root)
        #expect(bare.inode == Inode(rawValue: 5))
        #expect(suffixed.inode == Inode(rawValue: 4))
        await #expect(throws: EngineError.posix(ENOENT)) {
            try await harness.engine.lookup(named: "missing", in: Harness.root)
        }
        await #expect(throws: EngineError.posix(ENOENT)) {
            try await harness.engine.lookup(named: "test.txt", in: Inode(rawValue: 99))
        }
        await #expect(throws: EngineError.posix(ENOTDIR)) {
            try await harness.engine.lookup(named: "test.txt", in: Inode(rawValue: 4))
        }
    }

    @Test func firstAssignmentFollowsDriveIDAndLaterIDsDoNotMoveSuffixes() async throws {
        let path = try scratchPath("suffix-order")
        let drive = MemoryDrive()
        let configuration = Harness.configuration(renameIdenticalFiles: true)
        let original = try SQLiteMetadataStore(path: path)
        let engine = GCSFEngine(store: original, drive: drive, configuration: configuration)
        let first = try await engine.incorporate(
            [
                incoming("m", name: "test.txt"),
                incoming("a", name: "test.txt"),
                incoming(nil, name: "test.txt"),
            ],
            under: Harness.root
        )
        #expect(first.map(\.name) == ["test.txt.2", "test.txt.1", "test.txt"])
        let earlier = try await engine.incorporate([incoming("0", name: "test.txt")], under: Harness.root)
        #expect(earlier.map(\.name) == ["test.txt.3"])
        #expect(try await engine.lookup(named: "test.txt", in: Harness.root).inode == first[2].inode)
        #expect(try await engine.lookup(named: "test.txt.1", in: Harness.root).inode == first[1].inode)
        #expect(try await engine.lookup(named: "test.txt.2", in: Harness.root).inode == first[0].inode)
        let pair = try await engine.incorporate(
            [incoming("c", name: "test.txt"), incoming("b", name: "test.txt")],
            under: Harness.root
        )
        #expect(pair.map(\.name) == ["test.txt.5", "test.txt.4"])

        let reopenedStore = try SQLiteMetadataStore(path: path)
        let reopened = GCSFEngine(store: reopenedStore, drive: drive, configuration: configuration)
        #expect(try await reopened.lookup(named: "test.txt", in: Harness.root).inode == first[2].inode)
        #expect(try await reopened.lookup(named: "test.txt.1", in: Harness.root).inode == first[1].inode)
        #expect(try await reopened.lookup(named: "test.txt.3", in: Harness.root).inode == earlier[0].inode)
        let kept = try await reopenedStore.record(inode: first[0].inode)
        #expect(kept?.assignedDuplicateSuffix == "2")
        #expect(kept?.name == "test.txt")
    }

    @Test func identicalNamesStayUnsuffixedWhenRenameIsOff() async throws {
        let harness = try await Harness.open(renameIdenticalFiles: false)
        let created = try await harness.engine.incorporate([incoming("a", name: "test.txt")], under: Harness.root)
        #expect(created.map(\.name) == ["test.txt"])
        await #expect(throws: EngineError.posix(EEXIST)) {
            try await harness.engine.incorporate([incoming("b", name: "test.txt")], under: Harness.root)
        }
        let stored = try await harness.store.record(inode: created[0].inode)
        #expect(stored?.assignedDuplicateSuffix == nil)
        #expect(try await harness.store.record(driveID: DriveID(rawValue: "b")) == nil)
    }

    @Test func attributesAndXattrsExposeStoredDriveMetadata() async throws {
        let harness = try await Harness.open()
        let file = EngineIncoming(
            driveID: DriveID(rawValue: "drive-9"),
            name: "notes",
            mimeType: "text/plain",
            size: 42,
            created: Date(timeIntervalSince1970: 1_700_000_000),
            modified: Date(timeIntervalSince1970: 1_700_000_100),
            headRevision: "rev-9",
            md5: "md5-9",
            sha1: nil,
            sha256: "sha-9",
            owner: "owner@example.com",
            webLink: "https://example.com/notes",
            trashed: false
        )
        let item = try #require(try await harness.engine.incorporate([file], under: Harness.root).first)
        let attributes = try await harness.engine.attributes(item.inode)
        #expect(attributes.kind == .file)
        #expect(attributes.size == 42)
        #expect(attributes.linkCount == 1)
        #expect(attributes.mimeType == "text/plain")
        #expect(attributes.created == file.created)
        #expect(attributes.modified == file.modified)
        #expect(try await harness.engine.xattrNames(of: item.inode) == [
            "user.gcsf.id",
            "user.gcsf.mime_type",
            "user.gcsf.owner",
            "user.gcsf.web_link",
            "user.gcsf.md5",
            "user.gcsf.sha256",
            "user.gcsf.revision",
        ])
        #expect(try await harness.engine.xattr(named: "user.gcsf.id", of: item.inode) == Data("drive-9".utf8))
        #expect(try await harness.engine.xattr(named: "user.gcsf.sha256", of: item.inode) == Data("sha-9".utf8))
        await #expect(throws: EngineError.unknownXattr("user.gcsf.sha1")) {
            try await harness.engine.xattr(named: "user.gcsf.sha1", of: item.inode)
        }
        await #expect(throws: EngineError.unknownXattr("com.example.other")) {
            try await harness.engine.xattr(named: "com.example.other", of: item.inode)
        }
        await #expect(throws: EngineError.posix(ENOENT)) {
            try await harness.engine.xattr(named: "user.gcsf.id", of: Inode(rawValue: 40))
        }
        await #expect(throws: EngineError.posix(EPERM)) {
            try await harness.engine.setXattr(named: "user.gcsf.md5", value: Data("no".utf8), of: item.inode)
        }
        await #expect(throws: EngineError.posix(ENOTSUP)) {
            try await harness.engine.setXattr(named: "com.apple.FinderInfo", value: Data([1]), of: item.inode)
        }
        #expect(try await harness.engine.xattr(named: "user.gcsf.md5", of: item.inode) == Data("md5-9".utf8))
        let directory = try await harness.engine.attributes(Inode(rawValue: 2))
        #expect(directory.kind == .directory)
        #expect(directory.linkCount == 2)
    }

    @Test func enumerationIsInodeOrderAndRejectsAStaleCookie() async throws {
        let harness = try await Harness.open()
        try await harness.insert(inode: 6, driveID: "c", name: "c", suffix: nil)
        try await harness.insert(inode: 4, driveID: "a", name: "a", suffix: nil)
        try await harness.insert(inode: 5, driveID: "b", name: "b", suffix: "9")
        let first = try await harness.engine.enumerate(directory: Harness.root, startingAt: .start)
        let again = try await harness.engine.enumerate(directory: Harness.root, startingAt: .start)
        #expect(first.verifier == again.verifier)
        #expect(first.nextCookie == nil)
        #expect(first.entries.map(\.name) == ["Trash", "Shared with me", "a", "b.9", "c"])
        #expect(first.entries.map(\.item.inode.rawValue) == [2, 3, 4, 5, 6])
        let resumed = try await harness.engine.enumerate(
            directory: Harness.root,
            startingAt: first.entries[2].cookie
        )
        #expect(resumed.verifier == first.verifier)
        #expect(resumed.entries.map(\.name) == ["b.9", "c"])
        try await harness.insert(inode: 7, driveID: "d", name: "d", suffix: nil)
        await #expect(throws: EngineError.posix(ESTALE)) {
            try await harness.engine.enumerate(directory: Harness.root, startingAt: first.entries[2].cookie)
        }
        let refreshed = try await harness.engine.enumerate(directory: Harness.root, startingAt: .start)
        #expect(refreshed.verifier != first.verifier)
        #expect(refreshed.entries.map(\.name) == ["Trash", "Shared with me", "a", "b.9", "c", "d"])
        await #expect(throws: EngineError.posix(ENOTDIR)) {
            try await harness.engine.enumerate(directory: Inode(rawValue: 4), startingAt: .start)
        }
    }

    @Test func createRenameRemoveAndSymlinkHonorPOSIXNames() async throws {
        let harness = try await Harness.open(renameIdenticalFiles: true, skipTrash: true)
        let file = try await harness.engine.create(named: "test.txt", kind: .file, in: Harness.root)
        let folder = try await harness.engine.create(named: "folder", kind: .directory, in: Harness.root)
        #expect(file.name == "test.txt")
        #expect(file.inode.rawValue >= 4)
        #expect(folder.kind == .directory)
        let again = try await harness.engine.create(named: "test.txt", kind: .file, in: Harness.root)
        #expect(again.name == "test.txt.1")
        #expect(try await harness.store.record(inode: file.inode)?.assignedDuplicateSuffix == nil)
        await #expect(throws: EngineError.posix(EEXIST)) {
            try await harness.engine.rename(
                file.inode,
                fromParent: Harness.root,
                fromName: "test.txt",
                toParent: Harness.root,
                toName: "folder",
                replacing: nil
            )
        }
        let renamed = try await harness.engine.rename(
            file.inode,
            fromParent: Harness.root,
            fromName: "test.txt",
            toParent: folder.inode,
            toName: "moved.txt",
            replacing: nil
        )
        #expect(renamed.name == "moved.txt")
        #expect(try await harness.engine.lookup(named: "moved.txt", in: folder.inode).inode == file.inode)
        await #expect(throws: EngineError.posix(ENOENT)) {
            try await harness.engine.lookup(named: "test.txt", in: Harness.root)
        }
        let link = try await harness.engine.createSymlink(named: "alias", target: "../moved.txt", in: folder.inode)
        #expect(try await harness.engine.readlink(link.inode) == "../moved.txt")
        let emptyLink = try await harness.engine.create(named: "empty-link", kind: .symlink, in: folder.inode)
        #expect(try await harness.engine.readlink(emptyLink.inode) == "")
        await #expect(throws: EngineError.posix(EINVAL)) {
            try await harness.engine.readlink(file.inode)
        }
        await #expect(throws: EngineError.posix(EISDIR)) {
            try await harness.engine.remove(folder.inode, named: "folder", from: Harness.root)
        }
        await #expect(throws: EngineError.posix(ENOTDIR)) {
            try await harness.engine.rmdir(file.inode, named: "moved.txt", from: folder.inode)
        }
        let nested = try await harness.engine.create(named: "nested", kind: .file, in: folder.inode)
        await #expect(throws: EngineError.posix(ENOTEMPTY)) {
            try await harness.engine.rmdir(folder.inode, named: "folder", from: Harness.root)
        }
        try await harness.engine.remove(nested.inode, named: "nested", from: folder.inode)
        try await harness.engine.remove(link.inode, named: "alias", from: folder.inode)
        try await harness.engine.remove(emptyLink.inode, named: "empty-link", from: folder.inode)
        try await harness.engine.remove(file.inode, named: "moved.txt", from: folder.inode)
        try await harness.engine.rmdir(folder.inode, named: "folder", from: Harness.root)
        let calls = await harness.drive.snapshot()
        #expect(calls.deleted.contains(DriveID(rawValue: "new-1")))
        #expect(calls.multipart.isEmpty)
        #expect(calls.exported.isEmpty)
        await #expect(throws: EngineError.posix(ENOENT)) {
            try await harness.engine.lookup(named: "folder", in: Harness.root)
        }
    }

    @Test func renameReplacesOnlyTheNamedInode() async throws {
        let harness = try await Harness.open(skipTrash: true)
        let kept = try await harness.engine.create(named: "kept", kind: .file, in: Harness.root)
        let replaced = try await harness.engine.create(named: "replaced", kind: .file, in: Harness.root)
        let result = try await harness.engine.rename(
            kept.inode,
            fromParent: Harness.root,
            fromName: "kept",
            toParent: Harness.root,
            toName: "replaced",
            replacing: replaced.inode
        )
        #expect(result.name == "replaced")
        #expect(try await harness.engine.lookup(named: "replaced", in: Harness.root).inode == kept.inode)
        #expect(try await harness.store.record(inode: replaced.inode) == nil)
        let calls = await harness.drive.snapshot()
        #expect(calls.deleted == [DriveID(rawValue: "new-2")])
        #expect(calls.updated.map(\.metadata.name) == ["replaced"])
    }

    @Test func skipTrashDeletesAndOtherwiseReparentsUnderTrash() async throws {
        let trashed = try await Harness.open(skipTrash: false)
        let file = try await trashed.engine.create(named: "gone", kind: .file, in: Harness.root)
        try await trashed.engine.remove(file.inode, named: "gone", from: Harness.root)
        #expect(try await trashed.engine.lookup(named: "gone", in: Harness.trash).inode == file.inode)
        await #expect(throws: EngineError.posix(ENOENT)) {
            try await trashed.engine.lookup(named: "gone", in: Harness.root)
        }
        let stored = try #require(try await trashed.store.record(inode: file.inode))
        #expect(stored.parent == Harness.trash)
        #expect(stored.trashed)
        let calls = await trashed.drive.snapshot()
        #expect(calls.deleted.isEmpty)
        #expect(calls.updated.map(\.metadata.trashed) == [true])

        let erased = try await Harness.open(skipTrash: true)
        let other = try await erased.engine.create(named: "gone", kind: .file, in: Harness.root)
        try await erased.engine.remove(other.inode, named: "gone", from: Harness.root)
        #expect(try await erased.store.record(inode: other.inode) == nil)
        #expect(await erased.drive.snapshot().deleted == [DriveID(rawValue: "new-1")])
    }

    @Test func googleNativeFilesAreReadOnlyExports() async throws {
        let harness = try await Harness.open(addExtensionsToSpecialFiles: true)
        let specs = [
            ("Document", "application/vnd.google-apps.document", "#.odt", "application/vnd.oasis.opendocument.text"),
            ("Slides", "application/vnd.google-apps.presentation", "#.odp", "application/vnd.oasis.opendocument.presentation"),
            (
                "Sheet",
                "application/vnd.google-apps.spreadsheet",
                "#.xlsx",
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            ),
            ("Drawing", "application/vnd.google-apps.drawing", "#.png", "image/png"),
            ("Site", "application/vnd.google-apps.site", "#.txt", "text/plain"),
        ]
        for (name, mime, suffix, export) in specs {
            let item = try #require(
                try await harness.engine.incorporate(
                    [incoming("id-\(name)", name: name, mime: mime, size: 7)],
                    under: Harness.root
                ).first
            )
            #expect(item.name == "\(name)\(suffix)")
            await harness.drive.setExport(Data("1234567".utf8))
            let bytes = try await harness.engine.read(item.inode, at: 1, length: 3)
            #expect(bytes == Data("234".utf8))
            await #expect(throws: EngineError.posix(EROFS)) {
                _ = try await harness.engine.write(item.inode, bytes: Data("x".utf8), at: 0)
            }
            await #expect(throws: EngineError.posix(EROFS)) {
                try await harness.engine.truncate(item.inode, to: 0)
            }
            let calls = await harness.drive.snapshot()
            #expect(calls.exported.last?.mime == export)
        }
        let form = try #require(
            try await harness.engine.incorporate(
                [incoming("form", name: "Form", mime: "application/vnd.google-apps.form", webLink: "https://example.com/form")],
                under: Harness.root
            ).first
        )
        #expect(form.name == "Form")
        let placeholder = try await harness.engine.read(form.inode, at: 0, length: 200)
        let text = String(decoding: placeholder, as: UTF8.self)
        #expect(text.contains("UNEXPORTABLE_FILE"))
        #expect(text.contains("https://example.com/form"))
        let calls = await harness.drive.snapshot()
        #expect(calls.multipart.isEmpty)
        #expect(calls.exported.allSatisfy { $0.id != DriveID(rawValue: "form") })
        let plain = try await Harness.open(addExtensionsToSpecialFiles: false)
        let hidden = try #require(
            try await plain.engine.incorporate(
                [incoming("doc", name: "Doc", mime: "application/vnd.google-apps.document")],
                under: Harness.root
            ).first
        )
        #expect(hidden.name == "Doc")
        await #expect(throws: EngineError.posix(ENOENT)) {
            try await plain.engine.lookup(named: "Doc#.odt", in: Harness.root)
        }
    }

    @Test func readWriteAndTruncateUseLocalBytesWithoutUpload() async throws {
        let harness = try await Harness.open()
        let file = try await harness.engine.create(named: "data", kind: .file, in: Harness.root)
        let written = try await harness.engine.write(file.inode, bytes: Data("abcdef".utf8), at: 0)
        #expect(written == 6)
        #expect(try await harness.engine.write(file.inode, bytes: Data("Z".utf8), at: 2) == 1)
        #expect(try await harness.engine.read(file.inode, at: 1, length: 3) == Data("bZd".utf8))
        try await harness.engine.truncate(file.inode, to: 2)
        #expect(try await harness.engine.read(file.inode, at: 0, length: 10) == Data("ab".utf8))
        try await harness.engine.truncate(file.inode, to: 4)
        #expect(try await harness.engine.read(file.inode, at: 0, length: 4) == Data("ab\0\0".utf8))
        let stored = try #require(try await harness.store.record(inode: file.inode))
        #expect(stored.size == 4)
        #expect(stored.durability == .committed)
        let calls = await harness.drive.snapshot()
        #expect(calls.multipart.isEmpty)
        #expect(calls.exported.isEmpty)
        await #expect(throws: EngineError.posix(EISDIR)) {
            _ = try await harness.engine.read(Harness.root, at: 0, length: 1)
        }
        await #expect(throws: EngineError.posix(EINVAL)) {
            try await harness.engine.truncate(file.inode, to: -1)
        }
        try await harness.engine.synchronize()
    }

    @Test func readOnlyRejectsMutationsAndSynchronizeStillSucceeds() async throws {
        let harness = try await Harness.open(readOnly: true)
        await #expect(throws: EngineError.posix(EROFS)) {
            try await harness.engine.create(named: "nope", kind: .file, in: Harness.root)
        }
        try await harness.insert(inode: 4, driveID: "file", name: "file", suffix: nil)
        await #expect(throws: EngineError.posix(EROFS)) {
            _ = try await harness.engine.write(Inode(rawValue: 4), bytes: Data([1]), at: 0)
        }
        await #expect(throws: EngineError.posix(EROFS)) {
            try await harness.engine.truncate(Inode(rawValue: 4), to: 0)
        }
        await #expect(throws: EngineError.posix(EROFS)) {
            try await harness.engine.rename(
                Inode(rawValue: 4),
                fromParent: Harness.root,
                fromName: "file",
                toParent: Harness.root,
                toName: "other",
                replacing: nil
            )
        }
        await #expect(throws: EngineError.posix(EROFS)) {
            try await harness.engine.remove(Inode(rawValue: 4), named: "file", from: Harness.root)
        }
        await #expect(throws: EngineError.posix(EROFS)) {
            try await harness.engine.rmdir(Harness.trash, named: "Trash", from: Harness.root)
        }
        try await harness.engine.synchronize()
        #expect(await harness.drive.snapshot().created.isEmpty)
    }

    @Test func synchronizeFailsUntilEveryRowIsCommitted() async throws {
        let harness = try await Harness.open()
        try await harness.insert(inode: 4, driveID: "dirty", name: "dirty", suffix: nil, durability: .staged)
        for state in [DurabilityState.staged, .journaled, .conflicted] {
            var record = try #require(try await harness.store.record(inode: Inode(rawValue: 4)))
            record.durability = state
            try await harness.store.update(record)
            await #expect(throws: EngineError.posix(EBUSY)) {
                try await harness.engine.synchronize()
            }
        }
        var record = try #require(try await harness.store.record(inode: Inode(rawValue: 4)))
        record.durability = .committed
        try await harness.store.update(record)
        try await harness.engine.synchronize()
    }

    @Test func remoteReadUsesTheRequestedRange() async throws {
        let harness = try await Harness.open()
        let item = try #require(
            try await harness.engine.incorporate(
                [incoming("remote", name: "blob", size: 6)],
                under: Harness.root
            ).first
        )
        await harness.drive.setBody(DriveID(rawValue: "remote"), data: Data("abcdef".utf8))
        #expect(try await harness.engine.read(item.inode, at: 2, length: 2) == Data("cd".utf8))
        let calls = await harness.drive.snapshot()
        #expect(calls.downloaded == [MemoryDrive.Download(id: DriveID(rawValue: "remote"), offset: 2, length: 2)])
    }
}

private struct Harness {
    static let root = Inode(rawValue: 1)
    static let trash = Inode(rawValue: 2)
    let engine: GCSFEngine
    let store: SQLiteMetadataStore
    let drive: MemoryDrive

    static func configuration(
        renameIdenticalFiles: Bool = false,
        addExtensionsToSpecialFiles: Bool = false,
        readOnly: Bool = false,
        skipTrash: Bool = false
    ) -> EngineConfiguration {
        EngineConfiguration(
            renameIdenticalFiles: renameIdenticalFiles,
            addExtensionsToSpecialFiles: addExtensionsToSpecialFiles,
            readOnly: readOnly,
            skipTrash: skipTrash
        )
    }

    static func open(
        renameIdenticalFiles: Bool = false,
        addExtensionsToSpecialFiles: Bool = false,
        readOnly: Bool = false,
        skipTrash: Bool = false,
        name: String = "engine"
    ) async throws -> Harness {
        let path = try scratchPath(name)
        let store = try SQLiteMetadataStore(path: path)
        var root = try #require(try await store.record(inode: Self.root))
        root.driveID = DriveID(rawValue: "root")
        try await store.update(root)
        let drive = MemoryDrive()
        let engine = GCSFEngine(
            store: store,
            drive: drive,
            configuration: configuration(
                renameIdenticalFiles: renameIdenticalFiles,
                addExtensionsToSpecialFiles: addExtensionsToSpecialFiles,
                readOnly: readOnly,
                skipTrash: skipTrash
            )
        )
        return Harness(engine: engine, store: store, drive: drive)
    }

    func insert(
        inode: UInt64,
        driveID: String,
        name: String,
        suffix: String?,
        durability: DurabilityState = .committed
    ) async throws {
        try await store.insert(
            MetadataRecord(
                inode: Inode(rawValue: inode),
                driveID: DriveID(rawValue: driveID),
                parent: Self.root,
                name: name,
                assignedDuplicateSuffix: suffix,
                mimeType: "text/plain",
                size: 4,
                created: nil,
                modified: nil,
                headRevision: nil,
                md5: nil,
                sha1: nil,
                sha256: nil,
                owner: nil,
                webLink: nil,
                durability: durability,
                trashed: false
            )
        )
    }
}

private func incoming(
    _ driveID: String?,
    name: String,
    mime: String = "text/plain",
    size: Int64 = 0,
    webLink: String? = nil
) -> EngineIncoming {
    EngineIncoming(
        driveID: driveID.map { DriveID(rawValue: $0) },
        name: name,
        mimeType: mime,
        size: size,
        created: nil,
        modified: nil,
        headRevision: driveID == nil ? nil : "rev",
        md5: nil,
        sha1: nil,
        sha256: nil,
        owner: nil,
        webLink: webLink,
        trashed: false
    )
}

private func scratchPath(_ name: String) throws -> String {
    let directory = URL(fileURLWithPath: "/Users/josh/d/gcsf/.work/tmp/e2", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "\(name)-\(UUID().uuidString).sqlite").path
}

private actor MemoryDrive: DriveBackend {
    struct Download: Equatable, Sendable {
        var id: DriveID
        var offset: Int64
        var length: Int?
    }

    struct Update: Equatable, Sendable {
        var id: DriveID
        var metadata: DriveFileUpdate
    }

    struct Export: Equatable, Sendable {
        var id: DriveID
        var mime: String
    }

    struct Snapshot: Equatable, Sendable {
        var created: [DriveFileCreate]
        var updated: [Update]
        var deleted: [DriveID]
        var exported: [Export]
        var downloaded: [Download]
        var multipart: [String]
    }

    private var sequence = 0
    private var bodies: [String: Data] = [:]
    private var exportBody = Data()
    private var created: [DriveFileCreate] = []
    private var updated: [Update] = []
    private var deleted: [DriveID] = []
    private var exported: [Export] = []
    private var downloaded: [Download] = []
    private var multipart: [String] = []

    func setBody(_ id: DriveID, data: Data) {
        bodies[id.rawValue] = data
    }

    func setExport(_ data: Data) {
        exportBody = data
    }

    func snapshot() -> Snapshot {
        Snapshot(
            created: created,
            updated: updated,
            deleted: deleted,
            exported: exported,
            downloaded: downloaded,
            multipart: multipart
        )
    }

    func listFiles(query _: String?, pageToken _: String?, pageSize _: Int?) async throws -> DriveFilePage {
        DriveFilePage(files: [], nextPageToken: nil)
    }

    func getFile(id: DriveID) async throws -> DriveFile {
        throw EngineError.posix(ENOENT)
    }

    func createFile(metadata: DriveFileCreate) async throws -> DriveFile {
        sequence += 1
        created.append(metadata)
        return DriveFile(
            id: DriveID(rawValue: "new-\(sequence)"),
            name: metadata.name,
            mimeType: metadata.mimeType,
            parents: metadata.parents,
            size: 0,
            headRevision: nil,
            md5: nil,
            sha1: nil,
            sha256: nil,
            owner: nil,
            webViewLink: nil,
            trashed: false,
            created: nil,
            modified: nil
        )
    }

    func updateFile(id: DriveID, metadata: DriveFileUpdate) async throws -> DriveFile {
        updated.append(Update(id: id, metadata: metadata))
        return DriveFile(
            id: id,
            name: metadata.name ?? "",
            mimeType: metadata.mimeType ?? "application/octet-stream",
            parents: metadata.parents ?? [],
            size: nil,
            headRevision: nil,
            md5: nil,
            sha1: nil,
            sha256: nil,
            owner: nil,
            webViewLink: nil,
            trashed: metadata.trashed ?? false,
            created: nil,
            modified: nil
        )
    }

    func deleteFile(id: DriveID) async throws {
        deleted.append(id)
    }

    func exportFile(id: DriveID, mimeType: String) async throws -> Data {
        exported.append(Export(id: id, mime: mimeType))
        return exportBody
    }

    func downloadContent(id: DriveID, range: ByteRange?) async throws -> DriveContent {
        downloaded.append(Download(id: id, offset: range?.offset ?? 0, length: range?.length))
        let body = bodies[id.rawValue] ?? Data()
        let offset = range?.offset ?? 0
        guard offset >= 0, offset <= Int64(body.count) else {
            return DriveContent(bytes: Data(), offset: offset, totalSize: Int64(body.count))
        }
        let start = Int(offset)
        let stop: Int
        if let length = range?.length {
            stop = min(body.count, start + length)
        } else {
            stop = body.count
        }
        return DriveContent(bytes: Data(body[start..<stop]), offset: offset, totalSize: Int64(body.count))
    }

    func multipartUpload(_ intent: MultipartUploadIntent) async throws -> DriveFile {
        multipart.append(intent.metadata.name)
        throw EngineError.posix(EIO)
    }

    func startResumableUpload(_ intent: ResumableUploadIntent) async throws -> ResumableUploadSession {
        throw EngineError.posix(ENOTSUP)
    }

    func resumeUpload(session _: ResumableUploadSession, chunk _: DriveUploadChunk) async throws -> ResumableUploadProgress {
        throw EngineError.posix(ENOTSUP)
    }

    func startPageToken() async throws -> String {
        "token"
    }

    func listChanges(pageToken _: String, pageSize _: Int?) async throws -> DriveChangePage {
        DriveChangePage(changes: [], nextPageToken: nil, newStartPageToken: nil)
    }

    func about() async throws -> DriveAbout {
        DriveAbout(rootFolderID: DriveID(rawValue: "root"), userEmail: nil)
    }

    func refreshCredential() async throws {}
}
