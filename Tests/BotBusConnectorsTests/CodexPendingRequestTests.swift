import Foundation
import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

/// 协议 3.11：Codex 的服务端请求 → `PendingRequest`。电脑写的话带短语，中文原文由短语拼出、两边一致；
/// agent 的原话（理由、提问）原样放、不带短语。
final class CodexPendingRequestTests: XCTestCase {
    private func make(_ method: String, _ params: JSONValue, kind: PendingRequest.Kind,
                      fileChanges: [CodexFileChange] = []) -> PendingRequest {
        CodexConnector.pendingRequest(from: CodexServerRequest(id: .number(7), method: method, params: params,
                                                               fileChanges: fileChanges), kind: kind)
    }

    func testCommandWithReasonAndDirectory() {
        let request = make("item/commandExecution/requestApproval",
                           ["command": "rm -rf build\nls", "reason": "清掉旧产物", "cwd": "/tmp/project"], kind: .command)
        XCTAssertEqual(request.summary, "执行命令：rm -rf build ls")
        XCTAssertEqual(request.summaryPhrase, .runCommand("rm -rf build ls"))
        XCTAssertEqual(request.detail, "清掉旧产物\n工作目录：/tmp/project")
        XCTAssertEqual(request.detailPhrases, [.text("清掉旧产物"), .workingDirectory("/tmp/project")])
    }

    func testCommandWithoutCommandFallsBackToReasonThenToTheGenericPhrase() {
        let reasoned = make("item/commandExecution/requestApproval", ["reason": "需要联网"], kind: .command)
        XCTAssertEqual(reasoned.summary, "需要联网")
        XCTAssertNil(reasoned.summaryPhrase, "摘要是 agent 的原话")
        XCTAssertEqual(reasoned.detail, "需要联网")
        XCTAssertNil(reasoned.detailPhrases, "详情里只有原话时不带短语")

        let bare = make("item/commandExecution/requestApproval", [:], kind: .command)
        XCTAssertEqual(bare.summary, "请求执行命令")
        XCTAssertEqual(bare.summaryPhrase, .requestCommand)
        XCTAssertNil(bare.detail)
        XCTAssertNil(bare.detailPhrases)
    }

    func testLongCommandIsClampedInBothThePhraseAndTheSummary() {
        let long = String(repeating: "x", count: 1000)
        let request = make("item/commandExecution/requestApproval", ["command": .string(long)], kind: .command)
        let command = try? XCTUnwrap(request.summaryPhrase?.text)
        XCTAssertLessThanOrEqual(command?.count ?? .max, CodexConnector.summaryLimit)
        XCTAssertLessThanOrEqual(request.summary.count, CodexConnector.summaryLimit)
    }

    func testFileChangeNamesTheFilesAndKeepsTheDiffAsDetail() {
        let changes = [CodexFileChange(path: "/tmp/p/a.swift", kind: "update", diff: "-a\n+b"),
                       CodexFileChange(path: "/tmp/p/b.swift", kind: "add", diff: "+c")]
        let request = make("item/fileChange/requestApproval", [:], kind: .fileChange, fileChanges: changes)
        XCTAssertEqual(request.summary, "修改 2 个文件：a.swift、b.swift")
        XCTAssertEqual(request.summaryPhrase, .editFiles(["a.swift", "b.swift"]))
        XCTAssertEqual(request.detail, "--- /tmp/p/a.swift (update)\n-a\n+b\n--- /tmp/p/b.swift (add)\n+c")
        XCTAssertNil(request.detailPhrases, "补丁是原文")

        let many = (1...25).map { CodexFileChange(path: "/tmp/p/f\($0).swift", kind: "update", diff: "") }
        let truncated = make("item/fileChange/requestApproval", [:], kind: .fileChange, fileChanges: many)
        XCTAssertEqual(truncated.summaryPhrase?.items?.count, RequestPhrase.maxItems)
        XCTAssertEqual(truncated.summaryPhrase?.count, 25)
        XCTAssertTrue(truncated.summary.hasPrefix("修改 25 个文件：f1.swift、"))

        let unnamed = make("item/fileChange/requestApproval", [:], kind: .fileChange)
        XCTAssertEqual(unnamed.summary, "请求修改文件")
        XCTAssertEqual(unnamed.summaryPhrase, .requestFileChange)
        let reasoned = make("item/fileChange/requestApproval", ["reason": "改配置"], kind: .fileChange)
        XCTAssertEqual(reasoned.summary, "改配置")
        XCTAssertNil(reasoned.summaryPhrase)
        XCTAssertEqual(reasoned.detail, "改配置")
    }

