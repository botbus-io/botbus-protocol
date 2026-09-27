import XCTest
import BotBusProtocol
@testable import BotBusConnectorKit
@testable import BotBusConnectors

/// dsh 会话日志的形状照真实 0.1.5-rc.3 的日志抄的，内容全是编的。
enum DshFixture {
    static let header: JSONValue = ["type": "session", "version": 3, "id": "sess-1", "createdAt": 1_790_485_686_415,
                                    "cwd": "/Users/me/app", "isSeeded": false, "delegationDepth": 0]

    static func event(_ type: String, _ seq: Int64, _ data: JSONValue, surfaceOp: JSONValue? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["type": .string(type), "seq": .int(seq), "time": .int(1_790_485_686_415 + seq * 1000),
                                           "data": data]
        if let surfaceOp { object["surfaceOp"] = surfaceOp }
        return .object(object)
    }

    static func user(_ seq: Int64, _ text: String, kind: String = "user", id: String? = nil) -> JSONValue {
        event("user/message", seq, ["content": [["type": "text", "text": .string(text)]], "role": "user",
                                    "id": .string(id ?? "u-\(seq)"), "source": ["kind": .string(kind)]], surfaceOp: "append")
    }

    static func assistant(_ seq: Int64, text: String?, reasoning: String? = "想一想", toolCall: Bool = false,
                          surfaceOp: JSONValue = "append") -> JSONValue {
        var content: [JSONValue] = []
        if let reasoning { content.append(["type": "reasoning", "text": .string(reasoning)]) }
        if toolCall { content.append(["type": "tool-call", "id": .string("call_\(seq)"), "name": "bash", "arguments": "{}"]) }
        if let text { content.append(["type": "text", "text": .string(text)]) }
        return event("assistant/message", seq, ["turn": 1, "step": 1, "message": [
            "role": "assistant", "id": .string("a-\(seq)"), "content": .array(content), "source": ["kind": "model"],
        ]], surfaceOp: surfaceOp)
    }

    static func toolCall(_ seq: Int64, name: String = "bash", arguments: String = #"{"command": "ls -la\nwc -l"}"#) -> JSONValue {
        event("tool/call", seq, ["turn": 1, "step": 1, "callId": .string("call_\(seq)"), "name": .string(name),
                                 "arguments": .string(arguments)])
    }

    static func turnEnd(_ seq: Int64, _ kind: String) -> JSONValue {
        event("turn/end", seq, ["turn": 1, "reason": ["kind": .string(kind)]])
    }

    /// 一轮完整的会话：提示词 + 运行时上下文 + 技能目录 + 工具 + 回复。
    static var turn: [JSONValue] {
        [
            event("turn/start", 4, ["turn": 1]),
            user(8, "列一下文件"),
            user(9, "Current runtime context…", kind: "plugin"),
            user(10, "<system-reminder>skills</system-reminder>", kind: "skill-catalog"),
            assistant(14, text: nil, toolCall: true),
            toolCall(15),
            event("tool/result", 16, ["message": ["content": [["type": "tool-result", "content": [["type": "text", "text": "很长的输出"]]]]]],
                  surfaceOp: "append"),
            assistant(24, text: "一共 3 个文件，见 `out/a.png`"),
            event("session/title", 25, ["title": "列文件"]),
            turnEnd(26, "completed"),
        ]
    }

    static func jsonl(_ lines: [JSONValue]) -> Data {
        Data(lines.map { $0.encodedString() }.joined(separator: "\n").utf8 + [UInt8(ascii: "\n")])
    }
}

final class DshTranscriptParserTests: XCTestCase {
    private var events: [DshSessionEvent] { DshFixture.turn.compactMap(DshSessionEvent.init(json:)) }

    func testMapsOnlyRealPromptsRepliesAndToolCalls() {
        let entries = DshTranscriptParser.entries(from: events)
        XCTAssertEqual(entries.map(\.message.role), [.user, .tool, .agent])
        XCTAssertEqual(entries.map(\.message.text), ["列一下文件", "$ ls -la wc -l", "一共 3 个文件，见 `out/a.png`"])
        XCTAssertEqual(entries.map(\.message.id), ["u-8", "tool-call_15", "a-24"])
        XCTAssertEqual(entries.first?.message.createdAt, ProtocolJSON.timestamp(Date(timeIntervalSince1970: 1_790_485_694.415)))
    }

    func testFollowRecordsParseTheSameWay() {
        let wrapped = DshFixture.turn.map { JSONValue.object(["type": "event", "event": $0]) }
        let fromFollow = DshTranscriptParser.entries(from: wrapped.compactMap(DshSessionEvent.init(json:)))
        XCTAssertEqual(fromFollow, DshTranscriptParser.entries(from: events))
    }

