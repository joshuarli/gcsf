import Foundation
import Testing
import GCSFCore

@Suite struct SyncTests {
    @Test func renameMoveAndTrash() async throws {
        let directory = try scratchDirectory("names")
        let metadata = MemoryMetadataStore()
        let backend = PageDrive()
        let kernel = RecordingKernel()
        let folder = "application/vnd.google-apps.folder"
        try await metadata.insert(row(1, driveID: "root", parent: nil, name: "My Drive", mime: folder))
        try await metadata.insert(row(2, driveID: "trash", parent: 1, name: "Trash", mime: folder))
        try await metadata.insert(row(20, driveID: "folder", parent: 1, name: "Folder", mime: folder))
        try await metadata.insert(row(10, driveID: "file-1", parent: 1, name: "Report"))
        await backend.setPage(
            "start",
            DriveChangePage(
                changes: [change(file: driveFile("file-1", name: "Notes", parents: ["root"]))],
                nextPageToken: nil,
                newStartPageToken: "after-rename"
            )
        )
        let feed = makeFeed(directory: directory, metadata: metadata, backend: backend, kernel: kernel)
        try await feed.synchronize()
        var file = try #require(try await metadata.record(inode: Inode(rawValue: 10)))
        #expect(file.name == "Notes")
        #expect(file.parent == Inode(rawValue: 1))
        #expect(await kernel.invalidated.isEmpty)
        #expect(await kernel.revoked.isEmpty)
        #expect(await backend.startCalls == 1)
        #expect(try await feed.checkpoint() == "after-rename")

        await backend.setPage(
            "after-rename",
            DriveChangePage(
                changes: [change(file: driveFile("file-1", name: "Notes", parents: ["folder"]))],
                nextPageToken: nil,
                newStartPageToken: "after-move"
            )
        )
        try await feed.synchronize()
        file = try #require(try await metadata.record(inode: Inode(rawValue: 10)))
        #expect(file.parent == Inode(rawValue: 20))
        #expect(file.name == "Notes")
        #expect(await backend.startCalls == 1)

        await backend.setPage(
            "after-move",
            DriveChangePage(
                changes: [change(file: driveFile("file-1", name: "Notes", parents: ["folder"], trashed: true))],
                nextPageToken: nil,
                newStartPageToken: "after-trash"
            )
        )
        try await feed.synchronize()
        file = try #require(try await metadata.record(inode: Inode(rawValue: 10)))
        #expect(file.trashed == true)
        #expect(file.parent == Inode(rawValue: 2))
        #expect(file.name == "Notes")
        #expect(file.durability == .committed)
        #expect(file.headRevision == "rev-1")
        #expect(await kernel.invalidated.isEmpty)
        #expect(await kernel.revoked.isEmpty)
        #expect(await backend.startCalls == 1)
        #expect(await backend.pageSizes == [100, 100, 100])
        #expect(try String(contentsOf: directory.appending(path: "checkpoint"), encoding: .utf8) == "after-trash")
    }

    @Test func dirtyContentAndRemovalStayLocal() async throws {
        let directory = try scratchDirectory("dirty")
        let metadata = MemoryMetadataStore()
        let backend = PageDrive()
        let kernel = RecordingKernel()
        let staged = row(30, driveID: "s", parent: nil, name: "S", durability: .staged)
        let journaled = row(31, driveID: "j", parent: nil, name: "J", durability: .journaled)
        let conflicted = row(32, driveID: "c", parent: nil, name: "C", durability: .conflicted)
        let doomed = row(33, driveID: "gone", parent: nil, name: "G", durability: .journaled)
        try await metadata.insert(staged)
        try await metadata.insert(journaled)
        try await metadata.insert(conflicted)
        try await metadata.insert(doomed)
        let remoteDate = Date(timeIntervalSince1970: 50)
        func drifted(_ id: String, name: String) -> DriveFile {
            driveFile(
                id,
                name: name,
                size: 99,
                revision: "remote",
                md5: "other",
                mime: "application/octet-stream",
                modified: remoteDate
            )
        }
        await backend.setPage(
            "start",
            DriveChangePage(
                changes: [
                    change(file: drifted("s", name: "S")),
                    change(file: drifted("j", name: "J")),
                    change(file: drifted("c", name: "C")),
                    removed("gone"),
                ],
                nextPageToken: nil,
                newStartPageToken: "done"
            )
        )
        let feed = makeFeed(directory: directory, metadata: metadata, backend: backend, kernel: kernel)
        try await feed.synchronize()
        #expect(try await metadata.record(inode: staged.inode) == staged)
        #expect(try await metadata.record(inode: journaled.inode) == journaled)
        #expect(try await metadata.record(inode: conflicted.inode) == conflicted)
        #expect(try await metadata.record(inode: doomed.inode) == doomed)
        #expect(await kernel.invalidated.isEmpty)
        #expect(await kernel.revoked.isEmpty)
    }

