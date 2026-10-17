import Foundation
import SQLite3

public enum WritebackError: Error, Equatable, Sendable {
    case duplicate(JournalID)
    case missingRecord(JournalID)
    case missingMetadata(Inode)
    case missingStagedFile(String)
    case invalidPath(String)
    case invalidState(String)
    case schema(String)
    case stalled
    case sqlite(code: Int32, message: String)
}

public actor SQLiteWritebackJournal: WritebackJournal {
    private static let chunkSize = 256 * 1024

    private let database: JournalDatabase
    private let stagingDirectory: URL
    private let metadata: any MetadataStore
    private let backend: any DriveBackend
    private var flushing = false

    public init(
        path: String,
        stagingDirectory: URL,
        metadata: any MetadataStore,
        backend: any DriveBackend
    ) throws {
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        self.database = try JournalDatabase(path: path)
        self.stagingDirectory = stagingDirectory
        self.metadata = metadata
        self.backend = backend
    }

    public func record(id: JournalID) throws -> JournalRecord? {
        try database.stored(id: id)?.journal
    }

    public func records() throws -> [JournalRecord] {
        try database.records().map(\.journal)
    }

    public func insert(_ record: JournalRecord) throws {
        try validate(record.stagedRelativePath)
        try database.insert(record)
    }

    public func setState(id: JournalID, state: DurabilityState) throws {
        try database.setState(id: id, state: state)
    }

    public func remove(id: JournalID) throws {
        try database.remove(id: id)
    }

    public func writeStaged(relativePath: String, bytes: Data) throws {
        let url = try stagedFileURL(relativePath)
        try bytes.write(to: url, options: .atomic)
    }

    public func writeStaged(relativePath: String, at offset: Int64, bytes: Data) throws {
        if offset < 0 {
            throw POSIXError(.EINVAL)
        }
        let url = try prepareStagedFile(relativePath)
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: bytes)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    public func appendStaged(relativePath: String, bytes: Data) throws {
        let url = try stagedFileURL(relativePath)
        let size = FileManager.default.fileExists(atPath: url.path) ? try fileByteCount(url) : 0
        try writeStaged(relativePath: relativePath, at: size, bytes: bytes)
    }

    public func truncateStaged(relativePath: String, to length: Int64) throws {
        if length < 0 {
            throw POSIXError(.EINVAL)
        }
        let url = try prepareStagedFile(relativePath)
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.truncate(atOffset: UInt64(length))
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    public func recover() async throws {
        try beginFlush()
        defer { endFlush() }
        try Task.checkCancellation()
        try deleteUnreferencedStagedFiles()
        try await flushAll()
    }

    public func synchronize() async throws {
        try beginFlush()
        defer { endFlush() }
        try Task.checkCancellation()
        do {
            try await flushAll()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if try hasUnuploadedDirty() {
                throw POSIXError(.EIO)
            }
            throw error
        }
        if try hasUnuploadedDirty() {
            throw POSIXError(.EIO)
        }
    }

    private func flushAll() async throws {
        let ids = try database.records().map(\.journal.id)
        for id in ids {
            guard let stored = try database.stored(id: id) else {
                continue
            }
            try await flush(stored)
        }
    }

    private func flush(_ stored: StoredJournal) async throws {
        switch stored.journal.state {
        case .staged:
            try database.setState(id: stored.journal.id, state: .journaled)
            guard let promoted = try database.stored(id: stored.journal.id) else {
                throw WritebackError.missingRecord(stored.journal.id)
            }
            try await uploadJournaled(promoted.journal)
        case .journaled:
            try await uploadJournaled(stored.journal)
        case .committed:
            try await finalizeCommitted(stored.journal)
        case .conflicted:
            try await resolveConflict(stored)
        }
    }

    private func uploadJournaled(_ record: JournalRecord) async throws {
        let url = try existingStagedFile(record)
        if let uri = record.uploadSessionURI {
            let acknowledged = try await uploadSession(uri: uri, fileURL: url)
            try await finalizeCommitted(record, acknowledged: acknowledged, stagedURL: url)
            return
        }
        let meta = try await requireMetadata(record.inode)
        if let driveID = record.driveID ?? meta.driveID {
            let remote = try await backend.getFile(id: driveID)
            if remote.headRevision != record.headRevision {
                try database.setState(id: record.id, state: .conflicted)
                try database.setSession(id: record.id, uri: nil)
                guard let conflicted = try database.stored(id: record.id) else {
                    throw WritebackError.missingRecord(record.id)
                }
                try await uploadConflictCopy(
                    conflicted,
                    metadata: meta,
                    parents: remote.parents,
                    driveID: driveID,
                    fileURL: url
                )
                return
            }
            try await startUpload(
                record: record,
                existing: driveID,
                name: meta.name,
                mimeType: meta.mimeType,
                parents: remote.parents,
                fileURL: url
            )
            return
        }
        try await startUpload(
            record: record,
            existing: nil,
            name: meta.name,
            mimeType: meta.mimeType,
            parents: try await parentDriveIDs(of: meta),
            fileURL: url
        )
    }

    private func resolveConflict(_ stored: StoredJournal) async throws {
        if stored.conflictUploaded {
            try await markMetadataConflicted(stored.journal.inode)
            return
        }
        let url = try existingStagedFile(stored.journal)
        let meta = try await requireMetadata(stored.journal.inode)
        guard let driveID = stored.journal.driveID ?? meta.driveID else {
            throw WritebackError.missingMetadata(stored.journal.inode)
        }
        if let uri = stored.journal.uploadSessionURI {
            _ = try await uploadSession(uri: uri, fileURL: url)
            try database.markConflictUploaded(id: stored.journal.id)
            try await markMetadataConflicted(stored.journal.inode)
            return
        }
        try await uploadConflictCopy(
            stored,
            metadata: meta,
            parents: try await parentDriveIDs(of: meta),
            driveID: driveID,
            fileURL: url
        )
    }

    private func uploadConflictCopy(
        _ stored: StoredJournal,
        metadata: MetadataRecord,
        parents: [DriveID],
        driveID: DriveID,
        fileURL: URL
    ) async throws {
        let name = "\(metadata.name).gcsf-conflict-\(driveID.rawValue)"
        let size = try fileByteCount(fileURL)
        let session = try await backend.startResumableUpload(
            ResumableUploadIntent(
                existingFileID: nil,
                metadata: DriveFileCreate(name: name, mimeType: metadata.mimeType, parents: parents),
                mimeType: metadata.mimeType,
                totalSize: size
            )
        )
        try database.setSession(id: stored.journal.id, uri: session.uri)
        _ = try await uploadSession(uri: session.uri, fileURL: fileURL)
        try database.markConflictUploaded(id: stored.journal.id)
        try await markMetadataConflicted(stored.journal.inode)
    }

    private func startUpload(
        record: JournalRecord,
        existing: DriveID?,
        name: String,
        mimeType: String,
        parents: [DriveID],
        fileURL: URL
    ) async throws {
        let size = try fileByteCount(fileURL)
        let session = try await backend.startResumableUpload(
            ResumableUploadIntent(
                existingFileID: existing,
                metadata: DriveFileCreate(name: name, mimeType: mimeType, parents: parents),
                mimeType: mimeType,
                totalSize: size
            )
        )
        try database.setSession(id: record.id, uri: session.uri)
        let acknowledged = try await uploadSession(uri: session.uri, fileURL: fileURL)
        try await finalizeCommitted(record, acknowledged: acknowledged, stagedURL: fileURL)
    }

    private func uploadSession(uri: String, fileURL: URL) async throws -> DriveFile {
        let total = try fileByteCount(fileURL)
        var offset: Int64 = 0
        var queries = 0
        var steps = 0
        let chunkSpan = Int64(Self.chunkSize)
        let maxSteps = 8 + Int(min(total / chunkSpan, Int64(1_000_000)))
        while steps < maxSteps {
            steps += 1
            try Task.checkCancellation()
            if offset > total {
                throw WritebackError.stalled
            }
            if offset == total {
                let queried = try await backend.resumeUpload(
                    session: ResumableUploadSession(uri: uri, committedOffset: total),
                    chunk: DriveUploadChunk(offset: total, bytes: Data(), isLast: true)
                )
                if let file = queried.completedFile {
                    return file
                }
                queries += 1
                if queries > 2 || !queried.indeterminate {
                    throw WritebackError.stalled
                }
                continue
            }
            let length = Int(min(chunkSpan, total - offset))
            let bytes = try readChunk(url: fileURL, offset: offset, count: length)
            let isLast = offset + Int64(bytes.count) == total
            let progress = try await backend.resumeUpload(
                session: ResumableUploadSession(uri: uri, committedOffset: offset),
                chunk: DriveUploadChunk(offset: offset, bytes: bytes, isLast: isLast)
            )
            if let file = progress.completedFile {
                return file
            }
            if progress.indeterminate {
                queries += 1
                if queries > 2 {
                    throw WritebackError.stalled
                }
                let queried = try await backend.resumeUpload(
                    session: ResumableUploadSession(uri: uri, committedOffset: total),
                    chunk: DriveUploadChunk(offset: total, bytes: Data(), isLast: true)
                )
                if let file = queried.completedFile {
                    return file
                }
                if !queried.indeterminate, queried.committedOffset > offset {
                    offset = min(queried.committedOffset, total)
                    continue
                }
                throw WritebackError.stalled
            }
            guard progress.committedOffset > offset else {
                throw WritebackError.stalled
            }
            offset = progress.committedOffset
        }
        throw WritebackError.stalled
    }

    private func finalizeCommitted(
        _ record: JournalRecord,
        acknowledged: DriveFile,
        stagedURL: URL
    ) async throws {
        let stagedSize = try fileByteCount(stagedURL)
        let revision = acknowledged.headRevision ?? record.headRevision
        try database.markCommitted(id: record.id, revision: revision)
        if var row = try await metadata.record(inode: record.inode) {
            row.headRevision = revision
            row.durability = .committed
            row.size = acknowledged.size ?? stagedSize
            row.md5 = acknowledged.md5
            row.sha1 = acknowledged.sha1
            row.sha256 = acknowledged.sha256
            if let modified = acknowledged.modified {
                row.modified = modified
            }
            if row.driveID == nil {
                row.driveID = acknowledged.id
            }
            try await metadata.update(row)
        }
        if FileManager.default.fileExists(atPath: stagedURL.path) {
            try FileManager.default.removeItem(at: stagedURL)
        }
        try database.remove(id: record.id)
    }

    private func finalizeCommitted(_ record: JournalRecord) async throws {
        if var row = try await metadata.record(inode: record.inode) {
            row.headRevision = record.headRevision
            row.durability = .committed
            try await metadata.update(row)
        }
        let url = try stagedFileURL(record.stagedRelativePath)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try database.remove(id: record.id)
    }

    private func markMetadataConflicted(_ inode: Inode) async throws {
        guard var row = try await metadata.record(inode: inode) else {
            throw WritebackError.missingMetadata(inode)
        }
        row.durability = .conflicted
        try await metadata.update(row)
    }

    private func requireMetadata(_ inode: Inode) async throws -> MetadataRecord {
        guard let row = try await metadata.record(inode: inode) else {
            throw WritebackError.missingMetadata(inode)
        }
        return row
    }

    private func parentDriveIDs(of row: MetadataRecord) async throws -> [DriveID] {
        guard let parent = row.parent, let parentRow = try await metadata.record(inode: parent) else {
            return []
        }
        guard let driveID = parentRow.driveID else {
            return []
        }
        return [driveID]
    }

    private func existingStagedFile(_ record: JournalRecord) throws -> URL {
        let url = try stagedFileURL(record.stagedRelativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WritebackError.missingStagedFile(record.stagedRelativePath)
        }
        return url
    }

    private func deleteUnreferencedStagedFiles() throws {
        let referenced = Set(try database.records().map(\.journal.stagedRelativePath))
        let urls = try FileManager.default.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        for url in urls {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                continue
            }
            if referenced.contains(url.lastPathComponent) {
                continue
            }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func hasUnuploadedDirty() throws -> Bool {
        for stored in try database.records() {
            switch stored.journal.state {
            case .staged, .journaled:
                return true
            case .conflicted where !stored.conflictUploaded:
                return true
            case .committed, .conflicted:
                continue
            }
        }
        return false
    }

    private func beginFlush() throws {
        if flushing {
            throw WritebackError.stalled
        }
        flushing = true
    }

    private func endFlush() {
        flushing = false
    }

    private func prepareStagedFile(_ relativePath: String) throws -> URL {
        let url = try stagedFileURL(relativePath)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw WritebackError.missingStagedFile(relativePath)
            }
        }
        return url
    }

    private func stagedFileURL(_ relativePath: String) throws -> URL {
        try validate(relativePath)
        return stagingDirectory.appending(path: relativePath)
    }

    private func validate(_ relativePath: String) throws {
        if relativePath.isEmpty
            || relativePath == "."
            || relativePath == ".."
            || relativePath.contains("/")
            || relativePath.contains("\\")
            || relativePath.contains("\0") {
            throw WritebackError.invalidPath(relativePath)
        }
    }

    private func fileByteCount(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else {
            throw WritebackError.missingStagedFile(url.lastPathComponent)
        }
        return Int64(size)
    }

    private func readChunk(url: URL, offset: Int64, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        do {
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: count) ?? Data()
            try handle.close()
            guard data.count == count else {
                throw WritebackError.missingStagedFile(url.lastPathComponent)
            }
            return data
        } catch {
            try? handle.close()
            throw error
        }
    }
}

