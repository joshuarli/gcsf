import Darwin
import Foundation
import Testing
import GCSFCore
import GCSFTestSupport

@Suite struct AdversarialTests {
    @Test func emptyFileCreateAndRead() async throws {
        let opened = try await openEngine(name: "empty")
        let file = try await opened.engine.create(named: "empty", kind: .file, in: root)
        let attributes = try await opened.engine.attributes(file.inode)
        #expect(attributes.kind == .file)
        #expect(attributes.size == 0)
        #expect(try await opened.engine.read(file.inode, at: 0, length: 0).isEmpty)
        #expect(try await opened.engine.read(file.inode, at: 0, length: 1).isEmpty)
        let remote = try await opened.drive.getFile(id: try #require(try await opened.store.record(inode: file.inode)?.driveID))
        #expect(remote.size == 0)
    }

    @Test func unicodeNamesAreKeptAndDotOrSlashNamesAreRejected() async throws {
        let opened = try await openEngine(name: "names")
        let name = "héllo 日本語.txt"
        let file = try await opened.engine.create(named: name, kind: .file, in: root)
        #expect(file.name == name)
        #expect(try await opened.engine.lookup(named: name, in: root).inode == file.inode)
        #expect(try await opened.store.record(inode: file.inode)?.name == name)
        for rejected in [".", "..", "/", "//", "///"] {
            await #expect(throws: EngineError.posix(EINVAL)) {
                try await opened.engine.create(named: rejected, kind: .file, in: root)
            }
            await #expect(throws: EngineError.posix(ENOENT)) {
                try await opened.engine.lookup(named: rejected, in: root)
            }
        }
        #expect(try await opened.engine.lookup(named: name, in: root).inode == file.inode)
    }

    @Test func laterEarlierDriveIDDoesNotRenameExistingFile() async throws {
        let opened = try await openEngine(name: "suffix", renameIdenticalFiles: true)
        let first = try await opened.engine.incorporate(
            [
                incoming("m", name: "test.txt"),
                incoming("a", name: "test.txt"),
                incoming(nil, name: "test.txt"),
            ],
            under: root
        )
        #expect(first.map(\.name) == ["test.txt.2", "test.txt.1", "test.txt"])
        let earlier = try await opened.engine.incorporate(
            [incoming("0", name: "test.txt")],
            under: root
        )
        #expect(earlier.map(\.name) == ["test.txt.3"])
        #expect(try await opened.engine.lookup(named: "test.txt", in: root).inode == first[2].inode)
        #expect(try await opened.engine.lookup(named: "test.txt.1", in: root).inode == first[1].inode)
        #expect(try await opened.engine.lookup(named: "test.txt.2", in: root).inode == first[0].inode)
        #expect(try await opened.engine.lookup(named: "test.txt.3", in: root).inode == earlier[0].inode)
        let kept = try #require(try await opened.store.record(inode: first[0].inode))
        #expect(kept.name == "test.txt")
        #expect(kept.assignedDuplicateSuffix == "2")
        #expect(kept.driveID == DriveID(rawValue: "m"))
        let bare = try #require(try await opened.store.record(inode: first[2].inode))
        #expect(bare.assignedDuplicateSuffix == nil)
        #expect(bare.driveID == nil)
    }

    @Test func removeAndRmdirHonorDirectoryErrors() async throws {
        let opened = try await openEngine(name: "rmdir", skipTrash: true)
        let folder = try await opened.engine.create(named: "folder", kind: .directory, in: root)
        let file = try await opened.engine.create(named: "file", kind: .file, in: folder.inode)
        await #expect(throws: EngineError.posix(EISDIR)) {
            try await opened.engine.remove(folder.inode, named: "folder", from: root)
        }
        await #expect(throws: EngineError.posix(ENOTDIR)) {
            try await opened.engine.rmdir(file.inode, named: "file", from: folder.inode)
        }
        await #expect(throws: EngineError.posix(ENOTEMPTY)) {
            try await opened.engine.rmdir(folder.inode, named: "folder", from: root)
        }
        #expect(try await opened.engine.lookup(named: "folder", in: root).inode == folder.inode)
        #expect(try await opened.engine.lookup(named: "file", in: folder.inode).inode == file.inode)
        #expect(try await opened.store.record(inode: folder.inode) != nil)
        #expect(try await opened.store.record(inode: file.inode) != nil)
    }

    @Test func readOnlyRejectsCreateWriteAndRemove() async throws {
        let opened = try await openEngine(name: "ro", readOnly: true, skipTrash: true)
        let inode = Inode(rawValue: 4)
        try await opened.store.insert(metadataRow(inode: 4, driveID: nil, name: "file", revision: nil, durability: .committed, size: 0))
        await #expect(throws: EngineError.posix(EROFS)) {
            try await opened.engine.create(named: "nope", kind: .file, in: root)
        }
        await #expect(throws: EngineError.posix(EROFS)) {
            _ = try await opened.engine.write(inode, bytes: Data("x".utf8), at: 0)
        }
        await #expect(throws: EngineError.posix(EROFS)) {
            try await opened.engine.remove(inode, named: "file", from: root)
        }
        await #expect(throws: EngineError.posix(ENOENT)) {
            try await opened.engine.lookup(named: "nope", in: root)
        }
        let stored = try #require(try await opened.store.record(inode: inode))
        #expect(stored.name == "file")
        #expect(stored.size == 0)
        #expect(try await opened.engine.attributes(inode).size == 0)
    }

    @Test func googleNativeReadUsesExportAndRejectsMutation() async throws {
        let opened = try await openEngine(name: "native")
        let created = try await opened.drive.createFile(
            metadata: DriveFileCreate(
                name: "Doc",
                mimeType: "application/vnd.google-apps.document",
                parents: [DriveID(rawValue: "root")]
            )
        )
        let item = try #require(try await opened.engine.incorporate([EngineIncoming(driveFile: created)], under: root).first)
        let exported = Data("Google-native document".utf8)
        #expect(try await opened.engine.read(item.inode, at: 0, length: exported.count) == exported)
        #expect(try await opened.engine.read(item.inode, at: 7, length: 6) == Data("native".utf8))
        await #expect(throws: EngineError.posix(EROFS)) {
            _ = try await opened.engine.write(item.inode, bytes: Data("x".utf8), at: 0)
        }
        await #expect(throws: EngineError.posix(EROFS)) {
            try await opened.engine.truncate(item.inode, to: 0)
        }
        #expect(try await opened.engine.read(item.inode, at: 0, length: exported.count) == exported)
        let stored = try #require(try await opened.store.record(inode: item.inode))
        #expect(stored.mimeType == "application/vnd.google-apps.document")
        #expect(stored.size == 0)
    }

    @Test func recoverDeletesUnjournaledStagedFileAndResumesUpload() async throws {
        let directory = try scratchDirectory("recover")
        let drive = FakeDrive()
        let staged = Data("abcdef".utf8)
        let created = try await drive.createFile(
            metadata: DriveFileCreate(name: "Report", mimeType: "text/plain", parents: [DriveID(rawValue: "root")])
        )
        let session = try await drive.startResumableUpload(
            ResumableUploadIntent(
                existingFileID: created.id,
                metadata: DriveFileCreate(name: "Report", mimeType: "text/plain", parents: created.parents),
                mimeType: "text/plain",
                totalSize: Int64(staged.count)
            )
        )
        do {
            let opened = try openJournal(directory: directory, drive: drive)
            try await opened.store.insert(
                metadataRow(
                    inode: 10,
                    driveID: created.id.rawValue,
                    name: "Report",
                    revision: "1",
                    durability: .journaled,
                    size: Int64(staged.count)
                )
            )
            try await opened.journal.writeStaged(relativePath: "orphan", bytes: Data("gone".utf8))
            try await opened.journal.writeStaged(relativePath: "edit", bytes: staged)
            try await opened.journal.insert(
                journalRow(
                    id: "j1",
                    inode: 10,
                    driveID: created.id.rawValue,
                    state: .journaled,
                    revision: "1",
                    path: "edit",
                    session: session.uri
                )
            )
        }
        let opened = try openJournal(directory: directory, drive: drive)
        try await opened.journal.recover()
        #expect(FileManager.default.fileExists(atPath: stagedFile(directory, "orphan").path) == false)
        #expect(FileManager.default.fileExists(atPath: stagedFile(directory, "edit").path) == false)
        #expect(try await opened.journal.records().isEmpty)
        let row = try #require(try await opened.store.record(inode: Inode(rawValue: 10)))
        let remote = try await drive.getFile(id: created.id)
        #expect(row.durability == .committed)
        #expect(row.driveID == created.id)
        #expect(row.headRevision == "2")
        #expect(row.headRevision == remote.headRevision)
        #expect(row.size == Int64(staged.count))
        let body = try await drive.downloadContent(id: created.id, range: nil)
        #expect(body.bytes == staged)
    }

    @Test func synchronizeThrowsWhileJournaledRowCannotUpload() async throws {
        let directory = try scratchDirectory("eio")
        let drive = FakeDrive()
        let opened = try openJournal(directory: directory, drive: drive)
        let staged = Data("abc".utf8)
        try await opened.store.insert(
            metadataRow(inode: 10, driveID: "doc-1", name: "Report", revision: "1", durability: .journaled, size: Int64(staged.count))
        )
        try await opened.journal.writeStaged(relativePath: "edit", bytes: staged)
        try await opened.journal.insert(
            journalRow(id: "j1", inode: 10, driveID: "doc-1", state: .journaled, revision: "1", path: "edit", session: nil)
        )
        await drive.arm(.serverError)
        await #expect(throws: POSIXError(.EIO)) {
            try await opened.journal.synchronize()
        }
        let stored = try await opened.journal.record(id: JournalID(rawValue: "j1"))
        #expect(stored?.state == .journaled)
        #expect(stored?.headRevision == "1")
        #expect(try Data(contentsOf: stagedFile(directory, "edit")) == staged)
        let row = try #require(try await opened.store.record(inode: Inode(rawValue: 10)))
        #expect(row.durability == .journaled)
        #expect(row.headRevision == "1")
    }

    @Test func changeFeedDoesNotClobberJournaledHeadRevision() async throws {
        let directory = try scratchDirectory("feed")
        let store = try SQLiteMetadataStore(path: directory.appending(path: "index.sqlite").path)
        var rootRecord = try #require(try await store.record(inode: root))
        rootRecord.driveID = DriveID(rawValue: "root")
        try await store.update(rootRecord)
        let drive = FakeDrive()
        let created = try await drive.createFile(
            metadata: DriveFileCreate(name: "Doc", mimeType: "text/plain", parents: [DriveID(rawValue: "root")])
        )
        #expect(created.headRevision == "1")
        try await store.insert(
            metadataRow(inode: 10, driveID: created.id.rawValue, name: "Doc", revision: "1", durability: .journaled, size: 11)
        )
        let feed = ChangeFeed(
            metadata: store,
            backend: drive,
            kernel: NoOpKernelCachePort(),
            checkpointURL: directory.appending(path: "checkpoint"),
            allocateInode: { try await store.allocateInode() }
        )
        try await feed.synchronize()
        let uploaded = try await drive.multipartUpload(
            MultipartUploadIntent(
                existingFileID: created.id,
                metadata: DriveFileCreate(name: "Renamed", mimeType: "text/plain", parents: created.parents),
                mimeType: "text/plain",
                body: Data("zz".utf8)
            )
        )
        #expect(uploaded.headRevision == "2")
        try await feed.synchronize()
        let row = try #require(try await store.record(inode: Inode(rawValue: 10)))
        #expect(row.name == "Renamed")
        #expect(row.headRevision == "1")
        #expect(row.durability == .journaled)
        #expect(row.size == 11)
        #expect(row.driveID == created.id)
    }

    @Test func cacheServesRangeWhenFileExceedsMemoryLimit() async throws {
        let directory = try scratchDirectory("cache")
        let window = 64 * 1024
        let drive = SparseDrive(totalSize: 1 << 40, window: window)
        let cache = try BoundedContentCache(
            bounds: CacheBounds(memoryByteLimit: window, diskByteLimit: window),
            directory: directory,
            blockSize: window
        )
        let offset = Int64(window) * 4096
        let data = try await cache.read(
            driveID: DriveID(rawValue: "huge"),
            revision: "rev",
            offset: offset,
            length: window,
            backend: drive
        )
        #expect(data == Data(repeating: 9, count: window))
        #expect(await drive.allocated == window)
        #expect(await drive.calls == 1)
        #expect(await cache.residentByteCount <= window)
        #expect(await cache.diskByteCount <= window)
    }
}

