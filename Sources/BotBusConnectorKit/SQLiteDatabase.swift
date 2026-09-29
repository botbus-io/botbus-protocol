import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite)
import CSQLite
#endif

public enum SQLiteValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public var int: Int64? {
        if case .integer(let v) = self { return v }
        return nil
    }

    public var string: String? {
        if case .text(let v) = self { return v }
        return nil
    }
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

/// 极简 SQLite 封装，只覆盖本项目需要的：打开（默认只读）、带参数查询、（测试用）执行语句。
/// 不是线程安全的：每个使用方自己持有实例，不跨线程共享。
public final class SQLiteDatabase {
    private var handle: OpaquePointer?

    /// 这次是不是走了 `immutable=1` 兜底（见 `canRetryImmutable`）。诊断与测试用。
    public private(set) var usedImmutableFallback = false

    public init(path: String, readOnly: Bool = true) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        var (db, rc) = Self.openAndProbe(path, flags: flags)

        if rc == SQLITE_CANTOPEN, readOnly, Self.canRetryImmutable(path: path) {
            if let db { sqlite3_close(db) }
            (db, rc) = Self.openAndProbe(Self.immutableURI(for: path),
                                         flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
            usedImmutableFallback = rc == SQLITE_OK
        }

        guard rc == SQLITE_OK, let opened = db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            if let db { sqlite3_close(db) }
            throw SQLiteError(code: rc, message: message)
        }
        handle = opened
    }

    /// 打开并立刻探读一次。
    ///
    /// `sqlite3_open_v2` 是**惰性**的：它基本只记下文件名，并不去碰 WAL 侧文件，所以
    /// "WAL 库缺 `-wal`"这个错不会在打开时冒出来，而是等到第一次 prepare/step 才抛
    /// SQLITE_CANTOPEN(14)。探一条最便宜的语句把打开变"急"，兜底判断才有东西可依据；
    /// 顺带也让调用方拿到的句柄要么真能读，要么当场抛错，不会"开得成、读就炸"。
    private static func openAndProbe(_ filename: String, flags: Int32) -> (OpaquePointer?, Int32) {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(filename, &db, flags, nil)
        guard rc == SQLITE_OK, let opened = db else { return (db, rc) }
        // Codex 以 WAL 模式写库；读到锁时忙等最多 200 ms，而不是立刻失败。
        // 必须在探读之前设好，否则一次偶发的忙锁会被探读放大成打开失败。
        sqlite3_busy_timeout(opened, 200)
        return (opened, sqlite3_exec(opened, "SELECT 1 FROM sqlite_master LIMIT 1", nil, nil, nil))
    }

    /// 只读打开失败时要不要加 `immutable=1` 再试一次。
    ///
    /// 起因：WAL 库在"已被干净关闭"之后只读打不开。SQLite 读 WAL 库要用 `-shm` 共享内存文件；
    /// `-wal` 不存在时它得把 `-wal`/`-shm` 重新建出来，而只读连接没有创建权限，
    /// 于是报 SQLITE_CANTOPEN(14)——注意这个错要到第一次真读才冒出来，见 `openAndProbe`。
    /// 反面佐证：只要 `-wal` 还在，哪怕它是 0 字节（checkpoint 过但没被删），只读打开就能成功。
    ///
    /// ChatGPT.app 开着 Codex 库的时候 `-wal` 在，一切正常；它退出并 checkpoint 之后，
    /// `~/.codex/thread_history_1.sqlite` 就只剩主文件，Agent 每 2 秒的轮询会全部失败
    /// ——菜单栏一个 Codex 任务都看不到。
    ///
    /// 兜底是加 `immutable=1` 重开一次：这等于向 SQLite 保证"这个文件不会变"，它于是跳过
    /// WAL 与加锁，直接读主文件。这个保证只有在没人写的时候才成立，所以下面两个前提缺一不可：
    ///
    /// 1. **`-wal` 不存在**——这是安全条件，不能省。没有 `-wal` 说明库已经 checkpoint 过并被
    ///    干净关闭，此刻没有写者。反过来，只要 `-wal` 还在（哪怕是 0 字节）只读打开本来就会成功，
    ///    根本走不到这条兜底，所以这个条件也不会误伤正在被写的库。
    /// 2. **主文件存在**——`immutable=1` 打开一个不存在的文件**不报错**，而是当成一个空库。
    ///    少了这一条，Codex 库被删掉或路径配错就会静默变成"0 个任务"，而不是抛错让上层报警。
    ///
    /// 残余风险，如实记下：检查和打开之间有一个窗口，写者可能正好在这期间出现（比如用户恰好
    /// 在这一刻启动 ChatGPT.app）。后果是这一轮**可能**读到不一致的快照。能接受，是因为读出来的
    /// 是咨询性质的任务列表，不写回任何地方，而且 2 秒后的下一轮轮询就会自我纠正。
    /// 前提是连接必须短命——`CodexThreadReader` 每次读都新开库、读完即关（局部变量出作用域
    /// 就 deinit → `sqlite3_close`），不跨轮持有句柄，所以这个窗口最多影响一轮。
    private static func canRetryImmutable(path: String) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: path) && !fileManager.fileExists(atPath: path + "-wal")
    }

    /// SQLite 的 URI 文件名里 `?` 和 `#` 会截断路径、`%` 是转义前缀，这三个字符得先转义。
    private static func immutableURI(for path: String) -> String {
        var escaped = ""
        for scalar in path.unicodeScalars {
            switch scalar {
            case "%": escaped += "%25"
            case "?": escaped += "%3f"
            case "#": escaped += "%23"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "file:" + escaped + "?immutable=1"
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    public func execute(_ sql: String) throws {
        guard let handle else { return }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(errorMessage)
            throw SQLiteError(code: rc, message: message)
        }
    }

    public func query(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        guard let handle else { return [] }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            throw SQLiteError(code: prepared, message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        // SQLITE_TRANSIENT 在 Swift 里不可直接引用，用等价的 -1 析构指针让 SQLite 复制一份参数。
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .null:
                sqlite3_bind_null(statement, position)
            case .integer(let v):
                sqlite3_bind_int64(statement, position, v)
            case .real(let v):
                sqlite3_bind_double(statement, position, v)
            case .text(let v):
                sqlite3_bind_text(statement, position, v, -1, transient)
            case .blob(let v):
                v.withUnsafeBytes { buffer in
                    _ = sqlite3_bind_blob(statement, position, buffer.baseAddress, Int32(v.count), transient)
                }
            }
        }

        var rows: [[String: SQLiteValue]] = []
        let columnCount = sqlite3_column_count(statement)
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw SQLiteError(code: step, message: String(cString: sqlite3_errmsg(handle)))
            }
            var row: [String: SQLiteValue] = [:]
            for column in 0..<columnCount {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER:
                    row[name] = .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT:
                    row[name] = .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT:
                    row[name] = .text(String(cString: sqlite3_column_text(statement, column)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    if let bytes = sqlite3_column_blob(statement, column), count > 0 {
                        row[name] = .blob(Data(bytes: bytes, count: count))
                    } else {
                        row[name] = .blob(Data())
                    }
                default:
                    row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }
}
