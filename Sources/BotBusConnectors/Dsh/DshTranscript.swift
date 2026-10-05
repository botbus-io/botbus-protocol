import Foundation
import BotBusProtocol
import BotBusConnectorKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// 一份 dsh 会话日志读出来的样子：头、事件（升序）、前面有没有被截掉。
public struct DshSessionLog: Hashable, Sendable {
    public var header: DshSessionHeader?
    public var events: [DshSessionEvent]
    /// 只读了尾部（更早的事件没读）。
    public var truncated: Bool

    public init(header: DshSessionHeader?, events: [DshSessionEvent], truncated: Bool) {
        self.header = header
        self.events = events
        self.truncated = truncated
    }
}

/// 会话目录里的日志文件：`session.v<N>.jsonl.zstd`（默认）或 `session.v<N>.jsonl`（不压缩的配置），
/// 版本号最高的那份是当前代（dsh 升级格式时旧代留在旁边）。`session.jsonl` 是第 0 代。
public enum DshSessionFiles {
    public static func logFile(in sessionDirectory: URL, fileManager: FileManager = .default) -> URL? {
        guard let names = try? fileManager.contentsOfDirectory(atPath: sessionDirectory.path) else { return nil }
        let candidates = names.compactMap { name -> (version: Int, compressed: Bool, name: String)? in
            let compressed = name.hasSuffix(".jsonl.zstd")
            let base = compressed ? String(name.dropLast(".zstd".count)) : name
            guard base.hasPrefix("session."), base.hasSuffix(".jsonl") else { return nil }
            if base == "session.jsonl" { return (0, compressed, name) }
            let middle = base.dropFirst("session.".count).dropLast(".jsonl".count)
            guard middle.hasPrefix("v"), let version = Int(middle.dropFirst()), version > 0 else { return nil }
            return (version, compressed, name)
        }
        // 同一代两种都在时要压缩的（dsh 默认）。
        guard let best = candidates.max(by: { ($0.version, $0.compressed ? 1 : 0) < ($1.version, $1.compressed ? 1 : 0) }) else {
            return nil
        }
        return sessionDirectory.appendingPathComponent(best.name)
    }

    /// `.zstd` 结尾的要借 node 解。
    static func isCompressed(_ url: URL) -> Bool { url.pathExtension == "zstd" }
}

/// 不经 web 读会话日志。
///
/// - `.jsonl.zstd`：macOS SDK 里没有 zstd，借 dsh 用的 node 跑内嵌脚本（`node -e <脚本> -- <模式> <文件>`，10 秒超时）。
///   文件是多个 zstd 帧首尾拼接，Node 的 `zstdDecompressSync` 只解第一帧，所以脚本按帧格式切开再逐帧解
///  （与 `zstd -dc` 逐字节一致）。只要尾部时从后往前解到够 `tailBytes` 为止，头行另从第一帧取。写到一半的最后一帧丢掉。
/// - `.jsonl`：Swift 自己读（头 64 KB 取头行，尾部按 `tailBytes`）。
///
/// 输出只进内存，不落盘、不进日志。
public struct DshTranscriptDecoder: Sendable {
    public static let timeout: TimeInterval = 10
    public static let defaultTailBytes = 4 * 1024 * 1024

    /// 跑一次 node：参数、超时 → 标准输出。非 0 退出、超时都抛错。测试可注入。
    public typealias Runner = @Sendable (_ node: String, _ arguments: [String], _ timeout: TimeInterval) async throws -> Data

    public let node: String?
    private let runner: Runner

    /// - Parameter node: 够新的 node（`DshInstallation.node`）；nil 时只能读不压缩的日志。
    public init(node: String?, runner: @escaping Runner = DshTranscriptDecoder.runProcess) {
        self.node = node
        self.runner = runner
    }

    /// 读一份日志的头与尾部事件。
    public func read(_ file: URL, tailBytes: Int = DshTranscriptDecoder.defaultTailBytes) async throws -> DshSessionLog {
        if !DshSessionFiles.isCompressed(file) { return try Self.readPlain(file, tailBytes: tailBytes) }
        guard let node else { throw ConnectorError("没找到能解 DeepSeek Harness 会话记录的 node（需要 22.15 以上）") }
        let output = try await runner(node, ["-e", Self.script, "--", "decode", file.path, String(max(0, tailBytes))], Self.timeout)
        return try Self.parseDecoderOutput(output)
    }

