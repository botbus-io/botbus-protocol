import Foundation
import BotBusConnectorKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// web 的 prompt 接口不能挂 MCP。任务凭据通过私有 FIFO 给 CLI，提示词里只有管道路径。
/// FIFO 的字节只在内核内存中，目录 0700、管道 0600；退出 / 停用 / 解除配对后关闭并删除。
final class DshToolsContext: Sendable {
    let path: String
    let configuration: AgentToolsConfiguration
    let token: String
    private let worker: Task<Void, Never>

    init(injection: AgentToolsInjection) throws {
        #if os(Windows)
        throw ConnectorError("这个平台暂不支持 DeepSeek Harness 网页续聊的工具管道")
        #else
        var template = Array(FileManager.default.temporaryDirectory
            .appendingPathComponent("botbus-dsh-tools-XXXXXX").path.utf8CString)
        guard let created = mkdtemp(&template) else { throw ConnectorError("无法创建 DeepSeek Harness 工具上下文") }
        let directory = String(cString: created)
        let path = directory + "/context"
        guard mkfifo(path, 0o600) == 0 else {
            try? FileManager.default.removeItem(atPath: directory)
            throw ConnectorError("无法创建 DeepSeek Harness 工具管道")
        }
        // 独立读端防止 SIGPIPE，也用于 FIONREAD：macOS 的 O_RDWR FIFO 查到的是写端（恒为 0）。
        let reader = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard reader >= 0 else {
            try? FileManager.default.removeItem(atPath: directory)
            throw ConnectorError("无法打开 DeepSeek Harness 工具管道")
        }
        let fd = open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            close(reader)
            try? FileManager.default.removeItem(atPath: directory)
            throw ConnectorError("无法打开 DeepSeek Harness 工具管道")
        }
        var bytes = try JSONEncoder().encode(injection.environment)
        bytes.append(10)
        guard bytes.count <= fpathconf(fd, Int32(_PC_PIPE_BUF)) else {
            close(fd)
            close(reader)
            try? FileManager.default.removeItem(atPath: directory)
            throw ConnectorError("DeepSeek Harness 工具上下文过长")
        }
        self.path = path
        configuration = injection.configuration
        token = injection.token
        let payload = bytes
        worker = Task.detached {
            defer {
                close(fd)
                close(reader)
                try? FileManager.default.removeItem(atPath: directory)
            }
            while !Task.isCancelled {
                // 只保留一条完整记录，避免多条累积后读端在记录中间截断。
                var available: Int32 = 0
                #if canImport(Darwin)
                // Darwin 的 _IOR 宏不能由 Swift 导入：_IOR('f', 127, int)。
                let status = ioctl(reader, 0x4004667f, &available)
                #else
                let status = ioctl(reader, UInt(FIONREAD), &available)
                #endif
                if status == 0, available == 0 {
                    _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                }
                do { try await Task.sleep(for: .seconds(0.25)) } catch { break }
            }
        }
        #endif
    }

    deinit { worker.cancel() }

    func shutdown() async {
        worker.cancel()
        await worker.value
    }

    func prompt(_ text: String) -> String {
        let command = "BOTBUS_CONTEXT_PIPE=\(Self.quote(path)) \(Self.quote(configuration.cliPath))"
        return text + Self.marker + AgentToolsInstructions.text(cliPath: command, mcp: false) + "\n" +
            "Use that full command prefix for every BotBus CLI invocation. The task credentials are supplied by the pipe; do not read, print or copy them.\n" + Self.end
    }

    static let requestPrefix = "botbus-tools-"
    private static let marker = "\n\n<botbus-cli-context>\n"
    private static let end = "</botbus-cli-context>"

    /// 手机只显示原来的用户消息；只有本连接器带标记的 RPC 才去掉追加的上下文。
    static func visibleText(_ text: String, requestId: String?) -> String {
        guard requestId?.hasPrefix(requestPrefix) == true, text.hasSuffix(end),
              let range = text.range(of: marker, options: .backwards) else { return text }
        return String(text[..<range.lowerBound])
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
