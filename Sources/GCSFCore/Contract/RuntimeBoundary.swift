import Foundation

public enum RuntimeBoundary {
    public static let sharedGroupIdentifier = "group.com.joshuarli.gcsf"
    public static let keychainService = "com.joshuarli.gcsf"
    public static let configFileName = "config.json"
    public static let indexFileName = "index.sqlite"
    public static let journalFileName = "writeback-journal.sqlite"
    public static let stagedDirectoryName = "staged"
    public static let cacheDirectoryName = "cache"

    public static func groupContainerURL(home: URL) -> URL {
        home
            .appending(path: "Library/Group Containers", directoryHint: .isDirectory)
            .appending(path: sharedGroupIdentifier, directoryHint: .isDirectory)
    }
}
