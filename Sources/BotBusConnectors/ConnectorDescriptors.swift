import Foundation
import BotBusProtocol
import BotBusConnectorKit

/// 一档 Connector 的描述符表：从 Kit 的 `ConnectorRegistry.swift` 拆出来，因为它引用各连接器的路径探测。
/// 加第三个 Connector 的办法是在 `all(codexPaths:codexBinary:)` 的 switch 里加一个 case——
/// 那个 switch 对 `ConnectorKind` 穷举，新增枚举值会直接编译不过。
public extension ConnectorDescriptor {
    /// 本机的全部 Connector，顺序即 `ConnectorKind.allCases`。
    public static func all(codexPaths: @escaping @Sendable () -> CodexPaths = { CodexPaths() },
                           codexBinary: @escaping @Sendable () -> String? = { CodexPaths.detectCodexBinary() },
                           claudePaths: @escaping @Sendable () -> ClaudePaths = { ClaudePaths() },
                           claudeBinary: @escaping @Sendable () -> String? = { ClaudePaths.detectClaudeBinary() },
                           claudeHooksInstalled: @escaping @Sendable () -> Bool = { false },
                           hermesPaths: @escaping @Sendable () -> HermesPaths = { HermesPaths() },
                           hermesBinary: @escaping @Sendable () -> String? = { HermesPaths.detectHermesBinary() },
                           piPaths: @escaping @Sendable () -> PiPaths = { PiPaths() },
                           piBinary: @escaping @Sendable () -> String? = { PiPaths.detectPiBinary() },
                           openClawPaths: @escaping @Sendable () -> OpenClawPaths = { OpenClawPaths() },
                           openClawBinary: @escaping @Sendable () -> String? = { OpenClawPaths.detectOpenClawBinary() },
                           dshPaths: @escaping @Sendable () -> DshPaths = { DshPaths() },
                           dshInstallation: @escaping @Sendable () -> DshInstallation? = { DshInstallationProbe.shared.refresh() })
        -> [ConnectorDescriptor] {
        ConnectorKind.allCases.compactMap { kind -> ConnectorDescriptor? in
            switch kind {
            case .codex: return codex(paths: codexPaths, binary: codexBinary)
            case .claude: return claude(paths: claudePaths, binary: claudeBinary, hooksInstalled: claudeHooksInstalled)
            case .hermes: return hermes(paths: hermesPaths, binary: hermesBinary)
            case .pi: return pi(paths: piPaths, binary: piBinary)
            case .openclaw: return openClaw(paths: openClawPaths, binary: openClawBinary)
            case .dsh: return dsh(paths: dshPaths, installation: dshInstallation)
            // ACP agent 是运行时发现的，不在编译期的描述符表里，由 `AcpHub` 经 `ConnectorRegistry.setAcpEntries` 写入。
            case .acp: return nil
            }
        }
    }

    /// Hermes：`~/.hermes/state.db` 负责"看见"，`hermes chat -q` 负责"动手"，两样齐了才是 ok。
    public static func hermes(paths: @escaping @Sendable () -> HermesPaths,
                              binary: @escaping @Sendable () -> String?) -> ConnectorDescriptor {
        ConnectorDescriptor(kind: .hermes, displayName: "Hermes", defaultEnabled: true, reportsWhenUnavailable: false) {
            let home = paths()
            switch (binary() != nil, home.stateDatabase != nil) {
            case (true, true): return ConnectorProbe(available: true, status: .ok)
            case (true, false):
                return ConnectorProbe(available: true, status: .degraded,
                                      lastError: "还没有 Hermes 会话记录：\(home.hermesHome.path)")
            case (false, true):
                return ConnectorProbe(available: true, status: .degraded, lastError: "未找到 hermes 可执行文件，只能只读展示")
            case (false, false):
                return ConnectorProbe(available: false, status: .degraded, lastError: "本机未检测到 Hermes")
            }
        }
    }

    /// Pi：会话 JSONL 负责"看见"，`pi --mode json` 负责"动手"。
    public static func pi(paths: @escaping @Sendable () -> PiPaths,
                          binary: @escaping @Sendable () -> String?) -> ConnectorDescriptor {
        ConnectorDescriptor(kind: .pi, displayName: "Pi", defaultEnabled: true, reportsWhenUnavailable: false) {
            let home = paths()
            switch (binary() != nil, home.hasPiHome()) {
            case (true, _): return ConnectorProbe(available: true, status: .ok)
            case (false, true):
                return ConnectorProbe(available: true, status: .degraded, lastError: "未找到 pi 可执行文件，只能只读展示")
            case (false, false):
                return ConnectorProbe(available: false, status: .degraded, lastError: "本机未检测到 Pi")
            }
        }
    }

