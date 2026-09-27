import Foundation
import XCTest
@testable import BotBusConnectorKit

final class JSONRPCPeerTests: XCTestCase {
    func testRequestGetsResult() async throws {
        let (client, agent) = connectedPeers()
        await agent.setHandlers(request: { method, params in
            XCTAssertEqual(method, "echo")
            return params["value"] ?? .null
        }, notification: nil)
        let result = try await client.request("echo", params: ["value": "hi"])
        XCTAssertEqual(result, "hi")
    }

    func testErrorResponseBecomesJSONRPCError() async {
        let (client, agent) = connectedPeers()
        // ACP 的 `auth_required` 错误码（-32000）；Kit 只管 JSON-RPC 帧，错误码的含义在 BotBusConnectors。
        let authRequiredCode = -32000
        await agent.setHandlers(request: { _, _ in
            throw JSONRPCError(code: authRequiredCode, message: "auth_required")
        }, notification: nil)
        do {
            _ = try await client.request("session/new")
            XCTFail("应当抛错")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, authRequiredCode)
            XCTAssertEqual(error.message, "auth_required")
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testRequestWithoutHandlerIsMethodNotFound() async {
        let (client, _) = connectedPeers()
        do {
            _ = try await client.request("fs/read_text_file")
            XCTFail("应当抛错")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, JSONRPCError.methodNotFound)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testNotificationsArriveInOrder() async {
        let (client, agent) = connectedPeers()
        let seen = Locked<[Int64]>([])
        await client.setHandlers(request: nil, notification: { _, params in
            seen.withLock { $0.append(params["n"]?.intValue ?? -1) }
        })
        for n in 0..<50 { await agent.notify("tick", params: ["n": .int(Int64(n))]) }
        await assertEventually { seen.withLock { $0 } == (0..<50).map(Int64.init) }
    }

    func testTimeout() async {
        let peer = JSONRPCPeer(send: { _ in })
        do {
            _ = try await peer.request("initialize", timeout: 0.05)
            XCTFail("应当超时")
        } catch {
            XCTAssertEqual(error as? JSONRPCPeerError, .timeout(method: "initialize"))
        }
    }

    func testCloseFailsPendingAndLaterRequests() async throws {
        let sent = Locked(false)
        let peer = JSONRPCPeer(send: { _ in sent.withLock { $0 = true } })
        let waiting = Task { try await peer.request("session/prompt") }
        // 等请求真的发出去（进了 pending）再关闭，别靠猜时间的 sleep。
        await assertEventually { sent.withLock { $0 } }
        await peer.close(reason: "agent 进程退出了")
        do {
            _ = try await waiting.value
            XCTFail("应当失败")
        } catch {
            XCTAssertEqual(error as? JSONRPCPeerError, .closed(reason: "agent 进程退出了"))
        }
        do {
            _ = try await peer.request("x")
            XCTFail("应当失败")
        } catch {
            XCTAssertEqual(error as? JSONRPCPeerError, .closed(reason: "agent 进程退出了"))
        }
    }

    func testLineSplitAcrossChunks() async {
        let seen = Locked<[String]>([])
        let peer = JSONRPCPeer(send: { _ in })
        await peer.setHandlers(request: nil, notification: { method, _ in seen.withLock { $0.append(method) } })
        let bytes = Array((#"{"jsonrpc":"2.0","method":"session/update","params":{}}"# + "\n").utf8)
        await peer.receive(Data(bytes[..<10]))
        await peer.receive(Data(bytes[10...]))
        XCTAssertEqual(seen.withLock { $0 }, ["session/update"])
    }

    /// 对端的请求（审批要等人）不能堵住后面的通知。
    func testSlowIncomingRequestDoesNotBlockNotifications() async throws {
        let (client, agent) = connectedPeers()
        let gate = Locked(false)
        let seen = Locked<[String]>([])
        await client.setHandlers(request: { _, _ in
            while !gate.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
            return .null
        }, notification: { method, _ in seen.withLock { $0.append(method) } })
        let pending = Task { try await agent.request("session/request_permission") }
        await agent.notify("session/update")
        await assertEventually { seen.withLock { $0 } == ["session/update"] }
        gate.withLock { $0 = true }
        _ = try await pending.value
    }

    // MARK: - 框架健壮性

    func testStringRequestIdIsEchoedVerbatim() async {
        let sentLines = Locked<[String]>([])
        let peer = JSONRPCPeer(send: { line in sentLines.withLock { $0.append(line) } })
        await peer.setHandlers(request: { _, _ in .string("ok") }, notification: nil)
        let raw = #"{"jsonrpc":"2.0","id":"abc","method":"ping","params":{}}"# + "\n"
        await peer.receive(Data(raw.utf8))
        await assertEventually { sentLines.withLock { $0.count } == 1 }
        let response = sentLines.withLock { $0[0] }
        let decoded = try! JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
        XCTAssertEqual(decoded["id"], .string("abc"))
        XCTAssertEqual(decoded["result"], .string("ok"))
    }

    func testCarriageReturnLineEndingsAndBlankLinesAreSkipped() async {
        let seen = Locked<[String]>([])
        let peer = JSONRPCPeer(send: { _ in })
        await peer.setHandlers(request: nil, notification: { method, _ in seen.withLock { $0.append(method) } })
        let raw = "\r\n" + #"{"jsonrpc":"2.0","method":"a","params":{}}"# + "\r\n" + "\r\n"
            + #"{"jsonrpc":"2.0","method":"b","params":{}}"# + "\r\n"
        await peer.receive(Data(raw.utf8))
        XCTAssertEqual(seen.withLock { $0 }, ["a", "b"])
    }

    func testOversizedLineIsDroppedButNextMessageParses() async {
        let seen = Locked<[String]>([])
        let peer = JSONRPCPeer(send: { _ in })
        await peer.setHandlers(request: nil, notification: { method, _ in seen.withLock { $0.append(method) } })
        // 一大段没有换行符的数据：模拟一行异常巨大、始终没写完的攻击/故障场景。
        let oversized = Data(repeating: UInt8(ascii: "a"), count: JSONRPCPeer.maxLineBytes + 1)
        await peer.receive(oversized)
        let next = #"{"jsonrpc":"2.0","method":"after","params":{}}"# + "\n"
        await peer.receive(Data(next.utf8))
        XCTAssertEqual(seen.withLock { $0 }, ["after"])
    }

    func testLateResponseAfterTimeoutIsIgnored() async {
        let peer = JSONRPCPeer(send: { _ in })
        do {
            _ = try await peer.request("initialize", timeout: 0.02)
            XCTFail("应当超时")
        } catch {
            XCTAssertEqual(error as? JSONRPCPeerError, .timeout(method: "initialize"))
        }
        // 超时之后才到达的应答：不能崩，也不能让已经用掉的 continuation 被 resume 第二次。
        let late = #"{"jsonrpc":"2.0","id":1,"result":"late"}"# + "\n"
        await peer.receive(Data(late.utf8))
        // peer 本身应该还活着、照常工作。
        await peer.close(reason: "done")
        do {
            _ = try await peer.request("y")
            XCTFail("应当失败")
        } catch {
            XCTAssertEqual(error as? JSONRPCPeerError, .closed(reason: "done"))
        }
    }

    func testRequestHandlerThrowingPlainErrorYieldsInternalError() async {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
        let (client, agent) = connectedPeers()
        await agent.setHandlers(request: { _, _ in throw Boom() }, notification: nil)
        do {
            _ = try await client.request("do_it")
            XCTFail("应当抛错")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, JSONRPCError.internalError)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testRequestWithUnencodableParamsThrows() async {
        let peer = JSONRPCPeer(send: { _ in })
        do {
            _ = try await peer.request("x", params: ["bad": .double(.nan)])
            XCTFail("应当抛错")
        } catch {
            XCTAssertEqual(error as? JSONRPCPeerError, .unencodable(method: "x"))
        }
    }

    func testRequestHandlerReturningUnencodableResultFallsBackToInternalError() async {
        let (client, agent) = connectedPeers()
        await agent.setHandlers(request: { _, _ in .double(.nan) }, notification: nil)
        do {
            _ = try await client.request("weird")
            XCTFail("应当抛错")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, JSONRPCError.internalError)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    // MARK: - 分帧不应是二次方开销

    /// 单行 ~12 MB（仍在 `maxLineBytes` 16 MB 以内），按 64 KB 小 chunk 喂入。旧的「每个 chunk 从头扫一遍」
    /// 实现在这个体量下要跑到二十来秒；修好之后 debug 约 1 秒。上限给 6 秒：慢 CI runner 也不误报，又远低于退化后的耗时。
    func testLargeSingleLineAcrossManySmallChunksIsNotQuadratic() async {
        let seen = Locked<[String]>([])
        let peer = JSONRPCPeer(send: { _ in })
        await peer.setHandlers(request: nil, notification: { method, _ in seen.withLock { $0.append(method) } })
        let payload = String(repeating: "a", count: 12_000_000)
        let line = #"{"jsonrpc":"2.0","method":"big","params":{"data":""# + payload + #""}}"# + "\n"
        let bytes = Array(line.utf8)
        let chunkSize = 64 * 1024
        let start = Date()
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            await peer.receive(Data(bytes[offset..<end]))
            offset = end
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(seen.withLock { $0 }, ["big"])
        XCTAssertLessThan(elapsed, 6, "一行大消息按小 chunk 喂入不该是二次方开销（用了 \(elapsed) 秒）")
    }

    /// 只断言顺序与条数，不卡墙钟时间——真正防二次方退化的是上面那条大单行用例；
    /// 这条在慢 CI runner 上也不该因为跑得久了一点就变 flaky。
    func testManySmallNotificationsInOneChunkArriveInOrder() async {
        let seen = Locked<[Int64]>([])
        let peer = JSONRPCPeer(send: { _ in })
        await peer.setHandlers(request: nil, notification: { _, params in
            seen.withLock { $0.append(params["n"]?.intValue ?? -1) }
        })
        var combined = ""
        for n in 0..<20_000 {
            combined += #"{"jsonrpc":"2.0","method":"tick","params":{"n":\#(n)}}"# + "\n"
        }
        await peer.receive(Data(combined.utf8))
        XCTAssertEqual(seen.withLock { $0 }, (0..<20_000).map(Int64.init))
    }
}
