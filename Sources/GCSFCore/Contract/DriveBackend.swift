import Foundation

public struct DriveFile: Sendable, Equatable, Codable {
    public var id: DriveID
    public var name: String
    public var mimeType: String
    public var parents: [DriveID]
    public var size: Int64?
    public var headRevision: String?
    public var md5: String?
    public var sha1: String?
    public var sha256: String?
    public var owner: String?
    public var webViewLink: String?
    public var trashed: Bool
    public var created: Date?
    public var modified: Date?

    public init(
        id: DriveID,
        name: String,
        mimeType: String,
        parents: [DriveID],
        size: Int64?,
        headRevision: String?,
        md5: String?,
        sha1: String?,
        sha256: String?,
        owner: String?,
        webViewLink: String?,
        trashed: Bool,
        created: Date?,
        modified: Date?
    ) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.parents = parents
        self.size = size
        self.headRevision = headRevision
        self.md5 = md5
        self.sha1 = sha1
        self.sha256 = sha256
        self.owner = owner
        self.webViewLink = webViewLink
        self.trashed = trashed
        self.created = created
        self.modified = modified
    }
}

public struct DriveFilePage: Sendable, Equatable, Codable {
    public var files: [DriveFile]
    public var nextPageToken: String?

    public init(files: [DriveFile], nextPageToken: String?) {
        self.files = files
        self.nextPageToken = nextPageToken
    }
}

public struct DriveFileCreate: Sendable, Equatable, Codable {
    public var name: String
    public var mimeType: String
    public var parents: [DriveID]

    public init(name: String, mimeType: String, parents: [DriveID]) {
        self.name = name
        self.mimeType = mimeType
        self.parents = parents
    }
}

public struct DriveFileUpdate: Sendable, Equatable, Codable {
    public var name: String?
    public var mimeType: String?
    public var parents: [DriveID]?
    public var trashed: Bool?

    public init(name: String?, mimeType: String?, parents: [DriveID]?, trashed: Bool?) {
        self.name = name
        self.mimeType = mimeType
        self.parents = parents
        self.trashed = trashed
    }
}

public struct DriveChange: Sendable, Equatable, Codable {
    public var fileID: DriveID
    public var removed: Bool
    public var file: DriveFile?

    public init(fileID: DriveID, removed: Bool, file: DriveFile?) {
        self.fileID = fileID
        self.removed = removed
        self.file = file
    }
}

public struct DriveChangePage: Sendable, Equatable, Codable {
    public var changes: [DriveChange]
    public var nextPageToken: String?
    public var newStartPageToken: String?

    public init(changes: [DriveChange], nextPageToken: String?, newStartPageToken: String?) {
        self.changes = changes
        self.nextPageToken = nextPageToken
        self.newStartPageToken = newStartPageToken
    }
}

public struct DriveAbout: Sendable, Equatable, Codable {
    public var rootFolderID: DriveID
    public var userEmail: String?

    public init(rootFolderID: DriveID, userEmail: String?) {
        self.rootFolderID = rootFolderID
        self.userEmail = userEmail
    }
}

public struct ByteRange: Sendable, Equatable, Codable {
    public var offset: Int64
    public var length: Int?

    public init(offset: Int64, length: Int?) {
        self.offset = offset
        self.length = length
    }
}

public struct DriveContent: Sendable, Equatable {
    public var bytes: Data
    public var offset: Int64
    public var totalSize: Int64?

    public init(bytes: Data, offset: Int64, totalSize: Int64?) {
        self.bytes = bytes
        self.offset = offset
        self.totalSize = totalSize
    }
}

public struct MultipartUploadIntent: Sendable, Equatable {
    public var existingFileID: DriveID?
    public var metadata: DriveFileCreate
    public var mimeType: String
    public var body: Data

    public init(existingFileID: DriveID?, metadata: DriveFileCreate, mimeType: String, body: Data) {
        self.existingFileID = existingFileID
        self.metadata = metadata
        self.mimeType = mimeType
        self.body = body
    }
}

public struct ResumableUploadIntent: Sendable, Equatable, Codable {
    public var existingFileID: DriveID?
    public var metadata: DriveFileCreate
    public var mimeType: String
    public var totalSize: Int64

    public init(existingFileID: DriveID?, metadata: DriveFileCreate, mimeType: String, totalSize: Int64) {
        self.existingFileID = existingFileID
        self.metadata = metadata
        self.mimeType = mimeType
        self.totalSize = totalSize
    }
}

public struct ResumableUploadSession: Sendable, Equatable, Codable {
    public var uri: String
    public var committedOffset: Int64

    public init(uri: String, committedOffset: Int64) {
        self.uri = uri
        self.committedOffset = committedOffset
    }
}

public struct DriveUploadChunk: Sendable, Equatable {
    public var offset: Int64
    public var bytes: Data
    public var isLast: Bool

    public init(offset: Int64, bytes: Data, isLast: Bool) {
        self.offset = offset
        self.bytes = bytes
        self.isLast = isLast
    }
}

public struct ResumableUploadProgress: Sendable, Equatable {
    public var committedOffset: Int64
    public var completedFile: DriveFile?
    public var indeterminate: Bool

    public init(committedOffset: Int64, completedFile: DriveFile?, indeterminate: Bool) {
        self.committedOffset = committedOffset
        self.completedFile = completedFile
        self.indeterminate = indeterminate
    }
}

public protocol DriveBackend: Sendable {
    func listFiles(query: String?, pageToken: String?, pageSize: Int?) async throws -> DriveFilePage
    func getFile(id: DriveID) async throws -> DriveFile
    func createFile(metadata: DriveFileCreate) async throws -> DriveFile
    func updateFile(id: DriveID, metadata: DriveFileUpdate) async throws -> DriveFile
    func deleteFile(id: DriveID) async throws
    func exportFile(id: DriveID, mimeType: String) async throws -> Data
    func downloadContent(id: DriveID, range: ByteRange?) async throws -> DriveContent
    func multipartUpload(_ intent: MultipartUploadIntent) async throws -> DriveFile
    func startResumableUpload(_ intent: ResumableUploadIntent) async throws -> ResumableUploadSession
    func resumeUpload(session: ResumableUploadSession, chunk: DriveUploadChunk) async throws -> ResumableUploadProgress
    func startPageToken() async throws -> String
    func listChanges(pageToken: String, pageSize: Int?) async throws -> DriveChangePage
    func about() async throws -> DriveAbout
    func refreshCredential() async throws
}
