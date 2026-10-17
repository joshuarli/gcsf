import Foundation
import Testing
import GCSFCore

@Suite struct CacheTests {
    @Test func revisionChangeMissesAndRepeatHits() async throws {
        let directory = try scratchDirectory("revision")
        let backend = ScriptedDrive { range in
            let length = range?.length ?? 0
            return DriveContent(
                bytes: Data(repeating: 4, count: length),
                offset: range?.offset ?? 0,
                totalSize: nil
            )
        }
        let cache = try BoundedContentCache(
            bounds: CacheBounds(memoryByteLimit: 256 * 1024, diskByteLimit: 256 * 1024),
            directory: directory,
            blockSize: 64 * 1024
        )
        let id = DriveID(rawValue: "file")
        let first = try await cache.read(driveID: id, revision: "rev-1", offset: 0, length: 64 * 1024, backend: backend)
        let second = try await cache.read(driveID: id, revision: "rev-1", offset: 0, length: 64 * 1024, backend: backend)
        let third = try await cache.read(driveID: id, revision: "rev-2", offset: 0, length: 64 * 1024, backend: backend)
        #expect(first == second)
        #expect(third.count == 64 * 1024)
        #expect(await backend.calls == 2)
        #expect(await cache.residentByteCount <= 256 * 1024)
    }

    @Test func coalescesAdjacentBlocksAndReadsAheadOnTheNextSequentialRead() async throws {
        let directory = try scratchDirectory("coalesce")
        let backend = ScriptedDrive { range in
            let length = range?.length ?? 0
            return DriveContent(
                bytes: Data(repeating: 5, count: length),
                offset: range?.offset ?? 0,
                totalSize: 1024 * 1024
            )
        }
        let cache = try BoundedContentCache(
            bounds: CacheBounds(memoryByteLimit: 128 * 1024, diskByteLimit: 256 * 1024),
            directory: directory,
            blockSize: 32 * 1024
        )
        let id = DriveID(rawValue: "file")
        let wide = try await cache.read(driveID: id, revision: "rev", offset: 0, length: 64 * 1024, backend: backend)
        #expect(wide.count == 64 * 1024)
        #expect(await backend.calls == 1)
        let firstRange = await backend.ranges.first
        #expect(firstRange?.offset == 0)
        #expect(firstRange?.length == 64 * 1024)

        let next = try await cache.read(
            driveID: id,
            revision: "rev",
            offset: 64 * 1024,
            length: 32 * 1024,
            backend: backend
        )
        #expect(next.count == 32 * 1024)
        #expect(await backend.calls == 2)
        let secondRange = await backend.ranges
        #expect(secondRange[1].offset == 64 * 1024)
        #expect(secondRange[1].length == 64 * 1024)
        _ = try await cache.read(driveID: id, revision: "rev", offset: 96 * 1024, length: 32 * 1024, backend: backend)
        #expect(await backend.calls == 2)
    }

    @Test func evictsMemoryAndDiskToTheBounds() async throws {
        let directory = try scratchDirectory("evict")
        let backend = ScriptedDrive { range in
            let length = range?.length ?? 0
            return DriveContent(
                bytes: Data(repeating: 6, count: length),
                offset: range?.offset ?? 0,
                totalSize: nil
            )
        }
        let memoryLimit = 32 * 1024
        let diskLimit = 64 * 1024
        let cache = try BoundedContentCache(
            bounds: CacheBounds(memoryByteLimit: memoryLimit, diskByteLimit: diskLimit),
            directory: directory,
            blockSize: 32 * 1024
        )
        for name in ["a", "b", "c"] {
            _ = try await cache.read(
                driveID: DriveID(rawValue: name),
                revision: "rev",
                offset: 0,
                length: 32 * 1024,
                backend: backend
            )
            #expect(await cache.residentByteCount <= memoryLimit)
            #expect(await cache.diskByteCount <= diskLimit)
            #expect(try directoryBytes(directory) <= diskLimit)
        }
        let downloadsBefore = await backend.callsByID
        _ = try await cache.read(driveID: DriveID(rawValue: "c"), revision: "rev", offset: 0, length: 32 * 1024, backend: backend)
        _ = try await cache.read(driveID: DriveID(rawValue: "b"), revision: "rev", offset: 0, length: 32 * 1024, backend: backend)
        _ = try await cache.read(driveID: DriveID(rawValue: "a"), revision: "rev", offset: 0, length: 32 * 1024, backend: backend)
        let downloadsAfter = await backend.callsByID
        #expect(downloadsAfter["a"] == (downloadsBefore["a"] ?? 0) + 1)
        #expect(downloadsAfter["c"] == downloadsBefore["c"])
        #expect(downloadsAfter["b"] == downloadsBefore["b"])
        #expect(await cache.residentByteCount <= memoryLimit)
        #expect(await cache.diskByteCount <= diskLimit)
    }

