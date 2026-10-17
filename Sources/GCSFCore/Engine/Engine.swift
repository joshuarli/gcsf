import Darwin
import Foundation

public struct EngineConfiguration: Sendable, Equatable {
    public let renameIdenticalFiles: Bool
    public let addExtensionsToSpecialFiles: Bool
    public let readOnly: Bool
    public let skipTrash: Bool

    public init(
        renameIdenticalFiles: Bool,
        addExtensionsToSpecialFiles: Bool,
        readOnly: Bool,
        skipTrash: Bool
    ) {
        self.renameIdenticalFiles = renameIdenticalFiles
        self.addExtensionsToSpecialFiles = addExtensionsToSpecialFiles
        self.readOnly = readOnly
        self.skipTrash = skipTrash
    }
}

public struct EngineIncoming: Sendable, Equatable {
    public var driveID: DriveID?
    public var name: String
    public var mimeType: String
    public var size: Int64
    public var created: Date?
    public var modified: Date?
    public var headRevision: String?
    public var md5: String?
    public var sha1: String?
    public var sha256: String?
    public var owner: String?
    public var webLink: String?
    public var trashed: Bool

    public init(
        driveID: DriveID?,
        name: String,
        mimeType: String,
        size: Int64,
        created: Date?,
        modified: Date?,
        headRevision: String?,
        md5: String?,
        sha1: String?,
        sha256: String?,
        owner: String?,
        webLink: String?,
        trashed: Bool
    ) {
        self.driveID = driveID
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.created = created
        self.modified = modified
        self.headRevision = headRevision
        self.md5 = md5
        self.sha1 = sha1
        self.sha256 = sha256
        self.owner = owner
        self.webLink = webLink
        self.trashed = trashed
    }

    public init(driveFile: DriveFile) {
        self.init(
            driveID: driveFile.id,
            name: driveFile.name,
            mimeType: driveFile.mimeType,
            size: driveFile.size ?? 0,
            created: driveFile.created,
            modified: driveFile.modified,
            headRevision: driveFile.headRevision,
            md5: driveFile.md5,
            sha1: driveFile.sha1,
            sha256: driveFile.sha256,
            owner: driveFile.owner,
            webLink: driveFile.webViewLink,
            trashed: driveFile.trashed
        )
    }
}

public enum EngineError: Error, Equatable, Sendable {
    case posix(Int32)
    case unknownXattr(String)
}

