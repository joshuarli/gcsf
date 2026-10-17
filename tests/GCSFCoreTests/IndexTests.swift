import Foundation
import SQLite3
import Testing
import GCSFCore

@Suite struct IndexTests {
    @Test func restartKeepsInodesNamesSuffixesAndDriveIDs() async throws {
        let path = try scratchPath("restart")
        let original = sample(inode: 4, driveID: "drive-4", parent: 1, name: "Notes", suffix: "kept")
        do {
            let store = try SQLiteMetadataStore(path: path)
            try await store.insert(original)
        }
        let store = try SQLiteMetadataStore(path: path)
        let loaded = try await store.record(inode: original.inode)
        #expect(loaded == original)
        #expect(try await store.record(driveID: DriveID(rawValue: "drive-4")) == original)
    }

    @Test func reservedDirectoriesKeepInodesAcrossRestart() async throws {
        let path = try scratchPath("reserved")
        do {
            let store = try SQLiteMetadataStore(path: path)
            try await expectReserved(store)
        }
        let store = try SQLiteMetadataStore(path: path)
        try await expectReserved(store)
        let root = try #require(try await store.record(inode: Inode(rawValue: 1)))
        #expect(root.driveID == nil)
        #expect(root.parent == nil)
        let trash = try #require(try await store.record(inode: Inode(rawValue: 2)))
        #expect(trash.driveID == nil)
        #expect(trash.parent == Inode(rawValue: 1))
        let shared = try #require(try await store.record(inode: Inode(rawValue: 3)))
        #expect(shared.driveID == nil)
        #expect(shared.parent == Inode(rawValue: 1))
    }

    @Test func secondInsertDoesNotChangeExistingSuffix() async throws {
        let path = try scratchPath("suffix")
        let store = try SQLiteMetadataStore(path: path)
        let first = sample(inode: 4, driveID: "drive-4", parent: 1, name: "Report", suffix: "kept")
        try await store.insert(first)
        try await store.insert(sample(inode: 5, driveID: "drive-5", parent: 1, name: "Report", suffix: "other"))
        #expect(try await store.record(inode: first.inode)?.assignedDuplicateSuffix == "kept")
        let reopened = try SQLiteMetadataStore(path: path)
        #expect(try await reopened.record(inode: first.inode)?.assignedDuplicateSuffix == "kept")
        #expect(try await reopened.record(inode: Inode(rawValue: 5))?.assignedDuplicateSuffix == "other")
    }

