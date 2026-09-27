import Foundation
import BotBusConnectorKit

/// `botbus agent list` / `botbus agent check <id> [--prompt <文字>]`：给 agent 开发者自查接入
/// （见远程预览 spec「开发者工具」）。
///
/// `list` 只读发现结果与开关，不起进程；`check` 真的拉起 agent 跑一次握手，带 `--prompt` 时
/// 在临时目录里真的跑一轮对话。两条命令都不认领任务、不写 `TaskStore`，纯粹是给开发者看的诊断。
public enum AcpAgentCommand {
    public struct Context: Sendable {
        public var discover: @Sendable () -> AcpDiscoveryResult
        public var enabledOverrides: @Sendable () -> [String: Bool]
        public var launcher: AcpLauncherFactory
        public var output: @Sendable (String) -> Void
        public var error: @Sendable (String) -> Void

        public init(discover: @escaping @Sendable () -> AcpDiscoveryResult,
                    enabledOverrides: @escaping @Sendable () -> [String: Bool],
                    launcher: @escaping AcpLauncherFactory,
                    output: @escaping @Sendable (String) -> Void,
                    error: @escaping @Sendable (String) -> Void) {
            self.discover = discover
            self.enabledOverrides = enabledOverrides
            self.launcher = launcher
            self.output = output
            self.error = error
        }

        /// 真实环境：读约定目录与内置注册表；开关从 Mac app 的 UserDefaults 读。
        ///
        /// 域名是 Mac app 的 bundle id `io.botbus.agent`（`AgentSettings` 用 `.standard`；CLI 是另一个 bundle id，
        /// 所以要按名字读），键是 `AgentSettings.acpEnabledKey`（`"acpEnabled"`）。
        public static func live() -> Context {
            Context(discover: { AcpDiscovery.discover() },
                    enabledOverrides: {
                        UserDefaults(suiteName: "io.botbus.agent")?.dictionary(forKey: "acpEnabled") as? [String: Bool] ?? [:]
                    },
                    launcher: AcpLaunchRequest.subprocess,
                    output: { print($0) },
                    error: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
        }
    }

    /// `check --prompt` 等一轮 `session/prompt` 的上限：`AcpClient.prompt` 本身没有超时
    /// （一轮可能跑几分钟），但 `check` 是个一次性诊断命令，卡住的 agent 不能把它拖到天荒地老。
    static let promptTimeout: TimeInterval = 5 * 60

    static let usage = """
    用法：
      botbus agent list                       列出 BotBus 发现到的 ACP agent
      botbus agent check <id> [--prompt 文字]  拉起这个 agent 跑一次握手；带 --prompt 时在临时目录里真实跑一轮
    """

    public static func run(_ arguments: [String], context: Context) async -> Int32 {
        switch arguments.first {
        case "list":
            list(context)
            return 0
        case "check":
            guard arguments.count >= 2 else {
                context.error(usage)
                return 2
            }
            var prompt: String?
            if let index = arguments.firstIndex(of: "--prompt") {
                guard arguments.indices.contains(index + 1) else {
                    context.error("--prompt 后面要跟一句话")
                    return 2
                }
                prompt = arguments[index + 1]
            }
            return await check(arguments[1], prompt: prompt, context: context)
        default:
            context.error(usage)
            return 2
        }
    }

    private static func list(_ context: Context) {
        let result = context.discover()
        let overrides = context.enabledOverrides()
        if result.agents.isEmpty {
            context.output("没有发现 ACP agent。清单放在 \(AcpDiscovery.defaultManifestDirectory.path)/<id>.json")
        }
        for agent in result.agents {
            let enabled = overrides[agent.id] ?? agent.defaultEnabled
            let origin = agent.origin == .manifest ? "清单" : "注册表"
            let launch = agent.executable.map { ([$0] + agent.arguments).joined(separator: " ") }
                ?? "（没有启动命令，只能经反向扩展接入）"
            context.output("\(agent.id)\t\(agent.name)\t\(origin)\t\(enabled ? "已启用" : "已停用")\t\(launch)")
        }
        for problem in result.problems {
            context.output("✗ \(problem.file)：\(problem.reason)")
        }
    }