    @Test func cancellationThrowsAndDoesNotCache() async throws {
        let directory = try scratchDirectory("cancel")
        let gate = Gate()
        let backend = ScriptedDrive { range in
            let length = range?.length ?? 0
            return DriveContent(bytes: Data(repeating: 1, count: length), offset: range?.offset ?? 0, totalSize: nil)
        }
        await backend.armCancellation(gate)
        let cache = try BoundedContentCache(
            bounds: CacheBounds(memoryByteLimit: 64 * 1024, diskByteLimit: 64 * 1024),
            directory: directory
        )
        let task = Task {
            try await cache.read(
                driveID: DriveID(rawValue: "file"),
                revision: "rev",
                offset: 0,
                length: 1024,
                backend: backend
            )
        }
        await gate.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await cache.residentByteCount == 0)
        #expect(await cache.diskByteCount == 0)
        await backend.disarmCancellation()
        let data = try await cache.read(
            driveID: DriveID(rawValue: "file"),
            revision: "rev",
            offset: 0,
            length: 1024,
            backend: backend
        )
        #expect(data.count == 1024)
        #expect(await backend.calls == 2)
    }

    @Test func partialDownloadContinuesWithoutReadingTheRemoteSize() async throws {
        let directory = try scratchDirectory("partial")
        let backend = ScriptedDrive { range in
            let offset = range?.offset ?? 0
            let length = range?.length ?? 0
            if offset == 0 {
                let count = min(8_192, length)
                return DriveContent(
                    bytes: Data(repeating: 1, count: count),
                    offset: offset,
                    totalSize: 5 << 30
                )
            }
            return DriveContent(
                bytes: Data(repeating: 2, count: length),
                offset: offset,
                totalSize: 5 << 30
            )
        }
        let cache = try BoundedContentCache(
            bounds: CacheBounds(memoryByteLimit: 128 * 1024, diskByteLimit: 128 * 1024),
            directory: directory,
            blockSize: 64 * 1024
        )
        let data = try await cache.read(
            driveID: DriveID(rawValue: "file"),
            revision: "rev",
            offset: 0,
            length: 64 * 1024,
            backend: backend
        )
        #expect(data.count == 64 * 1024)
        #expect(data.prefix(8_192) == Data(repeating: 1, count: 8_192))
        #expect(data.dropFirst(8_192) == Data(repeating: 2, count: 64 * 1024 - 8_192))
        #expect(await backend.calls == 2)
        let ranges = await backend.ranges
        #expect(ranges[0] == ByteRange(offset: 0, length: 64 * 1024))
        #expect(ranges[1] == ByteRange(offset: 8_192, length: 64 * 1024 - 8_192))
        #expect(await backend.maxAllocation <= 64 * 1024)
        _ = try await cache.read(driveID: DriveID(rawValue: "file"), revision: "rev", offset: 0, length: 64 * 1024, backend: backend)
        #expect(await backend.calls == 2)
    }

    @Test func randomReadOfLargeFileDoesNotRetainTheRemoteSize() async throws {
        let directory = try scratchDirectory("large")
        let window = 64 * 1024
        let offset = Int64(window) * 4096
        let total = Int64(1) << 40
        let backend = ScriptedDrive { range in
            guard let range, range.offset == offset, range.length == window else {
                throw CacheFault.unbounded
            }
            return DriveContent(
                bytes: Data(repeating: 9, count: window),
                offset: range.offset,
                totalSize: total
            )
        }
        let cache = try BoundedContentCache(
            bounds: CacheBounds(memoryByteLimit: window, diskByteLimit: window),
            directory: directory,
            blockSize: window
        )
        let data = try await cache.read(
            driveID: DriveID(rawValue: "huge"),
            revision: "rev",
            offset: offset,
            length: window,
            backend: backend
        )
        #expect(data == Data(repeating: 9, count: window))
        #expect(await backend.calls == 1)
        #expect(await backend.maxAllocation == window)
        #expect(await cache.residentByteCount <= window)
        #expect(await cache.diskByteCount <= window)
        #expect(try directoryBytes(directory) <= window)
        #expect(Int64(await cache.residentByteCount) < total)
    }
}

