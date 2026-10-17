import Foundation
import FSKit
import Synchronization

public final class GCSFVolume: FSVolume, FSVolume.Handler, FSVolume.ReadWriteHandler, FSVolume.XattrHandler, FSVolume.DataCacheHandler, KernelCachePort, @unchecked Sendable {
    public let session: String
    public let engine: any FileSystemEngine

    let registry = ItemRegistry()
    private let gate = VolumeGate()
    private let flags: Mutex<Flags>
    private let capabilities: FSVolume.SupportedCapabilities

    struct Flags {
        var readOnly: Bool
        var retired = false
    }

    public init(session: String, engine: any FileSystemEngine, readOnly: Bool) {
        self.session = session
        self.engine = engine
        let capabilities = FSVolume.SupportedCapabilities()
        capabilities.supportsPersistentObjectIDs = true
        capabilities.supportsSymbolicLinks = true
        capabilities.supportsHardLinks = false
        capabilities.supports2TBFiles = true
        capabilities.supports64BitObjectIDs = true
        capabilities.supportsFastStatFS = false
        capabilities.doesNotSupportVolumeSizes = true
        capabilities.doesNotSupportSettingFilePermissions = true
        capabilities.caseFormat = .sensitive
        self.capabilities = capabilities
        self.flags = Mutex(Flags(readOnly: readOnly))
        super.init(volumeID: FSVolume.Identifier(uuid: UUID()), volumeName: FSFileName(string: session))
    }

    public var maximumLinkCount: Int { 1 }
    public var maximumNameLength: Int { AttributeMapping.maximumNameLength }
    public var restrictsOwnershipChanges: Bool { true }
    public var truncatesLongNames: Bool { false }
    public var enableOpenUnlinkEmulation: Bool { true }
    public var supportedVolumeCapabilities: FSVolume.SupportedCapabilities { capabilities }
    public var volumeStatistics: FSStatFSResult { FSStatFSResult(fileSystemTypeName: "gcsf") }

    public func kernelCacheAttempts() -> [KernelCacheAttempt] {
        registry.attempts()
    }

    public func invalidateCachedItem(_ inode: Inode) async {
        await updateKernelCache(inode, action: .invalidate, recorded: .invalidate)
    }

    public func revokeCachedItem(_ inode: Inode) async {
        await updateKernelCache(inode, action: .revoke, recorded: .revoke)
    }

    public func mount(options: FSTaskOptions) async throws {
        try await finish {
            if await gate.isClosed {
                throw POSIXError(.ENXIO)
            }
            if options.taskOptions.contains("--rdonly") {
                flags.withLock { $0.readOnly = true }
            }
        }
    }

    public func unmount() async {
        await gate.closeAndWait()
        flags.withLock { $0.retired = true }
        registry.removeAll()
    }

    public func synchronize(flags: FSSyncFlags) async throws {
        try await finish {
            let engine = self.engine
            try await perform {
                try await engine.synchronize()
            }
        }
    }

    public func reclaimItem(_ item: FSItem) async throws {
        guard let item = item as? GCSFItem else { return }
        registry.reclaim(item)
    }

    public func activateVolume(options: FSTaskOptions) async throws -> FSActivateResult {
        try await finish {
            let root = registry.adopt(inode: AttributeMapping.rootInode, parent: AttributeMapping.rootInode, kind: .directory)
            return try AttributeMapping.result(FSActivateResult(rootItem: root))
        }
    }

    public func deactivateVolume(options: FSDeactivateOptions) async throws {
        registry.removeAll()
    }

