import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors

/// 在临时目录里搭一个假的 `~/.dsh`：目录布局与投影缓存的形状照 dsh 0.1.5-rc.3，内容全是编的。
final class DshSessionScannerTests: XCTestCase {
    private var root: URL!
    private var paths: DshPaths { DshPaths(home: root) }
    private let now = Date(timeIntervalSince1970: 1_790_500_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: paths.projectionCacheDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// 建一个会话目录（日志文件内容无所谓，扫描不读它），按需写投影缓存。
    @discardableResult
    private func session(_ id: String, project: String = "--Users-me-app--", modified: Date,
                         cache: JSONValue?, cacheModified: Date? = nil, file: String = "session.v3.jsonl.zstd") throws -> URL {
        let directory = paths.sessionsDirectory.appendingPathComponent(project).appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent(file)
        try Data("x".utf8).write(to: log)
        FileManager.default.createFile(atPath: directory.appendingPathComponent("session.lock").path, contents: Data())
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: log.path)
        if let cache {
            let file = paths.projectionCacheFile(sessionId: Self.decoded(id))
            try JSONEncoder().encode(cache).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: cacheModified ?? modified], ofItemAtPath: file.path)
        }
        return log
    }

    private static func decoded(_ id: String) -> String { DshSessionScanner.decodeSegment(id) }

    /// web 进程写的缓存（字段齐）。
    private func webCache(cwd: String = "/Users/me/app", title: String? = "修 bug", blank: Bool = false,
                          openTurn: Int64? = nil, lastPromptAt: Int64 = 1_790_499_000_000) -> JSONValue {
        ["version": 7, "record": [
            "identity": ["formatVersion": 3, "createdAt": 1_790_490_000_000, "cwd": .string(cwd), "isSeeded": false,
                         "inheritedEventCount": 0],
            "rows": [
                "title": ["ver": 1, "seq": 31, "val": title.map(JSONValue.string) ?? .null],
                "turnBoundary": ["ver": 2, "seq": 31, "val": ["openTurnStartSeq": openTurn.map(JSONValue.int) ?? .null,
                                                               "lastStepStartSeq": 28, "lastTurn": 1]],
                "sessionListMetadata": ["ver": 1, "seq": 31, "val": ["blank": .bool(blank), "lastPromptAt": .int(lastPromptAt)]],
            ],
        ]]
    }

    /// ACP 进程写的缓存：只有标题和轮次边界。
    private func acpCache(title: String?, lastTurn: Int64?) -> JSONValue {
        ["version": 7, "record": [
            "identity": ["formatVersion": 3, "createdAt": 1_790_490_000_000, "cwd": "/Users/me/acp", "isSeeded": false],
            "rows": [
                "title": ["ver": 1, "seq": 3, "val": title.map(JSONValue.string) ?? .null],
                "turnBoundary": ["ver": 2, "seq": 3, "val": ["openTurnStartSeq": .null,
                                                              "lastTurn": lastTurn.map(JSONValue.int) ?? .null]],
            ],
        ]]
    }

    func testListsRecentSessionsNewestFirst() async throws {
        try session("session-a", modified: now.addingTimeInterval(-60), cache: webCache(openTurn: 12))
        try session("b-uuid", project: "--Users-me-acp--", modified: now.addingTimeInterval(-3600),
                    cache: acpCache(title: "ACP 会话", lastTurn: 1))
        try session("old", modified: now.addingTimeInterval(-8 * 24 * 3600), cache: webCache())
        let scanner = DshSessionScanner(paths: paths, now: { [now] in now })
        let found = await scanner.scan()
        XCTAssertEqual(found.map(\.sessionId), ["session-a", "b-uuid"], "7 天外的不要")
        let first = try XCTUnwrap(found.first)
        XCTAssertEqual(first.cwd, "/Users/me/app")
        XCTAssertEqual(first.title, "修 bug")
        XCTAssertTrue(first.hasOpenTurn)
        XCTAssertEqual(first.lastPromptAt, Date(timeIntervalSince1970: 1_790_499_000))
        XCTAssertEqual(first.createdAt, Date(timeIntervalSince1970: 1_790_490_000))
        XCTAssertEqual(first.updatedAt.timeIntervalSince1970, now.addingTimeInterval(-60).timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(first.logFile.lastPathComponent, "session.v3.jsonl.zstd")
        XCTAssertFalse(found[1].hasOpenTurn)
        XCTAssertNil(found[1].lastPromptAt)
    }

    func testSkipsBlankAndCwdlessSessions() async throws {
        try session("blank-web", modified: now, cache: webCache(title: nil, blank: true))
        try session("blank-acp", modified: now, cache: acpCache(title: nil, lastTurn: nil))
        try session("no-cache", modified: now, cache: nil)
        try session("no-log", modified: now, cache: webCache(), file: "session.lock.bak")
        try session("ok", modified: now, cache: webCache())
        // ACP 进程写的缓存停在刚建会话时（比日志旧）：不能据它判空白，照列、标上过时。
        try session("stale-acp", modified: now, cache: acpCache(title: nil, lastTurn: 0),
                    cacheModified: now.addingTimeInterval(-600))
        let found = await DshSessionScanner(paths: paths, now: { [now] in now }).scan()
        XCTAssertEqual(Set(found.map(\.sessionId)), ["ok", "stale-acp"])
        XCTAssertEqual(found.first { $0.sessionId == "stale-acp" }?.cacheIsStale, true)
        XCTAssertEqual(found.first { $0.sessionId == "ok" }?.cacheIsStale, false)
    }

    func testSkipsSubagentsUsingHeadersAndCachesThem() async throws {
        try session("session-p", modified: now, cache: webCache())
        try session("child-uuid", modified: now, cache: webCache(title: "子任务"))
        try session("session-f", modified: now, cache: nil)
        let calls = Locked<[[String]]>([])
        let scanner = DshSessionScanner(paths: paths, now: { [now] in now }, headers: { files in
            calls.withLock { $0.append(files.map(\.lastPathComponent)) }
            var result: [URL: DshSessionHeader] = [:]
            for file in files {
                switch file.deletingLastPathComponent().lastPathComponent {
                case "child-uuid": result[file] = DshSessionHeader(id: "child-uuid", cwd: "/Users/me/app", parentSession: "session-p",
                                                            origin: "subagent", delegationDepth: 1)
                case "session-f": result[file] = DshSessionHeader(id: "session-f", cwd: "/Users/me/fork", parentSession: "session-p",
                                                           isSeeded: true)
                case "session-p": result[file] = DshSessionHeader(id: "session-p", cwd: "/Users/me/app")
                default: break
                }
            }
            return result
        })
        let found = await scanner.scan()
        XCTAssertEqual(Set(found.map(\.sessionId)), ["session-p", "session-f"], "subagent 不列，fork 照列")
        XCTAssertEqual(found.first { $0.sessionId == "session-f" }?.cwd, "/Users/me/fork", "没有缓存时 cwd 取会话头")
        _ = await scanner.scan()
        XCTAssertEqual(calls.current.count, 1, "会话头只读一次")
        let cached = await scanner.cachedHeader(sessionId: "child-uuid")
        XCTAssertEqual(cached?.isSubagent, true)
    }

    func testDecodesEscapedSessionDirectoryNames() {
        XCTAssertEqual(DshSessionScanner.decodeSegment("a~0020b"), "a b")
        XCTAssertEqual(DshSessionScanner.decodeSegment("~002E"), ".")
        XCTAssertEqual(DshSessionScanner.decodeSegment("plain-id_1.x"), "plain-id_1.x")
        XCTAssertEqual(DshSessionScanner.decodeSegment("bad~zz"), "bad~zz")
    }

    func testMissingSessionsDirectoryIsEmpty() async {
        let scanner = DshSessionScanner(paths: DshPaths(home: root.appendingPathComponent("nothing")))
        let found = await scanner.scan()
        XCTAssertTrue(found.isEmpty)
    }
}