    @Test func cleanContentInvalidatesAndRemovalRevokes() async throws {
        let directory = try scratchDirectory("clean")
        let metadata = MemoryMetadataStore()
        let backend = PageDrive()
        let kernel = RecordingKernel()
        let live = row(40, driveID: "live", parent: nil, name: "Live", size: 4, revision: "rev-1", md5: "m1")
        let gone = row(41, driveID: "gone", parent: nil, name: "Gone")
        try await metadata.insert(live)
        try await metadata.insert(gone)
        await backend.setPage(
            "start",
            DriveChangePage(
                changes: [
                    change(file: driveFile("live", name: "Live", size: 8, revision: "rev-2", md5: "m2")),
                    removed("gone"),
                ],
                nextPageToken: nil,
                newStartPageToken: "done"
            )
        )
        let feed = makeFeed(directory: directory, metadata: metadata, backend: backend, kernel: kernel)
        try await feed.synchronize()
        let updated = try #require(try await metadata.record(inode: live.inode))
        #expect(updated.size == 8)
        #expect(updated.headRevision == "rev-2")
        #expect(updated.md5 == "m2")
        #expect(updated.name == "Live")
        #expect(try await metadata.record(inode: gone.inode) == nil)
        #expect(await kernel.invalidated == [live.inode])
        #expect(await kernel.revoked == [gone.inode])
    }

    @Test func duplicateEventsAreIdempotent() async throws {
        let directory = try scratchDirectory("dup")
        let metadata = MemoryMetadataStore()
        let backend = PageDrive()
        let kernel = RecordingKernel()
        let existing = row(50, driveID: "body", parent: nil, name: "Body", size: 1, revision: "old", md5: "old")
        let victim = row(51, driveID: "victim", parent: nil, name: "Victim")
        try await metadata.insert(existing)
        try await metadata.insert(victim)
        await metadata.resetCounts()
        let created = driveFile("fresh", name: "Fresh", size: 3, revision: "c1", md5: "c")
        let edited = driveFile("body", name: "Body", size: 9, revision: "new", md5: "new")
        await backend.setPage(
            "start",
            DriveChangePage(
                changes: [
                    change(file: created),
                    change(file: created),
                    change(file: edited),
                    change(file: edited),
                    removed("victim"),
                    removed("victim"),
                ],
                nextPageToken: nil,
                newStartPageToken: "done"
            )
        )
        let feed = makeFeed(directory: directory, metadata: metadata, backend: backend, kernel: kernel)
        try await feed.synchronize()
        #expect(await metadata.insertions == 1)
        #expect(await metadata.updates == 1)
        #expect(await metadata.removals == 1)
        #expect(await kernel.invalidated == [existing.inode])
        #expect(await kernel.revoked == [victim.inode])
        let fresh = try #require(try await metadata.record(driveID: DriveID(rawValue: "fresh")))
        #expect(fresh.name == "Fresh")
        #expect(fresh.durability == .committed)
        #expect(try await metadata.record(inode: victim.inode) == nil)
        let body = try #require(try await metadata.record(inode: existing.inode))
        #expect(body.headRevision == "new")
        #expect(body.size == 9)
        #expect(body.md5 == "new")
    }

