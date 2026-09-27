import XCTest
import BotBusConnectorKit
@testable import BotBusConnectorKit

final class TaskContextRegistryTests: XCTestCase {
    func testIssuedTokenIsRandomBase64URL() async {
        let registry = TaskContextRegistry()
        let first = await registry.issue()
        let second = await registry.issue()
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.count, 43, "32 字节 base64url 无填充是 43 字符")
        XCTAssertNil(first.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    func testBindThenResolveAndReverseLookup() async {
        let registry = TaskContextRegistry()
        let token = await registry.issue()
        let bound = await registry.bind(token, taskId: "claude:s1")
        XCTAssertTrue(bound)
        let resolved = await registry.resolve(token)
        XCTAssertEqual(resolved, "claude:s1")
        let reverse = await registry.token(for: "claude:s1")
        XCTAssertEqual(reverse, token)
    }

    func testUnknownTokenResolvesToNilImmediately() async {
        let registry = TaskContextRegistry()
        let started = Date()
        let resolved = await registry.resolve("nope", wait: 5)
        XCTAssertNil(resolved)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "没签发过的 token 不该等")
    }

    func testBindIgnoresTokensThisRegistryNeverIssued() async {
        let registry = TaskContextRegistry()
        let bound = await registry.bind("forged", taskId: "codex:t")
        XCTAssertFalse(bound)
        let reverse = await registry.token(for: "codex:t")
        XCTAssertNil(reverse)
    }

    /// Claude 的 session id 在进程起来几秒后才出现：先签发、后绑定，工具调用可能夹在中间。
    func testResolveWaitsForLateBinding() async {
        let registry = TaskContextRegistry()
        let token = await registry.issue()
        let waiter = Task { await registry.resolve(token, wait: 5) }
        try? await Task.sleep(for: .milliseconds(100))
        await registry.bind(token, taskId: "claude:late")
        let resolved = await waiter.value
        XCTAssertEqual(resolved, "claude:late")
    }

    func testResolveGivesUpAfterWait() async {
        let registry = TaskContextRegistry()
        let token = await registry.issue()
        let started = Date()
        let resolved = await registry.resolve(token, wait: 0.2)
        XCTAssertNil(resolved)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.15)
        // 超时之后再绑定不会碰到已经落定的等待者（OneShotContinuation 兜住二次 resume）。
        await registry.bind(token, taskId: "claude:after")
        let later = await registry.resolve(token, wait: 0)
        XCTAssertEqual(later, "claude:after")
    }

    func testCancelledResolveReturnsNil() async {
        let registry = TaskContextRegistry()
        let token = await registry.issue()
        let waiter = Task { await registry.resolve(token, wait: 5) }
        try? await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        let resolved = await waiter.value
        XCTAssertNil(resolved)
    }

    func testManyConcurrentWaitersAllWakeOnBind() async {
        let registry = TaskContextRegistry()
        let token = await registry.issue()
        let waiters = (0..<20).map { _ in Task { await registry.resolve(token, wait: 5) } }
        try? await Task.sleep(for: .milliseconds(50))
        await registry.bind(token, taskId: "codex:many")
        for waiter in waiters {
            let resolved = await waiter.value
            XCTAssertEqual(resolved, "codex:many")
        }
    }

    /// `--resume` 分支出新 session：同一个 token 改绑新 id，旧 id 仍能查回 token。
    func testRebindMovesTokenToForkedTask() async {
        let registry = TaskContextRegistry()
        let token = await registry.issue()
        await registry.bind(token, taskId: "claude:old")
        await registry.bind(token, taskId: "claude:fork")
        let resolved = await registry.resolve(token)
        XCTAssertEqual(resolved, "claude:fork")
        let old = await registry.token(for: "claude:old")
        let fork = await registry.token(for: "claude:fork")
        XCTAssertEqual(old, token)
        XCTAssertEqual(fork, token)
    }

    func testTokenCountIsBounded() async {
        let counter = Locked(0)
        let registry = TaskContextRegistry(generateToken: {
            counter.withLock { value -> String in
                value += 1
                return "t\(value)"
            }
        })
        let first = await registry.issue()
        await registry.bind(first, taskId: "codex:first")
        for _ in 0..<TaskContextRegistry.maxTokens { _ = await registry.issue() }
        let count = await registry.tokenCount
        XCTAssertEqual(count, TaskContextRegistry.maxTokens)
        let evicted = await registry.resolve(first, wait: 0)
        XCTAssertNil(evicted, "最早签发的被淘汰")
        let reverse = await registry.token(for: "codex:first")
        XCTAssertNil(reverse)
    }

    func testBase64URLOfSixteenBytesIsTwentyTwoCharacters() {
        let id = RandomID.base64url(byteCount: 16)
        XCTAssertEqual(id.count, 22)
        XCTAssertEqual(RandomID.base64url(Data([0xfb, 0xff])), "-_8")
    }
}