    /// 名字长、个数多时只留得下的几个，总数照记、句末加「…」；整句短语塞得进推送的预算。
    func testLongFileNamesStayWithinTheSentenceBudget() throws {
        let many = (1...25).map {
            CodexFileChange(path: "/tmp/p/\(String(repeating: "很长的中文文件名", count: 5))\($0).swift", kind: "update", diff: "")
        }
        let request = make("item/fileChange/requestApproval", [:], kind: .fileChange, fileChanges: many)
        let phrase = try XCTUnwrap(request.summaryPhrase)
        let kept = try XCTUnwrap(phrase.items)
        XCTAssertLessThan(kept.count, 25)
        XCTAssertLessThanOrEqual(kept.joined(separator: "、").count, RequestPhrase.maxItemsLength)
        XCTAssertEqual(phrase.count, 25)
        XCTAssertTrue(request.summary.hasPrefix("修改 25 个文件："))
        XCTAssertLessThanOrEqual(try ProtocolJSON.encoder().encode(phrase).count, 1024)
    }

    func testManyPathsAreMarkedAsTruncated() throws {
        let paths: [JSONValue] = (1...30).map { .string("/Users/demo/Projects/demo-app/dist/chunk-\($0).js") }
        let request = make("item/permissions/requestApproval", ["permissions": ["fileSystem": ["write": .array(paths)]]],
                           kind: .permission)
        let write = try XCTUnwrap(request.detailPhrases?.first)
        XCTAssertEqual(write.kind, .writePaths)
        XCTAssertEqual(write.count, 30)
        XCTAssertTrue(write.isTruncated)
        XCTAssertTrue(try XCTUnwrap(request.detail).hasSuffix("…"), "旧手机看到的中文也要看得出还有更多")
    }

    func testPermissionsDescribeWhatIsAskedFor() {
        let request = make("item/permissions/requestApproval", [
            "permissions": ["network": ["enabled": true],
                            "fileSystem": ["read": ["/a", "/b"], "write": ["/c"]]],
        ], kind: .permission)
        XCTAssertEqual(request.summary, "请求额外权限")
        XCTAssertEqual(request.summaryPhrase, .requestExtraPermissions)
        XCTAssertEqual(request.detail, "网络访问\n读取：/a、/b\n写入：/c")
        XCTAssertEqual(request.detailPhrases, [.networkAccess, .readPaths(["/a", "/b"]), .writePaths(["/c"])])

        let policy = make("item/permissions/requestApproval", ["reason": "装依赖", "permissions": ["network": ["enabled": false]]],
                          kind: .permission)
        XCTAssertEqual(policy.summary, "装依赖")
        XCTAssertNil(policy.summaryPhrase)
        XCTAssertEqual(policy.detail, "网络策略调整")
        XCTAssertEqual(policy.detailPhrases, [.networkPolicy])

        let empty = make("item/permissions/requestApproval", [:], kind: .permission)
        XCTAssertNil(empty.detail)
        XCTAssertNil(empty.detailPhrases)
    }

    func testInputUsesTheQuestionAndDescribesTheRest() {
        let request = make("item/tool/requestUserInput", ["questions": [
            ["id": "q1", "header": "部署到哪", "question": "要部署到哪个环境？",
             "options": [["label": "staging"], ["label": "production"]]],
            ["id": "q2", "question": "要不要先跑测试？"],
        ]], kind: .input)
        XCTAssertEqual(request.summary, "部署到哪")
        XCTAssertNil(request.summaryPhrase)
        XCTAssertEqual(request.question, "要部署到哪个环境？")
        XCTAssertEqual(request.detail, "可选项：staging、production\n还有 1 个问题")
        XCTAssertEqual(request.detailPhrases, [.options(["staging", "production"]), .moreQuestions(1)])
        XCTAssertEqual(request.questions?.count, 2)

        let blank = make("item/tool/requestUserInput", ["questions": [["id": "q1"]]], kind: .input)
        XCTAssertEqual(blank.summary, "Codex 在等你回答")
        XCTAssertEqual(blank.summaryPhrase, .awaitingAnswer(agent: "Codex"))
        XCTAssertNil(blank.detail)
        XCTAssertNil(blank.detailPhrases)
    }
}
