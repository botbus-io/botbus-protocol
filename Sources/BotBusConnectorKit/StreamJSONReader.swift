import Foundation

/// 读 `claude -p --output-format stream-json --verbose` 的 stdout。
///
/// 一行一个 JSON 对象。这里只关心三件事：
/// - `{"type":"system","subtype":"init","session_id":…}` —— 会话 id，命令回执等的就是它；
/// - `{"type":"assistant","message":{"content":[{"type":"text","text":…}]}}` —— 留最后一段文本；
/// - `{"type":"result",…}` —— 一轮结束，`is_error`/`subtype` 说明成没成。
///
/// 另外 `--permission-prompt-tool stdio` 时 claude 经 stdout 发 `control_request`（要不要放行一个工具）
/// 与 `control_cancel_request`，原样交给 `onControl`，回答由调用方写进 stdin。
///
/// 其余类型（工具调用、增量）一律忽略：任务的状态由 hooks 说了算，这里只补 hooks 给不了的
/// session id 与结尾文本。**解析全程容错**——多一种没见过的行不该让整轮白跑。
public final class StreamJSONReader: @unchecked Sendable {
    public struct Result: Sendable {
        public var sessionID: String?
        public var lastText: String?
        /// `result` 行报了错，或者根本没等到 `result`。
        public var failed: Bool
    }

    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var sessionID: String?
    private var lastText: String?
    private var sawResult = false
    private var failed = false
    private var finished = false

    private var sessionIDCallback: (@Sendable (String) -> Void)?
    private var finishedCallback: (@Sendable (Result) -> Void)?
    private var controlCallback: (@Sendable (_ line: Data, _ sessionID: String?) -> Void)?
    private var resultCallback: (@Sendable () -> Void)?

    public init(handle: FileHandle) {
        self.handle = handle
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

    /// 读到 `result` 行：这一轮结束了。stream-json 输入时 claude 读到 stdin 的 EOF 才退出，
    /// 调用方在这里关 stdin。必须在 `start()` 之前设好。
    public var onResult: (@Sendable () -> Void)? {
        get { lock.withLock { resultCallback } }
        set { lock.withLock { resultCallback = newValue } }
    }

    public func start() {
        handle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                self.finish()
                return
            }
            self.consume(chunk)
        }
    }

    /// 幂等：进程退出与读到 EOF 会各调一次，只有第一次作数。
    public func finish() {
        let callback: (@Sendable (Result) -> Void)?
        let result: Result
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        handle.readabilityHandler = nil
        callback = finishedCallback
        // 一行 `result` 都没见到就当失败：正常结束一定有它。
        result = Result(sessionID: sessionID, lastText: lastText, failed: failed || !sawResult)
        lock.unlock()
        callback?(result)
    }

    private func consume(_ chunk: Data) {
        var lines: [Data] = []
        var newSessionID: String?
        var sessionIDCallback: (@Sendable (String) -> Void)?
        var controls: [(line: Data, sessionID: String?)] = []
        var sawResultLine = false

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
            switch object["type"] as? String {
            case "system":
                // 只认 `init`：`--resume` 时 SessionStart hook 的 `hook_started` / `hook_response` 行排在它前面，
                // 带的是一个临时 session id，拿它当会话 id 会让续聊被误判成分支。
                guard sessionID == nil, object["subtype"] as? String == "init",
                      let id = object["session_id"] as? String, !id.isEmpty else { break }
                sessionID = id
                newSessionID = id
                sessionIDCallback = self.sessionIDCallback
            case "assistant":
                if let text = Self.text(in: object), !text.isEmpty { lastText = text }
            case "result":
                sawResult = true
                let isError = (object["is_error"] as? Bool) ?? false
                let subtype = (object["subtype"] as? String) ?? "success"
                if isError || subtype != "success" { failed = true }
                // `result` 行自带最终文本时用它，比累计的最后一段更准。
                if let text = object["result"] as? String, !text.isEmpty { lastText = text }
                sawResultLine = true
            case "control_request", "control_cancel_request":
                controls.append((Data(line), sessionID))
            default:
                break
            }
        }
        let controlCallback = controls.isEmpty ? nil : self.controlCallback
        let resultCallback = sawResultLine ? self.resultCallback : nil
        lock.unlock()

        // 回调都在锁外：调用方可能回头读属性。顺序与行序一致：先有 id，再有审批，最后收尾。
        if let newSessionID { sessionIDCallback?(newSessionID) }
        for control in controls { controlCallback?(control.line, control.sessionID) }
        resultCallback?()
    }

    /// `{"message":{"content":[{"type":"text","text":…}]}}` 里的文本，拼起来。
    private static func text(in object: [String: Any]) -> String? {
        let content = (object["message"] as? [String: Any])?["content"] ?? object["content"]
        if let text = content as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let blocks = content as? [[String: Any]] else { return nil }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
