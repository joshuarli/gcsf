import Foundation

public struct MetadataRecord: Sendable, Equatable, Codable {
    public var inode: Inode
    public var driveID: DriveID?
    public var parent: Inode?
    public var name: String
    public var assignedDuplicateSuffix: String?
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
    public var durability: DurabilityState
    public var trashed: Bool

    public init(
        inode: Inode,
        driveID: DriveID?,
        parent: Inode?,
        name: String,
        assignedDuplicateSuffix: String?,
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
        durability: DurabilityState,
        trashed: Bool
    ) {
        self.inode = inode
        self.driveID = driveID
        self.parent = parent
        self.name = name
        self.assignedDuplicateSuffix = assignedDuplicateSuffix
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
        self.durability = durability
        self.trashed = trashed
    }
}

public protocol MetadataStore: Actor {
    func record(inode: Inode) throws -> MetadataRecord?
    func record(driveID: DriveID) throws -> MetadataRecord?
    func child(of parent: Inode, name: String) throws -> MetadataRecord?
    func children(of parent: Inode) throws -> [MetadataRecord]
    func insert(_ record: MetadataRecord) throws
    func update(_ record: MetadataRecord) throws
    func remove(inode: Inode) throws
}