    @Test func checkpointAdvancesOnlyAfterApply() async throws {
        let directory = try scratchDirectory("cursor")
        let metadata = MemoryMetadataStore()
        let backend = PageDrive(start: "start-1")
        let kernel = RecordingKernel()
        let checkpoint = directory.appending(path: "checkpoint")
        await backend.setPage(
            "start-1",
            DriveChangePage(
                changes: [change(file: driveFile("a", name: "A"))],
                nextPageToken: "page-2",
                newStartPageToken: nil
            )
        )
        await backend.setPage(
            "page-2",
            DriveChangePage(
                changes: [change(file: driveFile("b", name: "B"))],
                nextPageToken: nil,
                newStartPageToken: "done"
            )
        )
        let feed = makeFeed(directory: directory, metadata: metadata, backend: backend, kernel: kernel)
        await metadata.setFailures(["a"])
        await #expect(throws: StoreFault.failed) {
            try await feed.synchronize()
        }
        #expect(FileManager.default.fileExists(atPath: checkpoint.path) == false)
        #expect(try await metadata.record(driveID: DriveID(rawValue: "a")) == nil)
        #expect(await backend.startCalls == 1)

        await metadata.setFailures(["b"])
        await #expect(throws: StoreFault.failed) {
            try await feed.synchronize()
        }
        #expect(try String(contentsOf: checkpoint, encoding: .utf8) == "page-2")
        #expect(try await metadata.record(driveID: DriveID(rawValue: "a")) != nil)
        #expect(try await metadata.record(driveID: DriveID(rawValue: "b")) == nil)
        #expect(await backend.startCalls == 2)

        await metadata.setFailures([])
        try await feed.synchronize()
        #expect(try String(contentsOf: checkpoint, encoding: .utf8) == "done")
        #expect(try await feed.checkpoint() == "done")
        #expect(try await metadata.record(driveID: DriveID(rawValue: "a")) != nil)
        #expect(try await metadata.record(driveID: DriveID(rawValue: "b")) != nil)
        #expect(await backend.startCalls == 2)
        #expect(await backend.pageSizes == [100, 100, 100, 100])
    }

    @Test func storedRejectedTokenRefreshesFromStart() async throws {
        let directory = try scratchDirectory("expired")
        let checkpoint = directory.appending(path: "checkpoint")
        try Data("expired".utf8).write(to: checkpoint)
        let metadata = MemoryMetadataStore()
        let backend = PageDrive(start: "fresh")
        let kernel = RecordingKernel()
        await backend.reject("expired")
        await backend.setPage(
            "fresh",
            DriveChangePage(
                changes: [change(file: driveFile("n", name: "New"))],
                nextPageToken: nil,
                newStartPageToken: "live"
            )
        )
        let feed = makeFeed(directory: directory, metadata: metadata, backend: backend, kernel: kernel)
        try await feed.synchronize()
        #expect(await backend.startCalls == 1)
        #expect(await backend.tokens == ["expired", "fresh"])
        #expect(await backend.pageSizes == [100, 100])
        #expect(try await feed.checkpoint() == "live")
        #expect(try await metadata.record(driveID: DriveID(rawValue: "n")) != nil)
    }

    @Test func rejectedTokenAfterAGoodPageRefreshesOnce() async throws {
        let directory = try scratchDirectory("refresh")
        let metadata = MemoryMetadataStore()
        let backend = PageDrive()
        let kernel = RecordingKernel()
        await backend.queueStarts(["p1", "fresh"])
        await backend.reject("stale")
        await backend.setPage(
            "p1",
            DriveChangePage(
                changes: [change(file: driveFile("a", name: "A"))],
                nextPageToken: "stale",
                newStartPageToken: nil
            )
        )
        await backend.setPage(
            "fresh",
            DriveChangePage(
                changes: [change(file: driveFile("b", name: "B"))],
                nextPageToken: nil,
                newStartPageToken: "done"
            )
        )
        let feed = makeFeed(directory: directory, metadata: metadata, backend: backend, kernel: kernel)
        try await feed.synchronize()
        #expect(await backend.startCalls == 2)
        #expect(await backend.tokens == ["p1", "stale", "fresh"])
        #expect(try await metadata.record(driveID: DriveID(rawValue: "a")) != nil)
        #expect(try await metadata.record(driveID: DriveID(rawValue: "b")) != nil)
        #expect(try await feed.checkpoint() == "done")
    }
}