    @Test func duplicateDriveIDOnInsertThrows() async throws {
        let path = try scratchPath("duplicate-drive")
        let store = try SQLiteMetadataStore(path: path)
        let first = sample(inode: 4, driveID: "drive-4", parent: 1, name: "Report", suffix: "kept")
        try await store.insert(first)
        let second = sample(inode: 8, driveID: "drive-4", parent: 1, name: "Copy", suffix: "nope")
        await #expect(throws: MetadataStoreError.duplicateDriveID(DriveID(rawValue: "drive-4"))) {
            try await store.insert(second)
        }
        #expect(try await store.record(inode: first.inode) == first)
        #expect(try await store.record(inode: second.inode) == nil)
        #expect(try await store.record(driveID: DriveID(rawValue: "drive-4"))?.inode == first.inode)
        #expect(try await store.allocateInode() == Inode(rawValue: 5))
    }

    @Test func deleteRemovesLookupByInodeAndDriveID() async throws {
        let path = try scratchPath("delete")
        let store = try SQLiteMetadataStore(path: path)
        let record = sample(inode: 4, driveID: "drive-4", parent: 1, name: "Gone", suffix: "kept")
        try await store.insert(record)
        try await store.remove(inode: record.inode)
        #expect(try await store.record(inode: record.inode) == nil)
        #expect(try await store.record(driveID: DriveID(rawValue: "drive-4")) == nil)
        let reopened = try SQLiteMetadataStore(path: path)
        #expect(try await reopened.record(inode: record.inode) == nil)
        #expect(try await reopened.record(driveID: DriveID(rawValue: "drive-4")) == nil)
    }

    @Test func childLookupUsesParentAndBaseName() async throws {
        let path = try scratchPath("children")
        let store = try SQLiteMetadataStore(path: path)
        try await store.insert(sample(inode: 9, driveID: "later", parent: 1, name: "Same", suffix: "zzz"))
        try await store.insert(sample(inode: 6, driveID: "earlier", parent: 1, name: "Same", suffix: "aaa"))
        try await store.insert(sample(inode: 7, driveID: "other", parent: 3, name: "Other", suffix: nil))
        let children = try await store.children(of: Inode(rawValue: 1))
        #expect(children.map(\.inode.rawValue) == [2, 3, 6, 9])
        let found = try await store.child(of: Inode(rawValue: 1), name: "Same")
        #expect(found?.inode == Inode(rawValue: 6))
        #expect(found?.assignedDuplicateSuffix == "aaa")
        #expect(try await store.child(of: Inode(rawValue: 1), name: "aaa") == nil)
        #expect(try await store.child(of: Inode(rawValue: 1), name: "Samezzz") == nil)
        #expect(try await store.child(of: Inode(rawValue: 3), name: "Other")?.inode == Inode(rawValue: 7))
        #expect(try await store.child(of: Inode(rawValue: 1), name: "Other") == nil)
    }

    @Test func attributesRoundTrip() async throws {
        let path = try scratchPath("round-trip")
        let store = try SQLiteMetadataStore(path: path)
        var record = sample(inode: 4, driveID: "drive-4", parent: 1, name: "Notes", suffix: "kept")
        try await store.insert(record)
        #expect(try await store.record(inode: record.inode) == record)
        record.size = 99
        record.trashed = false
        record.sha256 = nil
        record.md5 = "md5-next"
        record.owner = nil
        record.webLink = "https://example.com/next"
        record.headRevision = "rev-2"
        record.modified = Date(timeIntervalSince1970: 1_800_000_000.25)
        record.created = nil
        record.assignedDuplicateSuffix = "kept"
        for state in DurabilityState.allCases {
            record.durability = state
            try await store.update(record)
            #expect(try await store.record(inode: record.inode) == record)
        }
    }

    @Test func failedUpdateLeavesTheRowInPlace() async throws {
        let path = try scratchPath("update")
        let store = try SQLiteMetadataStore(path: path)
        let first = sample(inode: 4, driveID: "drive-4", parent: 1, name: "One", suffix: "a")
        let second = sample(inode: 5, driveID: "drive-5", parent: 1, name: "Two", suffix: "kept")
        try await store.insert(first)
        try await store.insert(second)
        var edited = second
        edited.driveID = first.driveID
        edited.assignedDuplicateSuffix = "changed"
        edited.name = "Renamed"
        await #expect(throws: MetadataStoreError.duplicateDriveID(DriveID(rawValue: "drive-4"))) {
            try await store.update(edited)
        }
        #expect(try await store.record(inode: second.inode) == second)
        #expect(try await store.record(driveID: DriveID(rawValue: "drive-5")) == second)
    }

    @Test func deletedInodeIsNotReusedUntilRestart() async throws {
        let path = try scratchPath("reuse")
        do {
            let store = try SQLiteMetadataStore(path: path)
            #expect(try await store.allocateInode() == Inode(rawValue: 4))
            try await store.insert(sample(inode: 4, driveID: "drive-4", parent: 1, name: "Short", suffix: nil))
            try await store.remove(inode: Inode(rawValue: 4))
            #expect(try await store.allocateInode() == Inode(rawValue: 5))
            await #expect(throws: MetadataStoreError.retiredInode(Inode(rawValue: 4))) {
                try await store.insert(sample(inode: 4, driveID: "drive-4b", parent: 1, name: "Again", suffix: nil))
            }
            try await store.insert(sample(inode: 9, driveID: "drive-9", parent: 1, name: "High", suffix: "kept"))
            #expect(try await store.allocateInode() == Inode(rawValue: 10))
        }
        var database: OpaquePointer?
        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        #expect(
            sqlite3_exec(
                database,
                "UPDATE meta SET value = 4 WHERE key = 'next_inode'",
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )
        sqlite3_close(database)
        let store = try SQLiteMetadataStore(path: path)
        #expect(try await store.allocateInode() == Inode(rawValue: 10))
        let restored = try await store.record(inode: Inode(rawValue: 9))
        #expect(restored?.name == "High")
        #expect(restored?.assignedDuplicateSuffix == "kept")
        try await store.insert(sample(inode: 4, driveID: "drive-4c", parent: 1, name: "After", suffix: "fresh"))
        #expect(try await store.record(inode: Inode(rawValue: 4))?.assignedDuplicateSuffix == "fresh")
    }

    @Test func missingColumnFailsOpen() throws {
        let path = try scratchPath("missing-column")
        var database: OpaquePointer?
        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        let sql = """
        PRAGMA user_version = 1;
        CREATE TABLE meta (
            key TEXT PRIMARY KEY NOT NULL,
            value INTEGER NOT NULL
        );
        INSERT INTO meta(key, value) VALUES ('next_inode', 4);
        CREATE TABLE nodes (
            inode INTEGER PRIMARY KEY NOT NULL,
            drive_id TEXT,
            parent INTEGER,
            name TEXT NOT NULL,
            assigned_duplicate_suffix TEXT,
            mime_type TEXT NOT NULL,
            size INTEGER NOT NULL,
            created INTEGER,
            modified INTEGER,
            head_revision TEXT,
            md5 TEXT,
            sha1 TEXT,
            owner TEXT,
            web_link TEXT,
            durability TEXT NOT NULL,
            trashed INTEGER NOT NULL
        );
        CREATE UNIQUE INDEX nodes_drive_id ON nodes(drive_id);
        """
        #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        #expect(throws: MetadataStoreError.self) {
            _ = try SQLiteMetadataStore(path: path)
        }
    }
}