private let root = Inode(rawValue: 1)

private struct OpenedEngine {
    var engine: GCSFEngine
    var store: SQLiteMetadataStore
    var drive: FakeDrive
}

private func openEngine(
    name: String,
    renameIdenticalFiles: Bool = false,
    addExtensionsToSpecialFiles: Bool = false,
    readOnly: Bool = false,
    skipTrash: Bool = true
) async throws -> OpenedEngine {
    let directory = try scratchDirectory(name)
    let store = try SQLiteMetadataStore(path: directory.appending(path: "index.sqlite").path)
    var rootRecord = try #require(try await store.record(inode: root))
    rootRecord.driveID = DriveID(rawValue: "root")
    try await store.update(rootRecord)
    let drive = FakeDrive()
    let engine = GCSFEngine(
        store: store,
        drive: drive,
        configuration: EngineConfiguration(
            renameIdenticalFiles: renameIdenticalFiles,
            addExtensionsToSpecialFiles: addExtensionsToSpecialFiles,
            readOnly: readOnly,
            skipTrash: skipTrash
        )
    )
    return OpenedEngine(engine: engine, store: store, drive: drive)
}

private func openJournal(
    directory: URL,
    drive: FakeDrive
) throws -> (journal: SQLiteWritebackJournal, store: SQLiteMetadataStore) {
    let store = try SQLiteMetadataStore(path: directory.appending(path: "index.sqlite").path)
    let journal = try SQLiteWritebackJournal(
        path: directory.appending(path: "journal.sqlite").path,
        stagingDirectory: directory.appending(path: "staged", directoryHint: .isDirectory),
        metadata: store,
        backend: drive
    )
    return (journal, store)
}

