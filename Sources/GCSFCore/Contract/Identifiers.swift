public struct DriveID: Hashable, Sendable, Codable, Equatable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct Inode: Hashable, Sendable, Codable, Equatable {
    public var rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}