private enum CacheFault: Error, Equatable {
    case unsupported
    case unbounded
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    func wait() async {
        await withCheckedContinuation { continuation in
            self.lock.lock()
            if self.opened {
                self.lock.unlock()
                continuation.resume()
                return
            }
            self.continuations.append(continuation)
            self.lock.unlock()
        }
    }

    func openGate() {
        lock.lock()
        opened = true
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor ScriptedDrive: DriveBackend {
    private let body: @Sendable (ByteRange?) async throws -> DriveContent
    private(set) var calls = 0
    private(set) var callsByID: [String: Int] = [:]
    private(set) var ranges: [ByteRange] = []
    private(set) var maxAllocation = 0
    private var cancelGate: Gate?

    init(_ body: @escaping @Sendable (ByteRange?) async throws -> DriveContent) {
        self.body = body
    }

    func armCancellation(_ gate: Gate) {
        cancelGate = gate
    }

    func disarmCancellation() {
        cancelGate = nil
    }

    func downloadContent(id: DriveID, range: ByteRange?) async throws -> DriveContent {
        calls += 1
        callsByID[id.rawValue, default: 0] += 1
        if let range {
            ranges.append(range)
        }
        if let cancelGate {
            cancelGate.openGate()
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let content = try await body(range)
        maxAllocation = max(maxAllocation, content.bytes.count)
        return content
    }

    func listFiles(query: String?, pageToken: String?, pageSize: Int?) async throws -> DriveFilePage {
        throw CacheFault.unsupported
    }

    func getFile(id: DriveID) async throws -> DriveFile {
        throw CacheFault.unsupported
    }

    func createFile(metadata: DriveFileCreate) async throws -> DriveFile {
        throw CacheFault.unsupported
    }

    func updateFile(id: DriveID, metadata: DriveFileUpdate) async throws -> DriveFile {
        throw CacheFault.unsupported
    }

    func deleteFile(id: DriveID) async throws {
        throw CacheFault.unsupported
    }

    func exportFile(id: DriveID, mimeType: String) async throws -> Data {
        throw CacheFault.unsupported
    }

    func multipartUpload(_ intent: MultipartUploadIntent) async throws -> DriveFile {
        throw CacheFault.unsupported
    }

    func startResumableUpload(_ intent: ResumableUploadIntent) async throws -> ResumableUploadSession {
        throw CacheFault.unsupported
    }

    func resumeUpload(session: ResumableUploadSession, chunk: DriveUploadChunk) async throws -> ResumableUploadProgress {
        throw CacheFault.unsupported
    }

    func startPageToken() async throws -> String {
        throw CacheFault.unsupported
    }

    func listChanges(pageToken: String, pageSize: Int?) async throws -> DriveChangePage {
        throw CacheFault.unsupported
    }

    func about() async throws -> DriveAbout {
        throw CacheFault.unsupported
    }

    func refreshCredential() async throws {
        throw CacheFault.unsupported
    }
}

private func scratchDirectory(_ name: String) throws -> URL {
    let root = URL(fileURLWithPath: "/Users/josh/d/gcsf/.work/tmp/c", isDirectory: true)
    let directory = root.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func directoryBytes(_ url: URL) throws -> Int {
    let files = try FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
    )
    var total = 0
    for file in files {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if values.isRegularFile == true {
            total += values.fileSize ?? 0
        }
    }
    return total
}