private func incoming(_ driveID: String?, name: String) -> EngineIncoming {
    EngineIncoming(
        driveID: driveID.map { DriveID(rawValue: $0) },
        name: name,
        mimeType: "text/plain",
        size: 0,
        created: nil,
        modified: nil,
        headRevision: driveID == nil ? nil : "rev",
        md5: nil,
        sha1: nil,
        sha256: nil,
        owner: nil,
        webLink: nil,
        trashed: false
    )
}

private func metadataRow(
    inode: UInt64,
    driveID: String?,
    name: String,
    revision: String?,
    durability: DurabilityState,
    size: Int64
) -> MetadataRecord {
    MetadataRecord(
        inode: Inode(rawValue: inode),
        driveID: driveID.map { DriveID(rawValue: $0) },
        parent: root,
        name: name,
        assignedDuplicateSuffix: nil,
        mimeType: "text/plain",
        size: size,
        created: nil,
        modified: nil,
        headRevision: revision,
        md5: nil,
        sha1: nil,
        sha256: nil,
        owner: nil,
        webLink: nil,
        durability: durability,
        trashed: false
    )
}

private func journalRow(
    id: String,
    inode: UInt64,
    driveID: String?,
    state: DurabilityState,
    revision: String?,
    path: String,
    session: String?
) -> JournalRecord {
    JournalRecord(
        id: JournalID(rawValue: id),
        inode: Inode(rawValue: inode),
        driveID: driveID.map { DriveID(rawValue: $0) },
        state: state,
        headRevision: revision,
        stagedRelativePath: path,
        uploadSessionURI: session
    )
}

