import Foundation
import FSKit

enum AttributeMapping {
    static let rootInode = Inode(rawValue: 1)
    static let maximumNameLength = 255

    static func plan(
        directory: UInt64,
        parent: UInt64,
        cookie: UInt64,
        includeDots: Bool,
        page: EngineEnumeration
    ) -> [PlannedEntry] {
        let bias: UInt64 = includeDots ? 2 : 0
        var planned: [PlannedEntry] = []
        if includeDots && cookie == 0 {
            planned.append(PlannedEntry(name: ".", kind: .directory, inode: directory, nextCookie: 1))
            planned.append(PlannedEntry(name: "..", kind: .directory, inode: parent, nextCookie: 2))
        } else if includeDots && cookie == 1 {
            planned.append(PlannedEntry(name: "..", kind: .directory, inode: parent, nextCookie: 2))
        }
        for entry in page.entries {
            planned.append(
                PlannedEntry(
                    name: entry.name,
                    kind: entry.item.kind,
                    inode: entry.item.inode.rawValue,
                    nextCookie: entry.cookie.rawValue + bias
                )
            )
        }
        return planned
    }

    static func engineCookie(from cookie: UInt64, includeDots: Bool) -> UInt64 {
        let bias: UInt64 = includeDots ? 2 : 0
        if cookie <= bias { return 0 }
        return cookie - bias
    }

    static func copy(_ data: Data, into destination: UnsafeMutableRawBufferPointer, limit: Int) -> Int {
        let count = min(data.count, destination.count, max(limit, 0))
        guard count > 0, let base = destination.baseAddress else { return 0 }
        data.withUnsafeBytes { source in
            guard let raw = source.baseAddress else { return }
            base.copyMemory(from: raw, byteCount: count)
        }
        return count
    }

    static func text(_ name: FSFileName) throws -> String {
        if name.data.contains(0) || name.data.contains(0x2F) {
            throw POSIXError(.EINVAL)
        }
        guard let string = name.string else { throw POSIXError(.EILSEQ) }
        guard string.isEmpty == false else { throw POSIXError(.EINVAL) }
        if string.utf8.count > maximumNameLength {
            throw POSIXError(.ENAMETOOLONG)
        }
        return string
    }

    static func itemType(_ kind: EngineItemKind) -> FSItem.ItemType {
        switch kind {
        case .file: .file
        case .directory: .directory
        case .symlink: .symlink
        }
    }

    static func kind(_ type: FSItem.ItemType) throws -> EngineItemKind {
        switch type {
        case .file: .file
        case .directory: .directory
        default: throw POSIXError(.ENOTSUP)
        }
    }

    static func attributes(from engine: EngineAttributes, uid: UInt32, gid: UInt32) -> FSItem.Attributes {
        let attributes = FSItem.Attributes()
        attributes.type = itemType(engine.kind)
        let size = UInt64(max(engine.size, 0))
        attributes.size = size
        attributes.allocSize = size
        attributes.linkCount = UInt32(clamping: max(engine.linkCount, 0))
        attributes.fileID = FSItem.Identifier(engine.inode.rawValue)
        attributes.uid = uid
        attributes.gid = gid
        attributes.mode = mode(engine.kind)
        if let created = engine.created {
            attributes.birthTime = stamp(created)
        }
        if let modified = engine.modified {
            let stamp = stamp(modified)
            attributes.modifyTime = stamp
            attributes.changeTime = stamp
        }
        return attributes
    }

    static func mode(_ kind: EngineItemKind) -> UInt32 {
        switch kind {
        case .directory: 0o755
        case .file: 0o644
        case .symlink: 0o777
        }
    }

    static func stamp(_ date: Date) -> timespec {
        var value = timespec()
        let seconds = date.timeIntervalSince1970
        let whole = seconds.rounded(.towardZero)
        var fraction = seconds - whole
        if fraction < 0 {
            fraction += 1
        }
        value.tv_sec = time_t(whole)
        value.tv_nsec = Int(fraction * 1_000_000_000)
        return value
    }

    static func result<T>(_ value: T?) throws -> T {
        guard let value else { throw POSIXError(.EIO) }
        return value
    }
}
