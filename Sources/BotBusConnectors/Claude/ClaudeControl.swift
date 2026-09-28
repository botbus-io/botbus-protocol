import Foundation
import BotBusConnectorKit

/// 手机那一轮的审批：`claude -p --permission-prompt-tool stdio` 的控制协议（Agent SDK 的 `canUseTool` 同一条路）。
///
/// 为什么不靠 `PermissionRequest` hook：Claude Code 2.1.268 之前 `-p` 模式根本不发这个 hook，
/// 没有 hook 给出决定时直接拒绝（工具结果 "This command requires approval"），手机上永远看不到审批。
/// 有了 permission host 之后 claude 需要人点头时在 stdout 写一行
/// `{"type":"control_request","request_id":…,"request":{"subtype":"can_use_tool","tool_name":…,"input":{…},"tool_use_id":…}}`，
/// 等 stdin 回一行 `control_response`。与 hooks 装没装、Claude Code 哪个版本（SDK 从 1.0.59 起就走它）都无关。
/// PermissionRequest hook 在这种模式下与 host 并行、先答者生效，所以本连接器自己的轮次里 hook 一律立刻回空。
public enum ClaudeControlRequest: Equatable, Sendable {
    /// 要不要放行一个工具。`input` 是原样的工具入参（JSON 对象），允许时整份带回 `updatedInput`。
    case canUseTool(requestID: String, toolName: String, input: Data, toolUseID: String?)
    /// claude 不再等这条请求的回答了（这一轮被打断之类）。
    case cancel(requestID: String)
    /// 认不出的请求：回一条错误，别让 claude 干等。
    case unsupported(requestID: String, subtype: String)

    public init?(line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let requestID = object["request_id"] as? String, !requestID.isEmpty else { return nil }
        switch object["type"] as? String {
        case "control_cancel_request":
            self = .cancel(requestID: requestID)
        case "control_request":
            let request = object["request"] as? [String: Any] ?? [:]
            let subtype = request["subtype"] as? String ?? ""
            guard subtype == "can_use_tool", let toolName = request["tool_name"] as? String, !toolName.isEmpty else {
                self = .unsupported(requestID: requestID, subtype: subtype)
                return
            }
            let input = (request["input"] as? [String: Any]) ?? [:]
            let data = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? Data("{}".utf8)
            let toolUseID = (request["tool_use_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            self = .canUseTool(requestID: requestID, toolName: toolName, input: data, toolUseID: toolUseID)
        default:
            return nil
        }
    }
}

/// 对一条审批的回答，hook 与控制协议共用；各自在 `ClaudeHookOutput` / `ClaudeControlOutput` 里编码。
public enum ClaudePermissionDecision: Equatable, Sendable {
    /// 放行。`updatedInput` 是替换后的整份入参（回答 AskUserQuestion 时带 `answers`）；nil = 原样。
    case allow(updatedInput: Data?)
    case deny(message: String)
}

/// 写回 claude stdin 的控制协议行，一行 JSON 加 `\n`。
public enum ClaudeControlOutput {
    /// `allow` 总带 `updatedInput`：老版本的 schema 要求有它，没改入参就把原入参带回去。
    public static func response(requestID: String, decision: ClaudePermissionDecision, originalInput: Data) -> Data {
        let body: [String: Any]
        switch decision {
        case .allow(let updated):
            let input = (updated ?? originalInput).jsonObject ?? [:]
            body = ["behavior": "allow", "updatedInput": input]
        case .deny(let message):
            body = ["behavior": "deny", "message": message]
        }
        return line(["type": "control_response",
                     "response": ["subtype": "success", "request_id": requestID, "response": body] as [String: Any]])
    }

    public static func error(requestID: String, message: String) -> Data {
        line(["type": "control_response",
              "response": ["subtype": "error", "request_id": requestID, "error": message]])
    }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        data.append(0x0A)
        return data
    }
}

extension Data {
    fileprivate var jsonObject: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: self)) as? [String: Any]
    }
}

/// 一个 `claude -p` 子进程的 stdin：先写 user 消息，这一轮里再写控制协议的回答，读到 `result` 后关掉（= EOF，claude 退出）。
///
/// 写都在一条串行队列上：几 MB 的图会阻塞到 claude 读走为止，不能占着 actor；串行保证回答排在 user 消息之后、
/// 关闭排在所有回答之后。管道关掉 SIGPIPE：claude 已经退出时写入只是失败，不能把整个 app 带走。
final class ClaudeControlChannel: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "io.botbus.claude.stdin", qos: .userInitiated)
    private let lock = NSLock()
    private var closed = false

    init(handle: FileHandle) {
        self.handle = handle
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    /// 已经关了返回 false：这一轮结束了，回答送不到。
    @discardableResult
    func send(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        queue.async { [handle] in try? handle.write(contentsOf: data) }
        return true
    }

    /// 幂等。
    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        queue.async { [handle] in try? handle.close() }
    }

    var isOpen: Bool { lock.withLock { !closed } }
}
