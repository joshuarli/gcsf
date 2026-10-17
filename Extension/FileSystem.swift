import ExtensionFoundation
import Foundation
import FSKit
import GCSFCore

@main
struct GCSFExtensionMain: UnaryFileSystemExtension {
    let fileSystem = GCSFFileSystem(makeEngine: DisconnectedEngine.init(session:))
}

private struct DisconnectedEngine: FileSystemEngine {
    let session: String

    private func unavailable() -> Error {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ENXIO),
            userInfo: [NSLocalizedDescriptionKey: "no engine for \(session)"]
        )
    }

    func lookup(named name: String, in parent: Inode) async throws -> EngineItem { throw unavailable() }
    func attributes(_ inode: Inode) async throws -> EngineAttributes { throw unavailable() }
    func xattr(named name: String, of inode: Inode) async throws -> Data { throw unavailable() }
    func setXattr(named name: String, value: Data?, of inode: Inode) async throws { throw unavailable() }
    func xattrNames(of inode: Inode) async throws -> [String] { throw unavailable() }
    func enumerate(directory: Inode, startingAt cookie: EngineDirectoryCookie) async throws -> EngineEnumeration { throw unavailable() }
    func create(named name: String, kind: EngineItemKind, in parent: Inode) async throws -> EngineItem { throw unavailable() }
    func rename(_ inode: Inode, fromParent: Inode, fromName: String, toParent: Inode, toName: String, replacing: Inode?) async throws -> EngineItem { throw unavailable() }
    func remove(_ inode: Inode, named name: String, from parent: Inode) async throws { throw unavailable() }
    func readlink(_ inode: Inode) async throws -> String { throw unavailable() }
    func read(_ inode: Inode, at offset: Int64, length: Int) async throws -> Data { throw unavailable() }
    func write(_ inode: Inode, bytes: Data, at offset: Int64) async throws -> Int { throw unavailable() }
    func truncate(_ inode: Inode, to length: Int64) async throws { throw unavailable() }
    func synchronize() async throws { throw unavailable() }
}