    public func lookupItem(named name: FSFileName, in directory: FSItem, context: FSContext) async throws -> FSLookupItemResult {
        try await finish {
            let parent = try inodeOf(directory)
            try requireDirectory(parent)
            let text = try AttributeMapping.text(name)
            let uid = UInt32(truncatingIfNeeded: context.effectiveUserID)
            let gid = UInt32(truncatingIfNeeded: context.effectiveGroupID)
            if text == "." || text == ".." {
                let resolved = text == "." ? parent : registry.parent(of: parent)
                let item = registry.adopt(inode: resolved, parent: registry.parent(of: resolved), kind: registry.kind(of: resolved) ?? .directory)
                let attributes = try await fetchAttributes(resolved, uid: uid, gid: gid)
                return try lookupResult(item: item, name: text, attributes: attributes)
            }
            let engine = self.engine
            let found = try await perform {
                try await engine.lookup(named: text, in: parent)
            }
            let item = registry.adopt(inode: found.inode, parent: parent, kind: found.kind)
            let attributes = try await fetchAttributes(found.inode, uid: uid, gid: gid)
            return try lookupResult(item: item, name: found.name, attributes: attributes)
        }
    }

    public func createItem(named name: FSFileName, type: FSItem.ItemType, in directory: FSItem, attributes: FSItem.SetAttributesRequest, context: FSContext) async throws -> FSCreateItemResult {
        try await finish {
            try ensureWritable()
            let parent = try inodeOf(directory)
            try requireDirectory(parent)
            let text = try AttributeMapping.text(name)
            if text == "." || text == ".." { throw POSIXError(.EEXIST) }
            let kind = try AttributeMapping.kind(type)
            let engine = self.engine
            let created = try await perform {
                try await engine.create(named: text, kind: kind, in: parent)
            }
            let item = registry.adopt(inode: created.inode, parent: parent, kind: created.kind)
            let uid = UInt32(truncatingIfNeeded: context.effectiveUserID)
            let gid = UInt32(truncatingIfNeeded: context.effectiveGroupID)
            let createdAttributes = try await fetchAttributes(created.inode, uid: uid, gid: gid)
            let directoryAttributes = try await fetchAttributes(parent, uid: uid, gid: gid)
            return try AttributeMapping.result(
                FSCreateItemResult(
                    newItem: item,
                    newItemName: FSFileName(string: created.name),
                    newItemAttributes: createdAttributes,
                    directoryAttributes: directoryAttributes,
                    freeSpace: nil
                )
            )
        }
    }

    public func createSymbolicLink(named name: FSFileName, in directory: FSItem, attributes: FSItem.SetAttributesRequest, linkContents: FSFileName, context: FSContext) async throws -> FSCreateSymlinkResult {
        try await finish {
            _ = try AttributeMapping.text(name)
            _ = try AttributeMapping.text(linkContents)
            throw POSIXError(.ENOTSUP)
        }
    }

    public func createLink(to item: FSItem, named name: FSFileName, in directory: FSItem, context: FSContext) async throws -> FSCreateLinkResult {
        try await finish {
            throw POSIXError(.ENOTSUP)
        }
    }

