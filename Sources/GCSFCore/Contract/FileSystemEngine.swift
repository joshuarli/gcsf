import Foundation

public enum EngineItemKind: String, Sendable, Codable, Equatable {
    case file
    case directory
    case symlink
}

public struct EngineItem: Sendable, Equatable {
    public var inode: Inode
    public var name: String
    public var kind: EngineItemKind

    public init(inode: Inode, name: String, kind: EngineItemKind) {
        self.inode = inode
        self.name = name
        self.kind = kind
    }
}

public struct EngineAttributes: Sendable, Equatable {
    public var inode: Inode
    public var kind: EngineItemKind
    public var size: Int64
    public var linkCount: Int
    public var created: Date?
    public var modified: Date?
    public var mimeType: String?

    public init(
        inode: Inode,
        kind: EngineItemKind,
        size: Int64,
        linkCount: Int,
        created: Date?,
        modified: Date?,
        mimeType: String?
    ) {
        self.inode = inode
        self.kind = kind
        self.size = size
        self.linkCount = linkCount
        self.created = created
        self.modified = modified
        self.mimeType = mimeType
    }
}

public struct EngineDirectoryCookie: Hashable, Sendable, Equatable {
    public var rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let start = EngineDirectoryCookie(rawValue: 0)
}

public struct EngineDirectoryEntry: Sendable, Equatable {
    public var name: String
    public var item: EngineItem
    public var cookie: EngineDirectoryCookie

    public init(name: String, item: EngineItem, cookie: EngineDirectoryCookie) {
        self.name = name
        self.item = item
        self.cookie = cookie
    }
}

public struct EngineEnumeration: Sendable, Equatable {
    public var entries: [EngineDirectoryEntry]
    public var verifier: UInt64
    public var nextCookie: EngineDirectoryCookie?

    public init(entries: [EngineDirectoryEntry], verifier: UInt64, nextCookie: EngineDirectoryCookie?) {
        self.entries = entries
        self.verifier = verifier
        self.nextCookie = nextCookie
    }
}

public protocol FileSystemEngine: Sendable {
    func lookup(named name: String, in parent: Inode) async throws -> EngineItem
    func attributes(_ inode: Inode) async throws -> EngineAttributes
    func xattr(named name: String, of inode: Inode) async throws -> Data
    func setXattr(named name: String, value: Data?, of inode: Inode) async throws
    func xattrNames(of inode: Inode) async throws -> [String]
    func enumerate(directory: Inode, startingAt cookie: EngineDirectoryCookie) async throws -> EngineEnumeration
    func create(named name: String, kind: EngineItemKind, in parent: Inode) async throws -> EngineItem
    func rename(
        _ inode: Inode,
        fromParent: Inode,
        fromName: String,
        toParent: Inode,
        toName: String,
        replacing: Inode?
    ) async throws -> EngineItem
    func remove(_ inode: Inode, named name: String, from parent: Inode) async throws
    func readlink(_ inode: Inode) async throws -> String
    func read(_ inode: Inode, at offset: Int64, length: Int) async throws -> Data
    func write(_ inode: Inode, bytes: Data, at offset: Int64) async throws -> Int
    func synchronize() async throws
}
