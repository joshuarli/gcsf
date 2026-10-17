import SQLite3

public enum Index {
    public static let linkedSQLiteVersion = String(cString: sqlite3_libversion())
}