    /// 只读若干份日志的头行（判断 subagent、补 cwd 用）。解不开的文件不在结果里。压缩的一次 node 进程读完。
    public func headers(_ files: [URL]) async throws -> [URL: DshSessionHeader] {
        var result: [URL: DshSessionHeader] = [:]
        var compressed: [URL] = []
        for file in files {
            if DshSessionFiles.isCompressed(file) {
                compressed.append(file)
            } else if let header = try? Self.readPlain(file, tailBytes: 0).header {
                result[file] = header
            }
        }
        guard !compressed.isEmpty, let node else { return result }
        let output = try await runner(node, ["-e", Self.script, "--", "headers"] + compressed.map(\.path), Self.timeout)
        let byPath = Dictionary(compressed.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        for line in output.split(separator: UInt8(ascii: "\n")) {
            guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
                  let path = json["file"]?.stringValue, let file = byPath[path],
                  let header = json["header"].flatMap(DshSessionHeader.init(json:)) else { continue }
            result[file] = header
        }
        return result
    }

    // MARK: - 解析输出

    /// 脚本的输出：第一行 `{"truncated":bool}`，第二行是头行（没有就是空行），之后是事件行。
    static func parseDecoderOutput(_ data: Data) throws -> DshSessionLog {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)[...]
        guard let metaLine = lines.popFirst(), let meta = try? JSONDecoder().decode(JSONValue.self, from: Data(metaLine)),
              let truncated = meta["truncated"]?.boolValue else {
            throw ConnectorError("解不开 DeepSeek Harness 的会话记录")
        }
        let headerLine = lines.popFirst() ?? Data()
        let header = (try? JSONDecoder().decode(JSONValue.self, from: Data(headerLine))).flatMap(DshSessionHeader.init(json:))
        return DshSessionLog(header: header, events: parseEvents(lines), truncated: truncated)
    }

    static func parseEvents<S: Sequence>(_ lines: S) -> [DshSessionEvent] where S.Element == Data.SubSequence {
        lines.compactMap { line in
            guard !line.isEmpty, let json = try? JSONDecoder().decode(JSONValue.self, from: Data(line)) else { return nil }
            return DshSessionEvent(json: json)
        }
    }