    /// OpenClaw：一切经本机 Gateway，探测只看装没装；Gateway 连不连得上由连接器运行时回报。
    ///
    /// **默认关闭**：OpenClaw 是个人助理，会话里是 WhatsApp / Telegram 等渠道的私人对话，
    /// 不该在用户没表态时就同步到手机。用户在菜单或手机上打开即可。
    public static func openClaw(paths: @escaping @Sendable () -> OpenClawPaths,
                                binary: @escaping @Sendable () -> String?) -> ConnectorDescriptor {
        ConnectorDescriptor(kind: .openclaw, displayName: "OpenClaw", defaultEnabled: false, reportsWhenUnavailable: false) {
            let home = paths()
            guard binary() != nil || home.hasStateDirectory() else {
                return ConnectorProbe(available: false, status: .degraded, lastError: "本机未检测到 OpenClaw")
            }
            guard FileManager.default.fileExists(atPath: home.configFile.path) else {
                return ConnectorProbe(available: true, status: .degraded,
                                      lastError: "未找到 OpenClaw 配置：\(home.configFile.path)")
            }
            return ConnectorProbe(available: true, status: .ok)
        }
    }

    /// DeepSeek Harness（协议 3.1）：找得到可执行文件（`dsh` 或 npx 缓存里的包）或 `~/.dsh/sessions` 在就算装了（没装不上报）。
    /// 没有可执行文件时只能看（web 在时还能续聊、审批），`canStartTask` 报 false。
    /// web 连不连得上、登录被拒由 `DshConnector` 运行时回报。`installation` 每次探测都重新找一遍（注册表 `refresh()` 时），
    /// app 传的是与连接器共用的 `DshInstallationProbe.refresh`。
    public static func dsh(paths: @escaping @Sendable () -> DshPaths,
                           installation: @escaping @Sendable () -> DshInstallation?) -> ConnectorDescriptor {
        ConnectorDescriptor(kind: .dsh, displayName: DshPaths.displayName, defaultEnabled: true,
                            reportsWhenUnavailable: false) {
            let home = paths()
            let found = installation()
            guard home.isInstalled(found) else {
                return ConnectorProbe(available: false, status: .degraded, lastError: "本机未检测到 DeepSeek Harness")
            }
            guard found != nil else {
                return ConnectorProbe(available: true, status: .degraded, lastError: "没找到 dsh 可执行文件，只能看电脑上的会话",
                                      canStartTask: false)
            }
            return ConnectorProbe(available: true, status: .ok)
        }
    }

    /// Codex：可执行文件与两个 SQLite 任一存在即算"检测到"（协议原话是"可执行文件或数据库"），
    /// 两者齐全才是 ok——只有库没有二进制时读得到任务但起不了新任务，只有二进制没有库时列表是空的。
    public static func codex(paths: @escaping @Sendable () -> CodexPaths,
                             binary: @escaping @Sendable () -> String?) -> ConnectorDescriptor {
        ConnectorDescriptor(kind: .codex, displayName: "Codex", defaultEnabled: true) {
            let home = paths()
            let hasDatabases = home.stateDatabase != nil && home.historyDatabase != nil
            switch (binary() != nil, hasDatabases) {
            case (true, true):
                return ConnectorProbe(available: true, status: .ok)
            case (true, false):
                return ConnectorProbe(available: true, status: .degraded,
                                      lastError: "未找到 Codex 数据库：\(home.codexHome.path)")
            case (false, true):
                return ConnectorProbe(available: true, status: .degraded, lastError: "未找到 codex 可执行文件，只能只读展示")
            case (false, false):
                return ConnectorProbe(available: false, status: .degraded,
                                      lastError: "本机未检测到 Codex：\(home.codexHome.path)")
            }
        }
    }

    /// Claude Code：可执行文件与 `~/.claude` 任一存在即算"检测到"，但**hooks 没装就只是可用而不健康**——
    /// 没有 hooks 就看不见电脑上正在跑的会话，这时候在界面上显示"正常"是骗人的。
    /// 反过来只有 hooks 没有二进制也不行：看得见，但发不了新任务。
    public static func claude(paths: @escaping @Sendable () -> ClaudePaths = { ClaudePaths() },
                              binary: @escaping @Sendable () -> String? = { ClaudePaths.detectClaudeBinary() },
                              hooksInstalled: @escaping @Sendable () -> Bool) -> ConnectorDescriptor {
        ConnectorDescriptor(kind: .claude, displayName: "Claude Code", defaultEnabled: true) {
            let home = paths()
            let hasBinary = binary() != nil
            guard hasBinary || home.hasClaudeHome() else {
                return ConnectorProbe(available: false, status: .degraded,
                                      lastError: "本机未检测到 Claude Code")
            }
            switch (hasBinary, hooksInstalled()) {
            case (true, true):
                return ConnectorProbe(available: true, status: .ok)
            case (true, false):
                return ConnectorProbe(available: true, status: .degraded,
                                      lastError: "还没安装 hooks，看不到电脑上的 Claude 会话（设置里可一键安装）")
            case (false, true):
                return ConnectorProbe(available: true, status: .degraded,
                                      lastError: "未找到 claude 可执行文件，只能看不能发起新任务")
            case (false, false):
                return ConnectorProbe(available: false, status: .degraded,
                                      lastError: "本机未检测到 Claude Code")
            }
        }
    }
}

public extension ConnectorRegistry {
    /// 带全部一档描述符的注册表（`ConnectorDescriptor.all()` 的默认探测）。
    convenience init(enabled overrides: [ConnectorKind: Bool] = [:], acpEnabled: [String: Bool] = [:]) {
        self.init(descriptors: ConnectorDescriptor.all(), enabled: overrides, acpEnabled: acpEnabled)
    }
}
