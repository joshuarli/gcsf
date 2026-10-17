public enum MetadataStoreError: Error, Equatable, Sendable {
    case duplicateDriveID(DriveID)
    case duplicateInode(Inode)
    case retiredInode(Inode)
    case missingRecord(Inode)
    case schema(String)
    case invalidRow(String)
    case sqlite(code: Int32, message: String)
}
