import Foundation

/// app 给连接器的"agent 工具"配置（spec 3.2）：嵌在 app 里的 `botbus` CLI 与本机工具服务器地址。
///
/// 两者任一缺失（开发环境没嵌 CLI、工具服务器没起来）就完全不注入，行为与没有这个功能时一致。
public struct AgentToolsConfiguration: Sendable, Hashable {
    /// `BotBus.app/Contents/Helpers/botbus` 的绝对路径。
    public var cliPath: String
    /// `http://127.0.0.1:<port>`，本机工具服务器（`LocalToolAPI`）。
    public var toolsURL: String

    public init(cliPath: String, toolsURL: String) {
        self.cliPath = cliPath
        self.toolsURL = toolsURL
    }

    /// CLI 真的在那儿且可执行、地址非空。每次注入前现查：app 被挪走或 CLI 被删了就别往 agent 手里塞一个坏路径。
    public var isUsable: Bool {
        !toolsURL.isEmpty && !cliPath.isEmpty && FileManager.default.isExecutableFile(atPath: cliPath)
    }
}

/// 注入给 agent 的说明文字。各连接器共用同一份，内含 CLI 的绝对路径。
public enum AgentToolsInstructions {
    /// - Parameter mcp: agent 这一侧有没有接上 `botbus` MCP server。Pi 没有 MCP、Hermes 的 `-q` 模式不能临时加 MCP，
    ///   它们只能在 shell 里调 CLI，说明文字就不提 MCP，免得 agent 去找一个不存在的工具。
    public static func text(cliPath: String, mcp: Bool = true) -> String {
        let intro = "This task was sent from the user's phone through BotBus. The user is not at this computer: they cannot see its screen or open localhost URLs. When you build or change something visual, share it"
        let tools: String
        if mcp {
            tools = """
             with the `botbus` tools (MCP server `botbus`, or the CLI at `\(cliPath)`):
            - `share_preview` with a `port` for a running dev server, or a `directory` for static files (serves `index.html`). In this environment background processes may be killed when your turn ends, so to run a dev server pass its `command` (and `cwd`) and BotBus will keep it running.
            - `share_file` for screenshots, images, videos or other files; `share_link` for public URLs. Videos are compressed automatically.
            """
        } else {
            tools = """
             by running the `botbus` CLI at `\(cliPath)` from your shell (`--help` lists everything):
            - `preview --port <port>` for a running dev server, or `preview --dir <dir>` for static files (serves `index.html`). Background processes may be killed when your turn ends, so to run a dev server pass `--cmd "<command>"` (and `--cwd <dir>`) and BotBus will keep it running.
            - `share <file>` for screenshots, images, videos or other files; `link <url>` for public URLs. Videos are compressed automatically.
            """
        }
        return intro + tools + "\n" + """
        Prefer relative URLs or the dev server's proxy over hard-coded `http://localhost:…` API URLs so the page works through the preview tunnel. Keep your final answer short; the user reads it on a phone.
        """
    }
}

/// 一次注入的全部内容：配置 + 这条任务的 token。连接器据此拼 Claude 的命令行或 Codex 的线程参数。
public struct AgentToolsInjection: Sendable, Hashable {
    public static let mcpServerName = "botbus"
    public static let toolsURLVariable = "BOTBUS_TOOLS_URL"
    public static let taskTokenVariable = "BOTBUS_TASK_TOKEN"
    public static let cliVariable = "BOTBUS_CLI"

    public var configuration: AgentToolsConfiguration
    public var token: String

    public init(configuration: AgentToolsConfiguration, token: String) {
        self.configuration = configuration
        self.token = token
    }

    /// 配置可用时签发（或续聊时复用）一个 token，否则 nil = 不注入。
    /// - Parameter reusing: 续聊的任务 id；它之前签过 token 就沿用，agent 手里那份一直有效。
    public static func make(_ configuration: AgentToolsConfiguration?, registry: TaskContextRegistry,
                            reusing taskId: String? = nil) async -> AgentToolsInjection? {
        guard let configuration, configuration.isUsable else { return nil }
        if let taskId, let existing = await registry.token(for: taskId) {
            return AgentToolsInjection(configuration: configuration, token: existing)
        }
        return AgentToolsInjection(configuration: configuration, token: await registry.issue())
    }

    /// 三个环境变量：子进程（Claude 的 shell、Codex 的 shell 与 MCP server）都靠它们找到工具服务器。
    public var environment: [String: String] {
        [Self.toolsURLVariable: configuration.toolsURL,
         Self.taskTokenVariable: token,
         Self.cliVariable: configuration.cliPath]
    }

    public var instructions: String { AgentToolsInstructions.text(cliPath: configuration.cliPath) }
    /// 只有 shell、没有 MCP 的 agent（Pi、Hermes 的 `-q`）用这一份。
    public var cliOnlyInstructions: String { AgentToolsInstructions.text(cliPath: configuration.cliPath, mcp: false) }

    /// `claude -p` 的追加参数。**必须放在 prompt 位置参数之后**：`--mcp-config` / `--allowedTools`
    /// 是可变参数，会把后面的位置参数当成自己的值吞掉；调用方随后再接 `--output-format` 等 `--flag` 来收尾。
    public func claudeArguments() -> [String] {
        ["--append-system-prompt", instructions,
         "--mcp-config", mcpConfigJSON(),
         "--allowedTools", "mcp__\(Self.mcpServerName)"]
    }

    /// Claude 的内联 MCP 配置：`{"mcpServers":{"botbus":{"command":<cli>,"args":["mcp"],"env":{…}}}}`。
    public func mcpConfigJSON() -> String {
        let object: [String: Any] = [
            "mcpServers": [
                Self.mcpServerName: [
                    "command": configuration.cliPath,
                    "args": ["mcp"],
                    "env": environment,
                ] as [String: Any],
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Codex `thread/start` / `thread/resume` 的 `config` 覆盖。**点路径写到叶子**：
    /// 写 `mcp_servers.botbus = {…}` 或 `shell_environment_policy = {…}` 会整张表覆盖用户自己的配置。
    public func codexConfig() -> JSONValue {
        var config: [String: JSONValue] = [
            "mcp_servers.\(Self.mcpServerName).command": .string(configuration.cliPath),
            "mcp_servers.\(Self.mcpServerName).args": .array([.string("mcp")]),
        ]
        for (name, value) in environment {
            config["mcp_servers.\(Self.mcpServerName).env.\(name)"] = .string(value)
            config["shell_environment_policy.set.\(name)"] = .string(value)
        }
        return .object(config)
    }
}
