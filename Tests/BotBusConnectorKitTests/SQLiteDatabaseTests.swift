import XCTest
import BotBusConnectorKit
@testable import BotBusConnectorKit

final class SQLiteDatabaseTests: XCTestCase {
    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("botbus-\(UUID().uuidString).sqlite").path
    }

    func testCreateInsertAndQueryWithBindings() throws {
        let path = temporaryPath()
        let writer = try SQLiteDatabase(path: path, readOnly: false)
        try writer.execute("CREATE TABLE t (id TEXT PRIMARY KEY, n INTEGER, x REAL, note TEXT)")
        try writer.execute("INSERT INTO t VALUES ('a', 1, 1.5, 'one'), ('b', 2, 2.5, NULL)")

        let reader = try SQLiteDatabase(path: path)
        let rows = try reader.query("SELECT id, n, x, note FROM t WHERE n >= ? ORDER BY n", [.integer(1)])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["id"], .text("a"))
        XCTAssertEqual(rows[0]["n"], .integer(1))
        XCTAssertEqual(rows[0]["x"], .real(1.5))
        XCTAssertEqual(rows[0]["note"], .text("one"))
        XCTAssertEqual(rows[1]["note"], .null)
        XCTAssertEqual(rows[1]["id"]?.string, "b")
        XCTAssertEqual(rows[1]["n"]?.int, 2)
    }

    func testReadOnlyHandleRejectsWrites() throws {
        let path = temporaryPath()
        try SQLiteDatabase(path: path, readOnly: false).execute("CREATE TABLE t (id TEXT)")
        let reader = try SQLiteDatabase(path: path)
        XCTAssertThrowsError(try reader.execute("INSERT INTO t VALUES ('x')"))
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try SQLiteDatabase(path: "/nonexistent/dir/none.sqlite"))
    }

    // MARK: - WAL 库的只读打开

    /// 每个用例一个独立目录：WAL 的 `-wal`/`-shm` 侧文件要能单独观察和删除。
    /// 全部在 temp 下，任何用例都不碰真实的 ~/.codex。
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("botbus-wal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// 建一个 WAL 模式的库并写三行。返回的 writer 还开着：调用方自己决定什么时候释放（= 关库）。
    private func makeWALDatabase(at path: String) throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(path: path, readOnly: false)
        try db.execute("PRAGMA journal_mode=WAL")
        try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, note TEXT)")
        try db.execute("INSERT INTO t VALUES (1, 'one'), (2, 'two'), (3, 'three')")
        return db
    }

    /// 数据库头第 18 字节：1 = rollback journal，2 = WAL。
    private func journalModeByte(at path: String) throws -> UInt8 {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let header = try XCTUnwrap(handle.read(upToCount: 19))
        XCTAssertEqual(header.count, 19)
        return header[18]
    }

    private func sidecarsExist(at path: String) -> (wal: Bool, shm: Bool) {
        (FileManager.default.fileExists(atPath: path + "-wal"),
         FileManager.default.fileExists(atPath: path + "-shm"))
    }

    /// 回归本体：库是 WAL 模式、已被干净关闭、侧文件都不在了，只读打开必须成功。
    ///
    /// 这正是 ChatGPT.app 退出后 ~/.codex/thread_history_1.sqlite 的状态；修复之前
    /// 这里会抛 SQLite error 14（unable to open database file），Agent 每 2 秒轮询全挂。
    func testReadOnlyOpenSucceedsForCleanlyClosedWALDatabase() throws {
        let path = try temporaryDirectory().appendingPathComponent("history.sqlite").path
        var writer: SQLiteDatabase? = try makeWALDatabase(at: path)
        XCTAssertNotNil(writer)
        writer = nil // sqlite3_close：干净关闭

        // Apple 自带的 SQLite 关库后会把 -wal 截成 0 字节留在原地（persistent WAL），
        // 而真实的 thread_history_1.sqlite 是连侧文件都没有的。显式删掉侧文件复现那个状态。
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }

        let sidecars = sidecarsExist(at: path)
        XCTAssertFalse(sidecars.wal, "-wal 必须不存在，否则这个用例根本没测到回归场景")
        XCTAssertFalse(sidecars.shm, "-shm 必须不存在")
        XCTAssertEqual(try journalModeByte(at: path), 2, "主文件必须仍然是 WAL 模式")

        let reader = try SQLiteDatabase(path: path)
        XCTAssertTrue(reader.usedImmutableFallback, "应当走 immutable=1 兜底")
        let rows = try reader.query("SELECT id, note FROM t ORDER BY id")
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0]["note"], .text("one"))
        XCTAssertEqual(rows[2]["id"], .integer(3))
    }

    /// 还有活的 `-wal` 时（写者开着，例如 ChatGPT.app 在跑）走正常路径，不需要 immutable。
    func testReadOnlyOpenUsesNormalPathWhenWALSidecarIsLive() throws {
        let path = try temporaryDirectory().appendingPathComponent("live.sqlite").path
        let writer = try makeWALDatabase(at: path) // 保持打开
        defer { withExtendedLifetime(writer) {} }

        XCTAssertTrue(sidecarsExist(at: path).wal, "写者开着时 -wal 应当存在")
        XCTAssertEqual(try journalModeByte(at: path), 2)

        let reader = try SQLiteDatabase(path: path)
        XCTAssertFalse(reader.usedImmutableFallback, "-wal 还在就不该退到 immutable")
        XCTAssertEqual(try reader.query("SELECT COUNT(*) AS n FROM t")[0]["n"], .integer(3))
    }

    /// 非 WAL（默认 rollback journal）库不受影响，也不该触发兜底。
    func testNonWALDatabaseIsUnaffected() throws {
        let path = try temporaryDirectory().appendingPathComponent("rollback.sqlite").path
        var writer: SQLiteDatabase? = try SQLiteDatabase(path: path, readOnly: false)
        try writer?.execute("CREATE TABLE t (id INTEGER)")
        try writer?.execute("INSERT INTO t VALUES (7)")
        writer = nil

        XCTAssertEqual(try journalModeByte(at: path), 1, "应当是 rollback journal 模式")
        let reader = try SQLiteDatabase(path: path)
        XCTAssertFalse(reader.usedImmutableFallback)
        XCTAssertEqual(try reader.query("SELECT id FROM t")[0]["id"], .integer(7))
    }

    /// 目录在、文件不在：必须抛错，不能被兜底吞成"一个空库"。
    ///
    /// 这条是给 `immutable=1` 兜底加的护栏：`immutable=1` 打开不存在的文件不会报错，
    /// 而是当成空库。少了主文件存在性检查，Codex 库被删或路径配错就会静默变成"0 个任务"。
    func testMissingFileInExistingDirectoryStillThrows() throws {
        let path = try temporaryDirectory().appendingPathComponent("absent.sqlite").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertThrowsError(try SQLiteDatabase(path: path)) { error in
            XCTAssertEqual((error as? SQLiteError)?.code, 14, "应当是 SQLITE_CANTOPEN")
        }
    }

    /// 文件被删掉后重新出现之前，reader 不该返回一个空库（上一条的查询侧补充）。
    func testMissingFileIsNotReportedAsEmptyDatabase() throws {
        let directory = try temporaryDirectory()
        let path = directory.appendingPathComponent("gone.sqlite").path
        var writer: SQLiteDatabase? = try makeWALDatabase(at: path)
        writer = nil
        XCTAssertNil(writer)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
        XCTAssertThrowsError(try SQLiteDatabase(path: path))
    }

    func testTextBindingIsCopied() throws {
        let path = temporaryPath()
        let db = try SQLiteDatabase(path: path, readOnly: false)
        try db.execute("CREATE TABLE t (s TEXT)")
        var value = "first"
        try db.execute("INSERT INTO t VALUES ('first')")
        value = "second"
        let rows = try db.query("SELECT s FROM t WHERE s = ?", [.text(String(value.dropLast(6)) + "first")])
        XCTAssertEqual(rows.count, 1)
    }
}
