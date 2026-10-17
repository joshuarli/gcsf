import Foundation
import SQLite3

public actor SQLiteMetadataStore: MetadataStore {
    private let database: SQLiteMetadataDatabase

    public init(path: String) throws {
        self.database = try SQLiteMetadataDatabase(path: path)
    }

    public func record(inode: Inode) throws -> MetadataRecord? {
        try database.record(inode: inode)
    }

    public func record(driveID: DriveID) throws -> MetadataRecord? {
        try database.record(driveID: driveID)
    }

    public func child(of parent: Inode, name: String) throws -> MetadataRecord? {
        try database.child(of: parent, name: name)
    }

    public func children(of parent: Inode) throws -> [MetadataRecord] {
        try database.children(of: parent)
    }

    public func insert(_ record: MetadataRecord) throws {
        try database.insert(record)
    }

    public func update(_ record: MetadataRecord) throws {
        try database.update(record)
    }

    public func remove(inode: Inode) throws {
        try database.remove(inode: inode)
    }

    public func allocateInode() throws -> Inode {
        try database.allocateInode()
    }
}

private final class SQLiteMetadataDatabase: @unchecked Sendable {
    private static let transient: sqlite3_destructor_type = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )
    private static let constraintPrimaryKey: Int32 = SQLITE_CONSTRAINT | (6 << 8)
    private static let constraintUnique: Int32 = SQLITE_CONSTRAINT | (8 << 8)
    private static let folderMime = "application/vnd.google-apps.folder"
    private static let columns = """
    inode, drive_id, parent, name, assigned_duplicate_suffix, mime_type, size, \
    created, modified, head_revision, md5, sha1, sha256, owner, web_link, \
    durability, trashed
    """
    private static let requiredColumns: [(name: String, type: String, notNull: Bool)] = [
        ("inode", "INTEGER", true),
        ("drive_id", "TEXT", false),
        ("parent", "INTEGER", false),
        ("name", "TEXT", true),
        ("assigned_duplicate_suffix", "TEXT", false),
        ("mime_type", "TEXT", true),
        ("size", "INTEGER", true),
        ("created", "INTEGER", false),
        ("modified", "INTEGER", false),
        ("head_revision", "TEXT", false),
        ("md5", "TEXT", false),
        ("sha1", "TEXT", false),
        ("sha256", "TEXT", false),
        ("owner", "TEXT", false),
        ("web_link", "TEXT", false),
        ("durability", "TEXT", true),
        ("trashed", "INTEGER", true),
    ]

    private var pointer: OpaquePointer?
    private var retired: Set<UInt64> = []

    init(path: String) throws {
        let existed = FileManager.default.fileExists(atPath: path)
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(path, &opened, flags, nil)
        guard code == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let opened {
                sqlite3_close(opened)
            }
            if !existed {
                try? FileManager.default.removeItem(atPath: path)
            }
            throw MetadataStoreError.sqlite(code: code, message: message)
        }
        pointer = opened
        sqlite3_extended_result_codes(opened, 1)
        sqlite3_busy_timeout(opened, 5_000)
        do {
            if existed {
                try verifySchema()
            } else {
                try createSchema()
                try transaction {
                    try insertRow(reserved(1, "My Drive", nil))
                    try insertRow(reserved(2, "Trash", 1))
                    try insertRow(reserved(3, "Shared with me", 1))
                }
            }
            try transaction {
                try reconcileCounter()
            }
            try validateRows()
        } catch {
            sqlite3_close(opened)
            pointer = nil
            if !existed {
                try? FileManager.default.removeItem(atPath: path)
            }
            throw error
        }
    }

    deinit {
        if let pointer {
            sqlite3_close(pointer)
        }
    }

    func record(inode: Inode) throws -> MetadataRecord? {
        let stored = try storageInode(inode)
        return try queryOne(
            "SELECT \(Self.columns) FROM nodes WHERE inode = ?",
            bind: { try self.bindInt($0, 1, stored) }
        )
    }

    func record(driveID: DriveID) throws -> MetadataRecord? {
        try queryOne(
            "SELECT \(Self.columns) FROM nodes WHERE drive_id = ?",
            bind: { try self.bindText($0, 1, driveID.rawValue) }
        )
    }

    func child(of parent: Inode, name: String) throws -> MetadataRecord? {
        let stored = try storageInode(parent)
        return try queryOne(
            """
            SELECT \(Self.columns) FROM nodes
            WHERE parent = ? AND name = ?
            ORDER BY inode ASC
            LIMIT 1
            """,
            bind: {
                try self.bindInt($0, 1, stored)
                try self.bindText($0, 2, name)
            }
        )
    }

    func children(of parent: Inode) throws -> [MetadataRecord] {
        let stored = try storageInode(parent)
        return try query(
            """
            SELECT \(Self.columns) FROM nodes
            WHERE parent = ?
            ORDER BY inode ASC
            """,
            bind: { try self.bindInt($0, 1, stored) }
        )
    }

    func insert(_ record: MetadataRecord) throws {
        let inode = try storageInode(record.inode)
        try transaction {
            if retired.contains(record.inode.rawValue) {
                throw MetadataStoreError.retiredInode(record.inode)
            }
            if try rowExists(inode) {
                throw MetadataStoreError.duplicateInode(record.inode)
            }
            try observe(inode)
            try insertRow(record)
        }
    }

    func update(_ record: MetadataRecord) throws {
        let inode = try storageInode(record.inode)
        try transaction {
            guard try rowExists(inode) else {
                throw MetadataStoreError.missingRecord(record.inode)
            }
            try updateRow(record)
        }
    }

    func remove(inode: Inode) throws {
        let stored = try storageInode(inode)
        let deleted = try transaction { () -> Bool in
            guard try rowExists(stored) else { return false }
            try run(
                "DELETE FROM nodes WHERE inode = ?",
                bind: { try self.bindInt($0, 1, stored) }
            )
            return true
        }
        if deleted {
            retired.insert(inode.rawValue)
        }
    }

    func allocateInode() throws -> Inode {
        try transaction {
            let current = try counter()
            guard current < Int64.max else {
                throw MetadataStoreError.schema("meta.next_inode")
            }
            try setCounter(current + 1)
            return Inode(rawValue: UInt64(current))
        }
    }

    private func createSchema() throws {
        try exec(
            """
            PRAGMA user_version = 1;
            CREATE TABLE meta (
                key TEXT PRIMARY KEY NOT NULL,
                value INTEGER NOT NULL
            ) STRICT;
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
                sha256 TEXT,
                owner TEXT,
                web_link TEXT,
                durability TEXT NOT NULL,
                trashed INTEGER NOT NULL,
                CHECK (trashed IN (0, 1))
            ) STRICT;
            CREATE UNIQUE INDEX nodes_drive_id ON nodes(drive_id);
            CREATE INDEX nodes_parent ON nodes(parent, inode);
            INSERT INTO meta(key, value) VALUES ('next_inode', 4);
            """
        )
    }

    private func verifySchema() throws {
        let version = try singleInt("PRAGMA user_version")
        guard version == 1 else {
            throw MetadataStoreError.schema("user_version")
        }
        let nodes = try tableInfo("nodes")
        guard nodes.contains(where: { $0.name == "inode" && $0.primaryKey == 1 }) else {
            throw MetadataStoreError.schema("nodes.inode")
        }
        guard nodes.allSatisfy({ $0.primaryKey == 0 || $0.name == "inode" }) else {
            throw MetadataStoreError.schema("nodes.inode")
        }
        for column in Self.requiredColumns {
            guard let found = nodes.first(where: { $0.name == column.name }) else {
                throw MetadataStoreError.schema("nodes.\(column.name)")
            }
            guard found.type.caseInsensitiveCompare(column.type) == .orderedSame else {
                throw MetadataStoreError.schema("nodes.\(column.name)")
            }
            guard found.notNull == column.notNull else {
                throw MetadataStoreError.schema("nodes.\(column.name)")
            }
        }
        let meta = try tableInfo("meta")
        guard meta.contains(where: { $0.name == "key" && $0.type.caseInsensitiveCompare("TEXT") == .orderedSame && $0.notNull }) else {
            throw MetadataStoreError.schema("meta.key")
        }
        guard meta.contains(where: { $0.name == "value" && $0.type.caseInsensitiveCompare("INTEGER") == .orderedSame && $0.notNull }) else {
            throw MetadataStoreError.schema("meta.value")
        }
        guard try driveIDIsUnique() else {
            throw MetadataStoreError.schema("nodes.drive_id")
        }
    }

    private func validateRows() throws {
        try forEach("SELECT durability, trashed FROM nodes") { statement in
            guard let raw = self.text(statement, 0), DurabilityState(rawValue: raw) != nil else {
                throw MetadataStoreError.invalidRow("durability")
            }
            guard sqlite3_column_type(statement, 1) == SQLITE_INTEGER else {
                throw MetadataStoreError.invalidRow("trashed")
            }
            let trashed = sqlite3_column_int64(statement, 1)
            guard trashed == 0 || trashed == 1 else {
                throw MetadataStoreError.invalidRow("trashed")
            }
        }
    }

    private func reconcileCounter() throws {
        guard try singleInt("SELECT value FROM meta WHERE key = 'next_inode'") != nil else {
            throw MetadataStoreError.schema("meta.next_inode")
        }
        let stored = try counter()
        guard let maxInode = try singleInt("SELECT MAX(inode) FROM nodes") else {
            if stored < 4 {
                try setCounter(4)
            }
            return
        }
        guard maxInode < Int64.max else {
            throw MetadataStoreError.schema("nodes.inode")
        }
        let floor = max(stored, maxInode + 1, Int64(4))
        if floor != stored {
            try setCounter(floor)
        }
    }

    private func reserved(_ inode: Int64, _ name: String, _ parent: Int64?) -> MetadataRecord {
        MetadataRecord(
            inode: Inode(rawValue: UInt64(inode)),
            driveID: nil,
            parent: parent.map { Inode(rawValue: UInt64($0)) },
            name: name,
            assignedDuplicateSuffix: nil,
            mimeType: Self.folderMime,
            size: 0,
            created: nil,
            modified: nil,
            headRevision: nil,
            md5: nil,
            sha1: nil,
            sha256: nil,
            owner: nil,
            webLink: nil,
            durability: .committed,
            trashed: false
        )
    }

    private func insertRow(_ record: MetadataRecord) throws {
        try run(
            """
            INSERT INTO nodes (\(Self.columns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bind: { try self.bind($0, record) },
            inode: record.inode,
            driveID: record.driveID
        )
    }

    private func updateRow(_ record: MetadataRecord) throws {
        let inode = try storageInode(record.inode)
        try run(
            """
            UPDATE nodes SET
                drive_id = ?,
                parent = ?,
                name = ?,
                assigned_duplicate_suffix = ?,
                mime_type = ?,
                size = ?,
                created = ?,
                modified = ?,
                head_revision = ?,
                md5 = ?,
                sha1 = ?,
                sha256 = ?,
                owner = ?,
                web_link = ?,
                durability = ?,
                trashed = ?
            WHERE inode = ?
            """,
            bind: {
                try self.bindText($0, 1, record.driveID?.rawValue)
                try self.bindOptionalInt($0, 2, record.parent.map { try self.storageInode($0) })
                try self.bindText($0, 3, record.name)
                try self.bindText($0, 4, record.assignedDuplicateSuffix)
                try self.bindText($0, 5, record.mimeType)
                try self.bindInt($0, 6, record.size)
                try self.bindDate($0, 7, record.created)
                try self.bindDate($0, 8, record.modified)
                try self.bindText($0, 9, record.headRevision)
                try self.bindText($0, 10, record.md5)
                try self.bindText($0, 11, record.sha1)
                try self.bindText($0, 12, record.sha256)
                try self.bindText($0, 13, record.owner)
                try self.bindText($0, 14, record.webLink)
                try self.bindText($0, 15, record.durability.rawValue)
                try self.bindInt($0, 16, record.trashed ? 1 : 0)
                try self.bindInt($0, 17, inode)
            },
            inode: record.inode,
            driveID: record.driveID
        )
    }

    private func bind(_ statement: OpaquePointer, _ record: MetadataRecord) throws {
        let inode = try storageInode(record.inode)
        try bindInt(statement, 1, inode)
        try bindText(statement, 2, record.driveID?.rawValue)
        try bindOptionalInt(statement, 3, record.parent.map { try storageInode($0) })
        try bindText(statement, 4, record.name)
        try bindText(statement, 5, record.assignedDuplicateSuffix)
        try bindText(statement, 6, record.mimeType)
        try bindInt(statement, 7, record.size)
        try bindDate(statement, 8, record.created)
        try bindDate(statement, 9, record.modified)
        try bindText(statement, 10, record.headRevision)
        try bindText(statement, 11, record.md5)
        try bindText(statement, 12, record.sha1)
        try bindText(statement, 13, record.sha256)
        try bindText(statement, 14, record.owner)
        try bindText(statement, 15, record.webLink)
        try bindText(statement, 16, record.durability.rawValue)
        try bindInt(statement, 17, record.trashed ? 1 : 0)
    }

    private func read(_ statement: OpaquePointer) throws -> MetadataRecord {
        let inode = try requiredInt(statement, 0)
        guard inode >= 0 else {
            throw MetadataStoreError.invalidRow("inode")
        }
        let parent = try optionalInt(statement, 2)
        if let parent, parent < 0 {
            throw MetadataStoreError.invalidRow("parent")
        }
        guard let name = text(statement, 3) else {
            throw MetadataStoreError.invalidRow("name")
        }
        guard let mimeType = text(statement, 5) else {
            throw MetadataStoreError.invalidRow("mime_type")
        }
        let size = try requiredInt(statement, 6)
        guard let durabilityRaw = text(statement, 15), let durability = DurabilityState(rawValue: durabilityRaw) else {
            throw MetadataStoreError.invalidRow("durability")
        }
        let trashed = try requiredInt(statement, 16)
        guard trashed == 0 || trashed == 1 else {
            throw MetadataStoreError.invalidRow("trashed")
        }
        return MetadataRecord(
            inode: Inode(rawValue: UInt64(inode)),
            driveID: text(statement, 1).map { DriveID(rawValue: $0) },
            parent: parent.map { Inode(rawValue: UInt64($0)) },
            name: name,
            assignedDuplicateSuffix: text(statement, 4),
            mimeType: mimeType,
            size: size,
            created: try date(statement, 7),
            modified: try date(statement, 8),
            headRevision: text(statement, 9),
            md5: text(statement, 10),
            sha1: text(statement, 11),
            sha256: text(statement, 12),
            owner: text(statement, 13),
            webLink: text(statement, 14),
            durability: durability,
            trashed: trashed == 1
        )
    }

    private func observe(_ inode: Int64) throws {
        guard inode < Int64.max else {
            throw MetadataStoreError.invalidRow("inode")
        }
        let current = try counter()
        let next = inode + 1
        if next > current {
            try setCounter(next)
        }
    }

    private func counter() throws -> Int64 {
        guard let value = try singleInt("SELECT value FROM meta WHERE key = 'next_inode'") else {
            throw MetadataStoreError.schema("meta.next_inode")
        }
        return value
    }

    private func setCounter(_ value: Int64) throws {
        try run(
            "UPDATE meta SET value = ? WHERE key = 'next_inode'",
            bind: { try self.bindInt($0, 1, value) }
        )
        guard sqlite3_changes(pointer) == 1 else {
            throw MetadataStoreError.schema("meta.next_inode")
        }
    }

    private func rowExists(_ inode: Int64) throws -> Bool {
        try singleInt("SELECT inode FROM nodes WHERE inode = ?", bind: { try self.bindInt($0, 1, inode) }) != nil
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try exec("COMMIT")
            return value
        } catch {
            sqlite3_exec(pointer, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func query(_ sql: String, bind: (OpaquePointer) throws -> Void) throws -> [MetadataRecord] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        var rows: [MetadataRecord] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                rows.append(try read(statement))
            } else if code == SQLITE_DONE {
                return rows
            } else {
                throw failure(code, inode: nil, driveID: nil)
            }
        }
    }

    private func queryOne(_ sql: String, bind: (OpaquePointer) throws -> Void) throws -> MetadataRecord? {
        let rows = try query(sql, bind: bind)
        guard rows.count < 2 else {
            throw MetadataStoreError.invalidRow("lookup")
        }
        return rows.first
    }

    private func forEach(_ sql: String, _ body: (OpaquePointer) throws -> Void) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                try body(statement)
            } else if code == SQLITE_DONE {
                return
            } else {
                throw failure(code, inode: nil, driveID: nil)
            }
        }
    }

    private func run(
        _ sql: String,
        bind: (OpaquePointer) throws -> Void,
        inode: Inode? = nil,
        driveID: DriveID? = nil
    ) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else {
            throw failure(code, inode: inode, driveID: driveID)
        }
    }

    private func singleInt(_ sql: String, bind: (OpaquePointer) throws -> Void = { _ in }) throws -> Int64? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE {
            return nil
        }
        guard code == SQLITE_ROW else {
            throw failure(code, inode: nil, driveID: nil)
        }
        guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
            throw MetadataStoreError.invalidRow(sql)
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func tableInfo(_ table: String) throws -> [ColumnInfo] {
        let statement = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        var columns: [ColumnInfo] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE {
                return columns
            }
            guard code == SQLITE_ROW else {
                throw failure(code, inode: nil, driveID: nil)
            }
            guard let name = text(statement, 1), let type = text(statement, 2) else {
                throw MetadataStoreError.schema(table)
            }
            columns.append(
                ColumnInfo(
                    name: name,
                    type: type,
                    notNull: sqlite3_column_int(statement, 3) == 1,
                    primaryKey: sqlite3_column_int(statement, 5)
                )
            )
        }
    }

    private func driveIDIsUnique() throws -> Bool {
        let statement = try prepare("PRAGMA index_list(nodes)")
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE {
                break
            }
            guard code == SQLITE_ROW else {
                throw failure(code, inode: nil, driveID: nil)
            }
            guard sqlite3_column_int(statement, 2) == 1, let name = text(statement, 1) else {
                continue
            }
            names.append(name)
        }
        for name in names where try indexColumns(name) == ["drive_id"] {
            return true
        }
        return false
    }

    private func indexColumns(_ name: String) throws -> [String] {
        let statement = try prepare("PRAGMA index_info(\(name))")
        defer { sqlite3_finalize(statement) }
        var columns: [String] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE {
                return columns
            }
            guard code == SQLITE_ROW, let column = text(statement, 2) else {
                throw failure(code, inode: nil, driveID: nil)
            }
            columns.append(column)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(pointer, sql, -1, &statement, nil))
        guard let statement else {
            throw MetadataStoreError.sqlite(code: SQLITE_ERROR, message: "prepare")
        }
        return statement
    }

    private func exec(_ sql: String) throws {
        try check(sqlite3_exec(pointer, sql, nil, nil, nil))
    }

    private func check(_ code: Int32) throws {
        guard code == SQLITE_OK else {
            throw failure(code, inode: nil, driveID: nil)
        }
    }

    private func failure(_ code: Int32, inode: Inode?, driveID: DriveID?) -> MetadataStoreError {
        let primary = code & 0xFF
        if primary == SQLITE_CONSTRAINT {
            let extended = sqlite3_extended_errcode(pointer)
            if extended == Self.constraintPrimaryKey, let inode {
                return .duplicateInode(inode)
            }
            if extended == Self.constraintUnique || extended == SQLITE_CONSTRAINT, let driveID {
                return .duplicateDriveID(driveID)
            }
        }
        let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite"
        return .sqlite(code: code, message: message)
    }

    private func bindInt(_ statement: OpaquePointer, _ index: Int32, _ value: Int64) throws {
        try check(sqlite3_bind_int64(statement, index, value))
    }

    private func bindOptionalInt(_ statement: OpaquePointer, _ index: Int32, _ value: Int64?) throws {
        if let value {
            try bindInt(statement, index, value)
        } else {
            try check(sqlite3_bind_null(statement, index))
        }
    }

    private func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String?) throws {
        guard let value else {
            try check(sqlite3_bind_null(statement, index))
            return
        }
        try value.withCString { cString in
            try check(sqlite3_bind_text(statement, index, cString, -1, Self.transient))
        }
    }

    private func bindDate(_ statement: OpaquePointer, _ index: Int32, _ value: Date?) throws {
        guard let value else {
            try check(sqlite3_bind_null(statement, index))
            return
        }
        let bits = Int64(bitPattern: value.timeIntervalSince1970.bitPattern)
        try bindInt(statement, index, bits)
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        guard let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
    }

    private func optionalInt(_ statement: OpaquePointer, _ index: Int32) throws -> Int64? {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return nil
        case SQLITE_INTEGER:
            return sqlite3_column_int64(statement, index)
        default:
            throw MetadataStoreError.invalidRow("column \(index)")
        }
    }

    private func requiredInt(_ statement: OpaquePointer, _ index: Int32) throws -> Int64 {
        guard let value = try optionalInt(statement, index) else {
            throw MetadataStoreError.invalidRow("column \(index)")
        }
        return value
    }

    private func date(_ statement: OpaquePointer, _ index: Int32) throws -> Date? {
        guard let bits = try optionalInt(statement, index) else {
            return nil
        }
        let interval = Double(bitPattern: UInt64(bitPattern: bits))
        return Date(timeIntervalSince1970: interval)
    }

    private func storageInode(_ inode: Inode) throws -> Int64 {
        guard inode.rawValue <= UInt64(Int64.max) else {
            throw MetadataStoreError.invalidRow("inode")
        }
        return Int64(inode.rawValue)
    }
}

private struct ColumnInfo {
    var name: String
    var type: String
    var notNull: Bool
    var primaryKey: Int32
}
