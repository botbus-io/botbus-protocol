import Foundation

/// 手机下发任务的"身份证"：一次性签发的随机 token → 这条任务的协议 id（`codex:<threadId>` / `claude:<sessionId>`）。
///
/// 连接器起 `claude -p` / `thread/start` 之前 `issue()` 一个 token，经环境变量与 MCP 配置交给 agent；
/// agent 调 `botbus` CLI 时带着它回到本机工具服务器（`LocalToolAPI`），我们据此知道产物该挂到哪条任务上。
/// 先签发、后绑定：Claude 的 session id 要等进程起来几秒后才从 stream-json 里出现，
/// 所以 `resolve` 对"已签发未绑定"的 token 会等一会儿（默认 5 秒）。
///
/// **只在内存里**。app 重启后旧 token 全部失效——被它启动的子进程也随 app 一起结束了，
/// 留着只会让一个泄露的 token 活得比它的任务更久。
public actor TaskContextRegistry {
    /// `resolve` 等绑定的默认上限（spec 3.1）。
    public static let defaultResolveWait: TimeInterval = 5
    /// 最多记多少个 token。每条手机任务一个，超了淘汰最早签发的——几百条之前的任务早就不在跑了。
    public static let maxTokens = 1000
    /// token 的随机字节数（base64url 后 43 字符）。
    public static let tokenBytes = 32

    /// 已签发的 token → 绑定的任务 id；nil = 已签发、还没绑定。
    private var taskByToken: [String: String?] = [:]
    /// 任务 id → 最近绑定给它的 token（续聊复用）。
    private var tokenByTask: [String: String] = [:]
    /// 签发顺序，淘汰时从队首拿。
    private var order: [String] = []
    /// 正在等某个 token 绑定的调用方。一律过 `OneShotContinuation`：绑定、超时、取消三条路径抢同一个出口。
    private var waiters: [String: [UUID: OneShotContinuation<String?>]] = [:]
    private let generate: @Sendable () -> String

    public init(generateToken: @escaping @Sendable () -> String = { RandomID.base64url(byteCount: TaskContextRegistry.tokenBytes) }) {
        self.generate = generateToken
    }

    /// 签发一个新 token（尚未绑定任务）。
    public func issue() -> String {
        var token = generate()
        // 随机 32 字节撞车只在测试注入的生成器里可能发生；撞了就换，别让两条任务共用一张身份证。
        while taskByToken[token] != nil { token = generate() }
        taskByToken[token] = .some(nil)
        order.append(token)
        trim()
        return token
    }

    /// 已知任务的手机续聊：复用 / 签发 / 绑定在同一次 actor 调用内完成，避免并发轮次各签一份。
    public func issue(for taskId: String) -> String {
        if let existing = tokenByTask[taskId] { return existing }
        let token = issue()
        bind(token, taskId: taskId)
        return token
    }

    /// 把 token 绑到任务上。只认本实例签发过的 token；可以重复绑定（Claude `--resume` 分支出新 session 时
    /// 同一个 token 改绑到新 id，旧 id 仍能用 `token(for:)` 查回它）。返回是否生效。
    @discardableResult
    public func bind(_ token: String, taskId: String) -> Bool {
        guard taskByToken[token] != nil, !taskId.isEmpty else { return false }
        taskByToken[token] = .some(taskId)
        tokenByTask[taskId] = token
        if let pending = waiters.removeValue(forKey: token) {
            for box in pending.values { box.resume(returning: taskId) }
        }
        return true
    }

    /// 这个任务上次用的 token。续聊时复用，agent 手里那份就一直有效。
    public func token(for taskId: String) -> String? { tokenByTask[taskId] }

    /// 不等待的查询：已绑定才有值。
    public func taskId(for token: String) -> String? { taskByToken[token] ?? nil }

    /// 把 token 解析成任务 id。未签发过 → 立刻 nil；已签发未绑定 → 最多等 `wait` 秒；调用方被取消 → nil。
    public func resolve(_ token: String, wait: TimeInterval = TaskContextRegistry.defaultResolveWait) async -> String? {
        guard let entry = taskByToken[token] else { return nil }
        if let taskId = entry { return taskId }
        guard wait > 0 else { return nil }

        let id = UUID()
        let box = OneShotContinuation<String?>()
        waiters[token, default: [:]][id] = box
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            await self?.expireWaiter(token: token, id: id)
        }
        let resolved = await withTaskCancellationHandler {
            (try? await box.value()) ?? nil
        } onCancel: {
            box.resume(returning: nil)
        }
        timer.cancel()
        removeWaiter(token: token, id: id)
        return resolved
    }

    /// 当前记着的 token 数（测试用）。
    public var tokenCount: Int { taskByToken.count }

    // MARK: - 内部

    private func expireWaiter(token: String, id: UUID) {
        waiters[token]?[id]?.resume(returning: nil)
        removeWaiter(token: token, id: id)
    }

    private func removeWaiter(token: String, id: UUID) {
        waiters[token]?.removeValue(forKey: id)
        if waiters[token]?.isEmpty == true { waiters.removeValue(forKey: token) }
    }

    private func trim() {
        while order.count > Self.maxTokens {
            let victim = order.removeFirst()
            if let bound = taskByToken.removeValue(forKey: victim) ?? nil, tokenByTask[bound] == victim {
                tokenByTask.removeValue(forKey: bound)
            }
            if let pending = waiters.removeValue(forKey: victim) {
                for box in pending.values { box.resume(returning: nil) }
            }
        }
    }
}

/// 密码学安全的随机 id。`SystemRandomNumberGenerator` 在 Apple 平台上走 `arc4random_buf`。
public enum RandomID {
    /// `byteCount` 个随机字节的 base64url（无填充）。16 字节 → 22 字符，32 字节 → 43 字符。
    public static func base64url(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64url(Data(bytes))
    }

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
