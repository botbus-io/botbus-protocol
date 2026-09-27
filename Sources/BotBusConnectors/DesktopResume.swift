import Foundation
import BotBusProtocol
import BotBusConnectorKit

/// 在电脑上接着一条会话聊下去的终端命令：Mac 菜单「在电脑上继续」用。
///
/// 手机任务是 BotBus 起的无界面子进程（`claude -p`、`codex app-server`、`hermes chat -q`……），
/// 各家桌面 App 未必列得出来（Claude 桌面 App 只列它自己建的会话），所以统一交给各自 CLI 的交互模式接上。
public struct DesktopResumeCommand: Hashable, Sendable {
    public var executable: String
    public var arguments: [String]
    /// 进这个目录再跑：Claude / Codex 按当前目录找会话与项目配置。
    public var workingDirectory: String
    /// 只给这一条命令放到 PATH 最前的目录。Pi / OpenClaw 是 `#!/usr/bin/env node` 脚本，
    /// 用户 shell 里排在前面的 node（常见是 nvm 的旧版本）可能跑不动它们；和连接器一样用脚本旁边的那个。
    public var pathDirectories: [String]

    public init(executable: String, arguments: [String], workingDirectory: String, pathDirectories: [String] = []) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.pathDirectories = pathDirectories
    }

    /// 一行 shell：`cd '<目录>' && [PATH='<目录>':"$PATH"] '<可执行文件>' '<参数>'…`，每一段都单引号转义。
    /// PATH 前缀只作用于这一条命令，之后留给用户的 shell 不受影响。
    public var shellLine: String {
        let command = ([executable] + arguments).map(Self.quoted).joined(separator: " ")
        let path = pathDirectories.isEmpty
            ? "" : "PATH=\(Self.quoted(pathDirectories.joined(separator: ":"))):\"$PATH\" "
        return "cd \(Self.quoted(workingDirectory)) && \(path)\(command)"
    }

    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum DesktopResume {
    /// 按任务来源拼命令。`executable` 是该 Agent 的 CLI；Pi 另要会话记录文件（续聊只认绝对路径，见 `PiConnector`）。
    /// 返回 nil = 拼不出来（id 不带来源前缀、Pi 找不到记录文件、ACP agent）。
    public static func command(for task: TaskRecord, executable: String,
                               piSessionFile: String? = nil) -> DesktopResumeCommand? {
        let prefix = "\(task.source.rawValue):"
        guard task.id.hasPrefix(prefix) else { return nil }
        let native = String(task.id.dropFirst(prefix.count))
        guard !native.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let directory = task.workingDirectory
        let arguments: [String]
        // Claude / Codex 是原生可执行文件，Codex 还在 App 包的 Resources 里——不把那个目录塞进 PATH。
        var pathDirectories: [String] = []
        switch task.source {
        case .claude: arguments = ["--resume", native]
        case .codex: arguments = ["resume", native]
        case .hermes:
            arguments = ["--resume", native]
            pathDirectories = AgentBinary.pathDirectories(for: executable)
        case .pi:
            guard let piSessionFile else { return nil }
            arguments = ["--session", piSessionFile]
            pathDirectories = AgentBinary.pathDirectories(for: executable)
        case .openclaw:
            arguments = ["tui", "--session", native]
            pathDirectories = AgentBinary.pathDirectories(for: executable)
        case .acp, .dsh:
            // dsh（0.1.5-rc.3）没有能核实的接续方式：网页端前端没有按会话的地址（打开只能进首页再在列表里点），
            // `dsh --profile tui --resume` 只是帮助里的示例，随包的 profile 模板（acp / web / headless / sdk / sdk-minimal）里没有交互终端。先不拼。
            // ACP 没有通用的「交互模式接上某条会话」的命令行，各家不一样；第一期不拼。
            return nil
        }
        return DesktopResumeCommand(executable: executable, arguments: arguments, workingDirectory: directory,
                                    pathDirectories: pathDirectories)
    }

    /// 用本机默认路径找 CLI 与 Pi 记录文件后拼命令。会读盘，别在主线程上反复调。
    public static func resolve(_ task: TaskRecord) -> DesktopResumeCommand? {
        let executable: String?
        var piSessionFile: String?
        switch task.source {
        case .claude: executable = ClaudePaths.detectClaudeBinary()
        case .codex: executable = CodexPaths.detectCodexBinary()
        case .hermes: executable = HermesPaths.detectHermesBinary()
        case .openclaw: executable = OpenClawPaths.detectOpenClawBinary()
        case .pi:
            executable = PiPaths.detectPiBinary()
            let native = String(task.id.dropFirst("\(TaskSource.pi.rawValue):".count))
            piSessionFile = PiSessionReader(paths: PiPaths()).sessionFile(for: native)?.path
        case .acp, .dsh:
            return nil
        }
        guard let executable else { return nil }
        return command(for: task, executable: executable, piSessionFile: piSessionFile)
    }
}
