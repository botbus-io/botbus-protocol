import Foundation

/// 读 `claude -p --output-format stream-json --verbose` 的 stdout。
///
/// 一行一个 JSON 对象。这里只关心三件事：
/// - `{"type":"system","subtype":"init","session_id":…}` —— 会话 id，命令回执等的就是它；
/// - `{"type":"assistant","message":{"content":[{"type":"text","text":…}]}}` —— 留最后一段文本；
/// - `{"type":"result",…}` —— 一轮结束，`is_error`/`subtype` 说明成没成，报错时 `result` 是错误原文。
///
/// 另外 `--permission-prompt-tool stdio` 时 claude 经 stdout 发 `control_request`（要不要放行一个工具）
/// 与 `control_cancel_request`，原样交给 `onControl`，回答由调用方写进 stdin。
///
/// 什么时候能关 stdin（`onIdle`）：`result` 不等于 claude 没事做了。这一轮在后台开了子代理或命令
/// （`Agent` / `Bash` 的 `run_in_background`）时，`result` 照常先出来，后台跑完 claude 自己再起一轮接着做；
/// 这时 stdin 已经关了的话，子代理与接下来那一轮要审批的工具全报 "Tool permission request failed: Stream closed"
/// （无人值守的员工因此跑不了命令、改不了文件）。所以以 claude 自己报的状态为准：
/// - `{"type":"system","subtype":"session_state_changed","state":"idle"}`（子进程环境带
///   `CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS=1` 才发）—— 后台子代理跑完、留着的 `result` 发完才到；
/// - `{"type":"system","subtype":"background_tasks_changed","tasks":[…]}` —— 当前还活着的全部后台任务（整体替换），
///   `ambient` 的不算活动。后台命令（`local_bash`）不拦 `idle`，得靠它。
///
/// 见过 `result`、claude 报空闲、没有后台任务三者同时成立才报；后台任务是在空闲时清空的，claude 多半紧接着
/// 起一轮处理完成通知，先等 `idleGrace` 秒，期间读到任何一行都重新算。不发 `session_state_changed` 的旧版本
/// 退回到读到 `result` 就报（老行为）。
///
/// 其余类型（工具调用、增量）一律忽略：任务的状态由 hooks 说了算，这里只补 hooks 给不了的
/// session id 与结尾文本。**解析全程容错**——多一种没见过的行不该让整轮白跑。
public final class StreamJSONReader: @unchecked Sendable {
    public struct Result: Sendable {
        public var sessionID: String?
        public var lastText: String?
        /// `result` 行报了错，或者根本没等到 `result`。
        public var failed: Bool
        /// 报错的 `result` 行（`is_error: true`）自带的原文，例如 "Not logged in · Please run /login"。
        /// 失败诊断（协议 3.7）只看它：`lastText` 可能是 agent 自己说的最后一段话。
        public var errorText: String?
    }

    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var sessionID: String?
    private var lastText: String?
    private var errorText: String?
    private var sawResult = false
    private var failed = false
    private var finished = false
    /// claude 发过 `session_state_changed`：以它的 idle 为准，不再只看 `result`。
    private var reportsSessionState = false
    private var sessionIdle = false
    /// 不发状态的旧版本：上一行 `result` 之后还没有新的活动。
    private var resultIsLatest = false
    /// 还活着的后台任务（`background_tasks_changed`，不含 `ambient`）。
    private var backgroundTasks: Set<String> = []
    private var idleSignalled = false
    /// 每读一行加一：宽限期到点时没变才算真的安静。
    private var generation = 0
    private let idleGrace: TimeInterval

    private var sessionIDCallback: (@Sendable (String) -> Void)?
    private var finishedCallback: (@Sendable (Result) -> Void)?
    private var controlCallback: (@Sendable (_ line: Data, _ sessionID: String?) -> Void)?
    private var idleCallback: (@Sendable () -> Void)?

    /// `idleGrace`：后台任务在空闲时清空后，等多久没有新的一轮才报 `onIdle`（测试里调短）。
    public init(handle: FileHandle, idleGrace: TimeInterval = 3) {
        self.handle = handle
        self.idleGrace = idleGrace
    }

    /// 必须在 `start()` 之前设好。
    public var onSessionID: (@Sendable (String) -> Void)? {
        get { lock.withLock { sessionIDCallback } }
        set { lock.withLock { sessionIDCallback = newValue } }
    }

    public var onFinished: (@Sendable (Result) -> Void)? {
        get { lock.withLock { finishedCallback } }
        set { lock.withLock { finishedCallback = newValue } }
    }

    /// `control_request` / `control_cancel_request` 整行原样交出，连同 init 报的 session id（还没见到 init 是 nil）。
    /// 必须在 `start()` 之前设好。
    public var onControl: (@Sendable (_ line: Data, _ sessionID: String?) -> Void)? {
        get { lock.withLock { controlCallback } }
        set { lock.withLock { controlCallback = newValue } }
    }

    /// claude 这一轮连同后台的事都做完了（规则见类型说明），最多报一次。stream-json 输入时 claude 读到 stdin 的 EOF
    /// 才退出，调用方在这里关 stdin；关早了，之后的审批都送不到。必须在 `start()` 之前设好。
    public var onIdle: (@Sendable () -> Void)? {
        get { lock.withLock { idleCallback } }
        set { lock.withLock { idleCallback = newValue } }
    }