private enum StoreFault: Error, Equatable, Sendable {
    case failed
}

private enum PageFault: Error, Equatable, Sendable {
    case unsupported
}

private actor InodeSource {
    private var next: UInt64

    init(start: UInt64) {
        next = start
    }

    func allocate() -> Inode {
        let value = next
        next += 1
        return Inode(rawValue: value)
    }
}

private actor MemoryMetadataStore: MetadataStore {
    private var rows: [UInt64: MetadataRecord] = [:]
    private var failing: Set<String> = []
    private(set) var insertions = 0
    private(set) var updates = 0
    private(set) var removals = 0

    func setFailures(_ ids: Set<String>) {
        failing = ids
    }

    func resetCounts() {
        insertions = 0
        updates = 0
        removals = 0
    }

    func record(inode: Inode) throws -> MetadataRecord? {
        rows[inode.rawValue]
    }

    func record(driveID: DriveID) throws -> MetadataRecord? {
        rows.values.first { $0.driveID == driveID }
    }

    func child(of parent: Inode, name: String) throws -> MetadataRecord? {
        rows.values.first { $0.parent == parent && $0.name == name }
    }

    func children(of parent: Inode) throws -> [MetadataRecord] {
        rows.values.filter { $0.parent == parent }
    }

    func insert(_ record: MetadataRecord) throws {
        if let id = record.driveID?.rawValue, failing.contains(id) {
            throw StoreFault.failed
        }
        if rows[record.inode.rawValue] != nil {
            throw StoreFault.failed
        }
        rows[record.inode.rawValue] = record
        insertions += 1
    }

    func update(_ record: MetadataRecord) throws {
        guard rows[record.inode.rawValue] != nil else {
            throw StoreFault.failed
        }
        rows[record.inode.rawValue] = record
        updates += 1
    }

    func remove(inode: Inode) throws {
        guard rows.removeValue(forKey: inode.rawValue) != nil else {
            throw StoreFault.failed
        }
        removals += 1
    }
}

private actor RecordingKernel: KernelCachePort {
    private(set) var invalidated: [Inode] = []
    private(set) var revoked: [Inode] = []

    func invalidateCachedItem(_ inode: Inode) async {
        invalidated.append(inode)
    }

    func revokeCachedItem(_ inode: Inode) async {
        revoked.append(inode)
    }
}