private func stagedFile(_ directory: URL, _ name: String) -> URL {
    directory.appending(path: "staged").appending(path: name)
}

private func scratchDirectory(_ name: String) throws -> URL {
    let root = URL(fileURLWithPath: "/Users/josh/d/gcsf/.work/tmp/h1", isDirectory: true)
    let directory = root.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private actor SparseDrive: DriveBackend {
    let totalSize: Int64
    private let window: Int
    private(set) var allocated = 0
    private(set) var calls = 0

    init(totalSize: Int64, window: Int) {
        self.totalSize = totalSize
        self.window = window
    }

    func downloadContent(id _: DriveID, range: ByteRange?) async throws -> DriveContent {
        guard let range, range.length == window, range.offset >= 0, range.offset < totalSize else {
            throw POSIXError(.EFBIG)
        }
        calls += 1
        allocated += window
        return DriveContent(bytes: Data(repeating: 9, count: window), offset: range.offset, totalSize: totalSize)
    }

    func listFiles(query _: String?, pageToken _: String?, pageSize _: Int?) async throws -> DriveFilePage {
        throw POSIXError(.ENOTSUP)
    }

    func getFile(id _: DriveID) async throws -> DriveFile {
        throw POSIXError(.ENOTSUP)
    }

    func createFile(metadata _: DriveFileCreate) async throws -> DriveFile {
        throw POSIXError(.ENOTSUP)
    }

    func updateFile(id _: DriveID, metadata _: DriveFileUpdate) async throws -> DriveFile {
        throw POSIXError(.ENOTSUP)
    }

    func deleteFile(id _: DriveID) async throws {
        throw POSIXError(.ENOTSUP)
    }

    func exportFile(id _: DriveID, mimeType _: String) async throws -> Data {
        throw POSIXError(.ENOTSUP)
    }

    func multipartUpload(_: MultipartUploadIntent) async throws -> DriveFile {
        throw POSIXError(.ENOTSUP)
    }

    func startResumableUpload(_: ResumableUploadIntent) async throws -> ResumableUploadSession {
        throw POSIXError(.ENOTSUP)
    }

    func resumeUpload(session _: ResumableUploadSession, chunk _: DriveUploadChunk) async throws -> ResumableUploadProgress {
        throw POSIXError(.ENOTSUP)
    }

    func startPageToken() async throws -> String {
        throw POSIXError(.ENOTSUP)
    }

    func listChanges(pageToken _: String, pageSize _: Int?) async throws -> DriveChangePage {
        throw POSIXError(.ENOTSUP)
    }

    func about() async throws -> DriveAbout {
        throw POSIXError(.ENOTSUP)
    }

    func refreshCredential() async throws {
        throw POSIXError(.ENOTSUP)
    }
}
