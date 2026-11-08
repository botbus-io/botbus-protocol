import Foundation
import BotBusProtocol
import BotBusConnectorKit

// 宿主自己派的无人值守轮次（`AgentRunContext.unattended`，团队看板的员工）不走 app-server，而是起一次
// `codex exec --json`——Codex 命令行的非交互模式：
//
// - **不进 Codex 桌面**。app-server 起的线程一律记成 `vscode` 来源（交互会话），桌面 App 的会话列表会把它们
//   列出来；共用桌面桥接时更是直接跑在桌面自己的 app-server 里。`codex exec` 的线程记成 `exec` 来源，
//   桌面 App 与 `codex resume` 默认都不列（Codex 给 SDK、脚本留的位置）。线程照样写进 `~/.codex`：
//   BotBus 的只读观察看得到（来源不限），手机上能看、能续聊（续聊照常经 app-server `thread/resume`）。
// - **没有审批这一步**。exec 不会发审批请求，app-server 那边无人值守轮次是「审批一律放行」，这里给同等的权限
//   （`--dangerously-bypass-approvals-and-sandbox`），与 Claude 的无人值守轮次一致。

/// `codex exec` 子进程：除了 `CodexProcessHandle` 的读写与结束，还要关 stdin（提示词从 stdin 读到 EOF）
/// 与发中断（SIGINT，像终端里按 Ctrl-C）。
public protocol CodexExecProcess: CodexProcessHandle {
    func closeInput()
    func interrupt()
}

/// 怎么起一次 `codex exec`。
public protocol CodexExecLauncher: Sendable {
    func launch(arguments: [String], workingDirectory: String) throws -> any CodexExecProcess
}

/// 生产用的启动器：本机的 codex 命令行（`CodexPaths.detectCodexBinary()`），**永远不经桌面桥接**。
/// 测试一律不用它。
public struct CodexExecSubprocessLauncher: CodexExecLauncher {
    public var executablePath: String
    /// nil = 继承当前进程的环境（codex 靠它找 `CODEX_HOME` 与登录态）。
    public var environment: [String: String]?

    public init(executablePath: String, environment: [String: String]? = nil) {
        self.executablePath = executablePath
        self.environment = environment
    }

    /// 与 app-server 同一份可执行文件与环境（npm 装的 `codex.js` 要把旁边的 node 放进 PATH）。
    public static func detected(fileManager: FileManager = .default) -> CodexExecSubprocessLauncher? {
        guard let launcher = CodexSubprocessLauncher.detected(fileManager: fileManager) else { return nil }
        return CodexExecSubprocessLauncher(executablePath: launcher.executablePath, environment: launcher.environment)
    }

    public func launch(arguments: [String], workingDirectory: String) throws -> any CodexExecProcess {
        try CodexSubprocess(executablePath: executablePath, arguments: arguments, environment: environment,
                            currentDirectory: URL(fileURLWithPath: workingDirectory), forwardStderr: false)
    }
}

/// `codex exec --json` 的一行事件。只认这几种，其余（工具调用、思考、增量）忽略。
enum CodexExecEvent: Hashable, Sendable {
    /// 第一行：线程 id。
    case threadStarted(threadId: String)
    case turnStarted
    /// 一条完整的 agent 回复（`item.completed` 里的 `agent_message`）。
    case agentMessage(String)
    case turnCompleted
    /// 这一轮失败了：`turn.failed` 的 `error.message`。
    case turnFailed(String)
    /// 顶层 `error`：多半是「Reconnecting... 2/5」这种过程中的报错，**不算这一轮失败**，只记作最近一条错误。
    case error(String)
    case other

    static func parse(_ line: Data) -> CodexExecEvent? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: line),
              let type = value["type"]?.stringValue else { return nil }
        switch type {
        case "thread.started":
            guard let id = value["thread_id"]?.stringValue, !id.isEmpty else { return .other }
            return .threadStarted(threadId: id)
        case "turn.started":
            return .turnStarted
        case "item.completed":
            guard value.path("item", "type")?.stringValue == "agent_message",
                  let text = value.path("item", "text")?.stringValue else { return .other }
            return .agentMessage(text)
        case "turn.completed":
            return .turnCompleted
        case "turn.failed":
            return .turnFailed(value.path("error", "message")?.stringValue ?? "")
        case "error":
            return .error(value["message"]?.stringValue ?? "")
        default:
            return .other
        }
    }
}