private actor PageDrive: DriveBackend {
    private let fallbackStart: String
    private var queuedStarts: [String] = []
    private var pages: [String: DriveChangePage] = [:]
    private var rejected: Set<String> = []
    private(set) var startCalls = 0
    private(set) var tokens: [String] = []
    private(set) var pageSizes: [Int?] = []

    init(start: String = "start") {
        fallbackStart = start
    }

    func queueStarts(_ tokens: [String]) {
        queuedStarts = tokens
    }

    func reject(_ token: String) {
        rejected.insert(token)
    }

    func setPage(_ token: String, _ page: DriveChangePage) {
        pages[token] = page
    }

    func listFiles(query: String?, pageToken: String?, pageSize: Int?) async throws -> DriveFilePage {
        throw PageFault.unsupported
    }

    func getFile(id: DriveID) async throws -> DriveFile {
        throw PageFault.unsupported
    }

    func createFile(metadata: DriveFileCreate) async throws -> DriveFile {
        throw PageFault.unsupported
    }

    func updateFile(id: DriveID, metadata: DriveFileUpdate) async throws -> DriveFile {
        throw PageFault.unsupported
    }

    func deleteFile(id: DriveID) async throws {
        throw PageFault.unsupported
    }

    func exportFile(id: DriveID, mimeType: String) async throws -> Data {
        throw PageFault.unsupported
    }

    func downloadContent(id: DriveID, range: ByteRange?) async throws -> DriveContent {
        throw PageFault.unsupported
    }

    func multipartUpload(_ intent: MultipartUploadIntent) async throws -> DriveFile {
        throw PageFault.unsupported
    }

    func startResumableUpload(_ intent: ResumableUploadIntent) async throws -> ResumableUploadSession {
        throw PageFault.unsupported
    }

    func resumeUpload(session: ResumableUploadSession, chunk: DriveUploadChunk) async throws -> ResumableUploadProgress {
        throw PageFault.unsupported
    }

    func startPageToken() async throws -> String {
        startCalls += 1
        if queuedStarts.isEmpty {
            return fallbackStart
        }
        return queuedStarts.removeFirst()
    }

    func listChanges(pageToken: String, pageSize: Int?) async throws -> DriveChangePage {
        tokens.append(pageToken)
        pageSizes.append(pageSize)
        if rejected.contains(pageToken) {
            throw DriveClientError.notFound
        }
        guard let page = pages[pageToken] else {
            throw DriveClientError.notFound
        }
        return page
    }

    func about() async throws -> DriveAbout {
        throw PageFault.unsupported
    }

    func refreshCredential() async throws {
        throw PageFault.unsupported
    }
}

private func makeFeed(
    directory: URL,
    metadata: MemoryMetadataStore,
    backend: PageDrive,
    kernel: RecordingKernel,
    startInode: UInt64 = 100
) -> ChangeFeed {
    let source = InodeSource(start: startInode)
    return ChangeFeed(
        metadata: metadata,
        backend: backend,
        kernel: kernel,
        checkpointURL: directory.appending(path: "checkpoint"),
        allocateInode: { await source.allocate() }
    )
}

private func change(file: DriveFile) -> DriveChange {
    DriveChange(fileID: file.id, removed: false, file: file)
}

private func removed(_ id: String) -> DriveChange {
    DriveChange(fileID: DriveID(rawValue: id), removed: true, file: nil)
}

private func driveFile(
    _ id: String,
    name: String,
    parents: [String] = [],
    size: Int64? = 4,
    revision: String? = "rev-1",
    md5: String? = "m1",
    mime: String = "text/plain",
    trashed: Bool = false,
    modified: Date? = nil
) -> DriveFile {
    DriveFile(
        id: DriveID(rawValue: id),
        name: name,
        mimeType: mime,
        parents: parents.map { DriveID(rawValue: $0) },
        size: size,
        headRevision: revision,
        md5: md5,
        sha1: nil,
        sha256: nil,
        owner: nil,
        webViewLink: nil,
        trashed: trashed,
        created: nil,
        modified: modified
    )
}

private func row(
    _ inode: UInt64,
    driveID: String?,
    parent: UInt64?,
    name: String,
    size: Int64 = 4,
    revision: String? = "rev-1",
    md5: String? = "m1",
    durability: DurabilityState = .committed,
    mime: String = "text/plain",
    trashed: Bool = false
) -> MetadataRecord {
    MetadataRecord(
        inode: Inode(rawValue: inode),
        driveID: driveID.map { DriveID(rawValue: $0) },
        parent: parent.map { Inode(rawValue: $0) },
        name: name,
        assignedDuplicateSuffix: nil,
        mimeType: mime,
        size: size,
        created: nil,
        modified: nil,
        headRevision: revision,
        md5: md5,
        sha1: nil,
        sha256: nil,
        owner: nil,
        webLink: nil,
        durability: durability,
        trashed: trashed
    )
}

private func scratchDirectory(_ name: String) throws -> URL {
    let root = URL(fileURLWithPath: "/Users/josh/d/gcsf/.work/tmp/c", isDirectory: true)
    let directory = root.appending(path: "sync-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
