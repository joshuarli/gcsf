import Foundation
import FSKit
import Synchronization

public final class GCSFFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations, @unchecked Sendable {
    public typealias EngineFactory = @Sendable (String) -> any FileSystemEngine

    private let makeEngine: EngineFactory
    private let volumes = Mutex<[String: GCSFVolume]>([:])

    public init(makeEngine: @escaping EngineFactory) {
        self.makeEngine = makeEngine
        super.init()
    }

    public func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        let once = OnceReply<(FSProbeResult?, (any Error)?)>()
        let result: FSProbeResult
        if let resource = resource as? FSGenericURLResource, let session = DriveVolumeAddress.session(from: resource.url) {
            result = FSProbeResult.usable(name: session, containerID: FSContainerIdentifier(uuid: UUID()))
        } else {
            result = FSProbeResult.notRecognized
        }
        once.send((result, nil), replyHandler)
    }

    public func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        let once = OnceReply<(FSVolume?, (any Error)?)>()
        nonisolated(unsafe) let reply = replyHandler
        nonisolated(unsafe) let loaded = resource
        nonisolated(unsafe) let loadedOptions = options
        Task.detached {
            do {
                let volume = try self.volume(for: loaded, options: loadedOptions)
                once.send((volume, nil), reply)
            } catch {
                once.send((nil, error), reply)
            }
        }
    }

    public func unloadResource(resource: FSResource, options: FSTaskOptions) async throws {
        guard let resource = resource as? FSGenericURLResource, let session = DriveVolumeAddress.session(from: resource.url) else {
            return
        }
        let volume = volumes.withLock { $0.removeValue(forKey: session) }
        await volume?.unmount()
    }

    func volume(for resource: FSResource, options: FSTaskOptions) throws -> GCSFVolume {
        guard let resource = resource as? FSGenericURLResource else { throw POSIXError(.EINVAL) }
        guard let session = DriveVolumeAddress.session(from: resource.url) else { throw POSIXError(.EINVAL) }
        if let existing = volumes.withLock({ $0[session] }) {
            return existing
        }
        let readOnly = options.taskOptions.contains("--rdonly")
        let created = GCSFVolume(session: session, engine: makeEngine(session), readOnly: readOnly)
        return volumes.withLock { volumes in
            if let existing = volumes[session] { return existing }
            volumes[session] = created
            return created
        }
    }
}
