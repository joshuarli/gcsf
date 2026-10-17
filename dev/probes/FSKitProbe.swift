import Foundation
import FSKit
import ExtensionFoundation

@objc
final class ProbeFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        replyHandler(FSProbeResult.notRecognized, nil)
    }
    func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        replyHandler(ProbeVolume(volumeID: FSVolume.Identifier(uuid: UUID()), volumeName: FSFileName(string: "Probe")), nil)
    }
    func unloadResource(resource: FSResource, options: FSTaskOptions) async throws {}
}

final class ProbeItem: FSItem {
    let inode: UInt64
    init(inode: UInt64) { self.inode = inode; super.init() }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

final class ProbeVolume: FSVolume, FSVolume.Handler, FSVolume.ReadWriteHandler, FSVolume.XattrHandler {
    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { false }
    var truncatesLongNames: Bool { false }
    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities { FSVolume.SupportedCapabilities() }
    var volumeStatistics: FSStatFSResult { FSStatFSResult(fileSystemTypeName: "gcsf") }

    func mount(options: FSTaskOptions) async throws {}
    func unmount() async {}
    func synchronize(flags: FSSyncFlags) async throws {}
    func reclaimItem(_ item: FSItem) async throws {}
    func activateVolume(options: FSTaskOptions) async throws -> FSActivateResult {
        FSActivateResult(rootItem: ProbeItem(inode: 1))!
    }
    func deactivateVolume(options: FSDeactivateOptions) async throws {}
    func lookupItem(named name: FSFileName, in directory: FSItem, context: FSContext) async throws -> FSLookupItemResult {
        throw fsError(ENOENT)
    }
    func createItem(named name: FSFileName, type: FSItem.ItemType, in directory: FSItem, attributes: FSItem.SetAttributesRequest, context: FSContext) async throws -> FSCreateItemResult {
        throw fsError(ENOTSUP)
    }
    func createSymbolicLink(named name: FSFileName, in directory: FSItem, attributes: FSItem.SetAttributesRequest, linkContents: FSFileName, context: FSContext) async throws -> FSCreateSymlinkResult {
        throw fsError(ENOTSUP)
    }
    func createLink(to item: FSItem, named name: FSFileName, in directory: FSItem, context: FSContext) async throws -> FSCreateLinkResult {
        throw fsError(ENOTSUP)
    }
    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?, context: FSContext) async throws -> FSRenameItemResult {
        throw fsError(ENOTSUP)
    }
    func removeItem(_ item: FSItem, named name: FSFileName, from directory: FSItem, context: FSContext) async throws -> FSRemoveItemResult {
        throw fsError(ENOTSUP)
    }
    func attributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem, context: FSContext) async throws -> FSGetAttributesResult {
        FSGetAttributesResult(attributes: FSItem.Attributes())!
    }
    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem, context: FSContext) async throws -> FSSetAttributesResult {
        FSSetAttributesResult(attributes: FSItem.Attributes(), freeSpace: nil)!
    }
    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker, context: FSContext) async throws -> FSEnumerateDirectoryResult {
        FSEnumerateDirectoryResult(verifier: 1)!
    }
    func readSymbolicLink(_ item: FSItem, context: FSContext) async throws -> FSReadSymlinkResult {
        throw fsError(ENOTSUP)
    }
    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) async throws -> FSReadFileResult {
        FSReadFileResult(bytesRead: 0, itemAttributes: FSItem.Attributes())!
    }
    func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> FSWriteFileResult {
        FSWriteFileResult(bytesWritten: contents.count, itemAttributes: FSItem.Attributes(), freeSpace: nil)!
    }
    func xattr(named name: FSFileName, of item: FSItem, context: FSContext) async throws -> FSGetXattrResult {
        FSGetXattrResult(xattrValue: Data())!
    }
    func setXattr(named name: FSFileName, to value: Data?, on item: FSItem, policy: FSVolume.SetXattrPolicy, context: FSContext) async throws -> FSSetXattrResult {
        FSSetXattrResult(freeSpace: nil)!
    }
    func xattrs(of item: FSItem, context: FSContext) async throws -> FSListXattrsResult {
        FSListXattrsResult(xattrNames: [])!
    }
}

func fsError(_ code: Int32) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }

@main
struct ProbeExtension: UnaryFileSystemExtension {
    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations { ProbeFileSystem() }
}
