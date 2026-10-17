import Foundation

public enum LiveSession {
    public static func production(session: String, tokens: any RefreshTokenStore) -> any FileSystemEngine {
        SessionFront {
            try await openProduction(session: session, tokens: tokens)
        }
    }

    public static func make(
        session: String,
        container: URL,
        tokens: any RefreshTokenStore,
        backend: any DriveBackend
    ) async throws -> GCSFEngine {
        let settings = try loadSettings(container)
        try await requireToken(session: session, tokens: tokens)
        return try await assemble(container: container, settings: settings, backend: backend)
    }

    private static func openProduction(session: String, tokens: any RefreshTokenStore) async throws -> GCSFEngine {
        let container = RuntimeBoundary.groupContainerURL(home: FileManager.default.homeDirectoryForCurrentUser)
        let settings = try loadSettings(container)
        try await requireToken(session: session, tokens: tokens)
        guard let document = settings.clientSecret, !document.isEmpty else {
            throw POSIXError(.ENXIO)
        }
        let client: OAuthClient
        do {
            client = try OAuthClient(document: document)
        } catch {
            throw POSIXError(.ENXIO)
        }
        let manager = TokenManager(client: client, tokenEndpoint: OAuthDrive.tokenEndpoint, tokens: tokens)
        let backend = DriveClient(bearerToken: "", refresh: {
            let access = try await manager.refresh(session: session)
            return access.accessToken
        })
        return try await assemble(container: container, settings: settings, backend: backend)
    }

    private static func loadSettings(_ container: URL) throws -> DriveSettings {
        do {
            return try DriveSettingsStore.load(container: container)
        } catch DriveSettingsError.missing {
            throw POSIXError(.ENXIO)
        }
    }

    private static func requireToken(session: String, tokens: any RefreshTokenStore) async throws {
        let token = try await tokens.load(session: session)
        guard let token, !token.isEmpty else {
            throw POSIXError(.ENXIO)
        }
    }

    private static func assemble(
        container: URL,
        settings: DriveSettings,
        backend: any DriveBackend
    ) async throws -> GCSFEngine {
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let store = try SQLiteMetadataStore(path: ContainerFiles.index(container).path)
        let staging = ContainerFiles.staged(container)
        let journal = try SQLiteWritebackJournal(
            path: ContainerFiles.journal(container).path,
            stagingDirectory: staging,
            metadata: store,
            backend: backend
        )
        let configuration = EngineConfiguration(
            renameIdenticalFiles: settings.renameIdenticalFiles,
            addExtensionsToSpecialFiles: settings.addExtensionsToSpecialFiles,
            readOnly: settings.readOnly,
            skipTrash: settings.skipTrash
        )
        return GCSFEngine(
            store: store,
            drive: backend,
            configuration: configuration,
            journal: journal,
            stagedDirectory: staging
        )
    }
}

private actor SessionFront: FileSystemEngine {
    private let load: @Sendable () async throws -> GCSFEngine
    private var loaded: GCSFEngine?
    private var opening: Task<GCSFEngine, Error>?

    init(_ load: @escaping @Sendable () async throws -> GCSFEngine) {
        self.load = load
    }

    func lookup(named name: String, in parent: Inode) async throws -> EngineItem {
        try await ready().lookup(named: name, in: parent)
    }

    func attributes(_ inode: Inode) async throws -> EngineAttributes {
        try await ready().attributes(inode)
    }

    func xattr(named name: String, of inode: Inode) async throws -> Data {
        try await ready().xattr(named: name, of: inode)
    }

    func setXattr(named name: String, value: Data?, of inode: Inode) async throws {
        try await ready().setXattr(named: name, value: value, of: inode)
    }

    func xattrNames(of inode: Inode) async throws -> [String] {
        try await ready().xattrNames(of: inode)
    }

    func enumerate(directory: Inode, startingAt cookie: EngineDirectoryCookie) async throws -> EngineEnumeration {
        try await ready().enumerate(directory: directory, startingAt: cookie)
    }

    func create(named name: String, kind: EngineItemKind, in parent: Inode) async throws -> EngineItem {
        try await ready().create(named: name, kind: kind, in: parent)
    }

    func rename(
        _ inode: Inode,
        fromParent: Inode,
        fromName: String,
        toParent: Inode,
        toName: String,
        replacing: Inode?
    ) async throws -> EngineItem {
        try await ready().rename(
            inode,
            fromParent: fromParent,
            fromName: fromName,
            toParent: toParent,
            toName: toName,
            replacing: replacing
        )
    }

    func remove(_ inode: Inode, named name: String, from parent: Inode) async throws {
        try await ready().remove(inode, named: name, from: parent)
    }

    func readlink(_ inode: Inode) async throws -> String {
        try await ready().readlink(inode)
    }

    func read(_ inode: Inode, at offset: Int64, length: Int) async throws -> Data {
        try await ready().read(inode, at: offset, length: length)
    }

    func write(_ inode: Inode, bytes: Data, at offset: Int64) async throws -> Int {
        try await ready().write(inode, bytes: bytes, at: offset)
    }

    func truncate(_ inode: Inode, to length: Int64) async throws {
        try await ready().truncate(inode, to: length)
    }

    func synchronize() async throws {
        try await ready().synchronize()
    }

    private func ready() async throws -> GCSFEngine {
        if let loaded {
            return loaded
        }
        if let opening {
            return try await opening.value
        }
        let load = self.load
        let task = Task { try await load() }
        opening = task
        do {
            let created = try await task.value
            loaded = created
            opening = nil
            return created
        } catch {
            opening = nil
            throw error
        }
    }
}