private struct StoredJournal {
    var journal: JournalRecord
    var conflictUploaded: Bool
}

private final class JournalDatabase: @unchecked Sendable {
    private static let transient: sqlite3_destructor_type = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    private var pointer: OpaquePointer?

    init(path: String) throws {
        let existed = FileManager.default.fileExists(atPath: path)
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(path, &opened, flags, nil)
        guard code == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let opened {
                sqlite3_close(opened)
            }
            if !existed {
                try? FileManager.default.removeItem(atPath: path)
            }
            throw WritebackError.sqlite(code: code, message: message)
        }
        pointer = opened
        sqlite3_extended_result_codes(opened, 1)
        sqlite3_busy_timeout(opened, 5_000)
        do {
            try exec("PRAGMA synchronous = FULL")
            if existed {
                try verifySchema()
            } else {
                try createSchema()
            }
        } catch {
            sqlite3_close(opened)
            pointer = nil
            if !existed {
                try? FileManager.default.removeItem(atPath: path)
            }
            throw error
        }
    }

    deinit {
        if let pointer {
            sqlite3_close(pointer)
        }
    }

    func stored(id: JournalID) throws -> StoredJournal? {
        try queryOne(
            """
            SELECT id, inode, drive_id, state, head_revision, staged_relative_path, \
            upload_session_uri, conflict_uploaded \
            FROM journal WHERE id = ?
            """,
            bind: { try self.bindText($0, 1, id.rawValue) }
        )
    }

    func records() throws -> [StoredJournal] {
        try query(
            """
            SELECT id, inode, drive_id, state, head_revision, staged_relative_path, \
            upload_session_uri, conflict_uploaded \
            FROM journal ORDER BY id ASC
            """
        )
    }

    func insert(_ record: JournalRecord) throws {
        try run(
            """
            INSERT INTO journal (
                id, inode, drive_id, state, head_revision, staged_relative_path, \
                upload_session_uri, conflict_uploaded
            ) VALUES (?, ?, ?, ?, ?, ?, ?, 0)
            """,
            bind: { statement in
                try self.bindText(statement, 1, record.id.rawValue)
                try self.bindInt(statement, 2, try self.storageInode(record.inode))
                try self.bindText(statement, 3, record.driveID?.rawValue)
                try self.bindText(statement, 4, record.state.rawValue)
                try self.bindText(statement, 5, record.headRevision)
                try self.bindText(statement, 6, record.stagedRelativePath)
                try self.bindText(statement, 7, record.uploadSessionURI)
            },
            id: record.id
        )
    }

    func setState(id: JournalID, state: DurabilityState) throws {
        try run(
            "UPDATE journal SET state = ? WHERE id = ?",
            bind: {
                try self.bindText($0, 1, state.rawValue)
                try self.bindText($0, 2, id.rawValue)
            },
            id: id
        )
        try requireChange(id)
    }

    func setSession(id: JournalID, uri: String?) throws {
        try run(
            "UPDATE journal SET upload_session_uri = ? WHERE id = ?",
            bind: {
                try self.bindText($0, 1, uri)
                try self.bindText($0, 2, id.rawValue)
            },
            id: id
        )
        try requireChange(id)
    }

    func markCommitted(id: JournalID, revision: String?) throws {
        try run(
            """
            UPDATE journal
            SET state = 'committed', head_revision = ?, upload_session_uri = NULL, conflict_uploaded = 0
            WHERE id = ?
            """,
            bind: {
                try self.bindText($0, 1, revision)
                try self.bindText($0, 2, id.rawValue)
            },
            id: id
        )
        try requireChange(id)
    }

    func markConflictUploaded(id: JournalID) throws {
        try run(
            """
            UPDATE journal
            SET state = 'conflicted', upload_session_uri = NULL, conflict_uploaded = 1
            WHERE id = ?
            """,
            bind: { try self.bindText($0, 1, id.rawValue) },
            id: id
        )
        try requireChange(id)
    }

    func remove(id: JournalID) throws {
        try run(
            "DELETE FROM journal WHERE id = ?",
            bind: { try self.bindText($0, 1, id.rawValue) },
            id: id
        )
        try requireChange(id)
    }

    private func createSchema() throws {
        try exec(
            """
            CREATE TABLE journal (
                id TEXT PRIMARY KEY NOT NULL,
                inode INTEGER NOT NULL,
                drive_id TEXT,
                state TEXT NOT NULL CHECK (state IN ('staged', 'journaled', 'committed', 'conflicted')),
                head_revision TEXT,
                staged_relative_path TEXT NOT NULL,
                upload_session_uri TEXT,
                conflict_uploaded INTEGER NOT NULL DEFAULT 0 CHECK (conflict_uploaded IN (0, 1))
            ) STRICT
            """
        )
    }

    private func verifySchema() throws {
        try exec(
            """
            SELECT id, inode, drive_id, state, head_revision, staged_relative_path, \
            upload_session_uri, conflict_uploaded \
            FROM journal LIMIT 0
            """
        )
    }

    private func requireChange(_ id: JournalID) throws {
        guard sqlite3_changes(pointer) == 1 else {
            throw WritebackError.missingRecord(id)
        }
    }

    private func query(_ sql: String, bind: (OpaquePointer) throws -> Void = { _ in }) throws -> [StoredJournal] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        var rows: [StoredJournal] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                rows.append(try read(statement))
            } else if code == SQLITE_DONE {
                return rows
            } else {
                throw failure(code, id: nil)
            }
        }
    }

    private func queryOne(_ sql: String, bind: (OpaquePointer) throws -> Void) throws -> StoredJournal? {
        let rows = try query(sql, bind: bind)
        guard rows.count < 2 else {
            throw WritebackError.schema("lookup")
        }
        return rows.first
    }

    private func run(
        _ sql: String,
        bind: (OpaquePointer) throws -> Void,
        id: JournalID
    ) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else {
            throw failure(code, id: id)
        }
    }

    private func read(_ statement: OpaquePointer) throws -> StoredJournal {
        guard let id = text(statement, 0) else {
            throw WritebackError.schema("id")
        }
        let inode = try requiredInt(statement, 1)
        guard inode >= 0 else {
            throw WritebackError.invalidState("inode")
        }
        guard let stateText = text(statement, 3), let state = DurabilityState(rawValue: stateText) else {
            throw WritebackError.invalidState(text(statement, 3) ?? "")
        }
        guard let path = text(statement, 5) else {
            throw WritebackError.invalidPath("")
        }
        let record = JournalRecord(
            id: JournalID(rawValue: id),
            inode: Inode(rawValue: UInt64(inode)),
            driveID: text(statement, 2).map { DriveID(rawValue: $0) },
            state: state,
            headRevision: text(statement, 4),
            stagedRelativePath: path,
            uploadSessionURI: text(statement, 6)
        )
        return StoredJournal(journal: record, conflictUploaded: try requiredInt(statement, 7) == 1)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(pointer, sql, -1, &statement, nil))
        guard let statement else {
            throw WritebackError.schema("prepare")
        }
        return statement
    }

    private func exec(_ sql: String) throws {
        try check(sqlite3_exec(pointer, sql, nil, nil, nil))
    }

    private func check(_ code: Int32) throws {
        guard code == SQLITE_OK else {
            throw failure(code, id: nil)
        }
    }

    private func failure(_ code: Int32, id: JournalID?) -> WritebackError {
        let primary = code & 0xFF
        if primary == SQLITE_CONSTRAINT, let id {
            return .duplicate(id)
        }
        let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite"
        return .sqlite(code: code, message: message)
    }

    private func bindInt(_ statement: OpaquePointer, _ index: Int32, _ value: Int64) throws {
        try check(sqlite3_bind_int64(statement, index, value))
    }

    private func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String?) throws {
        guard let value else {
            try check(sqlite3_bind_null(statement, index))
            return
        }
        try value.withCString { cString in
            try check(sqlite3_bind_text(statement, index, cString, -1, Self.transient))
        }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        guard let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
    }

    private func requiredInt(_ statement: OpaquePointer, _ index: Int32) throws -> Int64 {
        guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else {
            throw WritebackError.schema("column \(index)")
        }
        return sqlite3_column_int64(statement, index)
    }

    private func storageInode(_ inode: Inode) throws -> Int64 {
        guard inode.rawValue <= UInt64(Int64.max) else {
            throw WritebackError.invalidState("inode")
        }
        return Int64(inode.rawValue)
    }
}