public actor GCSFEngine: FileSystemEngine {
    static let folderMIME = "application/vnd.google-apps.folder"
    static let symlinkMIME = "inode/symlink"
    static let fileMIME = "application/octet-stream"
    static let root = Inode(rawValue: 1)
    static let trash = Inode(rawValue: 2)
    static let shared = Inode(rawValue: 3)
    private static let driveXattrs = [
        "user.gcsf.id",
        "user.gcsf.mime_type",
        "user.gcsf.owner",
        "user.gcsf.web_link",
        "user.gcsf.md5",
        "user.gcsf.sha1",
        "user.gcsf.sha256",
        "user.gcsf.revision",
    ]
    private static let exportExtensions = [
        "application/vnd.google-apps.document": "#.odt",
        "application/vnd.google-apps.presentation": "#.odp",
        "application/vnd.google-apps.spreadsheet": "#.xlsx",
        "application/vnd.google-apps.drawing": "#.png",
        "application/vnd.google-apps.site": "#.txt",
    ]
    private static let exportMIMEs = [
        "application/vnd.google-apps.document": "application/vnd.oasis.opendocument.text",
        "application/vnd.google-apps.presentation": "application/vnd.oasis.opendocument.presentation",
        "application/vnd.google-apps.spreadsheet":
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.google-apps.drawing": "image/png",
        "application/vnd.google-apps.site": "text/plain",
    ]

    private let store: SQLiteMetadataStore
    private let drive: any DriveBackend
    private let configuration: EngineConfiguration
    private let journal: SQLiteWritebackJournal?
    private let stagedDirectory: URL?
    private var contents: [UInt64: Data] = [:]
    private var symlinkTargets: [UInt64: String] = [:]

    public init(
        store: SQLiteMetadataStore,
        drive: any DriveBackend,
        configuration: EngineConfiguration,
        journal: SQLiteWritebackJournal? = nil,
        stagedDirectory: URL? = nil
    ) {
        self.store = store
        self.drive = drive
        self.configuration = configuration
        self.journal = journal
        self.stagedDirectory = stagedDirectory
    }

    public func lookup(named name: String, in parent: Inode) async throws -> EngineItem {
        _ = try await directory(parent)
        let children = try await store.children(of: parent)
        guard let match = children.first(where: { displayName($0) == name }) else {
            throw EngineError.posix(ENOENT)
        }
        return item(match)
    }

    public func attributes(_ inode: Inode) async throws -> EngineAttributes {
        let record = try await record(inode)
        let itemKind = kind(of: record)
        return EngineAttributes(
            inode: record.inode,
            kind: itemKind,
            size: record.size,
            linkCount: itemKind == .directory ? 2 : 1,
            created: record.created,
            modified: record.modified,
            mimeType: record.mimeType
        )
    }

    public func xattr(named name: String, of inode: Inode) async throws -> Data {
        let record = try await record(inode)
        guard let value = xattrString(record, name) else {
            throw EngineError.unknownXattr(name)
        }
        return Data(value.utf8)
    }

    public func setXattr(named name: String, value _: Data?, of inode: Inode) async throws {
        _ = try await record(inode)
        if name.hasPrefix("user.gcsf.") {
            throw EngineError.posix(EPERM)
        }
        throw EngineError.posix(ENOTSUP)
    }

    public func xattrNames(of inode: Inode) async throws -> [String] {
        let record = try await record(inode)
        return Self.driveXattrs.filter { xattrString(record, $0) != nil }
    }

    public func enumerate(directory: Inode, startingAt cookie: EngineDirectoryCookie) async throws -> EngineEnumeration {
        _ = try await self.directory(directory)
        let children = try await store.children(of: directory)
        let verifier = directoryVerifier(children)
        let start = try resumeIndex(cookie, verifier: verifier, count: children.count)
        let entries = children.enumerated().compactMap { offset, child -> EngineDirectoryEntry? in
            guard offset >= start else {
                return nil
            }
            return EngineDirectoryEntry(
                name: displayName(child),
                item: item(child),
                cookie: packCookie(verifier: verifier, index: offset + 1)
            )
        }
        return EngineEnumeration(entries: entries, verifier: verifier, nextCookie: nil)
    }

    public func create(named name: String, kind: EngineItemKind, in parent: Inode) async throws -> EngineItem {
        try await make(named: name, kind: kind, in: parent, symlinkTarget: kind == .symlink ? "" : nil)
    }

    public func createSymlink(named name: String, target: String, in parent: Inode) async throws -> EngineItem {
        try await make(named: name, kind: .symlink, in: parent, symlinkTarget: target)
    }

    public func incorporate(_ files: [EngineIncoming], under parent: Inode) async throws -> [EngineItem] {
        try rejectWrites()
        _ = try await directory(parent)
        let suffixes = try await plan(files, in: parent)
        var items: [EngineItem] = []
        for (file, suffix) in zip(files, suffixes) {
            let inode = try await store.allocateInode()
            let record = metadata(file, inode: inode, parent: parent, suffix: suffix, durability: .committed)
            try await store.insert(record)
            items.append(item(record))
        }
        return items
    }

    public func rename(
        _ inode: Inode,
        fromParent: Inode,
        fromName: String,
        toParent: Inode,
        toName: String,
        replacing: Inode?
    ) async throws -> EngineItem {
        try rejectWrites()
        try validateName(toName)
        var source = try await record(inode)
        guard source.parent == fromParent, displayName(source) == fromName else {
            throw EngineError.posix(ENOENT)
        }
        if isReserved(inode) {
            throw EngineError.posix(EPERM)
        }
        let sourceKind = kind(of: source)
        if sourceKind == .directory {
            if toParent == inode {
                throw EngineError.posix(EINVAL)
            }
            if try await isInside(toParent, ancestor: inode) {
                throw EngineError.posix(EINVAL)
            }
        }
        let parentRecord = try await directory(toParent)
        if fromParent == toParent, fromName == toName, replacing == nil || replacing == inode {
            return item(source)
        }
        let destination = try await store.children(of: toParent)
        let occupant = destination.first { $0.inode != inode && displayName($0) == toName }
        if let occupant {
            guard let replacing, replacing == occupant.inode else {
                throw EngineError.posix(EEXIST)
            }
            if isReserved(occupant.inode) {
                throw EngineError.posix(EPERM)
            }
            try validateReplacement(source: sourceKind, destination: occupant)
            if kind(of: occupant) == .directory {
                let nested = try await store.children(of: occupant.inode)
                if !nested.isEmpty {
                    throw EngineError.posix(ENOTEMPTY)
                }
            }
        } else if let replacing, replacing != inode, destination.contains(where: { $0.inode == replacing }) {
            throw EngineError.posix(EEXIST)
        }
        if let driveID = source.driveID {
            _ = try await drive.updateFile(
                id: driveID,
                metadata: DriveFileUpdate(
                    name: toName,
                    mimeType: nil,
                    parents: fromParent == toParent ? nil : parentRecord.driveID.map { [$0] },
                    trashed: trashFlag(from: fromParent, to: toParent, record: source)
                )
            )
        }
        if let occupant {
            if let driveID = occupant.driveID {
                try await drive.deleteFile(id: driveID)
            }
            try await store.remove(inode: occupant.inode)
            contents[occupant.inode.rawValue] = nil
            symlinkTargets[occupant.inode.rawValue] = nil
        }
        source.name = toName
        source.parent = toParent
        source.assignedDuplicateSuffix = nil
        if toParent == Self.trash {
            source.trashed = true
        } else if fromParent == Self.trash {
            source.trashed = false
        }
        try await store.update(source)
        return item(source)
    }

    public func remove(_ inode: Inode, named name: String, from parent: Inode) async throws {
        try await remove(inode, named: name, from: parent, directory: false)
    }

    public func rmdir(_ inode: Inode, named name: String, from parent: Inode) async throws {
        try await remove(inode, named: name, from: parent, directory: true)
    }

    public func readlink(_ inode: Inode) async throws -> String {
        let record = try await record(inode)
        guard kind(of: record) == .symlink else {
            throw EngineError.posix(EINVAL)
        }
        guard let target = symlinkTargets[inode.rawValue] else {
            throw EngineError.posix(EIO)
        }
        return target
    }

    public func read(_ inode: Inode, at offset: Int64, length: Int) async throws -> Data {
        if offset < 0 || length < 0 {
            throw EngineError.posix(EINVAL)
        }
        let record = try await record(inode)
        let itemKind = kind(of: record)
        if itemKind == .directory {
            throw EngineError.posix(EISDIR)
        }
        if itemKind == .symlink {
            throw EngineError.posix(EINVAL)
        }
        if length == 0 {
            return Data()
        }
        if let journal, record.durability == .journaled || record.durability == .conflicted {
            return try await readJournaled(journal, record: record, offset: offset, length: length)
        }
        if let stored = contents[inode.rawValue] {
            return slice(stored, offset: offset, length: length, size: record.size)
        }
        if isGoogleNative(record.mimeType) {
            let exported = try await exportedBytes(record)
            let size = record.size > 0 ? record.size : Int64(exported.count)
            return slice(exported, offset: offset, length: length, size: size)
        }
        guard offset < record.size else {
            return Data()
        }
        guard let driveID = record.driveID else {
            throw EngineError.posix(EIO)
        }
        let remaining = record.size - offset
        let wanted = min(Int64(length), remaining)
        guard wanted <= Int64(Int.max) else {
            throw EngineError.posix(EOVERFLOW)
        }
        let downloaded = try await drive.downloadContent(
            id: driveID,
            range: ByteRange(offset: offset, length: Int(wanted))
        )
        var bytes = sliceContent(downloaded, offset: offset, length: Int(wanted), size: record.size)
        if Int64(bytes.count) < wanted {
            bytes.append(Data(count: Int(wanted) - bytes.count))
        }
        return bytes
    }

    public func write(_ inode: Inode, bytes: Data, at offset: Int64) async throws -> Int {
        try rejectWrites()
        if offset < 0 {
            throw EngineError.posix(EINVAL)
        }
        guard offset <= Int64.max - Int64(bytes.count) else {
            throw EngineError.posix(EOVERFLOW)
        }
        let record = try await mutableFile(inode)
        if let journal {
            try await journalWrite(journal, record: record, bytes: bytes, offset: offset)
            return bytes.count
        }
        var data = try await mutableContent(record)
        let start = Int(offset)
        let end = start + bytes.count
        if start > data.count {
            data.append(Data(count: start - data.count))
        }
        if end > data.count {
            data.append(Data(count: end - data.count))
        }
        if !bytes.isEmpty {
            data.replaceSubrange(start..<end, with: bytes)
        }
        try await storeContent(data, on: record)
        return bytes.count
    }

    public func truncate(_ inode: Inode, to length: Int64) async throws {
        try rejectWrites()
        if length < 0 {
            throw EngineError.posix(EINVAL)
        }
        if journal == nil {
            guard length <= Int64(Int.max) else {
                throw EngineError.posix(EOVERFLOW)
            }
        }
        let record = try await mutableFile(inode)
        if let journal {
            try await journalTruncate(journal, record: record, length: length)
            return
        }
        if var data = contents[inode.rawValue] {
            let target = Int(length)
            if data.count > target {
                data.removeSubrange(target..<data.count)
            } else if data.count < target {
                data.append(Data(count: target - data.count))
            }
            try await storeContent(data, on: record)
            return
        }
        var updated = record
        updated.size = length
        try await store.update(updated)
    }

    public func synchronize() async throws {
        if let journal {
            do {
                try await journal.synchronize()
            } catch let error as POSIXError {
                throw EngineError.posix(error.code.rawValue)
            }
            return
        }
        var pending = [Self.root]
        var seen: Set<UInt64> = []
        while let inode = pending.popLast() {
            guard seen.insert(inode.rawValue).inserted else {
                continue
            }
            guard let record = try await store.record(inode: inode) else {
                continue
            }
            if record.durability != .committed {
                throw EngineError.posix(EBUSY)
            }
            if kind(of: record) == .directory {
                let children = try await store.children(of: inode)
                pending.append(contentsOf: children.map(\.inode))
            }
        }
    }

    private func make(
        named name: String,
        kind: EngineItemKind,
        in parent: Inode,
        symlinkTarget: String?
    ) async throws -> EngineItem {
        try rejectWrites()
        let parentRecord = try await directory(parent)
        let mime = mimeType(kind)
        let incoming = EngineIncoming(
            driveID: nil,
            name: name,
            mimeType: mime,
            size: 0,
            created: nil,
            modified: nil,
            headRevision: nil,
            md5: nil,
            sha1: nil,
            sha256: nil,
            owner: nil,
            webLink: nil,
            trashed: false
        )
        let suffix = try await plan([incoming], in: parent)[0]
        let created: DriveFile?
        if kind == .symlink {
            created = nil
        } else {
            guard let parentDriveID = parentRecord.driveID else {
                throw EngineError.posix(EIO)
            }
            created = try await drive.createFile(
                metadata: DriveFileCreate(name: name, mimeType: mime, parents: [parentDriveID])
            )
        }
        do {
            let inode = try await store.allocateInode()
            var file = incoming
            file.driveID = created?.id
            file.created = created?.created
            file.modified = created?.modified
            file.headRevision = created?.headRevision
            file.md5 = created?.md5
            file.sha1 = created?.sha1
            file.sha256 = created?.sha256
            file.owner = created?.owner
            file.webLink = created?.webViewLink
            file.size = created?.size ?? 0
            let record = metadata(file, inode: inode, parent: parent, suffix: suffix, durability: .committed)
            try await store.insert(record)
            if let symlinkTarget {
                symlinkTargets[inode.rawValue] = symlinkTarget
            }
            return item(record)
        } catch {
            if let created {
                _ = try? await drive.deleteFile(id: created.id)
            }
            throw error
        }
    }

    private func remove(_ inode: Inode, named name: String, from parent: Inode, directory: Bool) async throws {
        try rejectWrites()
        let record = try await record(inode)
        guard record.parent == parent, displayName(record) == name else {
            throw EngineError.posix(ENOENT)
        }
        let itemKind = kind(of: record)
        if directory {
            guard itemKind == .directory else {
                throw EngineError.posix(ENOTDIR)
            }
            let children = try await store.children(of: inode)
            if !children.isEmpty {
                throw EngineError.posix(ENOTEMPTY)
            }
        } else if itemKind == .directory {
            throw EngineError.posix(EISDIR)
        }
        if isReserved(inode) {
            throw EngineError.posix(EPERM)
        }
        if configuration.skipTrash {
            if let driveID = record.driveID {
                try await drive.deleteFile(id: driveID)
            }
            try await store.remove(inode: inode)
        } else {
            let trashed = try await trashedRecord(record)
            if let driveID = record.driveID {
                _ = try await drive.updateFile(
                    id: driveID,
                    metadata: DriveFileUpdate(name: nil, mimeType: nil, parents: nil, trashed: true)
                )
            }
            try await store.update(trashed)
        }
        contents[inode.rawValue] = nil
        symlinkTargets[inode.rawValue] = nil
    }

    private func trashedRecord(_ record: MetadataRecord) async throws -> MetadataRecord {
        var moved = record
        moved.parent = Self.trash
        moved.trashed = true
        let base = EngineIncoming(
            driveID: nil,
            name: record.name,
            mimeType: record.mimeType,
            size: record.size,
            created: record.created,
            modified: record.modified,
            headRevision: record.headRevision,
            md5: record.md5,
            sha1: record.sha1,
            sha256: record.sha256,
            owner: record.owner,
            webLink: record.webLink,
            trashed: true
        )
        let siblings = try await store.children(of: Self.trash).filter { $0.inode != record.inode }
        if configuration.renameIdenticalFiles {
            var taken = Set(siblings.map { displayName($0) })
            let suffixes = try assignSuffixes(
                existing: siblings.filter { $0.name == record.name },
                incoming: [base],
                takenDisplays: &taken
            )
            moved.assignedDuplicateSuffix = suffixes[0]
        } else {
            moved.assignedDuplicateSuffix = nil
        }
        return moved
    }

    private func plan(_ files: [EngineIncoming], in parent: Inode) async throws -> [String?] {
        for file in files {
            try validateName(file.name)
        }
        let children = try await store.children(of: parent)
        var taken = Set(children.map { displayName($0) })
        var assigned = [String?](repeating: nil, count: files.count)
        var order: [String] = []
        var grouped: [String: [Int]] = [:]
        for (index, file) in files.enumerated() {
            if grouped[file.name] == nil {
                order.append(file.name)
            }
            grouped[file.name, default: []].append(index)
        }
        for name in order {
            let indices = grouped[name] ?? []
            let incoming = indices.map { files[$0] }
            let existing = children.filter { $0.name == name }
            let suffixes = try assignSuffixes(existing: existing, incoming: incoming, takenDisplays: &taken)
            for (offset, index) in indices.enumerated() {
                assigned[index] = suffixes[offset]
            }
        }
        return assigned
    }

    private func assignSuffixes(
        existing: [MetadataRecord],
        incoming: [EngineIncoming],
        takenDisplays: inout Set<String>
    ) throws -> [String?] {
        if incoming.isEmpty {
            return []
        }
        if !configuration.renameIdenticalFiles {
            if !existing.isEmpty || incoming.count > 1 {
                throw EngineError.posix(EEXIST)
            }
            let display = displayName(base: incoming[0].name, mime: incoming[0].mimeType, suffix: nil)
            if takenDisplays.contains(display) {
                throw EngineError.posix(EEXIST)
            }
            takenDisplays.insert(display)
            return [nil]
        }
        let sorted = incoming.indices.sorted { lhs, rhs in
            driveIDPrecedes(incoming[lhs].driveID, incoming[rhs].driveID)
        }
        var next = (existing.compactMap { suffixNumber($0.assignedDuplicateSuffix) }.max() ?? 0) + 1
        var bareAvailable = existing.isEmpty
        var assigned = [String?](repeating: nil, count: incoming.count)
        for index in sorted {
            let file = incoming[index]
            var suffix: String?
            if bareAvailable {
                bareAvailable = false
            } else {
                suffix = String(next)
                next += 1
            }
            var display = displayName(base: file.name, mime: file.mimeType, suffix: suffix)
            while takenDisplays.contains(display) {
                suffix = String(next)
                next += 1
                display = displayName(base: file.name, mime: file.mimeType, suffix: suffix)
            }
            takenDisplays.insert(display)
            assigned[index] = suffix
        }
        return assigned
    }

    private func mutableFile(_ inode: Inode) async throws -> MetadataRecord {
        let record = try await record(inode)
        let itemKind = kind(of: record)
        if itemKind == .directory {
            throw EngineError.posix(EISDIR)
        }
        if itemKind == .symlink {
            throw EngineError.posix(EINVAL)
        }
        if isGoogleNative(record.mimeType) {
            throw EngineError.posix(EROFS)
        }
        return record
    }

    private func mutableContent(_ record: MetadataRecord) async throws -> Data {
        if let stored = contents[record.inode.rawValue] {
            return stored
        }
        guard record.size > 0 else {
            return Data()
        }
        guard record.size <= Int64(Int.max) else {
            throw EngineError.posix(EOVERFLOW)
        }
        guard let driveID = record.driveID else {
            return Data(count: Int(record.size))
        }
        let downloaded = try await drive.downloadContent(
            id: driveID,
            range: ByteRange(offset: 0, length: Int(record.size))
        )
        var data = downloaded.bytes
        let target = Int(record.size)
        if data.count > target {
            data = Data(data.prefix(target))
        } else if data.count < target {
            data.append(Data(count: target - data.count))
        }
        return data
    }

    private func journalWrite(
        _ journal: SQLiteWritebackJournal,
        record: MetadataRecord,
        bytes: Data,
        offset: Int64
    ) async throws {
        let path = stagedName(record.inode)
        let id = journalID(record.inode)
        let existed = try await journal.record(id: id) != nil
        if !existed {
            try await journal.truncateStaged(relativePath: path, to: 0)
            let covers = offset == 0 && Int64(bytes.count) >= record.size
            if !covers {
                try await seed(journal, record: record, path: path)
            }
        }
        if bytes.isEmpty {
            let size = try stagedSize(path)
            if offset > size {
                try await journal.truncateStaged(relativePath: path, to: offset)
            }
        } else {
            try await journal.writeStaged(relativePath: path, at: offset, bytes: bytes)
        }
        let size = try stagedSize(path)
        try await commitJournal(journal, record: record, id: id, path: path, size: size, existed: existed)
    }

    private func journalTruncate(
        _ journal: SQLiteWritebackJournal,
        record: MetadataRecord,
        length: Int64
    ) async throws {
        let path = stagedName(record.inode)
        let id = journalID(record.inode)
        let existed = try await journal.record(id: id) != nil
        if !existed {
            try await journal.truncateStaged(relativePath: path, to: 0)
            if length > 0, record.size > 0 {
                try await seed(journal, record: record, path: path)
            }
        }
        try await journal.truncateStaged(relativePath: path, to: length)
        try await commitJournal(journal, record: record, id: id, path: path, size: length, existed: existed)
    }

    private func seed(_ journal: SQLiteWritebackJournal, record: MetadataRecord, path: String) async throws {
        let size = record.size
        if size <= 0 {
            return
        }
        var offset: Int64 = 0
        let chunk = 65_536
        while offset < size {
            let length = Int(min(Int64(chunk), size - offset))
            let bytes = try await seedChunk(record, offset: offset, length: length)
            guard bytes.count == length else {
                throw EngineError.posix(EIO)
            }
            try await journal.writeStaged(relativePath: path, at: offset, bytes: bytes)
            offset += Int64(length)
        }
    }

    private func seedChunk(_ record: MetadataRecord, offset: Int64, length: Int) async throws -> Data {
        guard let driveID = record.driveID else {
            return Data(count: length)
        }
        let downloaded = try await drive.downloadContent(
            id: driveID,
            range: ByteRange(offset: offset, length: length)
        )
        var bytes = sliceContent(downloaded, offset: offset, length: length, size: record.size)
        if bytes.count < length {
            bytes.append(Data(count: length - bytes.count))
        }
        return bytes
    }

    private func commitJournal(
        _ journal: SQLiteWritebackJournal,
        record: MetadataRecord,
        id: JournalID,
        path: String,
        size: Int64,
        existed: Bool
    ) async throws {
        if existed {
            try await journal.setState(id: id, state: .journaled)
        } else {
            try await journal.insert(
                JournalRecord(
                    id: id,
                    inode: record.inode,
                    driveID: record.driveID,
                    state: .journaled,
                    headRevision: record.headRevision,
                    stagedRelativePath: path,
                    uploadSessionURI: nil
                )
            )
        }
        var updated = record
        updated.size = size
        updated.durability = .journaled
        try await store.update(updated)
    }

    private func readJournaled(
        _ journal: SQLiteWritebackJournal,
        record: MetadataRecord,
        offset: Int64,
        length: Int
    ) async throws -> Data {
        guard let stagedDirectory else {
            throw EngineError.posix(EIO)
        }
        guard let row = try await journal.record(id: journalID(record.inode)) else {
            throw EngineError.posix(EIO)
        }
        guard offset < record.size else {
            return Data()
        }
        let end = min(record.size, offset + Int64(length))
        let wanted = end - offset
        guard wanted <= Int64(Int.max) else {
            throw EngineError.posix(EOVERFLOW)
        }
        let url = stagedDirectory.appending(path: row.stagedRelativePath)
        do {
            let handle = try FileHandle(forReadingFrom: url)
            do {
                try handle.seek(toOffset: UInt64(offset))
                var data = try handle.read(upToCount: Int(wanted)) ?? Data()
                try handle.close()
                if data.count < Int(wanted) {
                    data.append(Data(count: Int(wanted) - data.count))
                }
                return data
            } catch {
                try? handle.close()
                throw error
            }
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.posix(EIO)
        }
    }

    private func stagedSize(_ path: String) throws -> Int64 {
        guard let stagedDirectory else {
            throw EngineError.posix(EIO)
        }
        let url = stagedDirectory.appending(path: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return 0
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else {
            throw EngineError.posix(EIO)
        }
        return Int64(size)
    }

    private func journalID(_ inode: Inode) -> JournalID {
        JournalID(rawValue: String(inode.rawValue))
    }

    private func stagedName(_ inode: Inode) -> String {
        String(inode.rawValue)
    }

    private func storeContent(_ data: Data, on record: MetadataRecord) async throws {
        let previous = contents[record.inode.rawValue]
        contents[record.inode.rawValue] = data
        var updated = record
        updated.size = Int64(data.count)
        do {
            try await store.update(updated)
        } catch {
            contents[record.inode.rawValue] = previous
            throw error
        }
    }

    private func exportedBytes(_ record: MetadataRecord) async throws -> Data {
        if let mime = Self.exportMIMEs[record.mimeType] {
            guard let driveID = record.driveID else {
                throw EngineError.posix(EIO)
            }
            return try await drive.exportFile(id: driveID, mimeType: mime)
        }
        let reason = "its MIME type is \"\(record.mimeType)\", which Drive cannot export"
        let link = record.webLink ?? "<unavailable>"
        let text = "UNEXPORTABLE_FILE: This file could not be retrieved because \(reason). It can be opened at: \(link)\n"
        return Data(text.utf8)
    }

    private func metadata(
        _ file: EngineIncoming,
        inode: Inode,
        parent: Inode,
        suffix: String?,
        durability: DurabilityState
    ) -> MetadataRecord {
        MetadataRecord(
            inode: inode,
            driveID: file.driveID,
            parent: parent,
            name: file.name,
            assignedDuplicateSuffix: suffix,
            mimeType: file.mimeType,
            size: file.size,
            created: file.created,
            modified: file.modified,
            headRevision: file.headRevision,
            md5: file.md5,
            sha1: file.sha1,
            sha256: file.sha256,
            owner: file.owner,
            webLink: file.webLink,
            durability: durability,
            trashed: file.trashed
        )
    }

    private func record(_ inode: Inode) async throws -> MetadataRecord {
        guard let record = try await store.record(inode: inode) else {
            throw EngineError.posix(ENOENT)
        }
        return record
    }

    private func directory(_ inode: Inode) async throws -> MetadataRecord {
        let record = try await record(inode)
        guard kind(of: record) == .directory else {
            throw EngineError.posix(ENOTDIR)
        }
        return record
    }

    private func item(_ record: MetadataRecord) -> EngineItem {
        EngineItem(inode: record.inode, name: displayName(record), kind: kind(of: record))
    }

    private func displayName(_ record: MetadataRecord) -> String {
        displayName(base: record.name, mime: record.mimeType, suffix: record.assignedDuplicateSuffix)
    }

    private func displayName(base: String, mime: String, suffix: String?) -> String {
        var name = base
        if configuration.addExtensionsToSpecialFiles, let ext = Self.exportExtensions[mime] {
            name.append(ext)
        }
        if let suffix {
            name.append(".")
            name.append(suffix)
        }
        return name
    }

    private func kind(of record: MetadataRecord) -> EngineItemKind {
        if record.mimeType == Self.folderMIME {
            return .directory
        }
        if record.mimeType == Self.symlinkMIME {
            return .symlink
        }
        return .file
    }

    private func mimeType(_ kind: EngineItemKind) -> String {
        switch kind {
        case .directory:
            Self.folderMIME
        case .symlink:
            Self.symlinkMIME
        case .file:
            Self.fileMIME
        }
    }

    private func isGoogleNative(_ mime: String) -> Bool {
        mime.hasPrefix("application/vnd.google-apps.") && mime != Self.folderMIME
    }

    private func isReserved(_ inode: Inode) -> Bool {
        inode == Self.root || inode == Self.trash || inode == Self.shared
    }

    private func rejectWrites() throws {
        if configuration.readOnly {
            throw EngineError.posix(EROFS)
        }
    }

    private func validateName(_ name: String) throws {
        if name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains("\0") {
            throw EngineError.posix(EINVAL)
        }
    }

    private func validateReplacement(source: EngineItemKind, destination: MetadataRecord) throws {
        let destKind = kind(of: destination)
        if source == .directory, destKind != .directory {
            throw EngineError.posix(ENOTDIR)
        }
        if source != .directory, destKind == .directory {
            throw EngineError.posix(EISDIR)
        }
    }

    private func trashFlag(from: Inode, to: Inode, record: MetadataRecord) -> Bool? {
        if to == Self.trash {
            return true
        }
        if from == Self.trash || record.trashed {
            return false
        }
        return nil
    }

    private func isInside(_ inode: Inode, ancestor: Inode) async throws -> Bool {
        var current: Inode? = inode
        var steps = 0
        while let cursor = current {
            if cursor == ancestor {
                return true
            }
            guard let record = try await store.record(inode: cursor) else {
                return false
            }
            current = record.parent
            steps += 1
            if steps > 1_000_000 {
                throw EngineError.posix(ELOOP)
            }
        }
        return false
    }

    private func xattrString(_ record: MetadataRecord, _ name: String) -> String? {
        switch name {
        case "user.gcsf.id":
            record.driveID?.rawValue
        case "user.gcsf.mime_type":
            record.mimeType
        case "user.gcsf.owner":
            record.owner
        case "user.gcsf.web_link":
            record.webLink
        case "user.gcsf.md5":
            record.md5
        case "user.gcsf.sha1":
            record.sha1
        case "user.gcsf.sha256":
            record.sha256
        case "user.gcsf.revision":
            record.headRevision
        default:
            nil
        }
    }

    private func suffixNumber(_ suffix: String?) -> Int? {
        guard let suffix, let value = Int(suffix), value > 0, String(value) == suffix else {
            return nil
        }
        return value
    }

    private func driveIDPrecedes(_ lhs: DriveID?, _ rhs: DriveID?) -> Bool {
        switch (lhs?.rawValue, rhs?.rawValue) {
        case (nil, .some):
            true
        case let (lhs?, rhs?):
            lhs < rhs
        default:
            false
        }
    }

    private func directoryVerifier(_ children: [MetadataRecord]) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for child in children {
            mix(&hash, child.inode.rawValue)
            mix(&hash, displayName(child))
        }
        return hash
    }

    private func mix(_ hash: inout UInt64, _ value: UInt64) {
        hash ^= value
        hash &*= 1_099_511_628_211
    }

    private func mix(_ hash: inout UInt64, _ string: String) {
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        hash ^= 0xFF
        hash &*= 1_099_511_628_211
    }

    private func packCookie(verifier: UInt64, index: Int) -> EngineDirectoryCookie {
        let high = UInt64(UInt32(truncatingIfNeeded: verifier))
        let low = UInt64(UInt32(index))
        return EngineDirectoryCookie(rawValue: (high << 32) | low)
    }

    private func resumeIndex(_ cookie: EngineDirectoryCookie, verifier: UInt64, count: Int) throws -> Int {
        if cookie == .start || cookie.rawValue == 0 {
            return 0
        }
        let packed = UInt32(cookie.rawValue >> 32)
        let position = Int(cookie.rawValue & 0xFFFF_FFFF)
        guard packed == UInt32(truncatingIfNeeded: verifier) else {
            throw EngineError.posix(ESTALE)
        }
        guard position >= 1, position <= count else {
            throw EngineError.posix(EINVAL)
        }
        return position
    }

    private func slice(_ data: Data, offset: Int64, length: Int, size: Int64) -> Data {
        guard offset >= 0, length > 0, offset < size else {
            return Data()
        }
        let end = min(size, offset + Int64(length))
        guard offset < Int64(data.count) else {
            let missing = Int(end - offset)
            return missing > 0 ? Data(count: missing) : Data()
        }
        let start = Int(offset)
        let stop = min(data.count, Int(end))
        var bytes = Data(data[start..<stop])
        if Int64(bytes.count) < end - offset {
            bytes.append(Data(count: Int(end - offset) - bytes.count))
        }
        return bytes
    }

    private func sliceContent(_ content: DriveContent, offset: Int64, length: Int, size: Int64) -> Data {
        let end = min(size, offset + Int64(length))
        let dataEnd = content.offset + Int64(content.bytes.count)
        let lower = max(offset, content.offset)
        let upper = min(end, dataEnd)
        guard lower < upper, lower >= content.offset else {
            return Data()
        }
        let start = Int(lower - content.offset)
        let stop = Int(upper - content.offset)
        return Data(content.bytes[start..<stop])
    }
}
