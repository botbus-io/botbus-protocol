import Foundation
import BotBusConnectorKit

/// 从 `~/.openclaw/openclaw.json` 读出连 Gateway 需要的三样东西：端口、共享密钥、默认工作区。
///
/// 规则照 OpenClaw 自己的解析（`src/config/paths.ts` 的 `resolveGatewayPort`、`docs/gateway/protocol/auth.md`）：
/// - 端口：环境变量 `OPENCLAW_GATEWAY_PORT` > `gateway.port` > 18789。按 profile 哈希出端口的分支不跟——
///   GUI 进程读不到用户 shell 里的 `OPENCLAW_PROFILE`，跟了也只会算错。
/// - 密钥：`gateway.auth.token` / `gateway.auth.password`，缺了再看 `OPENCLAW_GATEWAY_TOKEN` / `_PASSWORD`。
///   两个都有就都带上，Gateway 按自己的 `gateway.auth.mode` 取匹配的那个字段。
///   SecretRef（对象形式）解不了——那要跑 OpenClaw 自己的 secret provider——当作没有，让握手报错说清楚。
///
/// **密钥绝不进日志**：`description` 把它们打码，调用方拿 `"\(config)"` 记日志也不会漏。
/// 文件是 JSON5 风格（用户手改时会留注释、尾逗号、不带引号的键），先 `normalizedJSON5` 转成标准 JSON 再解析；
/// 解析失败一律退回默认值，不抛错——连不上 Gateway 时会有更具体的报错。
public struct OpenClawConfig: Sendable, Equatable {
    public var port: Int
    public var token: String?
    public var password: String?
    /// 会话没报工作目录时拿它当项目路径（`agents.defaults.workspace`，缺省 `<状态目录>/workspace`）。
    public var workspaceDirectory: String

    public init(port: Int = OpenClawPaths.defaultGatewayPort, token: String? = nil, password: String? = nil,
                workspaceDirectory: String = OpenClawConfig.defaultWorkspace(stateDirectory: OpenClawPaths.defaultStateDirectory)) {
        self.port = port
        self.token = token
        self.password = password
        self.workspaceDirectory = workspaceDirectory
    }

    /// 只连回环：Gateway 对"本机 + 共享密钥 + backend 客户端"免设备签名（见 handshake.md），换成局域网地址就不成立了。
    public var gatewayURL: URL { URL(string: "ws://127.0.0.1:\(port)")! }

    /// 给人看的地址，进菜单栏的错误文案用。
    public var displayAddress: String { "127.0.0.1:\(port)" }

    public static func defaultWorkspace(stateDirectory: URL) -> String {
        stateDirectory.appendingPathComponent("workspace", isDirectory: true).path
    }

    /// 读配置文件；文件不存在或解析不了都给默认值。
    public static func load(paths: OpenClawPaths = OpenClawPaths(),
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> OpenClawConfig {
        let text = (try? String(contentsOf: paths.configFile, encoding: .utf8)) ?? ""
        return parse(text, stateDirectory: paths.stateDirectory, environment: environment)
    }

    /// 纯函数版本，测试直接喂文本。
    public static func parse(_ text: String, stateDirectory: URL = OpenClawPaths.defaultStateDirectory,
                             environment: [String: String] = [:]) -> OpenClawConfig {
        var config = OpenClawConfig(workspaceDirectory: defaultWorkspace(stateDirectory: stateDirectory))
        let root = parseObject(text)
        let gateway = root?["gateway"] as? [String: Any]
        let auth = gateway?["auth"] as? [String: Any]

        if let port = portValue(environment["OPENCLAW_GATEWAY_PORT"]) {
            config.port = port
        } else if let port = portValue(gateway?["port"]) {
            config.port = port
        }
        config.token = secret(auth?["token"], environment: environment) ?? nonEmpty(environment["OPENCLAW_GATEWAY_TOKEN"])
        config.password = secret(auth?["password"], environment: environment) ?? nonEmpty(environment["OPENCLAW_GATEWAY_PASSWORD"])

        let agents = root?["agents"] as? [String: Any]
        let defaults = agents?["defaults"] as? [String: Any]
        if let workspace = nonEmpty(defaults?["workspace"] as? String) {
            config.workspaceDirectory = (workspace as NSString).expandingTildeInPath
        }
        return config
    }

    // MARK: - 取值

    /// 端口可能写成数字，也可能写成字符串（环境变量总是字符串）；超出 1...65535 的不认。
    static func portValue(_ raw: Any?) -> Int? {
        let number: Int?
        switch raw {
        case let value as NSNumber where CFGetTypeID(value) != CFBooleanGetTypeID(): number = value.intValue
        case let value as String: number = Int(value.trimmingCharacters(in: .whitespaces))
        default: number = nil
        }
        guard let number, (1...65535).contains(number) else { return nil }
        return number
    }

    /// 密钥只认字符串。整串是 `${NAME}` 的按 OpenClaw 的环境变量替换规则展开；SecretRef 对象解不了，给 nil。
    static func secret(_ raw: Any?, environment: [String: String]) -> String? {
        guard let text = nonEmpty(raw as? String) else { return nil }
        if text.hasPrefix("${"), text.hasSuffix("}"), text.count > 3 {
            let name = String(text.dropFirst(2).dropLast())
            return nonEmpty(environment[name])
        }
        return text
    }

    static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func parseObject(_ text: String) -> [String: Any]? {
        let normalized = normalizedJSON5(text)
        guard !normalized.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(normalized.utf8)) as? [String: Any] else { return nil }
        return object
    }

