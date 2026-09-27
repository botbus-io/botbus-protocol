import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

/// 对话记录的两种来源。映射写错的后果不是崩溃，而是"聊天记录里少了一半"，
/// 所以每种 item 类型都得有一条断言钉住。
final class MessageReaderTests: XCTestCase {

    // MARK: - Codex：thread_items 的各种 item_type

    func testCodexMapsEachItemTypeToReadableText() {
        func text(_ type: String, _ json: String) -> String? {
            CodexMessageReader.content(ofType: type, json: json).text
        }
        XCTAssertEqual(text("agentMessage", #"{"text":"改完了"}"#), "改完了")
        XCTAssertEqual(text("userMessage", #"{"content":[{"type":"text","text":"帮我改一下"}]}"#), "帮我改一下")
        XCTAssertEqual(text("userMessage", #"{"content":"老结构，直接是字符串"}"#), "老结构，直接是字符串")
        XCTAssertEqual(text("commandExecution", #"{"command":"swift build","exitCode":0}"#), "$ swift build")
        XCTAssertEqual(text("commandExecution", #"{"command":"swift test","exitCode":1}"#), "$ swift test（退出码 1）")
        XCTAssertEqual(text("fileChange", #"{"changes":[{"path":"/a/b/Foo.swift","kind":"edit"}]}"#), "改动 Foo.swift")
        XCTAssertEqual(text("mcpToolCall", #"{"server":"figma","tool":"get_file"}"#), "调用 figma/get_file")
        XCTAssertEqual(text("webSearch", #"{"query":"swift actor"}"#), "搜索「swift actor」")
    }

    /// `reasoning` 在真实库里是最多的一种（7000+ 条），放进来会把一问一答彻底淹掉。
    func testCodexExcludesReasoning() {
        XCTAssertFalse(CodexMessageReader.includedTypes.contains("reasoning"))
        XCTAssertNil(CodexMessageReader.content(ofType: "reasoning", json: #"{"text":"内部思考"}"#).text)
    }

    func testCodexRoleMapping() throws {
        func role(_ type: String, _ json: String) throws -> Message.Role {
            let row: [String: SQLiteValue] = ["item_id": .text("i1"), "item_type": .text(type),
                                              "item_json": .text(json), "created_at_ms": .integer(1_760_000_000_000)]
            return try XCTUnwrap(CodexMessageReader.entry(from: row)?.message).role
        }
        XCTAssertEqual(try role("userMessage", #"{"content":[{"type":"text","text":"问"}]}"#), .user)
        XCTAssertEqual(try role("agentMessage", #"{"text":"答"}"#), .agent)
        XCTAssertEqual(try role("commandExecution", #"{"command":"ls"}"#), .tool)
        XCTAssertEqual(try role("fileChange", #"{"changes":[{"path":"/a.swift"}]}"#), .tool)
    }

    /// 正文为空的条目不该变成一条空气泡。
    func testCodexSkipsEmptyItems() {
        let row: [String: SQLiteValue] = ["item_id": .text("i1"), "item_type": .text("agentMessage"),
                                          "item_json": .text(#"{"text":"   "}"#), "created_at_ms": .integer(0)]
        XCTAssertNil(CodexMessageReader.entry(from: row)?.message)
    }

    func testMessageTextIsTruncatedWithEllipsis() {
        let long = String(repeating: "长", count: TaskMessages.maxMessageLength + 50)
        let row: [String: SQLiteValue] = ["item_id": .text("i1"), "item_type": .text("agentMessage"),
                                          "item_json": .text(String(data: try! JSONSerialization.data(
                                              withJSONObject: ["text": long]), encoding: .utf8)!),
                                          "created_at_ms": .integer(0)]
        let message = CodexMessageReader.entry(from: row)?.message
        XCTAssertEqual(message?.text.count, TaskMessages.maxMessageLength + 1, "截断后多一个省略号")
        XCTAssertEqual(message?.text.hasSuffix("…"), true)
    }

    // MARK: - Codex：图片

    private func codexRow(_ type: String, _ json: String, id: String = "i1") -> [String: SQLiteValue] {
        ["item_id": .text(id), "item_type": .text(type), "item_json": .text(json), "created_at_ms": .integer(0)]
    }

    func testCodexUserMessageCollectsLocalAndInlineImages() throws {
        let json = """
            {"content":[{"type":"text","text":"看"},{"type":"localImage","path":"/tmp/x.png","detail":null},\
            {"type":"image","url":"\(TestImage.pngDataURL)","detail":null}]}
            """
        let entry = try XCTUnwrap(CodexMessageReader.entry(from: codexRow("userMessage", json)))
        XCTAssertEqual(entry.message.role, .user)
        XCTAssertEqual(entry.message.text, "看")
        XCTAssertEqual(entry.images, [.file(URL(fileURLWithPath: "/tmp/x.png")), .data(TestImage.png, contentType: "image/png")])
        XCTAssertEqual(entry.pathCandidates, [])
        XCTAssertNil(entry.message.attachments, "附件由 uploader 填，读取器不碰")
    }

    /// 只发了一张图、没打字：2.9 起也是一条对话，正文为空串。
    func testCodexImageOnlyUserMessageIsKept() throws {
        let entry = try XCTUnwrap(CodexMessageReader.entry(from: codexRow(
            "userMessage", #"{"content":[{"type":"localImage","path":"/tmp/x.png"}]}"#)))
        XCTAssertEqual(entry.message.text, "")
        XCTAssertEqual(entry.images, [.file(URL(fileURLWithPath: "/tmp/x.png"))])
    }

    func testCodexImageGenerationIsAnAgentImage() throws {
        XCTAssertTrue(CodexMessageReader.includedTypes.contains("imageGeneration"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gen-\(UUID().uuidString).png")
        try TestImage.png.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let saved = try XCTUnwrap(CodexMessageReader.entry(from: codexRow("imageGeneration", """
            {"id":"ig1","status":"completed","result":"\(TestImage.pngBase64)","savedPath":"\(file.path)","revisedPrompt":"一只猫"}
            """)))
        XCTAssertEqual(saved.message.role, .agent)
        XCTAssertEqual(saved.message.text, "一只猫")
        XCTAssertEqual(saved.images, [.file(URL(fileURLWithPath: file.path))], "落盘的文件优先，不搬 base64")

        let inline = try XCTUnwrap(CodexMessageReader.entry(from: codexRow("imageGeneration", """
            {"id":"ig2","status":"completed","result":"\(TestImage.pngBase64)"}
            """)))
        XCTAssertEqual(inline.message.text, "")
        XCTAssertEqual(inline.images, [.data(TestImage.png, contentType: "image/png")], "没落盘就用 result")

        let home = try XCTUnwrap(CodexMessageReader.entry(from: codexRow("imageGeneration", """
            {"id":"ig3","savedPath":"~/.codex/generated_images/t/exec-1.png","revisedPrompt":"猫"}
            """)))
        XCTAssertEqual(home.images, [.file(URL(fileURLWithPath: NSHomeDirectory() + "/.codex/generated_images/t/exec-1.png"))],
                       "~ 开头的展开成 home")
    }

    /// 用户删了落盘的图：`savedPath` 还在库里，退回 `result` 的内嵌字节。
    func testCodexImageGenerationFallsBackToResultWhenSavedFileIsGone() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("gone-\(UUID().uuidString).png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let entry = try XCTUnwrap(CodexMessageReader.entry(from: codexRow("imageGeneration", """
            {"id":"ig4","result":"\(TestImage.pngBase64)","savedPath":"\(missing.path)","revisedPrompt":"猫"}
            """)))
        XCTAssertEqual(entry.images, [.data(TestImage.png, contentType: "image/png")])
    }

    func testCodexImageGenerationPromptIsTruncatedLikeOtherText() throws {
        let long = String(repeating: "猫", count: TaskMessages.maxMessageLength + 10)
        let entry = try XCTUnwrap(CodexMessageReader.entry(from: codexRow("imageGeneration", """
            {"savedPath":"/tmp/gen.png","revisedPrompt":"\(long)"}
            """)))
        XCTAssertEqual(entry.message.text.count, TaskMessages.maxMessageLength + 1)
    }

    func testCodexTextOnlyAndBrokenImagesHaveNoImages() throws {
        let plain = try XCTUnwrap(CodexMessageReader.entry(from: codexRow("userMessage", #"{"content":[{"type":"text","text":"问"}]}"#)))
        XCTAssertEqual(plain.images, [])
        XCTAssertEqual(try XCTUnwrap(CodexMessageReader.entry(from: codexRow("agentMessage", #"{"text":"答"}"#))).images, [])
        // 相对路径、非图片的 data URL、坏 base64 都不算图；没有文字就整条不出。
        XCTAssertNil(CodexMessageReader.entry(from: codexRow("userMessage", """
            {"content":[{"type":"localImage","path":"x.png"},{"type":"image","url":"data:text/plain;base64,aGk="}]}
            """)))
        XCTAssertNil(CodexMessageReader.entry(from: codexRow("imageGeneration", #"{"result":"不是 base64"}"#)))
    }

    // MARK: - Claude：JSONL transcript

    func testClaudeParsesTranscriptLines() throws {
        func message(_ line: String) -> Message? {
            ClaudeMessageReader.entries(from: Substring(line), ordinal: 0).first?.message
        }
        let user = try XCTUnwrap(message(#"{"type":"user","uuid":"u1","timestamp":"2026-09-20T10:00:00Z","message":{"content":[{"type":"text","text":"帮我改一下"}]}}"#))
        XCTAssertEqual(user.role, .user)
        XCTAssertEqual(user.text, "帮我改一下")
        XCTAssertEqual(user.id, "u1", "有 uuid 就用它——行号在中途插入时会漂")
        XCTAssertEqual(user.createdAt, "2026-09-20T10:00:00Z")
        let precise = try XCTUnwrap(message(#"{"type":"user","uuid":"u2","timestamp":"2026-09-20T10:00:05.598Z","message":{"content":"再改"}}"#))
        XCTAssertEqual(precise.createdAt, "2026-09-20T10:00:05Z", "transcript 的毫秒时间换成协议的秒精度")

        let assistant = try XCTUnwrap(message(#"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"改完了"}]}}"#))
        XCTAssertEqual(assistant.role, .agent)
        XCTAssertEqual(assistant.text, "改完了")

        // 工具调用压成一行 `.tool`；tool_result 的正文往往是整个文件，直接跳过。
        let tool = try XCTUnwrap(message(#"{"type":"assistant","uuid":"a2","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}"#))
        XCTAssertEqual(tool.role, .tool)
        XCTAssertEqual(tool.id, "a2#1")
        XCTAssertEqual(tool.text, "调用 Bash")

        // 不是对话的行一律忽略，不能变成空气泡。
        XCTAssertNil(message(#"{"type":"system","subtype":"init"}"#))
        XCTAssertNil(message("这一行根本不是 JSON"))
        XCTAssertNil(message(#"{"type":"assistant","uuid":"a3","message":{"content":[{"type":"tool_result","content":"一屏日志"}]}}"#))
    }

    /// resume 一个没跑完的会话时 Claude Code 自己补的两行（2.1.273 实测形状）不进对话；API 报错照常显示。
    func testClaudeSkipsResumeFillerButKeepsAPIErrors() throws {
        func message(_ line: String) -> Message? {
            ClaudeMessageReader.entries(from: Substring(line), ordinal: 0).first?.message
        }
        XCTAssertNil(message(#"{"type":"user","isMeta":true,"uuid":"m1","message":{"role":"user","content":[{"type":"text","text":"Continue from where you left off."}]}}"#))
        XCTAssertNil(message(#"{"type":"assistant","uuid":"m2","isApiErrorMessage":false,"message":{"model":"<synthetic>","content":[{"type":"text","text":"No response requested."}]}}"#))
        let error = try XCTUnwrap(message(#"{"type":"assistant","uuid":"m3","isApiErrorMessage":true,"error":"authentication_failed","message":{"model":"<synthetic>","content":[{"type":"text","text":"Not logged in · Please run /login"}]}}"#))
        XCTAssertEqual(error.text, "Not logged in · Please run /login")
        // 中断时 Claude Code 以 user 身份写的标记行，不是用户说的话。
        XCTAssertNil(message(#"{"type":"user","uuid":"m4","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#))
        XCTAssertNil(message(#"{"type":"user","uuid":"m5","message":{"role":"user","content":"[Request interrupted by user for tool use]"}}"#))
        // 用户真的这么写、或者带着别的话，照常显示。
        XCTAssertNotNil(message(#"{"type":"user","uuid":"m6","message":{"role":"user","content":[{"type":"text","text":"刚才 [Request interrupted by user] 是什么意思"}]}}"#))

        // 最后一条消息（Stop 读 transcript、启动补历史）也不能是填充行。
        let filler: [String: Any] = ["type": "assistant", "message": ["model": "<synthetic>", "content": [["type": "text", "text": "No response requested."]]]]
        XCTAssertNil(ClaudeConnector.assistantText(filler))
    }

    /// Claude Code 往 transcript 里写的 user 行有一大半不是人说的话，手机上不能当成用户消息显示。
    func testClaudeSkipsInjectedUserLines() throws {
        func message(_ line: String) -> Message? {
            ClaudeMessageReader.entries(from: Substring(line), ordinal: 0).first?.message
        }
        XCTAssertNil(message(#"{"type":"user","uuid":"u1","message":{"content":[{"type":"text","text":"<system-reminder>\nYou are operating in a git worktree.\n</system-reminder>"}]}}"#),
                     "整条都是注入块的行不出气泡")
        XCTAssertNil(message(#"{"type":"user","uuid":"u2","message":{"content":[{"type":"text","text":"<task-notification>\n<task-id>abc</task-id>\n</task-notification>"}]}}"#))
        XCTAssertNil(message(#"{"type":"user","uuid":"u3","isMeta":true,"message":{"content":[{"type":"text","text":"[Image: source: /tmp/a.png]"}]}}"#),
                     "isMeta 是 Claude Code 自己写的占位行")
        XCTAssertNil(message(#"{"type":"user","uuid":"u4","isSidechain":true,"message":{"content":[{"type":"text","text":"子代理的活"}]}}"#))

        // 夹在真话后面时只去掉那一段。
        let mixed = try XCTUnwrap(message(#"{"type":"user","uuid":"u5","message":{"content":[{"type":"text","text":"继续<system-reminder>别忘了 X</system-reminder>"}]}}"#))
        XCTAssertEqual(mixed.text, "继续")
        // 闭标签被截掉时删到末尾，不能把半截提醒露出来。
        let unclosed = try XCTUnwrap(message(#"{"type":"user","uuid":"u6","message":{"content":"继续<system-reminder>别忘了 X"}}"#))
        XCTAssertEqual(unclosed.text, "继续")
        // 真话本身带尖括号不受影响。
        XCTAssertEqual(try XCTUnwrap(message(#"{"type":"user","uuid":"u7","message":{"content":[{"type":"text","text":"<div> 这个标签改一下"}]}}"#)).text,
                       "<div> 这个标签改一下")
    }

    /// 正文与工具调用混在一行时拆开：正文一条 `.agent`（用 uuid），每个 tool_use 各一行 `.tool`（`uuid#n`）。
    func testClaudeSplitsToolUseIntoToolRows() {
        let line = #"""
            {"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"我先看看"},\#
            {"type":"tool_use","name":"Bash","input":{"command":"git status\n--short"}},\#
            {"type":"tool_use","name":"Edit","input":{"file_path":"/p/Sources/App.swift","old_string":"整段文件"}},\#
            {"type":"tool_use","name":"Grep","input":{"pattern":"TODO"}}]}}
            """#
        let entries = ClaudeMessageReader.entries(from: Substring(line), ordinal: 0)
        XCTAssertEqual(entries.map(\.message.id), ["a1", "a1#1", "a1#2", "a1#3"])
        XCTAssertEqual(entries.map(\.message.role), [.agent, .tool, .tool, .tool])
        XCTAssertEqual(entries.map(\.message.text),
                       ["我先看看", "$ git status --short", "调用 Edit：App.swift", "调用 Grep：TODO"])
    }

    func testClaudeUserImagesAreCollected() throws {
        func entry(_ content: String) -> TranscriptEntry? {
            ClaudeMessageReader.entries(from: Substring(#"{"type":"user","uuid":"u1","message":{"content":"# + content + "}}"), ordinal: 0).first
        }
        let mixed = try XCTUnwrap(entry("""
            [{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"\(TestImage.pngBase64)"}},{"type":"text","text":"这张"}]
            """))
        XCTAssertEqual(mixed.message.text, "这张")
        XCTAssertEqual(mixed.images, [.data(TestImage.png, contentType: "image/jpeg")])
        XCTAssertEqual(mixed.pathCandidates, [])

        let imageOnly = try XCTUnwrap(entry("""
            [{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\(TestImage.pngBase64)"}}]
            """))
        XCTAssertEqual(imageOnly.message.text, "", "只有图也是一条")
        XCTAssertEqual(imageOnly.images.count, 1)

        // tool_result 里嵌的是工具截图，跟 tool_result 一起跳过：这样的 user 行照旧不出消息。
        XCTAssertNil(entry("""
            [{"type":"tool_result","tool_use_id":"t1","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\(TestImage.pngBase64)"}}]}]
            """))
        XCTAssertEqual(try XCTUnwrap(entry(#"[{"type":"text","text":"纯文字"}]"#)).images, [])
    }

    func testClaudeAssistantImagesAreIgnored() throws {
        let line = """
            {"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"给你"},\
            {"type":"image","source":{"type":"base64","media_type":"image/png","data":"\(TestImage.pngBase64)"}}]}}
            """
        let entry = try XCTUnwrap(ClaudeMessageReader.entries(from: Substring(line), ordinal: 0).first)
        XCTAssertEqual(entry.message.text, "给你")
        XCTAssertEqual(entry.images, [])
        let imageOnly = """
            {"type":"assistant","uuid":"a2","message":{"content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\(TestImage.pngBase64)"}}]}}
            """
        XCTAssertEqual(ClaudeMessageReader.entries(from: Substring(imageOnly), ordinal: 0), [])
    }

    /// transcript 靠文件名定位——文件名就是 session id，所以 Agent 重启丢了内存状态也找得回来。
    func testClaudeFindsTranscriptByFileName() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-transcripts-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("-Users-me-Projects-demo", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "b3f162c3-8b27-4d7c-b058-3feeeaa19ade"
        try Data("{}".utf8).write(to: project.appendingPathComponent("\(sessionID).jsonl"))

        XCTAssertNotNil(ClaudeMessageReader.transcriptURL(sessionID: sessionID, in: root))
        XCTAssertNil(ClaudeMessageReader.transcriptURL(sessionID: "不存在的会话", in: root))
    }

    func testClaudeReadsNewestMessagesAndReportsHasMore() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-transcripts-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("p", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "s-1"
        let lines = (0..<10).map { i in
            #"{"type":"user","uuid":"u\#(i)","message":{"content":[{"type":"text","text":"第 \#(i) 条"}]}}"#
        }
        try Data(lines.joined(separator: "\n").utf8).write(to: project.appendingPathComponent("\(sessionID).jsonl"))

        // ClaudePaths 指向临时目录：projectsDirectory 就是 root 下的 projects，所以这里直接造一个。
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: project, to: home.appendingPathComponent("projects/p"))

        let reader = ClaudeMessageReader(paths: { ClaudePaths(claudeHome: home) })
        let (messages, hasMore) = try await reader.messages(taskId: "claude:\(sessionID)", limit: 4)
        XCTAssertEqual(messages.count, 4)
        XCTAssertTrue(hasMore)
        XCTAssertEqual(messages.map(\.text), ["第 6 条", "第 7 条", "第 8 条", "第 9 条"], "取最近的 4 条，按时间升序")
    }

    /// 工具行不占对话名额：limit 数的是用户与 Agent 的消息，夹在中间的工具行一并带上。
    func testClaudeWindowCountsOnlyConversation() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-transcripts-\(UUID().uuidString)", isDirectory: true)
        let project = home.appendingPathComponent("projects/p", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let lines = (0..<4).flatMap { i in
            [#"{"type":"user","uuid":"u\#(i)","message":{"content":"问 \#(i)"}}"#]
                + (0..<5).map { t in
                    #"{"type":"assistant","uuid":"t\#(i)-\#(t)","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}"#
                }
                + [#"{"type":"assistant","uuid":"a\#(i)","message":{"content":[{"type":"text","text":"答 \#(i)"}]}}"#]
        }
        try Data(lines.joined(separator: "\n").utf8).write(to: project.appendingPathComponent("s-1.jsonl"))

        let reader = ClaudeMessageReader(paths: { ClaudePaths(claudeHome: home) })
        let (messages, hasMore) = try await reader.messages(taskId: "claude:s-1", limit: 3)
        XCTAssertTrue(hasMore)
        XCTAssertEqual(messages.filter { $0.role != .tool }.map(\.text), ["答 2", "问 3", "答 3"])
        XCTAssertEqual(messages.count, 3 + 10, "a2 之前那一轮的 5 行工具、u3 之后的 5 行都在")
        XCTAssertEqual(messages.first?.id, "t2-0#1", "从上一条对话之后开始：最旧那条回复所在一轮的工具行也带上")
    }

    /// 路径候选只给最终窗口里的 Agent 回复认（整份 transcript 不跑正则），窗口里的照样都有、原文未截断。
    func testClaudeReaderFillsPathCandidatesForTheWindow() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-transcripts-\(UUID().uuidString)", isDirectory: true)
        let project = home.appendingPathComponent("projects/p", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let long = String(repeating: "长", count: TaskMessages.maxMessageLength + 10)
        let lines = (0..<6).flatMap { i in [
            #"{"type":"user","uuid":"u\#(i)","message":{"content":"看 in/\#(i).png"}}"#,
            #"{"type":"assistant","uuid":"a\#(i)","message":{"content":[{"type":"text","text":"\#(long) 存到 `out/\#(i).png`"}]}}"#,
        ] }
        try Data(lines.joined(separator: "\n").utf8).write(to: project.appendingPathComponent("s-1.jsonl"))

        let reader = ClaudeMessageReader(paths: { ClaudePaths(claudeHome: home) })
        let (entries, hasMore) = try await reader.entries(taskId: "claude:s-1", limit: 3)
        XCTAssertTrue(hasMore)
        XCTAssertEqual(entries.map(\.message.id), ["a4", "u5", "a5"])
        XCTAssertEqual(entries.map(\.pathCandidates), [["out/4.png"], [], ["out/5.png"]])
    }

    // MARK: - 窗口

    /// 工具行超过上限时丢最旧的，对话一条不少；对话不够 limit 条时从头取，`hasMore` 为假。
    func testTranscriptWindowCapsOldestToolRows() {
        func entry(_ id: String, _ role: Message.Role) -> TranscriptEntry {
            TranscriptEntry(message: Message(id: id, role: role, text: id, createdAt: "2026-09-25T00:00:00Z"))
        }
        let tools = TaskMessages.maxToolMessages + 20
        let all = [entry("u", .user)] + (0..<tools).map { entry("t\($0)", .tool) } + [entry("a", .agent)]
        let (window, hasMore) = TranscriptWindow.latest(all, limit: 40)
        XCTAssertFalse(hasMore)
        XCTAssertEqual(window.count, 2 + TaskMessages.maxToolMessages)
        XCTAssertEqual(window.map(\.message.id).prefix(2), ["u", "t20"], "丢的是最旧的 20 行工具")
        XCTAssertEqual(window.last?.message.id, "a")
    }

    // MARK: - id 前缀

    func testNativeTaskIdRejectsWrongPrefix() {
        XCTAssertEqual(try? nativeTaskId("codex:thr_1", kind: .codex), "thr_1")
        XCTAssertEqual(try? nativeTaskId("claude:s-1", kind: .claude), "s-1")
        XCTAssertNil(try? nativeTaskId("claude:s-1", kind: .codex), "前缀不符要拒绝，不能张冠李戴")
        XCTAssertNil(try? nativeTaskId("codex:", kind: .codex))
    }

    // MARK: - 文件路径候选（协议 2.9 的 Message.files）

    /// 路径从截断前的原文里认：超过 1000 字的回复末尾的路径也要在。只有 agent 的有，用户消息与工具行没有。
    func testCodexAgentMessagesCarryPathCandidatesFromUntruncatedText() throws {
        let long = String(repeating: "长", count: TaskMessages.maxMessageLength + 50) + " 已保存到 `out/a.png`"
        let agentJSON = String(data: try JSONSerialization.data(withJSONObject: ["text": long]), encoding: .utf8)!
        let agent = try XCTUnwrap(CodexMessageReader.entry(from: codexRow("agentMessage", agentJSON)))
        XCTAssertFalse(agent.message.text.contains("out/a.png"), "前提：正文已被截断")
        XCTAssertEqual(agent.pathCandidates, ["out/a.png"])

        let user = try XCTUnwrap(CodexMessageReader.entry(from: codexRow(
            "userMessage", #"{"content":[{"type":"text","text":"看看 `in/b.png`"}]}"#)))
        XCTAssertEqual(user.pathCandidates, [])
        let tool = try XCTUnwrap(CodexMessageReader.entry(from: codexRow(
            "commandExecution", #"{"command":"open out/c.png","exitCode":0}"#)))
        XCTAssertEqual(tool.pathCandidates, [])
    }

    func testClaudeAssistantMessagesCarryPathCandidates() throws {
        func entry(_ line: String) throws -> TranscriptEntry {
            try XCTUnwrap(ClaudeMessageReader.entries(from: Substring(line), ordinal: 0).first)
        }
        let assistant = try entry(#"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"截图在 [这里](shots/home.png)"}]}}"#)
        XCTAssertEqual(assistant.pathCandidates, ["shots/home.png"])
        let user = try entry(#"{"type":"user","uuid":"u1","message":{"content":[{"type":"text","text":"看 shots/home.png"}]}}"#)
        XCTAssertEqual(user.pathCandidates, [])
    }
}
