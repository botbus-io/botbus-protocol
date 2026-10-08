import Foundation
import XCTest
@testable import BotBusConnectorKit
import BotBusProtocol

/// 协议 3.11：短语 → 电脑写给旧手机的中文。手机 zh-Hans 的词条 key 就是这些原文，
/// ClientCore 的 `RequestPhraseTextTests` 与 Android 的 `RequestPhraseTextTest` 断言同一批句子。
final class RequestPhraseTextTests: XCTestCase {
    func testEveryKindHasItsChineseSentence() {
        let cases: [(RequestPhrase, String)] = [
            (.text("先清掉旧的构建产物"), "先清掉旧的构建产物"),
            (.runCommand("rm -rf build/"), "执行命令：rm -rf build/"),
            (.requestCommand, "请求执行命令"),
            (.editFiles(["App.swift", "LoginView.swift"]), "修改 2 个文件：App.swift、LoginView.swift"),
            (RequestPhrase(kind: .editFiles, items: ["App.swift", "LoginView.swift"], count: 23),
             "修改 23 个文件：App.swift、LoginView.swift…"),
            (.requestFileChange, "请求修改文件"),
            (.requestPermission(tool: "bash"), "bash 请求授权"),
            (.requestPermission(), "请求权限"),
            (.requestPermission(tool: ""), "请求权限"),
            (.requestExtraPermissions, "请求额外权限"),
            (.toolCall, "工具调用"),
            (.awaitingAnswer(agent: "Codex"), "Codex 在等你回答"),
            (.workingDirectory("/Users/demo/Projects/demo-app"), "工作目录：/Users/demo/Projects/demo-app"),
            (.networkAccess, "网络访问"),
            (.networkPolicy, "网络策略调整"),
            (.readPaths(["/a", "/b"]), "读取：/a、/b"),
            (RequestPhrase(kind: .writePaths, items: ["/a", "/b"], count: 30), "写入：/a、/b…"),
            (.writePaths(["/c"]), "写入：/c"),
            (.options(["staging", "production"]), "可选项：staging、production"),
            (.moreQuestions(2), "还有 2 个问题"),
        ]
        for (phrase, expected) in cases {
            XCTAssertEqual(phrase.chineseText, expected, phrase.kind.rawValue)
        }
    }

    func testDetailLinesJoinWithNewlines() {
        XCTAssertEqual([RequestPhrase.text("理由"), .workingDirectory("/tmp")].chineseText, "理由\n工作目录：/tmp")
    }

    /// 样本里的中文原文与短语对得上：改了句子要同时改样本。
    func testFixtureSummariesMatchTheirPhrases() throws {
        let snapshot = try ProtocolJSON.decoder().decode(Snapshot.self, from: Data(contentsOf: try fixture()))
        var checked = 0
        for task in snapshot.tasks {
            let request = try XCTUnwrap(task.pendingRequest)
            if let phrase = request.summaryPhrase {
                XCTAssertEqual(phrase.chineseText, request.summary, task.id)
                checked += 1
            }
            if let phrases = request.detailPhrases {
                XCTAssertEqual(phrases.chineseText, request.detail, task.id)
                checked += 1
            }
        }
        XCTAssertEqual(checked, 8)
    }

    /// 往上找 `protocol-fixtures`：本仓库与公开仓库的目录层数不同。
    private func fixture() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while true {
            let candidate = url.appendingPathComponent("protocol-fixtures/plain/snapshot-request-phrases.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        throw XCTSkip("找不到 protocol-fixtures")
    }
}
