public struct JournalID: Hashable, Sendable, Codable, Equatable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct JournalRecord: Sendable, Equatable, Codable {
    public var id: JournalID
    public var inode: Inode
    public var driveID: DriveID?
    public var state: DurabilityState
    public var headRevision: String?
    public var stagedRelativePath: String
    public var uploadSessionURI: String?

    public init(
        id: JournalID,
        inode: Inode,
        driveID: DriveID?,
        state: DurabilityState,
        headRevision: String?,
        stagedRelativePath: String,
        uploadSessionURI: String?
    ) {
        self.id = id
        self.inode = inode
        self.driveID = driveID
        self.state = state
        self.headRevision = headRevision
        self.stagedRelativePath = stagedRelativePath
        self.uploadSessionURI = uploadSessionURI
    }
}

public protocol WritebackJournal: Actor {
    func record(id: JournalID) throws -> JournalRecord?
    func records() throws -> [JournalRecord]
    func insert(_ record: JournalRecord) throws
    func setState(id: JournalID, state: DurabilityState) throws
    func remove(id: JournalID) throws
}