    public func start() {
        handle.portableReadabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else {
                handle.finishPortableReading()
                return
            }
            if chunk.isEmpty {
                self.finish()
                return
            }
            self.consume(chunk)
        }
    }

    /// 幂等：进程退出与读到 EOF 会各调一次，只有第一次作数。之后不再读，读端交给 `finishPortableReading()` 关。
    public func finish() {
        let callback: (@Sendable (Result) -> Void)?
        let result: Result
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        // 不只摘 handler：Linux 上还得关掉读端，否则每一轮 `claude -p` 漏一个描述符。
        handle.finishPortableReading()
        callback = finishedCallback
        // 一行 `result` 都没见到就当失败：正常结束一定有它。
        result = Result(sessionID: sessionID, lastText: lastText, failed: failed || !sawResult, errorText: errorText)
        lock.unlock()
        callback?(result)
    }

    private func consume(_ chunk: Data) {
        var lines: [Data] = []
        var newSessionID: String?
        var sessionIDCallback: (@Sendable (String) -> Void)?
        var controls: [(line: Data, sessionID: String?)] = []
        // 这一块里有让「安静」成立的那一行（idle，或旧版本的 result）：条件满足就立刻报，不用宽限。
        var settledHere = false

        lock.lock()
        buffer.append(chunk)
        while let index = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(buffer[buffer.startIndex..<index])
            buffer = buffer[buffer.index(after: index)...]
        }
        // 一行都没读完整就先攒着。上限只是防一个坏掉的流把内存吃光。
        if buffer.count > 1 << 20 { buffer.removeAll(keepingCapacity: false) }
        for line in lines {
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            generation += 1
            switch object["type"] as? String {
            case "system":
                switch object["subtype"] as? String {
                case "session_state_changed":
                    reportsSessionState = true
                    sessionIdle = object["state"] as? String == "idle"
                    if sessionIdle { settledHere = true }
                case "background_tasks_changed":
                    let tasks = object["tasks"] as? [[String: Any]] ?? []
                    backgroundTasks = Set(tasks.compactMap { task in
                        task["ambient"] as? Bool == true ? nil : task["task_id"] as? String
                    })
                case "init":
                    // 只认 `init`：`--resume` 时 SessionStart hook 的 `hook_started` / `hook_response` 行排在它前面，
                    // 带的是一个临时 session id，拿它当会话 id 会让续聊被误判成分支。
                    // 后台任务跑完 claude 再起一轮时会再发一次 init，同一个 id，不理。
                    guard sessionID == nil, let id = object["session_id"] as? String, !id.isEmpty else { break }
                    sessionID = id
                    newSessionID = id
                    sessionIDCallback = self.sessionIDCallback
                default:
                    break
                }
            case "assistant":
                resultIsLatest = false
                if let text = Self.text(in: object), !text.isEmpty { lastText = text }
            case "result":
                sawResult = true
                let isError = (object["is_error"] as? Bool) ?? false
                let subtype = (object["subtype"] as? String) ?? "success"
                if isError || subtype != "success" { failed = true }
                // `result` 行自带最终文本时用它，比累计的最后一段更准。
                if let text = object["result"] as? String, !text.isEmpty {
                    lastText = text
                    if isError { errorText = text }
                }
                resultIsLatest = true
                if !reportsSessionState { settledHere = true }
            case "control_request", "control_cancel_request":
                resultIsLatest = false
                controls.append((Data(line), sessionID))
            default:
                break
            }
        }
        let controlCallback = controls.isEmpty ? nil : self.controlCallback
        var idleCallback: (@Sendable () -> Void)?
        if isQuiet {
            if settledHere {
                idleSignalled = true
                idleCallback = self.idleCallback
            } else {
                scheduleIdle(after: generation)
            }
        }
        lock.unlock()

        // 回调都在锁外：调用方可能回头读属性。顺序与行序一致：先有 id，再有审批，最后收尾。
        if let newSessionID { sessionIDCallback?(newSessionID) }
        for control in controls { controlCallback?(control.line, control.sessionID) }
        idleCallback?()
    }

    /// 持锁调用。还没报过，见过 `result`，claude 不在跑（报状态的看 idle，旧版本看最后一行 `result` 之后没有新活动），也没有后台任务。
    private var isQuiet: Bool {
        guard !idleSignalled, !finished, sawResult, backgroundTasks.isEmpty else { return false }
        return reportsSessionState ? sessionIdle : resultIsLatest
    }

    /// 持锁调用。后台任务在空闲时清空：claude 多半马上起一轮处理完成通知（那一行可能还在管道里），
    /// 等一会儿；到点时又读过别的行就作废，由那一块重新判断。
    private func scheduleIdle(after generation: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + idleGrace) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let callback: (@Sendable () -> Void)?
            if self.generation == generation, self.isQuiet {
                self.idleSignalled = true
                callback = self.idleCallback
            } else {
                callback = nil
            }
            self.lock.unlock()
            callback?()
        }
    }

    /// `{"message":{"content":[{"type":"text","text":…}]}}` 里的文本，拼起来。
    private static func text(in object: [String: Any]) -> String? {
        let content = (object["message"] as? [String: Any])?["content"] ?? object["content"]
        if let text = content as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let blocks = content as? [[String: Any]] else { return nil }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
