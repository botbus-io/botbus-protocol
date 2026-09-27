import Foundation

/// 独占一个 `CheckedContinuation` 的一次性盒子：谁先 resume 谁生效，其余静默丢弃，线程安全。
///
/// 回调式 API 包出来的 continuation 必须过它。`URLSessionWebSocketTask.sendPing` 的 pong 回调
/// 在任务被 cancel 时会被再触发一次（pong 已到达、紧接着 cancel，两条路径各调一次），
/// 而 `CheckedContinuation` 第二次 resume 是**无条件**的运行时检查：它走 `_assertionFailure`
/// 直接 SIGTRAP，不像 `assertionFailure` 那样只在 Debug 生效——Release 构建照样把整个进程打死。
/// Agent 是 24/7 后台进程，这种崩溃表现为菜单栏图标凭空消失。
///
/// 让这个类型自己持有 continuation（而不是只给一个"闸门"布尔），调用方就没机会忘了加保护；
/// 同时超时、取消、回调三条路径可以共用同一个盒子，不必再靠 TaskGroup 去做"先到者胜"。
public final class OneShotContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    /// install 之前抢先到达的结果（超时/取消可能跑在 continuation 装上之前），install 时立即兑现。
    private var pending: Result<Value, Error>?
    private var finished = false

    public init() {}

    /// 在 `withCheckedThrowingContinuation` 的 body 里调用一次。
    public func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        let ready = pending
        pending = nil
        if ready == nil { self.continuation = continuation }
        lock.unlock()
        if let ready { continuation.resume(with: ready) }
    }

    /// 第一个调用者生效并返回 true，其余静默丢弃返回 false。install 之前调用也安全。
    @discardableResult
    public func resume(returning value: Value) -> Bool { finish(.success(value)) }

    /// 第一个调用者生效并返回 true，其余静默丢弃返回 false。install 之前调用也安全。
    @discardableResult
    public func resume(throwing error: Error) -> Bool { finish(.failure(error)) }

    /// 等这个盒子落定。install 之前就已经落定的结果同样拿得到（`pending` 会在这里兑现）。
    /// 一个盒子只该被 await 一次——第二次 `install` 会覆盖前一个 continuation，把它永远挂住。
    public func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in install(continuation) }
    }

    private func finish(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        if finished {
            lock.unlock()
            return false
        }
        finished = true
        let taken = continuation
        continuation = nil
        // 还没 install：先存着，等 install 时立刻兑现。
        if taken == nil { pending = result }
        lock.unlock()
        // 出锁再 resume：continuation 的 resume 会同步唤醒等待方，握着锁调用容易自找死锁。
        taken?.resume(with: result)
        return true
    }
}