    private static func check(_ id: String, prompt: String?, context: Context) async -> Int32 {
        guard let spec = context.discover().agents.first(where: { $0.id == id }) else {
            context.error("没有发现 id 为 \(id) 的 agent（先跑 botbus agent list 看看）")
            return 1
        }
        guard let executable = spec.executable else {
            context.error("\(spec.name) 没有启动命令：只能由 agent 自己经反向扩展连 \(AcpReverseServer.defaultSocketPath)")
            return 1
        }
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("botbus-check-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let request = AcpLaunchRequest(executable: executable, arguments: spec.arguments,
                                       environment: AgentBinary.environment(for: executable, adding: spec.environment),
                                       workingDirectory: workDirectory.path)
        let handle: any CodexProcessHandle
        do {
            handle = try context.launcher(request).launch()
        } catch {
            context.error("起不来：\(AcpConnector.describe(error))")
            return 1
        }
        defer { handle.terminate() }

        // 写 stdin 排成一条队，跟 `AcpConnector.launch` 一样：每行一个 Task 会乱序。
        let (lines, sink) = AsyncStream<String>.makeStream()
        let writer = Task { for await line in lines { try? await handle.writeStdin(Data((line + "\n").utf8)) } }
        defer { writer.cancel() }
        let peer = JSONRPCPeer(send: { sink.yield($0) })
        let output = context.output
        await peer.setHandlers(request: { method, _ in
            guard method == "session/request_permission" else {
                throw JSONRPCError(code: JSONRPCError.methodNotFound, message: "check 模式不支持 \(method)")
            }
            output("（agent 请求审批；check 模式一律回 cancelled）")
            return AcpPermissionOutcome.cancelled.json
        }, notification: { method, params in
            guard method == "session/update", let update = params["update"] else { return }
            switch AcpSessionUpdate(json: update) {
            case .agentMessage(let text, _) where !text.isEmpty:
                output("agent: \(text)")
            case .toolCall(let call), .toolCallUpdate(let call):
                output("工具: \(call.title ?? call.kind ?? call.toolCallId)")
            default:
                break
            }
        })
        // 唯一的读循环（`JSONRPCPeer.receive` 必须串行），同 `AcpConnector.launch`：进程退出后
        // 先关 peer（在等的请求带着退出原因失败），再让 stdin 那条队自然收尾。
        let reader = Task {
            while let chunk = try? await handle.readStdout() { await peer.receive(chunk) }
            let exit = await handle.waitForExit()
            sink.finish()
            await peer.close(reason: "agent 进程退出了（退出码 \(exit.status)）")
        }
        defer { reader.cancel() }

        let client = AcpClient(peer: peer)
        do {
            let capabilities = try await client.initialize(clientVersion: "check")
            output("ACP 协议版本: \(capabilities.protocolVersion)")
            output("loadSession: \(capabilities.loadSession ? "是" : "否")")
            output("图片: \(capabilities.images ? "是" : "否")")
            output("session/list: \(capabilities.listSessions ? "是" : "否")")
            output("登录方式: \(capabilities.authMethodCount) 种")
            guard let prompt else { return 0 }
            let sessionId = try await client.newSession(cwd: workDirectory.path, mcpServers: [])
            output("会话: \(sessionId)")
            let stop = try await withTimeout(promptTimeout,
                                             message: "等 \(spec.name) 回应超过 \(Int(promptTimeout)) 秒，可能是卡住了") {
                try await client.prompt(sessionId, text: prompt, images: [])
            }
            output("结束原因: \(stop.rawValue)")
            return 0
        } catch {
            context.error("失败：\(AcpConnector.describe(error))")
            return 1
        }
    }

    /// 给一段可能一直不返回的操作设个上限；超时抛出的错误带着 `message`，调用方按普通错误处理。
    private static func withTimeout<T: Sendable>(_ seconds: TimeInterval, message: String,
                                                 operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw ConnectorError(message)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
