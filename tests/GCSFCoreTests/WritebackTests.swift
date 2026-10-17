import Foundation
import Testing
import GCSFCore

@Suite struct WritebackTests {
    @Test func recoveryDeletesUnreferencedStagedBytes() async throws {
        let directory = try scratchDirectory("orphan")
        let backend = MemoryDrive()
        await backend.seedFile(
            driveFile(id: "kept-id", name: "Kept", revision: "rev-1", parents: [], bytes: 4),
            bytes: Data("orig".utf8)
        )
        do {
            let opened = try openJournal(directory: directory, backend: backend)
            try await opened.metadata.insert(
                metadataRow(inode: 10, driveID: "kept-id", name: "Kept", revision: "rev-1", durability: .journaled, size: 4)
            )
            try await opened.journal.writeStaged(relativePath: "orphan", bytes: Data("hello".utf8))
            try await opened.journal.writeStaged(relativePath: "orphan", at: 1, bytes: Data("A".utf8))
            try await opened.journal.appendStaged(relativePath: "orphan", bytes: Data("!".utf8))
            try await opened.journal.truncateStaged(relativePath: "orphan", to: 4)
            #expect(try Data(contentsOf: stagedFile(directory, "orphan")) == Data("hAll".utf8))
            try await opened.journal.writeStaged(relativePath: "kept", bytes: Data("kept-bytes".utf8))
            try await opened.journal.insert(
                journalRow(id: "kept", inode: 10, driveID: "kept-id", state: .journaled, revision: "rev-1", path: "kept")
            )
        }
        await backend.setOffline(true)
        let opened = try openJournal(directory: directory, backend: backend)
        await #expect(throws: DriveFault.offline) {
            try await opened.journal.recover()
        }
        #expect(FileManager.default.fileExists(atPath: stagedFile(directory, "orphan").path) == false)
        #expect(try Data(contentsOf: stagedFile(directory, "kept")) == Data("kept-bytes".utf8))
        let kept = try await opened.journal.record(id: JournalID(rawValue: "kept"))
        #expect(kept?.state == .journaled)
        #expect(await backend.updated.isEmpty)
        #expect(await backend.resumableNames.isEmpty)
    }

    @Test func journaledSessionResumesOnRecover() async throws {
        let directory = try scratchDirectory("resume")
        let backend = MemoryDrive()
        let staged = Data("abcdefghij".utf8)
        await backend.seedFile(
            driveFile(id: "doc-1", name: "Report", revision: "rev-1", parents: ["folder-9"], bytes: 4),
            bytes: Data("XXXX".utf8)
        )
        await backend.seedSession(
            uri: "https://upload.example/session-1",
            existing: "doc-1",
            name: "Report",
            mimeType: "text/plain",
            parents: ["folder-9"],
            totalSize: Int64(staged.count),
            committed: 4,
            prefix: Data("XXXX".utf8)
        )
        do {
            let opened = try openJournal(directory: directory, backend: backend)
            try await opened.metadata.insert(
                metadataRow(
                    inode: 10,
                    driveID: "doc-1",
                    name: "Report",
                    revision: "rev-1",
                    durability: .journaled,
                    size: Int64(staged.count)
                )
            )
            try await opened.journal.writeStaged(relativePath: "edit", bytes: staged)
            try await opened.journal.insert(
                journalRow(
                    id: "j1",
                    inode: 10,
                    driveID: "doc-1",
                    state: .journaled,
                    revision: "rev-1",
                    path: "edit",
                    session: "https://upload.example/session-1"
                )
            )
        }
        let opened = try openJournal(directory: directory, backend: backend)
        try await opened.journal.recover()
        let row = try #require(try await opened.metadata.record(inode: Inode(rawValue: 10)))
        let remote = try #require(await backend.file(id: "doc-1"))
        #expect(row.headRevision == remote.headRevision)
        #expect(row.headRevision != "rev-1")
        #expect(row.durability == .committed)
        #expect(row.driveID == DriveID(rawValue: "doc-1"))
        #expect(await backend.storedBytes(id: "doc-1") == Data("XXXXefghij".utf8))
        #expect(await backend.getIDs.isEmpty)
        #expect(await backend.resumableNames.isEmpty)
        #expect(await backend.resumeOffsets == [0, 4])
        #expect(await backend.updated.isEmpty)
        #expect(try await opened.journal.records().isEmpty)
        #expect(FileManager.default.fileExists(atPath: stagedFile(directory, "edit").path) == false)
    }

    @Test func matchingHeadUploadsTheOriginal() async throws {
        let directory = try scratchDirectory("match")
        let backend = MemoryDrive()
        let staged = Data("abcdef".utf8)
        await backend.seedFile(
            driveFile(id: "doc-1", name: "Report", revision: "rev-1", parents: ["folder-9"], bytes: 3),
            bytes: Data("old".utf8)
        )
        let opened = try openJournal(directory: directory, backend: backend)
        try await opened.metadata.insert(
            metadataRow(inode: 10, driveID: "doc-1", name: "Report", revision: "rev-1", durability: .journaled, size: 3)
        )
        try await opened.journal.writeStaged(relativePath: "edit", bytes: staged)
        try await opened.journal.insert(
            journalRow(id: "j1", inode: 10, driveID: "doc-1", state: .journaled, revision: "rev-1", path: "edit")
        )
        try await opened.journal.synchronize()
        let row = try #require(try await opened.metadata.record(inode: Inode(rawValue: 10)))
        let remote = try #require(await backend.file(id: "doc-1"))
        #expect(row.headRevision == remote.headRevision)
        #expect(row.headRevision != "rev-1")
        #expect(row.durability == .committed)
        #expect(row.driveID == DriveID(rawValue: "doc-1"))
        #expect(row.size == Int64(staged.count))
        #expect(await backend.storedBytes(id: "doc-1") == staged)
        #expect(await backend.resumableExisting == ["doc-1"])
        #expect(await backend.updated.isEmpty)
        #expect(await backend.deleted.isEmpty)
        #expect(await backend.multipartExisting.isEmpty)
        #expect(try await opened.journal.records().isEmpty)
        #expect(FileManager.default.fileExists(atPath: stagedFile(directory, "edit").path) == false)
    }

    @Test func mismatchBecomesConflictedWithoutUpdatingTheOriginal() async throws {
        let directory = try scratchDirectory("conflict")
        let backend = MemoryDrive()
        let local = Data("local-edit".utf8)
        let remoteBytes = Data("remote-bytes".utf8)
        await backend.seedFile(
            driveFile(id: "doc-1", name: "Report", revision: "rev-2", parents: ["folder-9"], bytes: Int64(remoteBytes.count)),
            bytes: remoteBytes
        )
        do {
            let opened = try openJournal(directory: directory, backend: backend)
            try await opened.metadata.insert(
                metadataRow(
                    inode: 10,
                    driveID: "doc-1",
                    name: "Report",
                    revision: "rev-1",
                    durability: .journaled,
                    size: Int64(local.count)
                )
            )
            try await opened.journal.writeStaged(relativePath: "edit", bytes: local)
            try await opened.journal.insert(
                journalRow(id: "j1", inode: 10, driveID: "doc-1", state: .journaled, revision: "rev-1", path: "edit")
            )
            try await opened.journal.synchronize()
            let row = try #require(try await opened.metadata.record(inode: Inode(rawValue: 10)))
            #expect(row.durability == .conflicted)
            #expect(row.headRevision == "rev-1")
            #expect(row.size == Int64(local.count))
            #expect(row.driveID == DriveID(rawValue: "doc-1"))
            #expect(try Data(contentsOf: stagedFile(directory, "edit")) == local)
            let stored = try await opened.journal.record(id: JournalID(rawValue: "j1"))
            #expect(stored?.state == .conflicted)
            #expect(stored?.uploadSessionURI == nil)
            #expect(await backend.updated.isEmpty)
            #expect(await backend.deleted.isEmpty)
            #expect(await backend.multipartExisting.isEmpty)
            #expect(await backend.resumableExisting == [nil])
            #expect(await backend.resumableNames == ["Report.gcsf-conflict-doc-1"])
            #expect(await backend.resumableParents == [["folder-9"]])
            #expect(await backend.storedBytes(id: "doc-1") == remoteBytes)
            #expect(await backend.file(id: "doc-1")?.headRevision == "rev-2")
            let copies = await backend.files(named: "Report.gcsf-conflict-doc-1")
            #expect(copies.count == 1)
            #expect(await backend.storedBytes(id: copies[0].id.rawValue) == local)
            let uploads = await backend.resumableNames.count
            let gets = await backend.getIDs.count
            try await opened.journal.synchronize()
            #expect(await backend.resumableNames.count == uploads)
            #expect(await backend.getIDs.count == gets)
            #expect(await backend.updated.isEmpty)
        }
        await backend.setOffline(true)
        let opened = try openJournal(directory: directory, backend: backend)
        try await opened.journal.recover()
        let row = try #require(try await opened.metadata.record(inode: Inode(rawValue: 10)))
        #expect(row.durability == .conflicted)
        #expect(row.headRevision == "rev-1")
        #expect(try Data(contentsOf: stagedFile(directory, "edit")) == local)
        #expect(await backend.updated.isEmpty)
        #expect(await backend.deleted.isEmpty)
        #expect(await backend.resumableNames == ["Report.gcsf-conflict-doc-1"])
        #expect(await backend.file(id: "doc-1")?.headRevision == "rev-2")
        #expect(await backend.storedBytes(id: "doc-1") == remoteBytes)
    }

    @Test func synchronizeThrowsWhileJournaled() async throws {
        let directory = try scratchDirectory("eio")
        let backend = MemoryDrive()
        await backend.setOffline(true)
        let opened = try openJournal(directory: directory, backend: backend)
        try await opened.metadata.insert(
            metadataRow(inode: 10, driveID: "doc-1", name: "Report", revision: "rev-1", durability: .journaled, size: 3)
        )
        try await opened.journal.writeStaged(relativePath: "edit", bytes: Data("abc".utf8))
        try await opened.journal.insert(
            journalRow(id: "j1", inode: 10, driveID: "doc-1", state: .journaled, revision: "rev-1", path: "edit")
        )
        await #expect(throws: POSIXError(.EIO)) {
            try await opened.journal.synchronize()
        }
        let stored = try await opened.journal.record(id: JournalID(rawValue: "j1"))
        #expect(stored?.state == .journaled)
        #expect(try Data(contentsOf: stagedFile(directory, "edit")) == Data("abc".utf8))
        #expect(await backend.updated.isEmpty)
        #expect(await backend.resumableNames.isEmpty)
    }

    @Test func committedRecoveryAppliesAcknowledgedRevision() async throws {
        let directory = try scratchDirectory("committed")
        let backend = MemoryDrive()
        await backend.setOffline(true)
        do {
            let opened = try openJournal(directory: directory, backend: backend)
            try await opened.metadata.insert(
                metadataRow(inode: 10, driveID: "doc-1", name: "Report", revision: "old", durability: .journaled, size: 4)
            )
            try await opened.journal.writeStaged(relativePath: "edit", bytes: Data("done".utf8))
            try await opened.journal.insert(
                journalRow(id: "j1", inode: 10, driveID: "doc-1", state: .committed, revision: "ack-9", path: "edit")
            )
        }
        let opened = try openJournal(directory: directory, backend: backend)
        try await opened.journal.recover()
        let row = try #require(try await opened.metadata.record(inode: Inode(rawValue: 10)))
        #expect(row.headRevision == "ack-9")
        #expect(row.durability == .committed)
        #expect(try await opened.journal.records().isEmpty)
        #expect(FileManager.default.fileExists(atPath: stagedFile(directory, "edit").path) == false)
        #expect(await backend.getIDs.isEmpty)
        #expect(await backend.resumableNames.isEmpty)
        #expect(await backend.resumeURIs.isEmpty)
        #expect(await backend.updated.isEmpty)
    }
}