    /// 不压缩的日志：头 64 KB 找头行，尾部 `tailBytes`（从某行中间开始时丢掉那半行）。
    static func readPlain(_ file: URL, tailBytes: Int) throws -> DshSessionLog {
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw ConnectorError("读不到会话记录文件") }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: min(size, 64 * 1024)) ?? Data()
        let headerLine = head.split(separator: UInt8(ascii: "\n"), maxSplits: 1, omittingEmptySubsequences: false).first ?? Data()
        let header = (try? JSONDecoder().decode(JSONValue.self, from: Data(headerLine))).flatMap(DshSessionHeader.init(json:))
        guard tailBytes > 0 else { return DshSessionLog(header: header, events: [], truncated: size > 0) }
        let start = max(0, size - tailBytes)
        try handle.seek(toOffset: UInt64(start))
        var tail = try handle.readToEnd() ?? Data()
        if start > 0 {
            // 前一个字节不是换行就说明从半行开始：丢到第一个换行为止。
            try handle.seek(toOffset: UInt64(start - 1))
            let previous = try handle.read(upToCount: 1)
            if previous != Data([UInt8(ascii: "\n")]) {
                if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
                    tail = Data(tail[tail.index(after: newline)...])
                } else {
                    tail = Data()
                }
            }
        }
        let events = parseEvents(tail.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false))
        return DshSessionLog(header: header, events: events, truncated: start > 0)
    }

    // MARK: - 进程

    /// 起只读的解码进程；stderr 丢掉（可能带路径与内容，不收）。超时强制结束并报错。
    public static let runProcess: Runner = { node, arguments, timeout in
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = arguments
        // 与 AgentBinary 同一套 PATH；node 脚本不读 DSH_HOME，其他环境原样继承。
        process.environment = AgentBinary.environment(for: node)
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? stdout.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            throw ConnectorError("起不了 node：\(error.localizedDescription)")
        }
        let stop: @Sendable () -> Void = {
            guard process.isRunning else { return }
            // 解码不写会话文件，无须等待清理。SIGTERM 可被忽略，不能作为超时的硬上限。
            #if os(Windows)
            PlatformProcess.interrupt(process.processIdentifier)
            #else
            kill(process.processIdentifier, SIGKILL)
            #endif
        }
        let timer = DispatchWorkItem(block: stop)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data: Data = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
                    // 读完就关：Linux 的 Foundation 不会在 EOF 时替你关读端，每读一次会话记录就漏一个描述符。
                    try? stdout.fileHandleForReading.close()
                    process.waitUntilExit()
                    continuation.resume(returning: data)
                }
            }
        } onCancel: {
            stop()
        }
        timer.cancel()
        try Task.checkCancellation()
        // 超时会强制结束它（node 自己出错是非 0 退出码）。
        if process.terminationReason == .uncaughtSignal { throw ConnectorError("解会话记录超时") }
        guard process.terminationStatus == 0 else { throw ConnectorError("解不开 DeepSeek Harness 的会话记录") }
        return data
    }

    /// 内嵌脚本（CommonJS，`node -e`）。模式：
    /// - `decode <文件> <tailBytes>`：输出 `{"truncated":bool}`、头行、之后是完整的事件行（tailBytes 为 0 = 全部）；
    /// - `headers <文件>...`：每个文件一行 `{"file":…,"header":<头行 JSON 或 null>}`，只解第一帧。
    ///
    /// 帧格式（RFC 8878）：magic `0xFD2FB528`；帧头描述符定窗口、字典 id、内容大小的字节数；之后是若干块，
    /// 每块 3 字节头（last、type、size），RLE 块只占 1 字节；可选 4 字节校验和。`0x184D2A5?` 是可跳过帧。
    public static let script = #"""
    const fs = require('fs'), zlib = require('zlib');
    const args = process.argv.slice(1);
    const mode = args[0];
    function frames(buf) {
      const out = []; let p = 0;
      while (p + 4 <= buf.length) {
        const magic = buf.readUInt32LE(p);
        if (((magic & 0xFFFFFFF0) >>> 0) === 0x184D2A50) {
          if (p + 8 > buf.length) break;
          p += 8 + buf.readUInt32LE(p + 4); continue;
        }
        if (magic !== 0xFD2FB528) throw new Error('bad magic');
        const start = p; if (p + 5 > buf.length) break;
        const fhd = buf[p + 4]; p += 5;
        const fcsFlag = fhd >> 6, single = (fhd >> 5) & 1, checksum = (fhd >> 2) & 1, dictFlag = fhd & 3;
        if (!single) p += 1;
        p += [0, 1, 2, 4][dictFlag];
        p += [single ? 1 : 0, 2, 4, 8][fcsFlag];
        let complete = false;
        while (p + 3 <= buf.length) {
          const h = buf[p] | (buf[p + 1] << 8) | (buf[p + 2] << 16); p += 3;
          const last = h & 1, type = (h >> 1) & 3, size = h >>> 3;
          p += type === 1 ? 1 : size;
          if (last) { complete = true; break; }
        }
        if (checksum) p += 4;
        if (!complete || p > buf.length) break;
        out.push([start, p]);
      }
      return out;
    }
    function firstLine(b) { const i = b.indexOf(10); return (i < 0 ? b : b.subarray(0, i)).toString('utf8'); }
    if (mode === 'headers') {
      const lines = [];
      for (const file of args.slice(1)) {
        let header = null;
        try {
          const buf = fs.readFileSync(file); const fr = frames(buf);
          if (fr.length) header = JSON.parse(firstLine(zlib.zstdDecompressSync(buf.subarray(fr[0][0], fr[0][1]))));
        } catch (e) { header = null; }
        lines.push(JSON.stringify({ file, header }));
      }
      process.stdout.write(lines.join('\n') + '\n');
    } else if (mode === 'decode') {
      const buf = fs.readFileSync(args[1]); const tail = Number(args[2]) || 0; const fr = frames(buf);
      const dec = i => zlib.zstdDecompressSync(buf.subarray(fr[i][0], fr[i][1]));
      if (!fr.length) { process.stdout.write('{"truncated":false}\n\n'); process.exit(0); }
      const first = dec(0);
      const header = firstLine(first);
      let parts = [], size = 0, k = fr.length;
      while (k > 0 && (tail === 0 || size < tail)) { k--; const d = k === 0 ? first : dec(k); parts.unshift(d); size += d.length; }
      let body = Buffer.concat(parts);
      if (k > 0) {
        // 从第 k 帧开始：前一帧不是以换行结尾的话，第 k 帧开头是半行，丢到第一个换行为止。
        const prev = dec(k - 1);
        if (prev.length && prev[prev.length - 1] !== 10) { const i = body.indexOf(10); body = i < 0 ? Buffer.alloc(0) : body.subarray(i + 1); }
      }
      process.stdout.write(JSON.stringify({ truncated: k > 0 }) + '\n' + header + '\n');
      process.stdout.write(body);
    } else {
      process.exit(2);
    }
    """#
}

/// dsh 会话事件 → BotBus 对话记录。JSONL 与 web 的 follow / page 记录解出来都是 `DshSessionEvent`，同一套规则：
///
/// - `user/message` 只认 `source.kind == "user"`（人发的提示词：ACP 的没有 `rpcId`，web 的有）；运行时上下文
///  （`plugin`）、技能目录（`skill-catalog`）不进。
/// - `assistant/message` 的 `text` 段 → `.agent`，`reasoning` 与 `tool-call` 段不进；一轮里每一步各一条（没字的丢掉）。
/// - `tool/call` → 一行 `.tool` 摘要（工具名，能认出命令 / 路径时带上）；`tool/result` 不进（正文往往很长）。
/// - 带 `surfaceOp` 且不是 `"append"` 的（压缩上下文时的替换副本）不进：它们只给模型看，人已经看过原文。
///
/// id：消息用 dsh 的消息 id（`data.id` / `data.message.id`），没有就 `seq-<seq>`；工具行 `tool-<callId>`。重复拉取时稳定。
public enum DshTranscriptParser {
    /// 全部条目，升序，**不带路径候选**（窗口里的回复另补，见 `window`）。
    public static func entries(from events: [DshSessionEvent]) -> [TranscriptEntry] {
        events.compactMap { event -> TranscriptEntry? in
            guard !event.isReplacement else { return nil }
            let createdAt = ProtocolJSON.timestamp(event.time ?? Date(timeIntervalSince1970: 0))
            switch event.type {
            case "user/message":
                guard event.sourceKind == "user" else { return nil }
                return transcriptEntry(id: messageId(event), role: .user, text: event.text, createdAt: createdAt,
                                       extractPaths: false)
            case "assistant/message":
                return transcriptEntry(id: messageId(event), role: .agent, text: event.text, createdAt: createdAt,
                                       extractPaths: false)
            case "tool/call":
                guard let callId = event.data["callId"]?.stringValue, !callId.isEmpty else { return nil }
                return transcriptEntry(id: "tool-\(callId)", role: .tool, text: toolSummary(event.data), createdAt: createdAt)
            default:
                return nil
            }
        }
    }

    /// 最近 `limit` 条对话的窗口（`TranscriptWindow.latest`），窗口里的 Agent 回复补路径候选。
    /// `truncated`（只读了尾部）时 `hasMore` 一定为 true。
    public static func window(from events: [DshSessionEvent], limit: Int,
                              truncated: Bool = false) -> (entries: [TranscriptEntry], hasMore: Bool) {
        let (window, hasMore) = TranscriptWindow.latest(entries(from: events), limit: limit)
        let wanted = Set(window.filter { $0.message.role == .agent }.map(\.message.id))
        var raw: [String: String] = [:]
        for event in events where event.type == "assistant/message" && !event.isReplacement {
            let id = messageId(event)
            if wanted.contains(id) { raw[id] = event.text }
        }
        return (addingPathCandidates(to: window) { raw[$0.message.id] }, hasMore || truncated)
    }

    /// 最后一条 Agent 回复（有字的 `assistant/message`），原文不截断；没有返回 nil。
    public static func lastAgentMessage(in events: [DshSessionEvent]) -> String? {
        for event in events.reversed() where event.type == "assistant/message" && !event.isReplacement {
            if let text = event.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        }
        return nil
    }

    /// 最后一次 `turn/end`（原因、时间）。之后又有 `turn/start` 的（这一轮还在跑）返回 nil。
    public static func lastTurnEnd(in events: [DshSessionEvent]) -> (reason: DshTurnEndReason, at: Date?)? {
        for event in events.reversed() {
            if event.type == "turn/start" { return nil }
            if let reason = event.turnEndReason { return (reason, event.time) }
        }
        return nil
    }

    /// 最后一个 `turn/start` 之后还没有 `turn/end`：这一轮在跑（或进程在这一轮中途没了）。
    public static func hasOpenTurn(_ events: [DshSessionEvent]) -> Bool {
        for event in events.reversed() {
            if event.type == "turn/end" { return false }
            if event.type == "turn/start" { return true }
        }
        return false
    }

    static func messageId(_ event: DshSessionEvent) -> String {
        let id = event.type == "assistant/message" ? event.data.path("message", "id")?.stringValue : event.data["id"]?.stringValue
        return id.flatMap { $0.isEmpty ? nil : $0 } ?? "seq-\(event.seq)"
    }

    /// 工具名，加上参数里最能说明它在干什么的一个字符串（命令、路径、网址、查询）。参数是 JSON 字符串。
    static func toolSummary(_ data: JSONValue) -> String {
        let name = data["name"]?.stringValue ?? "tool"
        guard let text = data["arguments"]?.stringValue,
              let arguments = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return name }
        if let command = arguments["command"]?.stringValue, !command.isEmpty { return "$ \(AcpSessionState.singleLine(command))" }
        for key in ["path", "file_path", "url", "query", "pattern", "description"] {
            if let value = arguments[key]?.stringValue, !value.isEmpty { return "\(name) \(AcpSessionState.singleLine(value))" }
        }
        return name
    }
}

extension DshSessionEvent {
    /// 压缩上下文时写的替换副本（`surfaceOp` 是 `{op:"replace",…}` 而不是 `"append"`）。
    public var isReplacement: Bool { surfaceOp.map { $0 != .string("append") } ?? false }
}