    // MARK: - JSON5 → JSON

    /// 把 JSON5 里最常见的几种写法转成标准 JSON：`//` 与 `/* */` 注释、尾逗号、单引号字符串、不带引号的键。
    ///
    /// 逐字符扫一遍、自己跟踪"是否在字符串里"：正则去注释会误伤字符串里的 `//`（URL 就有）。
    /// 更冷门的 JSON5 语法（十六进制、`Infinity`、多行字符串续行）不管，碰上就让 JSONSerialization 失败、退回默认值。
    public static func normalizedJSON5(_ text: String) -> String {
        let chars = Array(text)
        var output = ""
        output.reserveCapacity(chars.count)
        var index = 0

        /// 输出末尾（跳过空白）是不是一个逗号：遇到 `}` / `]` 时用来删尾逗号。
        func dropTrailingComma() {
            var end = output.endIndex
            while end > output.startIndex {
                let previous = output.index(before: end)
                if output[previous].isWhitespace { end = previous; continue }
                if output[previous] == "," { output.remove(at: previous) }
                return
            }
        }

        while index < chars.count {
            let char = chars[index]
            let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil

            if char == "\"" || char == "'" {
                // 字符串原样搬运（单引号的改成双引号，内部的 `"` 补转义、`\'` 去掉多余的反斜杠）。
                let quote = char
                output.append("\"")
                index += 1
                while index < chars.count {
                    let inner = chars[index]
                    if inner == "\\", index + 1 < chars.count {
                        let escaped = chars[index + 1]
                        if quote == "'" && escaped == "'" {
                            output.append("'")
                        } else {
                            output.append(inner)
                            output.append(escaped)
                        }
                        index += 2
                        continue
                    }
                    if inner == quote { index += 1; break }
                    if quote == "'" && inner == "\"" { output.append("\\\"") } else { output.append(inner) }
                    index += 1
                }
                output.append("\"")
                continue
            }
            if char == "/" && next == "/" {
                while index < chars.count && chars[index] != "\n" { index += 1 }
                continue
            }
            if char == "/" && next == "*" {
                index += 2
                while index < chars.count && !(chars[index] == "*" && index + 1 < chars.count && chars[index + 1] == "/") {
                    index += 1
                }
                index += 2
                continue
            }
            if char == "}" || char == "]" {
                dropTrailingComma()
                output.append(char)
                index += 1
                continue
            }
            if char.isLetter || char == "_" || char == "$" {
                // 裸标识符：后面（跳过空白）紧跟 `:` 的是键，补上引号；true/false/null 这类值原样放过。
                var end = index
                while end < chars.count && (chars[end].isLetter || chars[end].isNumber || chars[end] == "_" || chars[end] == "$") {
                    end += 1
                }
                let word = String(chars[index..<end])
                var lookahead = end
                while lookahead < chars.count && chars[lookahead].isWhitespace { lookahead += 1 }
                if lookahead < chars.count && chars[lookahead] == ":" {
                    output.append("\"\(word)\"")
                } else {
                    output.append(word)
                }
                index = end
                continue
            }
            output.append(char)
            index += 1
        }
        return output
    }
}

extension OpenClawConfig: CustomStringConvertible, CustomDebugStringConvertible {
    /// 打码：密钥只报"有没有"，别让一句 `log("\(config)")` 把 token 写进系统日志。
    public var description: String {
        "OpenClawConfig(port: \(port), token: \(token == nil ? "nil" : "<redacted>"), password: \(password == nil ? "nil" : "<redacted>"), workspace: \(workspaceDirectory))"
    }

    public var debugDescription: String { description }
}