private enum DriveFault: Error, Equatable, Sendable {
    case unsupported
    case offline
}

private actor MemoryDrive: DriveBackend {
    private struct Session {
        var intent: ResumableUploadIntent
        var buffer: Data
        var committed: Int64
        var completed: DriveFile?
    }

    private var offline = false
    private var filesByID: [String: DriveFile] = [:]
    private var content: [String: Data] = [:]
    private var sessions: [String: Session] = [:]
    private var nextSession = 0
    private var nextAck = 0
    private(set) var getIDs: [String] = []
    private(set) var updated: [String] = []
    private(set) var deleted: [String] = []
    private(set) var resumableExisting: [String?] = []
    private(set) var resumableNames: [String] = []
    private(set) var resumableParents: [[String]] = []
    private(set) var resumeURIs: [String] = []
    private(set) var resumeOffsets: [Int64] = []
    private(set) var multipartExisting: [String?] = []

    func setOffline(_ offline: Bool) {
        self.offline = offline
    }

    func seedFile(_ file: DriveFile, bytes: Data) {
        filesByID[file.id.rawValue] = file
        content[file.id.rawValue] = bytes
    }

    func seedSession(
        uri: String,
        existing: String?,
        name: String,
        mimeType: String,
        parents: [String],
        totalSize: Int64,
        committed: Int64,
        prefix: Data
    ) {
        let intent = ResumableUploadIntent(
            existingFileID: existing.map { DriveID(rawValue: $0) },
            metadata: DriveFileCreate(name: name, mimeType: mimeType, parents: parents.map { DriveID(rawValue: $0) }),
            mimeType: mimeType,
            totalSize: totalSize
        )
        sessions[uri] = Session(intent: intent, buffer: prefix, committed: committed, completed: nil)
    }

    func file(id: String) -> DriveFile? {
        filesByID[id]
    }

    func storedBytes(id: String) -> Data? {
        content[id]
    }

    func files(named name: String) -> [DriveFile] {
        filesByID.values.filter { $0.name == name }.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    func listFiles(query: String?, pageToken: String?, pageSize: Int?) async throws -> DriveFilePage {
        throw DriveFault.unsupported
    }

    func getFile(id: DriveID) async throws -> DriveFile {
        if offline {
            throw DriveFault.offline
        }
        getIDs.append(id.rawValue)
        guard let file = filesByID[id.rawValue] else {
            throw DriveClientError.notFound
        }
        return file
    }

    func createFile(metadata: DriveFileCreate) async throws -> DriveFile {
        throw DriveFault.unsupported
    }

    func updateFile(id: DriveID, metadata: DriveFileUpdate) async throws -> DriveFile {
        updated.append(id.rawValue)
        throw DriveFault.unsupported
    }

    func deleteFile(id: DriveID) async throws {
        deleted.append(id.rawValue)
        throw DriveFault.unsupported
    }

    func exportFile(id: DriveID, mimeType: String) async throws -> Data {
        throw DriveFault.unsupported
    }

    func downloadContent(id: DriveID, range: ByteRange?) async throws -> DriveContent {
        throw DriveFault.unsupported
    }

    func multipartUpload(_ intent: MultipartUploadIntent) async throws -> DriveFile {
        multipartExisting.append(intent.existingFileID?.rawValue)
        throw DriveFault.unsupported
    }

    func startResumableUpload(_ intent: ResumableUploadIntent) async throws -> ResumableUploadSession {
        if offline {
            throw DriveFault.offline
        }
        nextSession += 1
        let uri = "session-\(nextSession)"
        resumableExisting.append(intent.existingFileID?.rawValue)
        resumableNames.append(intent.metadata.name)
        resumableParents.append(intent.metadata.parents.map(\.rawValue))
        sessions[uri] = Session(intent: intent, buffer: Data(), committed: 0, completed: nil)
        return ResumableUploadSession(uri: uri, committedOffset: 0)
    }

    func resumeUpload(session: ResumableUploadSession, chunk: DriveUploadChunk) async throws -> ResumableUploadProgress {
        if offline {
            throw DriveFault.offline
        }
        resumeURIs.append(session.uri)
        resumeOffsets.append(chunk.offset)
        guard var stored = sessions[session.uri] else {
            throw DriveFault.unsupported
        }
        if let completed = stored.completed {
            return ResumableUploadProgress(committedOffset: stored.committed, completedFile: completed, indeterminate: false)
        }
        if chunk.offset < stored.committed {
            return ResumableUploadProgress(committedOffset: stored.committed, completedFile: nil, indeterminate: false)
        }
        if chunk.offset > stored.committed {
            return ResumableUploadProgress(committedOffset: stored.committed, completedFile: nil, indeterminate: true)
        }
        if stored.buffer.count < Int(chunk.offset) {
            stored.buffer.append(Data(count: Int(chunk.offset) - stored.buffer.count))
        } else if stored.buffer.count > Int(chunk.offset) {
            stored.buffer.removeSubrange(Int(chunk.offset)..<stored.buffer.count)
        }
        stored.buffer.append(chunk.bytes)
        stored.committed = chunk.offset + Int64(chunk.bytes.count)
        if chunk.isLast {
            let file = finish(&stored)
            stored.completed = file
            sessions[session.uri] = stored
            return ResumableUploadProgress(committedOffset: stored.committed, completedFile: file, indeterminate: false)
        }
        sessions[session.uri] = stored
        return ResumableUploadProgress(committedOffset: stored.committed, completedFile: nil, indeterminate: false)
    }

    func startPageToken() async throws -> String {
        throw DriveFault.unsupported
    }

    func listChanges(pageToken: String, pageSize: Int?) async throws -> DriveChangePage {
        throw DriveFault.unsupported
    }

    func about() async throws -> DriveAbout {
        throw DriveFault.unsupported
    }

    func refreshCredential() async throws {
        throw DriveFault.unsupported
    }

    private func finish(_ stored: inout Session) -> DriveFile {
        nextAck += 1
        let id = stored.intent.existingFileID ?? DriveID(rawValue: "new-\(nextAck)")
        let file = DriveFile(
            id: id,
            name: stored.intent.metadata.name,
            mimeType: stored.intent.mimeType,
            parents: stored.intent.metadata.parents,
            size: Int64(stored.buffer.count),
            headRevision: "ack-\(nextAck)",
            md5: "md5",
            sha1: nil,
            sha256: nil,
            owner: nil,
            webViewLink: nil,
            trashed: false,
            created: nil,
            modified: nil
        )
        filesByID[id.rawValue] = file
        content[id.rawValue] = stored.buffer
        return file
    }
}

private func openJournal(
    directory: URL,
    backend: any DriveBackend
) throws -> (journal: SQLiteWritebackJournal, metadata: SQLiteMetadataStore) {
    let metadata = try SQLiteMetadataStore(path: directory.appending(path: "index.sqlite").path)
    let journal = try SQLiteWritebackJournal(
        path: directory.appending(path: "journal.sqlite").path,
        stagingDirectory: directory.appending(path: "staged", directoryHint: .isDirectory),
        metadata: metadata,
        backend: backend
    )
    return (journal, metadata)
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
        parent: Inode(rawValue: 1),
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

private func driveFile(id: String, name: String, revision: String?, parents: [String], bytes: Int64) -> DriveFile {
    DriveFile(
        id: DriveID(rawValue: id),
        name: name,
        mimeType: "text/plain",
        parents: parents.map { DriveID(rawValue: $0) },
        size: bytes,
        headRevision: revision,
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

private func journalRow(
    id: String,
    inode: UInt64,
    driveID: String?,
    state: DurabilityState,
    revision: String?,
    path: String,
    session: String? = nil
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
    let root = URL(fileURLWithPath: "/Users/josh/d/gcsf/.work/tmp/c", isDirectory: true)
    let directory = root.appending(path: "wb-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