    func testReplacementCopiesAreSkipped() {
        let replaced = DshSessionEvent(json: DshFixture.assistant(30, text: "压缩后的摘要",
                                                                  surfaceOp: ["op": "replace", "startSeq": 8, "endSeq": 24]))!
        XCTAssertTrue(replaced.isReplacement)
        XCTAssertTrue(DshTranscriptParser.entries(from: events + [replaced]).allSatisfy { $0.message.text != "压缩后的摘要" })
        XCTAssertEqual(DshTranscriptParser.lastAgentMessage(in: events + [replaced]), "一共 3 个文件，见 `out/a.png`")
    }

    func testToolSummaries() {
        func summary(_ name: String, _ arguments: String) -> String {
            DshTranscriptParser.toolSummary(["name": .string(name), "arguments": .string(arguments)])
        }
        XCTAssertEqual(summary("read_file", #"{"path": "src/a.swift"}"#), "read_file src/a.swift")
        XCTAssertEqual(summary("todo", #"{"items": []}"#), "todo")
        XCTAssertEqual(summary("weird", "not json"), "weird")
    }

    func testWindowAddsPathCandidatesAndHonoursTruncation() {
        let (entries, hasMore) = DshTranscriptParser.window(from: events, limit: 40)
        XCTAssertFalse(hasMore)
        XCTAssertEqual(entries.last?.pathCandidates, ["out/a.png"])
        XCTAssertTrue(DshTranscriptParser.window(from: events, limit: 40, truncated: true).hasMore)
        let (one, more) = DshTranscriptParser.window(from: events, limit: 1)
        XCTAssertEqual(one.map(\.message.role), [.tool, .agent], "最旧那条回复所在一轮的工具行跟着进窗口")
        XCTAssertTrue(more)
    }

    func testTurnState() {
        XCTAssertEqual(DshTranscriptParser.lastTurnEnd(in: events)?.reason, .completed)
        XCTAssertFalse(DshTranscriptParser.hasOpenTurn(events))
        let next = events + [DshSessionEvent(json: DshFixture.event("turn/start", 27, ["turn": 2]))!,
                             DshSessionEvent(json: DshFixture.user(28, "再来"))!]
        XCTAssertNil(DshTranscriptParser.lastTurnEnd(in: next))
        XCTAssertTrue(DshTranscriptParser.hasOpenTurn(next))
        let aborted = next + [DshSessionEvent(json: DshFixture.turnEnd(29, "aborted"))!]
        XCTAssertEqual(DshTranscriptParser.lastTurnEnd(in: aborted)?.reason.status, .interrupted)
        XCTAssertNil(DshTranscriptParser.lastAgentMessage(in: [DshSessionEvent(json: DshFixture.assistant(1, text: "  "))!]))
    }
}

final class DshTranscriptDecoderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testPicksNewestGenerationLogFile() throws {
        for name in ["session.jsonl", "session.v2.jsonl.zstd", "session.v3.jsonl.zstd", "session.v3.jsonl", "session.lock",
                     "session.v10.tmp", "session.vx.jsonl"] {
            FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: Data())
        }
        XCTAssertEqual(DshSessionFiles.logFile(in: root)?.lastPathComponent, "session.v3.jsonl.zstd")
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: legacy.appendingPathComponent("session.jsonl").path, contents: Data())
        XCTAssertEqual(DshSessionFiles.logFile(in: legacy)?.lastPathComponent, "session.jsonl")
        XCTAssertNil(DshSessionFiles.logFile(in: root.appendingPathComponent("missing")))
    }

    func testParsesDecoderOutput() throws {
        var output = Data(#"{"truncated":true}"#.utf8 + [10])
        output += DshFixture.header.encodedString().utf8 + [10]
        output += DshFixture.jsonl(DshFixture.turn)
        let log = try DshTranscriptDecoder.parseDecoderOutput(output)
        XCTAssertTrue(log.truncated)
        XCTAssertEqual(log.header?.id, "sess-1")
        XCTAssertEqual(log.header?.cwd, "/Users/me/app")
        XCTAssertEqual(log.events.count, DshFixture.turn.count)
        XCTAssertThrowsError(try DshTranscriptDecoder.parseDecoderOutput(Data("garbage".utf8)))
    }

    func testReadsPlainLogTail() async throws {
        let file = root.appendingPathComponent("session.v3.jsonl")
        try DshFixture.jsonl([DshFixture.header] + DshFixture.turn).write(to: file)
        let decoder = DshTranscriptDecoder(node: nil)
        let full = try await decoder.read(file)
        XCTAssertFalse(full.truncated)
        XCTAssertEqual(full.header?.id, "sess-1")
        XCTAssertEqual(full.events.count, DshFixture.turn.count)
        // 尾部落在某行中间：那半行丢掉，其余完整。
        let tail = try await decoder.read(file, tailBytes: 300)
        XCTAssertTrue(tail.truncated)
        XCTAssertEqual(tail.header?.id, "sess-1")
        XCTAssertFalse(tail.events.isEmpty)
        XCTAssertEqual(tail.events.last?.type, "turn/end")
        XCTAssertEqual(tail.events.map(\.seq), full.events.suffix(tail.events.count).map(\.seq))
        let headers = try await decoder.headers([file])
        XCTAssertEqual(headers[file]?.id, "sess-1")
    }

    func testCompressedWithoutNodeExplainsItself() async {
        let decoder = DshTranscriptDecoder(node: nil)
        do {
            _ = try await decoder.read(root.appendingPathComponent("session.v3.jsonl.zstd"))
            XCTFail("应当失败")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("node"), error.localizedDescription)
        }
    }

    func testRunnerTimeoutAndArguments() async throws {
        let seen = Locked<[String]>([])
        let decoder = DshTranscriptDecoder(node: "/fake/node") { node, arguments, timeout in
            seen.withLock { $0 = [node] + arguments.filter { $0 != DshTranscriptDecoder.script } + ["\(Int(timeout))"] }
            return Data(#"{"truncated":false}"#.utf8 + [10, 10])
        }
        let log = try await decoder.read(URL(fileURLWithPath: "/x/session.v3.jsonl.zstd"), tailBytes: 1234)
        XCTAssertEqual(seen.current, ["/fake/node", "-e", "--", "decode", "/x/session.v3.jsonl.zstd", "1234", "10"])
        XCTAssertNil(log.header)
        XCTAssertTrue(log.events.isEmpty)
    }

    /// 真 node：拿 node 自己的 `zstdCompressSync` 把 JSONL 按几段各压一帧再拼起来（同 dsh 追加写的形状），
    /// 解回来要逐字节一样；只要尾部时头行照给、事件行完整。本机没有够新的 node 就跳过。
    func testRealNodeDecodesMultiFrameZstd() async throws {
        guard let node = DshPaths.selectNode(from: DshPaths.defaultNodeCandidates(), version: DshPaths.probeNodeVersion) else {
            throw XCTSkip("本机没有 22.15 以上的 node")
        }
        let plain = root.appendingPathComponent("plain.jsonl")
        let lines = [DshFixture.header] + DshFixture.turn + (30..<60).map { DshFixture.user(Int64($0), String(repeating: "长", count: 200)) }
        try DshFixture.jsonl(lines).write(to: plain)
        let compressed = root.appendingPathComponent("session.v3.jsonl.zstd")
        // 每 700 字节切一刀（故意切在行中间），各压一帧。
        let pack = """
        const fs = require('fs'), zlib = require('zlib');
        const [src, dst] = process.argv.slice(1); const buf = fs.readFileSync(src); const parts = [];
        for (let i = 0; i < buf.length; i += 700) parts.push(zlib.zstdCompressSync(buf.subarray(i, i + 700)));
        fs.writeFileSync(dst, Buffer.concat(parts));
        """
        _ = try await DshTranscriptDecoder.runProcess(node, ["-e", pack, "--", plain.path, compressed.path], 10)
        let decoder = DshTranscriptDecoder(node: node)

        let full = try await decoder.read(compressed, tailBytes: 0)
        XCTAssertFalse(full.truncated)
        XCTAssertEqual(full.header?.id, "sess-1")
        XCTAssertEqual(full.events.count, lines.count - 1)
        let raw = try await DshTranscriptDecoder.runProcess(node, ["-e", DshTranscriptDecoder.script, "--", "decode",
                                                                   compressed.path, "0"], 10)
        let body = raw.split(separator: UInt8(ascii: "\n"), maxSplits: 2, omittingEmptySubsequences: false)[2]
        XCTAssertEqual(Data(body), try Data(contentsOf: plain), "与原文逐字节一致")

        let tail = try await decoder.read(compressed, tailBytes: 2000)
        XCTAssertTrue(tail.truncated)
        XCTAssertEqual(tail.header?.id, "sess-1")
        XCTAssertFalse(tail.events.isEmpty)
        XCTAssertEqual(tail.events.map(\.seq), full.events.suffix(tail.events.count).map(\.seq))

        let headers = try await decoder.headers([compressed, root.appendingPathComponent("missing.jsonl.zstd")])
        XCTAssertEqual(headers.count, 1)
        XCTAssertEqual(headers[compressed]?.cwd, "/Users/me/app")

        // 写到一半的最后一帧：丢掉，之前的照读。
        var partial = try Data(contentsOf: compressed)
        partial.removeLast(5)
        let cut = root.appendingPathComponent("cut.jsonl.zstd")
        try partial.write(to: cut)
        let recovered = try await decoder.read(cut, tailBytes: 0)
        XCTAssertEqual(recovered.header?.id, "sess-1")
        XCTAssertLessThan(recovered.events.count, full.events.count)
    }
}