    public func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?, context: FSContext) async throws -> FSRenameItemResult {
        try await finish {
            try ensureWritable()
            let inode = try inodeOf(item)
            let source = try inodeOf(sourceDirectory)
            let destination = try inodeOf(destinationDirectory)
            let fromName = try AttributeMapping.text(sourceName)
            let toName = try AttributeMapping.text(destinationName)
            if fromName == "." || fromName == ".." || toName == "." || toName == ".." {
                throw POSIXError(.EINVAL)
            }
            let replacing = try overItem.map { try self.inodeOf($0) }
            let engine = self.engine
            let renamed = try await perform {
                try await engine.rename(inode, fromParent: source, fromName: fromName, toParent: destination, toName: toName, replacing: replacing)
            }
            _ = registry.adopt(inode: renamed.inode, parent: destination, kind: renamed.kind)
            let uid = UInt32(truncatingIfNeeded: context.effectiveUserID)
            let gid = UInt32(truncatingIfNeeded: context.effectiveGroupID)
            let renamedAttributes = try await fetchAttributes(renamed.inode, uid: uid, gid: gid)
            let sourceAttributes = try await fetchAttributes(source, uid: uid, gid: gid)
            let destinationAttributes = try await fetchAttributes(destination, uid: uid, gid: gid)
            let overAttributes: FSItem.Attributes?
            if let replacing {
                overAttributes = try await fetchAttributes(replacing, uid: uid, gid: gid)
            } else {
                overAttributes = nil
            }
            return try AttributeMapping.result(
                FSRenameItemResult(
                    newName: FSFileName(string: renamed.name),
                    renamedItemAttributes: renamedAttributes,
                    sourceDirectoryAttributes: sourceAttributes,
                    destinationDirectoryAttributes: destinationAttributes,
                    overItemAttributes: overAttributes,
                    freeSpace: nil
                )
            )
        }
    }

    public func removeItem(_ item: FSItem, named name: FSFileName, from directory: FSItem, context: FSContext) async throws -> FSRemoveItemResult {
        try await finish {
            try ensureWritable()
            let inode = try inodeOf(item)
            let parent = try inodeOf(directory)
            let text = try AttributeMapping.text(name)
            if text == "." || text == ".." { throw POSIXError(.EINVAL) }
            let uid = UInt32(truncatingIfNeeded: context.effectiveUserID)
            let gid = UInt32(truncatingIfNeeded: context.effectiveGroupID)
            let itemAttributes = try await fetchAttributes(inode, uid: uid, gid: gid)
            let engine = self.engine
            try await perform {
                try await engine.remove(inode, named: text, from: parent)
            }
            let directoryAttributes = try await fetchAttributes(parent, uid: uid, gid: gid)
            return try AttributeMapping.result(
                FSRemoveItemResult(itemAttributes: itemAttributes, directoryAttributes: directoryAttributes, freeSpace: nil)
            )
        }
    }

    public func attributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem, context: FSContext) async throws -> FSGetAttributesResult {
        try await finish {
            let inode = try inodeOf(item)
            let uid = UInt32(truncatingIfNeeded: context.effectiveUserID)
            let gid = UInt32(truncatingIfNeeded: context.effectiveGroupID)
            let attributes = try await fetchAttributes(inode, uid: uid, gid: gid)
            return try AttributeMapping.result(FSGetAttributesResult(attributes: attributes))
        }
    }

    public func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem, context: FSContext) async throws -> FSSetAttributesResult {
        try await finish {
            let inode = try inodeOf(item)
            let kind = registry.kind(of: inode)
            if newAttributes.isValid(.size), kind == .file {
                try ensureWritable()
                let length = Int64(newAttributes.size)
                let engine = self.engine
                try await perform {
                    try await engine.truncate(inode, to: length)
                }
                newAttributes.consumedAttributes = .size
            }
            let uid = UInt32(truncatingIfNeeded: context.effectiveUserID)
            let gid = UInt32(truncatingIfNeeded: context.effectiveGroupID)
            let attributes = try await fetchAttributes(inode, uid: uid, gid: gid)
            return try AttributeMapping.result(FSSetAttributesResult(attributes: attributes, freeSpace: nil))
        }
    }

    public func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker, context: FSContext) async throws -> FSEnumerateDirectoryResult {
        try await finish {
            let directoryInode = try inodeOf(directory)
            try requireDirectory(directoryInode)
            let includeDots = attributes == nil
            let engineCookie = AttributeMapping.engineCookie(from: cookie.rawValue, includeDots: includeDots)
            let engine = self.engine
            let page = try await perform {
                try await engine.enumerate(directory: directoryInode, startingAt: EngineDirectoryCookie(rawValue: engineCookie))
            }
            let parent = registry.parent(of: directoryInode).rawValue
            let planned = AttributeMapping.plan(
                directory: directoryInode.rawValue,
                parent: parent,
                cookie: cookie.rawValue,
                includeDots: includeDots,
                page: page
            )
            let uid = UInt32(truncatingIfNeeded: context.effectiveUserID)
            let gid = UInt32(truncatingIfNeeded: context.effectiveGroupID)
            for entry in planned {
                let packedAttributes: FSItem.Attributes?
                if attributes == nil {
                    packedAttributes = nil
                } else {
                    packedAttributes = try await fetchAttributes(Inode(rawValue: entry.inode), uid: uid, gid: gid)
                }
                let packed = packer.packEntry(
                    name: FSFileName(string: entry.name),
                    itemType: AttributeMapping.itemType(entry.kind),
                    itemID: FSItem.Identifier(entry.inode),
                    nextCookie: FSDirectoryCookie(rawValue: entry.nextCookie),
                    attributes: packedAttributes
                )
                if packed == false { break }
            }
            return try AttributeMapping.result(FSEnumerateDirectoryResult(verifier: page.verifier))
        }
    }

    public func readSymbolicLink(_ item: FSItem, context: FSContext) async throws -> FSReadSymlinkResult {
        try await finish {
            let inode = try inodeOf(item)
            let engine = self.engine
            let target = try await perform {
                try await engine.readlink(inode)
            }
            let uid = UInt32(truncatingIfNeeded: context.effectiveUserID)
            let gid = UInt32(truncatingIfNeeded: context.effectiveGroupID)
            let attributes = try await fetchAttributes(inode, uid: uid, gid: gid)
            return try AttributeMapping.result(
                FSReadSymlinkResult(contents: FSFileName(string: target), symlinkAttributes: attributes)
            )
        }
    }

    public func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) async throws -> FSReadFileResult {
        try await finish {
            if offset < 0 || length < 0 { throw POSIXError(.EINVAL) }
            let inode = try inodeOf(item)
            let engine = self.engine
            let data = try await perform {
                try await engine.read(inode, at: offset, length: length)
            }
            let copied = buffer.withUnsafeMutableBytes { destination in
                AttributeMapping.copy(data, into: destination, limit: length)
            }
            let attributes = try await fetchAttributes(inode, uid: 0, gid: 0)
            return try AttributeMapping.result(FSReadFileResult(bytesRead: copied, itemAttributes: attributes))
        }
    }

    public func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> FSWriteFileResult {
        try await finish {
            try ensureWritable()
            if offset < 0 { throw POSIXError(.EINVAL) }
            let inode = try inodeOf(item)
            let engine = self.engine
            let written = try await perform {
                try await engine.write(inode, bytes: contents, at: offset)
            }
            if written < 0 { throw POSIXError(.EIO) }
            let attributes = try await fetchAttributes(inode, uid: 0, gid: 0)
            return try AttributeMapping.result(
                FSWriteFileResult(bytesWritten: written, itemAttributes: attributes, freeSpace: nil)
            )
        }
    }

    public func xattr(named name: FSFileName, of item: FSItem, context: FSContext) async throws -> FSGetXattrResult {
        try await finish {
            let inode = try inodeOf(item)
            let text = try AttributeMapping.text(name)
            let engine = self.engine
            let value = try await perform {
                try await engine.xattr(named: text, of: inode)
            }
            return try AttributeMapping.result(FSGetXattrResult(xattrValue: value))
        }
    }

    public func setXattr(named name: FSFileName, to value: Data?, on item: FSItem, policy: FSVolume.SetXattrPolicy, context: FSContext) async throws -> FSSetXattrResult {
        try await finish {
            try ensureWritable()
            let inode = try inodeOf(item)
            let text = try AttributeMapping.text(name)
            if value == nil && policy != .delete { throw POSIXError(.EINVAL) }
            let engine = self.engine
            switch policy {
            case .alwaysSet:
                try await perform {
                    try await engine.setXattr(named: text, value: value, of: inode)
                }
            case .mustCreate:
                let names = try await perform { try await engine.xattrNames(of: inode) }
                if names.contains(text) { throw POSIXError(.EEXIST) }
                try await perform {
                    try await engine.setXattr(named: text, value: value, of: inode)
                }
            case .mustReplace:
                _ = try await perform { try await engine.xattr(named: text, of: inode) }
                try await perform {
                    try await engine.setXattr(named: text, value: value, of: inode)
                }
            case .delete:
                let names = try await perform { try await engine.xattrNames(of: inode) }
                if names.contains(text) == false { throw POSIXError(.ENOATTR) }
                try await perform {
                    try await engine.setXattr(named: text, value: nil, of: inode)
                }
            @unknown default:
                throw POSIXError(.ENOTSUP)
            }
            return try AttributeMapping.result(FSSetXattrResult(freeSpace: nil))
        }
    }

    public func xattrs(of item: FSItem, context: FSContext) async throws -> FSListXattrsResult {
        try await finish {
            let inode = try inodeOf(item)
            let engine = self.engine
            let names = try await perform {
                try await engine.xattrNames(of: inode)
            }
            let fileNames = try names.map { name -> FSFileName in
                if name.utf8.count > AttributeMapping.maximumNameLength { throw POSIXError(.ENAMETOOLONG) }
                return FSFileName(string: name)
            }
            return try AttributeMapping.result(FSListXattrsResult(xattrNames: fileNames))
        }
    }

    public func open(_ item: FSItem, modes: FSVolume.OpenModes, cacheMode: FSVolume.DataCacheMode, context: FSContext) async throws -> FSOpenItemResult {
        try await finish {
            let inode = try inodeOf(item)
            let mode = cacheMode
            try await gate.withPermit {
                self.registry.setCacheMode(inode, mode)
            }
            return FSOpenItemResult(grantedCoherency: .noCache)
        }
    }

    public func close(_ item: FSItem, context: FSContext) async {}

    public func upgrade(_ item: FSItem, cacheMode: FSVolume.DataCacheMode, context: FSContext) async throws -> FSUpgradeItemResult {
        try await finish {
            let inode = try inodeOf(item)
            let mode = cacheMode
            try await gate.withPermit {
                self.registry.setCacheMode(inode, mode)
            }
            return FSUpgradeItemResult(grantedCoherency: .noCache)
        }
    }

    private func updateKernelCache(_ inode: Inode, action: FSVolume.KernelCacheCoherencyAction, recorded: KernelCacheAttempt.Action) async {
        let item = registry.item(for: inode)
        let mode = registry.cacheMode(of: inode)
        var attempt = KernelCacheAttempt(
            inode: inode,
            action: recorded,
            calledSetCacheState: false,
            kernelErrorDomain: nil,
            kernelErrorCode: nil,
            kernelEffectVerified: false
        )
        if let item {
            let error = setCacheState(for: item, cacheMode: mode, coherencyType: .noCache, action: action)
            attempt.calledSetCacheState = true
            attempt.kernelEffectVerified = false
            if let error = error as NSError? {
                attempt.kernelErrorDomain = error.domain
                attempt.kernelErrorCode = error.code
            }
        }
        registry.record(attempt)
    }

    private func finish<T>(_ body: () async throws -> T) async throws -> T {
        try await gate.begin()
        do {
            let value = try await body()
            await gate.end()
            return value
        } catch {
            await gate.end()
            throw error
        }
    }

    private func perform<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await FSKitCallbackTask.$isServingCallback.withValue(true) {
            try await Task.detached {
                try await work()
            }.value
        }
    }

    private func fetchAttributes(_ inode: Inode, uid: UInt32, gid: UInt32) async throws -> FSItem.Attributes {
        let engine = self.engine
        let attributes = try await perform {
            try await engine.attributes(inode)
        }
        return AttributeMapping.attributes(from: attributes, uid: uid, gid: gid)
    }

    private func lookupResult(item: GCSFItem, name: String, attributes: FSItem.Attributes) throws -> FSLookupItemResult {
        try AttributeMapping.result(
            FSLookupItemResult(foundItem: item, itemName: FSFileName(string: name), itemAttributes: attributes)
        )
    }

    private func inodeOf(_ item: FSItem) throws -> Inode {
        guard let item = item as? GCSFItem else { throw POSIXError(.EINVAL) }
        return item.inode
    }

    private func requireDirectory(_ inode: Inode) throws {
        if let kind = registry.kind(of: inode), kind != .directory {
            throw POSIXError(.ENOTDIR)
        }
    }

    private func ensureWritable() throws {
        if flags.withLock({ $0.readOnly }) {
            throw POSIXError(.EROFS)
        }
    }
}
