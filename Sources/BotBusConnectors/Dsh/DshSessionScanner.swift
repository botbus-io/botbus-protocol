import Foundation
import BotBusConnectorKit

/// 扫盘得到的一个 dsh 会话（web 不在时用）。只有元数据，不含对话内容（标题除外）；DshConnector 据此拼 `TaskRecord`。
public struct DshSessionSummary: Hashable, Sendable {
    public var sessionId: String
    public var cwd: String
    /// 投影缓存里的标题（dsh 取首条提示词或模型起的）。没有就是 nil。
    public var title: String?
    public var createdAt: Date?
    /// 会话日志文件的修改时间：最后一次有事件落盘。
    public var updatedAt: Date
    /// 最后一次人发提示词的时间（web 写的缓存才有）。web 的 `session/list` 按 `max(createdAt, lastPromptAt)` 排。
    public var lastPromptAt: Date?
    /// 缓存说有一轮开了还没收尾（`turnBoundary.openTurnStartSeq` 非空）：可能正在跑，也可能进程在这一轮中途没了。
    public var hasOpenTurn: Bool
    /// 投影缓存比日志旧（或没有缓存）：标题、`hasOpenTurn` 可能过时。ACP 进程常常只在会话开头写一次缓存，
    /// 之后几轮都不刷新；要准的话解日志（`DshTranscriptDecoder`）看 `session/title` 与 `turn/end`。
    public var cacheIsStale: Bool
    public var directory: URL
    public var logFile: URL

    public init(sessionId: String, cwd: String, title: String?, createdAt: Date?, updatedAt: Date, lastPromptAt: Date?,
                hasOpenTurn: Bool, cacheIsStale: Bool = false, directory: URL, logFile: URL) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastPromptAt = lastPromptAt
        self.hasOpenTurn = hasOpenTurn
        self.cacheIsStale = cacheIsStale
        self.directory = directory
        self.logFile = logFile
    }
}