/// 把 stdout 的字节切成行再解析成事件。只由一个读者串行调用（先是起任务的那条命令，等到 `thread.started`，
/// 之后交给连接器的跟随任务）。
final class CodexExecEvents: @unchecked Sendable {
    /// 一行最多攒这么多字节（工具输出可能很长，但不该无限长）；超了就整行丢掉。
    static let lineLimit = 16 * 1024 * 1024

    let process: any CodexExecProcess
    private var buffer = Data()
    private var finished = false

    init(_ process: any CodexExecProcess) { self.process = process }

    /// 下一条认得的事件；stdout 关了就是 nil。解析不了的行（不是 JSON、没有 type）跳过。
    func next() async -> CodexExecEvent? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let event = CodexExecEvent.parse(Data(line)) { return event }
                continue
            }
            guard !finished else {
                // 最后一行可能没有换行。
                guard !buffer.isEmpty else { return nil }
                let line = buffer
                buffer = Data()
                if let event = CodexExecEvent.parse(line) { return event }
                return nil
            }
            let chunk = try? await process.readStdout()
            guard let chunk else {
                finished = true
                continue
            }
            buffer.append(chunk)
            if buffer.count > Self.lineLimit, buffer.firstIndex(of: 0x0A) == nil { buffer = Data() }
        }
    }
}

enum CodexExec {
    /// `codex exec` 的参数。提示词走 stdin（`-`）：放进参数里的话，Windows 的命令行只有 32K 字符。
    ///
    /// 注入（说明文字、botbus MCP 与 shell 环境变量）用 `-c` 写到叶子，与 app-server 的 `config` 覆盖同一份
    /// （`AgentToolsInjection.codexConfig()`），不会整张表盖掉用户自己的 `mcp_servers` / `shell_environment_policy`。
    static func arguments(cwd: String, selection: ModelSelection, injection: AgentToolsInjection?,
                          images: [URL]) -> [String] {
        var arguments = ["exec", "--json", "--skip-git-repo-check", "-C", cwd,
                         "--dangerously-bypass-approvals-and-sandbox"]
        if let model = selection.model { arguments += ["-m", model] }
        if let effort = selection.effort { arguments += ["-c", "model_reasoning_effort=\(tomlString(effort))"] }
        if let injection {
            arguments += ["-c", "developer_instructions=\(tomlString(injection.instructions))"]
            for (key, value) in (injection.codexConfig().objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let literal = tomlValue(value) else { continue }
                arguments += ["-c", "\(key)=\(literal)"]
            }
        }
        for image in images { arguments += ["-i", image.path] }
        arguments.append("-")
        return arguments
    }

    /// TOML 基本字符串：`-c` 的值按 TOML 解析，解析不了才当原样字符串——多行的说明文字必须转义。
    static func tomlString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func tomlValue(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text): return tomlString(text)
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .double(let number): return number.isFinite ? String(number) : nil
        case .array(let items):
            let literals = items.compactMap(tomlValue)
            guard literals.count == items.count else { return nil }
            return "[" + literals.joined(separator: ", ") + "]"
        case .null, .object: return nil
        }
    }

    /// `turn.failed` 的原文 → 协议 3.7 的诊断。exec 不带 app-server 的 `codexErrorInfo`，只能认原文：
    /// 401 是没登录或登录失效（手机与团队看板都让人重新 `codex login`），额度 / 限流是 usageLimit。
    static func diagnosis(message: String?) -> FailureDiagnosis? {
        guard let message = message?.lowercased(), !message.isEmpty else { return nil }
        if message.contains("401 unauthorized") || message.contains("not logged in")
            || message.contains("please run `codex login`") || message.contains("please run codex login") {
            return .signInExpired
        }
        if message.contains("usage limit") || message.contains("usage_limit") || message.contains("429 too many requests")
            || message.contains("rate limit") {
            return .usageLimit()
        }
        return nil
    }
}
