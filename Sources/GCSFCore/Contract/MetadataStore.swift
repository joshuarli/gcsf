import Foundation

public struct MetadataRecord: Sendable, Equatable, Codable {
    public var inode: Inode
    public var driveID: DriveID
    public var parent: Inode?
    public var name: String
    public var assignedDuplicateSuffix: String?
    public var mimeType: String
    public var size: Int64
    public var created: Date?
    public var modified: Date?
    public var headRevision: String?
    public var durability: DurabilityState
    public var trashed: Bool

    public init(
        inode: Inode,
        driveID: DriveID,
        parent: Inode?,
        name: String,
        assignedDuplicateSuffix: String?,
        mimeType: String,
        size: Int64,
        created: Date?,
        modified: Date?,
        headRevision: String?,
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
