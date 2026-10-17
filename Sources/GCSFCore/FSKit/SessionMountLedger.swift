import Foundation

public struct SessionMountLedger: Sendable {
    public let directory: URL

    public init(home: URL) {
        directory = RuntimeBoundary.groupContainerURL(home: home)
    }

    public func url(for session: String) throws -> URL? {
        let stored = try load()
        guard let text = stored[session] else { return nil }
        guard let url = URL(string: text) else {
            throw POSIXError(.EINVAL)
        }
        return url
    }

    public func store(_ url: URL, for session: String) throws {
        var stored = try load()
        stored[session] = url.absoluteString
        try save(stored)
    }

    public func remove(_ session: String) throws {
        var stored = try load()
        stored.removeValue(forKey: session)
        try save(stored)
    }

    private var file: URL {
        directory.appending(path: "mount-urls.json")
    }

    private func load() throws -> [String: String] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.path) else { return [:] }
        let data = try Data(contentsOf: file)
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private func save(_ stored: [String: String]) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(stored)
        try data.write(to: file, options: .atomic)
    }
}
