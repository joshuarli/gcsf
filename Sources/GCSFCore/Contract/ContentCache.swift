import Foundation

public struct CacheBounds: Sendable, Equatable, Codable {
    public var memoryByteLimit: Int
    public var diskByteLimit: Int

    public init(memoryByteLimit: Int, diskByteLimit: Int) {
        self.memoryByteLimit = memoryByteLimit
        self.diskByteLimit = diskByteLimit
    }
}

public protocol ContentCache: Sendable {
    var bounds: CacheBounds { get }
    func read(
        driveID: DriveID,
        revision: String?,
        offset: Int64,
        length: Int,
        backend: any DriveBackend
    ) async throws -> Data
}
