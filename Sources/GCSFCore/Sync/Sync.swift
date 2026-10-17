import Foundation

public enum ChangeFeedError: Error, Equatable, Sendable {
    case rejectedPageToken
    case missingParent(DriveID)
    case missingCursor
}

public actor ChangeFeed {
    private static let pageSize = 100
    private static let trashInode = Inode(rawValue: 2)

    private let metadata: any MetadataStore
    private let backend: any DriveBackend
    private let kernel: any KernelCachePort
    private let checkpointURL: URL
    private let allocateInode: @Sendable () async throws -> Inode

    public init(
        metadata: any MetadataStore,
        backend: any DriveBackend,
        kernel: any KernelCachePort,
        checkpointURL: URL,
        allocateInode: @escaping @Sendable () async throws -> Inode
    ) {
        self.metadata = metadata
        self.backend = backend
        self.kernel = kernel
        self.checkpointURL = checkpointURL
        self.allocateInode = allocateInode
    }

    public func checkpoint() throws -> String? {
        guard FileManager.default.fileExists(atPath: checkpointURL.path) else {
            return nil
        }
        let text = try String(contentsOf: checkpointURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    public func synchronize() async throws {
        try Task.checkCancellation()
        var token = try checkpoint()
        var refreshed = false
        if token == nil {
            token = try await backend.startPageToken()
        }
        while true {
            try Task.checkCancellation()
            let page: DriveChangePage
            do {
                page = try await backend.listChanges(pageToken: token ?? "", pageSize: Self.pageSize)
            } catch {
                if !refreshed, isRejectedPageToken(error) {
                    token = try await backend.startPageToken()
                    refreshed = true
                    continue
                }
                throw error
            }
            try await apply(page)
            guard let next = page.nextPageToken ?? page.newStartPageToken else {
                throw ChangeFeedError.missingCursor
            }
            try saveCheckpoint(next)
            guard let nextPage = page.nextPageToken else {
                return
            }
            token = nextPage
        }
    }

    private func apply(_ page: DriveChangePage) async throws {
        for change in page.changes {
            try Task.checkCancellation()
            try await apply(change)
        }
    }

    private func apply(_ change: DriveChange) async throws {
        if change.removed {
            try await remove(change.fileID)
            return
        }
        guard let file = change.file else {
            return
        }
        if let row = try await metadata.record(driveID: change.fileID) {
            if isDirty(row) {
                try await applyDirty(row, file)
            } else {
                try await applyClean(row, file)
            }
            return
        }
        try await insert(file, id: change.fileID)
    }

    private func applyClean(_ row: MetadataRecord, _ file: DriveFile) async throws {
        var updated = row
        updated.name = file.name
        updated.mimeType = file.mimeType
        if let size = file.size {
            updated.size = size
        }
        if let created = file.created {
            updated.created = created
        }
        if let modified = file.modified {
            updated.modified = modified
        }
        updated.headRevision = file.headRevision
        updated.md5 = file.md5
        updated.sha1 = file.sha1
        updated.sha256 = file.sha256
        updated.owner = file.owner
        updated.webLink = file.webViewLink
        updated.trashed = file.trashed
        if let parent = try await parentInode(of: file) {
            updated.parent = parent
        }
        if file.trashed, let trash = try await trashInode() {
            updated.parent = trash
        }
        let contentChanged = updated.size != row.size
            || updated.headRevision != row.headRevision
            || updated.md5 != row.md5
            || updated.sha1 != row.sha1
            || updated.sha256 != row.sha256
        if contentChanged {
            await kernel.invalidateCachedItem(row.inode)
        }
        if updated != row {
            try await metadata.update(updated)
        }
    }

    private func applyDirty(_ row: MetadataRecord, _ file: DriveFile) async throws {
        var updated = row
        updated.name = file.name
        updated.trashed = file.trashed
        if let parent = try await parentInode(of: file) {
            updated.parent = parent
        }
        if file.trashed, let trash = try await trashInode() {
            updated.parent = trash
        }
        if updated != row {
            try await metadata.update(updated)
        }
    }

    private func insert(_ file: DriveFile, id: DriveID) async throws {
        let inode = try await allocateInode()
        var parent = try await parentInode(of: file)
        if file.trashed, let trash = try await trashInode() {
            parent = trash
        }
        let record = MetadataRecord(
            inode: inode,
            driveID: id,
            parent: parent,
            name: file.name,
            assignedDuplicateSuffix: nil,
            mimeType: file.mimeType,
            size: file.size ?? 0,
            created: file.created,
            modified: file.modified,
            headRevision: file.headRevision,
            md5: file.md5,
            sha1: file.sha1,
            sha256: file.sha256,
            owner: file.owner,
            webLink: file.webViewLink,
            durability: .committed,
            trashed: file.trashed
        )
        try await metadata.insert(record)
    }

    private func remove(_ id: DriveID) async throws {
        guard let row = try await metadata.record(driveID: id) else {
            return
        }
        if isDirty(row) {
            return
        }
        await kernel.revokeCachedItem(row.inode)
        try await metadata.remove(inode: row.inode)
    }

    private func parentInode(of file: DriveFile) async throws -> Inode? {
        guard let parentID = file.parents.first else {
            return nil
        }
        guard let parent = try await metadata.record(driveID: parentID) else {
            throw ChangeFeedError.missingParent(parentID)
        }
        return parent.inode
    }

    private func trashInode() async throws -> Inode? {
        guard let trash = try await metadata.record(inode: Self.trashInode), trash.name == "Trash" else {
            return nil
        }
        return trash.inode
    }

    private func isDirty(_ row: MetadataRecord) -> Bool {
        switch row.durability {
        case .staged, .journaled, .conflicted:
            return true
        case .committed:
            return false
        }
    }

    private func isRejectedPageToken(_ error: Error) -> Bool {
        if let feed = error as? ChangeFeedError, feed == .rejectedPageToken {
            return true
        }
        if let drive = error as? DriveClientError, drive == .notFound {
            return true
        }
        return false
    }

    private func saveCheckpoint(_ token: String) throws {
        try FileManager.default.createDirectory(
            at: checkpointURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(token.utf8).write(to: checkpointURL, options: .atomic)
    }
}
