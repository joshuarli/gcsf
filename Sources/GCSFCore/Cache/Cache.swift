import Foundation

public actor BoundedContentCache: ContentCache {
    public nonisolated let bounds: CacheBounds
    public nonisolated let blockSize: Int

    private let directory: URL
    private var memory: [BlockKey: CachedBlock] = [:]
    private var disk: [BlockKey: DiskBlock] = [:]
    private var stamp: UInt64 = 0
    private var cursors: [StreamKey: Int64] = [:]

    public init(bounds: CacheBounds, directory: URL, blockSize: Int = 65_536) throws {
        self.bounds = bounds
        if bounds.memoryByteLimit > 0 {
            self.blockSize = min(max(blockSize, 1), bounds.memoryByteLimit)
        } else {
            self.blockSize = max(blockSize, 1)
        }
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let loaded = try Self.loadDisk(directory: directory, limit: bounds.diskByteLimit)
        self.disk = loaded.blocks
        self.stamp = loaded.stamp
    }

    public var residentByteCount: Int {
        memory.values.reduce(0) { $0 + $1.bytes.count }
    }

    public var diskByteCount: Int {
        disk.values.reduce(0) { $0 + $1.bytes }
    }

    public func read(
        driveID: DriveID,
        revision: String?,
        offset: Int64,
        length: Int,
        backend: any DriveBackend
    ) async throws -> Data {
        try Task.checkCancellation()
        if offset < 0 || length < 0 {
            throw POSIXError(.EINVAL)
        }
        if length == 0 {
            return Data()
        }
        let (end, overflowed) = offset.addingReportingOverflow(Int64(length))
        if overflowed {
            throw POSIXError(.EFBIG)
        }
        let span = Int64(blockSize)
        let first = offset / span
        let last = (end - 1) / span
        let stream = StreamKey(driveID: driveID.rawValue, revision: revision ?? "")
        var have: [Int64: Data] = [:]
        var missing: [Int64] = []
        var index = first
        while index <= last {
            let key = BlockKey(driveID: driveID.rawValue, revision: revision ?? "", index: index)
            if let bytes = try cached(key) {
                have[index] = bytes
            } else {
                missing.append(index)
            }
            let (advanced, advancedOverflow) = index.addingReportingOverflow(1)
            if advancedOverflow {
                throw POSIXError(.EFBIG)
            }
            index = advanced
        }
        if !missing.isEmpty, cursors[stream] == offset, bounds.memoryByteLimit / blockSize >= 2 {
            let (next, nextOverflow) = last.addingReportingOverflow(1)
            if !nextOverflow {
                let key = BlockKey(driveID: driveID.rawValue, revision: revision ?? "", index: next)
                if !holds(key) {
                    missing.append(next)
                }
            }
        }

        var runStart: Int64?
        var runEnd: Int64?
        for hole in missing + [Int64.max] {
            let continues = hole != Int64.max && runEnd.map { hole == $0 + 1 } == true
            if continues {
                runEnd = hole
                continue
            }
            if let start = runStart, let finish = runEnd {
                let fetched = try await fetch(
                    driveID: driveID,
                    revision: revision ?? "",
                    first: start,
                    last: finish,
                    backend: backend
                )
                for (block, bytes) in fetched {
                    have[block] = bytes
                }
            }
            if hole == Int64.max {
                break
            }
            runStart = hole
            runEnd = hole
        }

        var result = Data()
        index = first
        while index <= last {
            guard let block = have[index] else {
                break
            }
            let blockStart = index * span
            let sliceStart = max(offset, blockStart)
            let sliceEnd = min(end, blockStart + Int64(block.count))
            if sliceStart >= sliceEnd {
                break
            }
            let lo = Int(sliceStart - blockStart)
            let hi = Int(sliceEnd - blockStart)
            result.append(block[lo..<hi])
            if block.count < blockSize {
                break
            }
            index += 1
        }
        cursors[stream] = offset + Int64(result.count)
        return result
    }

    private func fetch(
        driveID: DriveID,
        revision: String,
        first: Int64,
        last: Int64,
        backend: any DriveBackend
    ) async throws -> [Int64: Data] {
        let span = Int64(blockSize)
        let (count64, countOverflow) = (last - first + 1).multipliedReportingOverflow(by: span)
        if countOverflow || count64 > Int64(Int.max) || count64 < 0 {
            throw POSIXError(.EFBIG)
        }
        let start = first * span
        let payload = try await download(
            driveID: driveID,
            start: start,
            length: Int(count64),
            backend: backend
        )
        var stored: [Int64: Data] = [:]
        var index = first
        var local = 0
        while local < payload.bytes.count && index <= last {
            let remaining = payload.bytes.count - local
            let take = min(blockSize, remaining)
            let tail = local + take == payload.bytes.count
            let complete = take == blockSize || (tail && payload.reachedEnd)
            if complete {
                let slice = Data(payload.bytes[local..<(local + take)])
                let key = BlockKey(driveID: driveID.rawValue, revision: revision, index: index)
                try retain(key, slice)
                stored[index] = slice
            }
            if take < blockSize {
                break
            }
            local += take
            index += 1
        }
        return stored
    }

    private func download(
        driveID: DriveID,
        start: Int64,
        length: Int,
        backend: any DriveBackend
    ) async throws -> (bytes: Data, reachedEnd: Bool) {
        var collected = Data()
        collected.reserveCapacity(length)
        var cursor = start
        let end = start + Int64(length)
        var reachedEnd = false
        while cursor < end {
            try Task.checkCancellation()
            let want = end - cursor
            guard want <= Int64(Int.max) else {
                throw POSIXError(.EFBIG)
            }
            let content = try await backend.downloadContent(
                id: driveID,
                range: ByteRange(offset: cursor, length: Int(want))
            )
            try Task.checkCancellation()
            if content.bytes.isEmpty {
                reachedEnd = true
                break
            }
            if content.offset > cursor {
                reachedEnd = true
                break
            }
            let skip = Int(cursor - content.offset)
            if skip >= content.bytes.count {
                reachedEnd = true
                break
            }
            let piece = content.bytes.dropFirst(skip)
            let room = Int(end - cursor)
            let take = min(room, piece.count)
            if take == 0 {
                reachedEnd = true
                break
            }
            collected.append(contentsOf: piece.prefix(take))
            cursor += Int64(take)
            if let total = content.totalSize, cursor >= total {
                reachedEnd = true
                break
            }
            if take < Int(want), content.totalSize == nil || (content.totalSize ?? 0) <= cursor {
                reachedEnd = true
                break
            }
        }
        if cursor < end {
            reachedEnd = true
        }
        return (collected, reachedEnd)
    }

    private func holds(_ key: BlockKey) -> Bool {
        if memory[key] != nil {
            return true
        }
        guard let stored = disk[key] else {
            return false
        }
        return FileManager.default.fileExists(atPath: stored.url.path)
    }

    private func cached(_ key: BlockKey) throws -> Data? {
        if let hit = memory[key] {
            stamp += 1
            memory[key]?.stamp = stamp
            if disk[key] != nil {
                disk[key]?.stamp = stamp
                try touch(disk[key]?.url)
            }
            return hit.bytes
        }
        guard var stored = disk[key] else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: stored.url.path) else {
            disk.removeValue(forKey: key)
            return nil
        }
        let bytes = try Data(contentsOf: stored.url)
        stamp += 1
        stored.stamp = stamp
        stored.bytes = bytes.count
        disk[key] = stored
        try touch(stored.url)
        retainMemory(key, bytes)
        return bytes
    }

    private func retain(_ key: BlockKey, _ bytes: Data) throws {
        guard !bytes.isEmpty else {
            return
        }
        try retainDisk(key, bytes)
        retainMemory(key, bytes)
    }

    private func retainMemory(_ key: BlockKey, _ bytes: Data) {
        guard bounds.memoryByteLimit > 0, bytes.count <= bounds.memoryByteLimit else {
            return
        }
        memory.removeValue(forKey: key)
        evictMemory(makingRoomFor: bytes.count)
        guard residentByteCount + bytes.count <= bounds.memoryByteLimit else {
            return
        }
        stamp += 1
        memory[key] = CachedBlock(bytes: bytes, stamp: stamp)
    }

    private func retainDisk(_ key: BlockKey, _ bytes: Data) throws {
        guard bounds.diskByteLimit > 0, bytes.count <= bounds.diskByteLimit else {
            return
        }
        let existing = disk[key]?.bytes ?? 0
        let growth = max(0, bytes.count - existing)
        try evictDisk(makingRoomFor: growth, keeping: key)
        guard diskByteCount + growth <= bounds.diskByteLimit else {
            return
        }
        let url = directory.appending(path: key.fileName)
        try bytes.write(to: url, options: .atomic)
        stamp += 1
        disk[key] = DiskBlock(url: url, bytes: bytes.count, stamp: stamp)
    }

    private func evictMemory(makingRoomFor extra: Int) {
        while residentByteCount + extra > bounds.memoryByteLimit {
            guard let victim = memory.min(by: { $0.value.stamp < $1.value.stamp })?.key else {
                return
            }
            memory.removeValue(forKey: victim)
        }
    }

    private func evictDisk(makingRoomFor extra: Int, keeping: BlockKey?) throws {
        while diskByteCount + extra > bounds.diskByteLimit {
            let candidates = disk.filter { $0.key != keeping }
            guard let victim = candidates.min(by: { $0.value.stamp < $1.value.stamp }) else {
                return
            }
            if FileManager.default.fileExists(atPath: victim.value.url.path) {
                try FileManager.default.removeItem(at: victim.value.url)
            }
            disk.removeValue(forKey: victim.key)
        }
    }

    private static func loadDisk(directory: URL, limit: Int) throws -> (blocks: [BlockKey: DiskBlock], stamp: UInt64) {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        )
        var loaded: [(BlockKey, URL, Int, Date)] = []
        for url in urls {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true,
                  let size = values.fileSize,
                  let key = BlockKey(decoding: url.lastPathComponent) else {
                continue
            }
            loaded.append((key, url, size, values.contentModificationDate ?? .distantPast))
        }
        loaded.sort { $0.3 < $1.3 }
        var blocks: [BlockKey: DiskBlock] = [:]
        var stamp: UInt64 = 0
        for item in loaded {
            stamp += 1
            blocks[item.0] = DiskBlock(url: item.1, bytes: item.2, stamp: stamp)
        }
        while blocks.values.reduce(0, { $0 + $1.bytes }) > limit {
            guard let victim = blocks.min(by: { $0.value.stamp < $1.value.stamp }) else {
                break
            }
            if FileManager.default.fileExists(atPath: victim.value.url.path) {
                try FileManager.default.removeItem(at: victim.value.url)
            }
            blocks.removeValue(forKey: victim.key)
        }
        return (blocks, stamp)
    }

    private func touch(_ url: URL?) throws {
        guard let url else {
            return
        }
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }
}

private struct StreamKey: Hashable {
    var driveID: String
    var revision: String
}

private struct CachedBlock {
    var bytes: Data
    var stamp: UInt64
}

private struct DiskBlock {
    var url: URL
    var bytes: Int
    var stamp: UInt64
}

private struct BlockKey: Hashable {
    var driveID: String
    var revision: String
    var index: Int64

    var fileName: String {
        "\(Self.escape(driveID)).\(Self.escape(revision)).\(index)"
    }

    init(driveID: String, revision: String, index: Int64) {
        self.driveID = driveID
        self.revision = revision
        self.index = index
    }

    init?(decoding name: String) {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let index = Int64(parts[2]) else {
            return nil
        }
        guard let driveID = Self.unescape(String(parts[0])),
              let revision = Self.unescape(String(parts[1])) else {
            return nil
        }
        self.init(driveID: driveID, revision: revision, index: index)
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func unescape(_ value: String) -> String? {
        value.removingPercentEncoding
    }
}
