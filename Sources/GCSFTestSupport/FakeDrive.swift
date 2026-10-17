import Foundation
import GCSFCore

public enum FakeDriveFault: Sendable, Equatable {
    case unauthorized
    case refreshFailure
    case forbidden
    case rateLimited
    case serverError
    case malformedMetadata
    case timeout
    case cancellation
    case partialDownload
    case resumeIncomplete
    case redirect
    case indeterminate
}

public enum FakeDriveError: Error, Equatable, Sendable {
    public static let redirectLocation = "https://redirect.invalid/drive"

    case unauthorized
    case refreshFailure
    case forbidden
    case rateLimited
    case server
    case malformedMetadata
    case timeout
    case unknownQuery(String)
    case notFound(DriveID)
    case pageToken(String)
    case pageSize
    case range
    case uploadSession(String)
    case redirect(String)
}

public actor FakeDrive: DriveBackend {
    private static let googlePrefix = "application/vnd.google-apps."
    private static let nativeExport = Data("Google-native document".utf8)

    private enum Call: Equatable {
        case general
        case refresh
        case download
        case resume
    }

    private enum Clause: Equatable {
        case trashed(Bool)
        case parent(DriveID)
    }

    private struct Session {
        var intent: ResumableUploadIntent
        var bytes: Data
        var committedOffset: Int64
        var publishedID: DriveID?
    }

    public let rootFolderID: DriveID
    public let userEmail: String?
    public private(set) var redirects: [String] = []

    private var files: [DriveID: DriveFile] = [:]
    private var bodies: [DriveID: Data] = [:]
    private var order: [DriveID] = []
    private var changes: [DriveChange] = []
    private var sessions: [String: Session] = [:]
    private var faults: [FakeDriveFault] = []
    private var nextID = 1
    private var nextSession = 1
    private var clock: TimeInterval = 1_700_000_000

    public init(rootFolderID: DriveID = DriveID(rawValue: "root"), userEmail: String? = "owner@example.com") {
        self.rootFolderID = rootFolderID
        self.userEmail = userEmail
    }

    public func arm(_ fault: FakeDriveFault) {
        faults.append(fault)
    }

    public func listFiles(query: String?, pageToken: String?, pageSize: Int?) async throws -> DriveFilePage {
        _ = try consume(.general)
        let clauses = try parse(query)
        let matched = order.compactMap { files[$0] }.filter { matches($0, clauses) }
        let start = try offset(pageToken, limit: matched.count)
        let end = try sliceEnd(start: start, count: matched.count, pageSize: pageSize)
        let next = end < matched.count ? String(end) : nil
        return DriveFilePage(files: Array(matched[start..<end]), nextPageToken: next)
    }

    public func getFile(id: DriveID) async throws -> DriveFile {
        _ = try consume(.general)
        guard let file = files[id] else { throw FakeDriveError.notFound(id) }
        return file
    }

    public func createFile(metadata: DriveFileCreate) async throws -> DriveFile {
        _ = try consume(.general)
        return insert(name: metadata.name, mimeType: metadata.mimeType, parents: metadata.parents, trashed: false, body: Data(), created: nil, revision: "1", webViewLink: nil)
    }

    public func updateFile(id: DriveID, metadata: DriveFileUpdate) async throws -> DriveFile {
        _ = try consume(.general)
        guard let current = files[id] else { throw FakeDriveError.notFound(id) }
        let mime = metadata.mimeType ?? current.mimeType
        let file = materialize(
            id: id,
            name: metadata.name ?? current.name,
            mimeType: mime,
            parents: metadata.parents ?? current.parents,
            trashed: metadata.trashed ?? current.trashed,
            body: bodies[id] ?? Data(),
            created: current.created,
            headRevision: current.headRevision ?? "1",
            webViewLink: current.webViewLink
        )
        files[id] = file
        record(file)
        return file
    }

    public func deleteFile(id: DriveID) async throws {
        _ = try consume(.general)
        guard files.removeValue(forKey: id) != nil else { throw FakeDriveError.notFound(id) }
        bodies.removeValue(forKey: id)
        order.removeAll { $0 == id }
        changes.append(DriveChange(fileID: id, removed: true, file: nil))
    }

    public func exportFile(id: DriveID, mimeType: String) async throws -> Data {
        _ = try consume(.general)
        guard let file = files[id] else { throw FakeDriveError.notFound(id) }
        if file.mimeType.hasPrefix(Self.googlePrefix) {
            return Self.nativeExport
        }
        return bodies[id] ?? Data()
    }

    public func downloadContent(id: DriveID, range: ByteRange?) async throws -> DriveContent {
        let fault = try consume(.download)
        guard files[id] != nil else { throw FakeDriveError.notFound(id) }
        var content = try slice(bodies[id] ?? Data(), range)
        if fault == .partialDownload, !content.bytes.isEmpty {
            content.bytes.removeLast()
        }
        return content
    }

    public func multipartUpload(_ intent: MultipartUploadIntent) async throws -> DriveFile {
        _ = try consume(.general)
        let mime = intent.metadata.mimeType.isEmpty ? intent.mimeType : intent.metadata.mimeType
        if let existing = intent.existingFileID {
            guard let current = files[existing] else { throw FakeDriveError.notFound(existing) }
            let file = materialize(
                id: existing,
                name: intent.metadata.name,
                mimeType: mime,
                parents: intent.metadata.parents,
                trashed: current.trashed,
                body: intent.body,
                created: current.created,
                headRevision: bumped(current.headRevision),
                webViewLink: current.webViewLink
            )
            files[existing] = file
            bodies[existing] = intent.body
            record(file)
            return file
        }
        return insert(name: intent.metadata.name, mimeType: mime, parents: intent.metadata.parents, trashed: false, body: intent.body, created: nil, revision: "1", webViewLink: nil)
    }

    public func startResumableUpload(_ intent: ResumableUploadIntent) async throws -> ResumableUploadSession {
        _ = try consume(.general)
        guard intent.totalSize >= 0 else { throw FakeDriveError.uploadSession("size") }
        if let existing = intent.existingFileID {
            guard files[existing] != nil else { throw FakeDriveError.notFound(existing) }
        }
        let uri = "fakesession:\(nextSession)"
        nextSession += 1
        sessions[uri] = Session(intent: intent, bytes: Data(), committedOffset: 0, publishedID: nil)
        return ResumableUploadSession(uri: uri, committedOffset: 0)
    }

    public func resumeUpload(session: ResumableUploadSession, chunk: DriveUploadChunk) async throws -> ResumableUploadProgress {
        guard var stored = sessions[session.uri] else { throw FakeDriveError.uploadSession(session.uri) }
        let fault = try consume(.resume)
        if fault == .indeterminate {
            return ResumableUploadProgress(committedOffset: stored.committedOffset, completedFile: nil, indeterminate: true)
        }
        let end = try append(chunk, to: &stored)
        sessions[session.uri] = stored
        if fault != .resumeIncomplete, completes(stored, chunk: chunk, end: end) {
            let file = try publish(&stored)
            sessions[session.uri] = stored
            return ResumableUploadProgress(committedOffset: end, completedFile: file, indeterminate: false)
        }
        return ResumableUploadProgress(committedOffset: end, completedFile: nil, indeterminate: false)
    }

    public func startPageToken() async throws -> String {
        _ = try consume(.general)
        return String(changes.count)
    }

    public func listChanges(pageToken: String, pageSize: Int?) async throws -> DriveChangePage {
        _ = try consume(.general)
        let start = try offset(pageToken, limit: changes.count)
        let end = try sliceEnd(start: start, count: changes.count, pageSize: pageSize)
        let finished = end == changes.count
        return DriveChangePage(
            changes: Array(changes[start..<end]),
            nextPageToken: finished ? nil : String(end),
            newStartPageToken: finished ? String(changes.count) : nil
        )
    }

    public func about() async throws -> DriveAbout {
        _ = try consume(.general)
        return DriveAbout(rootFolderID: rootFolderID, userEmail: userEmail)
    }

    public func refreshCredential() async throws {
        _ = try consume(.refresh)
    }

    private func insert(
        name: String,
        mimeType: String,
        parents: [DriveID],
        trashed: Bool,
        body: Data,
        created: Date?,
        revision: String,
        webViewLink: String?
    ) -> DriveFile {
        let id = allocateID()
        let file = materialize(
            id: id,
            name: name,
            mimeType: mimeType,
            parents: parents,
            trashed: trashed,
            body: body,
            created: created,
            headRevision: revision,
            webViewLink: webViewLink
        )
        files[id] = file
        bodies[id] = body
        order.append(id)
        record(file)
        return file
    }

    private func publish(_ session: inout Session) throws -> DriveFile {
        if let published = session.publishedID, let existing = files[published] {
            return existing
        }
        let metadata = session.intent.metadata
        let mime = metadata.mimeType.isEmpty ? session.intent.mimeType : metadata.mimeType
        if let existingID = session.intent.existingFileID {
            guard let current = files[existingID] else { throw FakeDriveError.notFound(existingID) }
            let file = materialize(
                id: existingID,
                name: metadata.name,
                mimeType: mime,
                parents: metadata.parents,
                trashed: current.trashed,
                body: session.bytes,
                created: current.created,
                headRevision: bumped(current.headRevision),
                webViewLink: current.webViewLink
            )
            files[existingID] = file
            bodies[existingID] = session.bytes
            session.publishedID = existingID
            record(file)
            return file
        }
        let file = insert(
            name: metadata.name,
            mimeType: mime,
            parents: metadata.parents,
            trashed: false,
            body: session.bytes,
            created: nil,
            revision: "1",
            webViewLink: nil
        )
        session.publishedID = file.id
        return file
    }

    private func materialize(
        id: DriveID,
        name: String,
        mimeType: String,
        parents: [DriveID],
        trashed: Bool,
        body: Data,
        created: Date?,
        headRevision: String,
        webViewLink: String?
    ) -> DriveFile {
        let createdAt = created ?? stamp()
        let modifiedAt = stamp()
        let google = mimeType.hasPrefix(Self.googlePrefix)
        return DriveFile(
            id: id,
            name: name,
            mimeType: mimeType,
            parents: parents,
            size: google ? nil : Int64(body.count),
            headRevision: headRevision,
            md5: nil,
            sha1: nil,
            sha256: nil,
            owner: userEmail,
            webViewLink: webViewLink,
            trashed: trashed,
            created: createdAt,
            modified: modifiedAt
        )
    }

    private func record(_ file: DriveFile) {
        changes.append(DriveChange(fileID: file.id, removed: false, file: file))
    }

    private func append(_ chunk: DriveUploadChunk, to session: inout Session) throws -> Int64 {
        guard chunk.offset == session.committedOffset else {
            throw FakeDriveError.uploadSession(String(chunk.offset))
        }
        let end = try endOffset(chunk)
        guard end <= session.intent.totalSize else { throw FakeDriveError.uploadSession(String(end)) }
        session.bytes.append(chunk.bytes)
        session.committedOffset = end
        return end
    }

    private func completes(_ session: Session, chunk: DriveUploadChunk, end: Int64) -> Bool {
        guard chunk.isLast, end == session.intent.totalSize, session.intent.totalSize <= Int64(Int.max) else {
            return false
        }
        return session.bytes.count == Int(session.intent.totalSize)
    }

    private func endOffset(_ chunk: DriveUploadChunk) throws -> Int64 {
        guard chunk.offset >= 0 else { throw FakeDriveError.uploadSession("offset") }
        let sum = chunk.offset.addingReportingOverflow(Int64(chunk.bytes.count))
        guard !sum.overflow else { throw FakeDriveError.uploadSession("offset") }
        return sum.partialValue
    }

    private func slice(_ data: Data, _ range: ByteRange?) throws -> DriveContent {
        let total = Int64(data.count)
        guard let range else { return DriveContent(bytes: data, offset: 0, totalSize: total) }
        guard range.offset >= 0, range.offset <= total else { throw FakeDriveError.range }
        let start = Int(range.offset)
        let rest = data.count - start
        let count: Int
        if let length = range.length {
            guard length >= 0 else { throw FakeDriveError.range }
            count = min(length, rest)
        } else {
            count = rest
        }
        return DriveContent(bytes: data.subdata(in: start..<(start + count)), offset: range.offset, totalSize: total)
    }

    private func parse(_ query: String?) throws -> [Clause] {
        guard let query else { return [] }
        let parts = query.components(separatedBy: " and ")
        guard !parts.isEmpty else { throw FakeDriveError.unknownQuery(query) }
        return try parts.map { part in
            if part == "trashed = true" { return .trashed(true) }
            if part == "trashed = false" { return .trashed(false) }
            if let parent = parentClause(part) { return .parent(parent) }
            throw FakeDriveError.unknownQuery(query)
        }
    }

    private func parentClause(_ clause: String) -> DriveID? {
        let suffix = "' in parents"
        guard clause.count > suffix.count + 1, clause.hasPrefix("'"), clause.hasSuffix(suffix) else { return nil }
        let inner = clause.dropFirst().dropLast(suffix.count)
        guard !inner.isEmpty, inner.allSatisfy({ $0 != "'" }) else { return nil }
        return DriveID(rawValue: String(inner))
    }

    private func matches(_ file: DriveFile, _ clauses: [Clause]) -> Bool {
        for clause in clauses {
            switch clause {
            case .trashed(let trashed):
                if file.trashed != trashed { return false }
            case .parent(let parent):
                if !file.parents.contains(parent) { return false }
            }
        }
        return true
    }

    private func offset(_ token: String?, limit: Int) throws -> Int {
        guard let token else { return 0 }
        guard let index = canonicalIndex(token), index <= limit else { throw FakeDriveError.pageToken(token) }
        return index
    }

    private func sliceEnd(start: Int, count: Int, pageSize: Int?) throws -> Int {
        if let pageSize {
            guard pageSize > 0 else { throw FakeDriveError.pageSize }
            return min(count, start + pageSize)
        }
        return count
    }

    private func canonicalIndex(_ token: String) -> Int? {
        guard !token.isEmpty, token.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        if token.count > 1, token.first == "0" { return nil }
        return Int(token)
    }

    private func allocateID() -> DriveID {
        let id = DriveID(rawValue: "f\(nextID)")
        nextID += 1
        return id
    }

    private func bumped(_ revision: String?) -> String {
        guard let revision, let value = Int(revision), value >= 0 else { return "1" }
        return String(value + 1)
    }

    private func stamp() -> Date {
        let date = Date(timeIntervalSince1970: clock)
        clock += 1
        return date
    }

    private func applies(_ fault: FakeDriveFault, to call: Call) -> Bool {
        switch fault {
        case .refreshFailure:
            call == .refresh
        case .partialDownload:
            call == .download
        case .resumeIncomplete, .indeterminate:
            call == .resume
        default:
            true
        }
    }

    private func consume(_ call: Call) throws -> FakeDriveFault? {
        if Task.isCancelled { throw CancellationError() }
        guard let index = faults.firstIndex(where: { applies($0, to: call) }) else { return nil }
        let fault = faults.remove(at: index)
        switch fault {
        case .unauthorized:
            throw FakeDriveError.unauthorized
        case .refreshFailure:
            throw FakeDriveError.refreshFailure
        case .forbidden:
            throw FakeDriveError.forbidden
        case .rateLimited:
            throw FakeDriveError.rateLimited
        case .serverError:
            throw FakeDriveError.server
        case .malformedMetadata:
            throw FakeDriveError.malformedMetadata
        case .timeout:
            throw FakeDriveError.timeout
        case .cancellation:
            throw CancellationError()
        case .redirect:
            redirects.append(FakeDriveError.redirectLocation)
            throw FakeDriveError.redirect(FakeDriveError.redirectLocation)
        case .partialDownload, .resumeIncomplete, .indeterminate:
            return fault
        }
    }
}