private func expectReserved(_ store: SQLiteMetadataStore) async throws {
    let root = try #require(try await store.record(inode: Inode(rawValue: 1)))
    let trash = try #require(try await store.record(inode: Inode(rawValue: 2)))
    let shared = try #require(try await store.record(inode: Inode(rawValue: 3)))
    #expect(root.name == "My Drive")
    #expect(trash.name == "Trash")
    #expect(shared.name == "Shared with me")
    #expect(root.inode == Inode(rawValue: 1))
    #expect(trash.inode == Inode(rawValue: 2))
    #expect(shared.inode == Inode(rawValue: 3))
}

private func sample(
    inode: UInt64,
    driveID: String?,
    parent: UInt64?,
    name: String,
    suffix: String?
) -> MetadataRecord {
    MetadataRecord(
        inode: Inode(rawValue: inode),
        driveID: driveID.map { DriveID(rawValue: $0) },
        parent: parent.map { Inode(rawValue: $0) },
        name: name,
        assignedDuplicateSuffix: suffix,
        mimeType: "text/plain",
        size: 42,
        created: Date(timeIntervalSince1970: 1_700_000_000.125),
        modified: Date(timeIntervalSince1970: 1_700_000_100.5),
        headRevision: "rev-1",
        md5: "md5",
        sha1: "sha1",
        sha256: "sha256",
        owner: "owner@example.com",
        webLink: "https://example.com/file",
        durability: .journaled,
        trashed: true
    )
}

private func scratchPath(_ name: String) throws -> String {
    let directory = URL(fileURLWithPath: "/Users/josh/d/gcsf/.work/tmp/e1", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "\(name)-\(UUID().uuidString).sqlite").path
}