/// 扫 `~/.dsh/sessions/<项目>/<会话>/` 与投影缓存 `storages/session_projcache/sessions/<id>.json`（只读）。
///
/// 规则（spec「看见」）：
/// - 只要日志文件修改时间在 7 天窗口（`SessionFormatting.recentWindow`）里的，按修改时间新的在前，最多 `maxSessions` 条；
/// - 空白会话跳过：缓存 `sessionListMetadata.blank == true`；ACP 进程写的缓存没有这一行，这时只有缓存不比日志旧、
///   且"没标题、没开过一轮"才算空白（ACP 进程的缓存常常停在会话刚建好的那一刻，旧缓存说空白不可信；web 的列表对没有这一行的一律当不空白）；
/// - cwd 取缓存 `record.identity.cwd`，没有再看会话头；都没有的跳过（web 的列表也不列没有 cwd 的会话）；
/// - **subagent 的会话跳过**：它与父会话在同一个项目目录里，只有会话头（`origin: "subagent"`、`delegationDepth > 0`）
///   认得出来，投影缓存里没有这个信息。头在压缩日志的第一帧里，要靠 `headers`（`DshTranscriptDecoder.headers`，起一次 node）读；
///   会话头不会变，按会话 id 缓存，之后的扫描不再读。没有 `headers`（找不到 node）时认不出 subagent，照常列出。
///
/// 项目目录名是 cwd 的有损编码（反解不回），会话目录名是会话 id（`~XXXX` 转义的字符还原）。
public actor DshSessionScanner {
    public static let maxSessions = 200
    public typealias HeaderReader = @Sendable ([URL]) async -> [URL: DshSessionHeader]

    private let paths: DshPaths
    private let now: @Sendable () -> Date
    private let headers: HeaderReader?
    /// 会话 id → 头（读不出来的记 nil，也不再读）。
    private var headerCache: [String: DshSessionHeader?] = [:]
    /// 会话 id → 投影缓存（及读它时文件的修改时间）。
    private var cacheMemo: [String: (modified: Date?, cache: DshProjectionCache?)] = [:]

    public init(paths: DshPaths, now: @escaping @Sendable () -> Date = { Date() }, headers: HeaderReader? = nil) {
        self.paths = paths
        self.now = now
        self.headers = headers
    }

    public func scan() async -> [DshSessionSummary] {
        let fileManager = FileManager.default
        let current = now()
        var found: [(sessionId: String, directory: URL, log: URL, modified: Date)] = []
        let projects = (try? fileManager.contentsOfDirectory(at: paths.sessionsDirectory, includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles])) ?? []
        for project in projects where Self.isDirectory(project) {
            let sessions = (try? fileManager.contentsOfDirectory(at: project, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
            for directory in sessions where Self.isDirectory(directory) {
                guard let log = DshSessionFiles.logFile(in: directory),
                      let modified = (try? fileManager.attributesOfItem(atPath: log.path))?[.modificationDate] as? Date,
                      current.timeIntervalSince(modified) <= SessionFormatting.recentWindow else { continue }
                let sessionId = Self.decodeSegment(directory.lastPathComponent)
                guard !sessionId.isEmpty else { continue }
                found.append((sessionId, directory, log, modified))
            }
        }
        found.sort { $0.modified > $1.modified }
        let recent = found.prefix(Self.maxSessions)
        let keep = Set(recent.map(\.sessionId))
        cacheMemo = cacheMemo.filter { keep.contains($0.key) }

        if let headers {
            let missing = recent.filter { headerCache[$0.sessionId] == nil }
            if !missing.isEmpty {
                let read = await headers(missing.map(\.log))
                for entry in missing { headerCache[entry.sessionId] = .some(read[entry.log]) }
            }
        }

        return recent.compactMap { entry -> DshSessionSummary? in
            let header = headerCache[entry.sessionId] ?? nil
            if header?.isSubagent == true { return nil }
            let cacheFile = paths.projectionCacheFile(sessionId: entry.sessionId)
            let cacheModified = (try? FileManager.default.attributesOfItem(atPath: cacheFile.path))?[.modificationDate] as? Date
            let cache = projectionCache(entry.sessionId, file: cacheFile, modified: cacheModified)
            let stale = cache == nil || (cacheModified.map { $0 < entry.modified } ?? true)
            if let cache, cache.listBlank ?? (!stale && cache.looksBlank) { return nil }
            guard let cwd = cache?.cwd ?? header?.cwd, !cwd.isEmpty else { return nil }
            return DshSessionSummary(sessionId: entry.sessionId, cwd: cwd, title: cache?.title,
                                     createdAt: cache?.createdAt ?? header?.createdAt, updatedAt: entry.modified,
                                     lastPromptAt: cache?.lastPromptAt, hasOpenTurn: cache?.openTurnStartSeq != nil,
                                     cacheIsStale: stale, directory: entry.directory, logFile: entry.log)
        }
    }

    /// 投影缓存按文件修改时间记住：DshConnector 在 web 不在时每几秒扫一次，没变的缓存不重读、不重解 JSON。
    private func projectionCache(_ sessionId: String, file: URL, modified: Date?) -> DshProjectionCache? {
        if let memo = cacheMemo[sessionId], memo.modified == modified { return memo.cache }
        let cache = modified == nil ? nil : DshProjectionCache.read(file)
        cacheMemo[sessionId] = (modified, cache)
        return cache
    }

    /// 已缓存的会话头（测试与 DshConnector 读 subagent 判定用）。
    public func cachedHeader(sessionId: String) -> DshSessionHeader? { headerCache[sessionId] ?? nil }

    /// 磁盘上还在的会话 id（有日志文件的会话目录，不看时间窗口）。会话根目录或某个项目目录读不了返回 nil：
    /// 不知道不等于删了。只在有「只有 ACP 记着」的会话时用，判断它们在电脑上删了没有。
    static func sessionIdsOnDisk(in sessionsDirectory: URL) -> Set<String>? {
        let fileManager = FileManager.default
        guard let projects = try? fileManager.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles]) else { return nil }
        var ids: Set<String> = []
        for project in projects where isDirectory(project) {
            guard let sessions = try? fileManager.contentsOfDirectory(at: project, includingPropertiesForKeys: nil,
                                                                      options: [.skipsHiddenFiles]) else { return nil }
            for directory in sessions where isDirectory(directory) && DshSessionFiles.logFile(in: directory) != nil {
                let sessionId = decodeSegment(directory.lastPathComponent)
                if !sessionId.isEmpty { ids.insert(sessionId) }
            }
        }
        return ids
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// dsh 的 `encodeSegment` 反过来：`~XXXX`（4 位十六进制的 UTF-16 码元）还原。认不出的 `~` 原样留。
    static func decodeSegment(_ segment: String) -> String {
        guard segment.contains("~") else { return segment }
        var units: [UInt16] = []
        let chars = Array(segment.utf16)
        var index = 0
        while index < chars.count {
            if chars[index] == UInt16(UInt8(ascii: "~")), index + 4 < chars.count,
               let code = UInt16(String(utf16CodeUnits: Array(chars[(index + 1)...(index + 4)]), count: 4), radix: 16) {
                units.append(code)
                index += 5
            } else {
                units.append(chars[index])
                index += 1
            }
        }
        return String(utf16CodeUnits: units, count: units.count)
    }
}

/// 投影缓存 `storages/session_projcache/sessions/<id>.json` 里 BotBus 用到的几行。
/// 形状：`{version, record:{identity:{createdAt, cwd, …}, rows:{<key>:{ver, seq, val}}}}`。
struct DshProjectionCache: Hashable, Sendable {
    var cwd: String?
    var createdAt: Date?
    var title: String?
    var openTurnStartSeq: Int64?
    var lastTurn: Int64?
    /// `sessionListMetadata`：web 进程写的缓存才有。
    var listBlank: Bool?
    var lastPromptAt: Date?

    static func read(_ url: URL) -> DshProjectionCache? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return DshProjectionCache(json: json)
    }

    init?(json: JSONValue) {
        guard let record = json["record"], record.objectValue != nil else { return nil }
        let rows = record["rows"]
        cwd = record.path("identity", "cwd")?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        createdAt = dshDate(record.path("identity", "createdAt"))
        title = rows?.path("title", "val")?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        openTurnStartSeq = rows?.path("turnBoundary", "val", "openTurnStartSeq")?.intValue
        lastTurn = rows?.path("turnBoundary", "val", "lastTurn")?.intValue
        listBlank = rows?.path("sessionListMetadata", "val", "blank")?.boolValue
        lastPromptAt = dshDate(rows?.path("sessionListMetadata", "val", "lastPromptAt"))
    }

    /// 没有 `sessionListMetadata` 时的判断：没标题、没开过一轮。只在缓存不比日志旧时可信。
    var looksBlank: Bool {
        title == nil && (lastTurn ?? 0) == 0 && openTurnStartSeq == nil
    }
}
