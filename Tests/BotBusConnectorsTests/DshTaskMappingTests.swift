import Foundation
import XCTest
import BotBusProtocol
@testable import BotBusConnectorKit
@testable import BotBusConnectors

/// `DshTaskMapping` 的纯规则：对账合并、状态推算、waterfall → PendingRequest、手机的回答 → dsh 的回答。
final class DshTaskMappingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func facts(_ id: String, ago: TimeInterval, title: String? = nil, webRunning: Bool = false,
                       openTurnRecent: Bool = false) -> DshSessionFacts {
        DshSessionFacts(sessionId: id, cwd: "/Users/me/app", title: title, createdAt: now.addingTimeInterval(-ago - 60),
                        updatedAt: now.addingTimeInterval(-ago), webRunning: webRunning, openTurnRecent: openTurnRecent)
    }

    private func acpRecord(_ id: String, title: String, status: TaskStatus, at date: Date, last: String? = nil) -> TaskRecord {
        var record = AcpSessionState.newRecord(identity: .builtin(.dsh), sessionId: id, cwd: "/Users/me/app", title: title,
                                               origin: .watch, controllable: true, at: ProtocolJSON.timestamp(date))
        record.status = status
        record.lastMessage = last
        return record
    }

    func testStatusRules() {
        let recent = DshTaskMapping.record(facts: facts("a", ago: 600), live: nil, pending: nil, acp: nil, controllable: true, now: now)
        XCTAssertEqual(recent.status, .completed)
        XCTAssertEqual(recent.id, "dsh:a")
        XCTAssertEqual(recent.source, .dsh)
        XCTAssertNil(recent.connectorId)
        XCTAssertEqual(recent.title, "app", "没有标题时用项目名")
        let stale = DshTaskMapping.record(facts: facts("a", ago: 2 * 86_400), live: nil, pending: nil, acp: nil,
                                          controllable: true, now: now)
        XCTAssertEqual(stale.status, .idle)
        let running = DshTaskMapping.record(facts: facts("a", ago: 5, webRunning: true), live: nil, pending: nil, acp: nil,
                                            controllable: true, now: now)
        XCTAssertEqual(running.status, .running)
        let open = DshTaskMapping.record(facts: facts("a", ago: 5, openTurnRecent: true), live: nil, pending: nil, acp: nil,
                                         controllable: false, now: now)
        XCTAssertEqual(open.status, .running)
        XCTAssertFalse(open.controllable)

        var live = DshLiveState()
        live.apply(DshSessionEvent(type: "turn/start", seq: 1, time: now.addingTimeInterval(-50), data: ["turn": 1]))
        live.apply(DshSessionEvent(type: "turn/end", seq: 2, time: now.addingTimeInterval(-40),
                                   data: ["turn": 1, "reason": ["kind": "error", "error": ["message": "Model not exist."]]]))
        let failed = DshTaskMapping.record(facts: facts("a", ago: 600, title: "列表标题"), live: live, pending: nil, acp: nil,
                                           controllable: true, now: now)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.lastMessage, "Model not exist.", "这一轮没说话就用错误文本")
        XCTAssertEqual(failed.updatedAt, ProtocolJSON.timestamp(now.addingTimeInterval(-40)), "取更新的那个时间")
        // 跟到的收尾之后日志又动了、还开着一轮：别的进程在跑。
        let resumed = DshTaskMapping.record(facts: facts("a", ago: 5, openTurnRecent: true), live: live, pending: nil, acp: nil,
                                            controllable: true, now: now)
        XCTAssertEqual(resumed.status, .running)
    }

    func testMergedWindowAndAcpPrecedence() {
        let base = [facts("desk", ago: 3600, title: "桌面会话"), facts("mine", ago: 3600, title: "dsh 的标题"),
                    facts("old", ago: 8 * 86_400)]
        let mine = acpRecord("mine", title: "手机上开的", status: .failed, at: now.addingTimeInterval(-3000), last: "出错了")
        let onlyAcp = acpRecord("fresh", title: "刚建的", status: .completed, at: now.addingTimeInterval(-10))
        let merged = DshTaskMapping.merged(base: base, acp: [mine, onlyAcp], live: [:], controllable: false, now: now)
        XCTAssertEqual(Set(merged.map(\.id)), ["dsh:desk", "dsh:mine", "dsh:fresh"], "7 天窗口外的不要，只在 ACP 里的也列")
        let merge = merged.first { $0.id == "dsh:mine" }
        XCTAssertEqual(merge?.origin, .watch)
        XCTAssertEqual(merge?.title, "手机上开的")
        XCTAssertEqual(merge?.status, .failed, "BotBus 的记录更新，状态以它为准")
        XCTAssertEqual(merge?.lastMessage, "出错了")
        XCTAssertTrue(merged.allSatisfy { !$0.controllable })
        let desk = merged.first { $0.id == "dsh:desk" }
        XCTAssertEqual(desk?.origin, .desktop)

        // ACP 的记录比列表旧（之后又在电脑上聊过）：状态按列表算，来源与标题仍按 ACP；占位标题不盖。
        let older = acpRecord("mine", title: "app", status: .interrupted, at: now.addingTimeInterval(-9000))
        let again = DshTaskMapping.merged(base: base, acp: [older], live: [:], controllable: true, now: now)
            .first { $0.id == "dsh:mine" }
        XCTAssertEqual(again?.status, .completed)
        XCTAssertEqual(again?.title, "dsh 的标题")
        XCTAssertEqual(again?.origin, .watch)
    }

    func testWebSummaryFilters() {
        let base = DshWebSessionSummary(sessionId: "s", updatedAt: now, running: false, blank: false, cwd: "/x")
        XCTAssertNotNil(DshSessionFacts(web: base))
        var blank = base
        blank.blank = true
        XCTAssertNil(DshSessionFacts(web: blank))
        var child = base
        child.origin = "subagent"
        XCTAssertNil(DshSessionFacts(web: child))
        var noCwd = base
        noCwd.cwd = nil
        XCTAssertNil(DshSessionFacts(web: noCwd))
    }

    func testApprovalMapping() {
        var live = DshLiveState()
        live.apply(DshSessionEvent(type: "tool/call", seq: 1, time: now, data: [
            "callId": "c1", "name": "bash", "arguments": #"{"command": "rm -rf build\nls", "description": "清理"}"#]))
        live.apply(DshSessionEvent(type: "approval/asked", seq: 2, time: now, data: ["id": "ap", "callId": "c1"]))
        let bash = DshWaterfall(eventId: "e1", sessionId: "s", request: .approval(toolName: "bash", callId: "c1", reason: "需要网络"))
        let command = DshTaskMapping.pendingRequest(bash, live: live)
        XCTAssertEqual(command?.status, .waitingApproval)
        XCTAssertEqual(command?.request, PendingRequest(id: "e1", kind: .command, summary: "执行命令：rm -rf build ls",
                                                        detail: "需要网络"))
        // 没见过这次调用：退成 permission，摘要是理由。
        let unknown = DshTaskMapping.pendingRequest(
            DshWaterfall(eventId: "e2", sessionId: "s", request: .approval(toolName: "bash", callId: "zz", reason: nil)), live: live)
        XCTAssertEqual(unknown?.request.kind, .permission)
        XCTAssertEqual(unknown?.request.summary, "bash 请求授权")
        // 很长的参数截到 2000。
        var big = DshLiveState()
        big.apply(DshSessionEvent(type: "tool/call", seq: 1, time: now, data: [
            "callId": "c2", "name": "write_file", "arguments": .string(String(repeating: "x", count: 5000))]))
        let file = DshTaskMapping.pendingRequest(
            DshWaterfall(eventId: "e3", sessionId: "s", request: .approval(toolName: "write_file", callId: "c2", reason: "写文件")),
            live: big)
        XCTAssertEqual(file?.request.kind, .permission)
        XCTAssertEqual(file?.request.detail?.count, 2000)
        // approval/decided 报出落定的是哪次调用。
        XCTAssertEqual(live.apply(DshSessionEvent(type: "approval/decided", seq: 3, time: now, data: ["id": "ap"])), "c1")
        XCTAssertNil(DshTaskMapping.pendingRequest(DshWaterfall(eventId: "e", sessionId: "s", request: .other(event: "x")),
                                                   live: nil))
    }

    func testQuestionAnswers() {
        let single = DshQuestion(id: "color", question: "颜色？", options: ["红", "蓝"])
        let multi = DshQuestion(id: "extras", question: "加料？", options: ["糖", "奶"], multiSelect: true)
        let skipped = DshQuestion(id: "size", question: "大小？", options: ["大"])
        XCTAssertEqual(DshTaskMapping.answers(for: [single, multi, skipped],
                                              from: ["color": ["蓝", "红"], "extras": ["奶", " 少冰 "]]), [
            DshQuestionAnswer(id: "color", selected: ["蓝"]),
            DshQuestionAnswer(id: "extras", selected: ["奶"], custom: "少冰"),
            DshQuestionAnswer(id: "size", selected: []),
        ])
        XCTAssertEqual(DshTaskMapping.answers(for: [single], from: ["color": ["紫"]]),
                       [DshQuestionAnswer(id: "color", selected: [], custom: "紫")], "单选题自己写的盖过选项")
        XCTAssertEqual(DshTaskMapping.skipped([single, multi]).map(\.isEmpty), [true, true])
        XCTAssertEqual(DshTaskMapping.answers(for: [single], text: "都行"),
                       [DshQuestionAnswer(id: "color", selected: [], custom: "都行")])
        XCTAssertEqual(DshQuestionAnswer(id: "a", selected: ["x"], custom: "y").json,
                       ["id": "a", "selected": ["x"], "custom": "y"])
    }

    func testQuestionPendingRequestLimits() {
        let many = (0..<12).map { DshQuestion(id: "q\($0)", question: "第 \($0) 题", detail: $0 == 0 ? "补充说明" : nil,
                                               options: (0..<20).map { "选项\($0)" }) }
        let mapped = DshTaskMapping.pendingRequest(DshWaterfall(eventId: "e", sessionId: "s", request: .questions(many)), live: nil)
        XCTAssertEqual(mapped?.status, .waitingInput)
        XCTAssertEqual(mapped?.request.questions?.count, PendingQuestion.maxQuestions)
        XCTAssertEqual(mapped?.request.questions?.first?.options.count, PendingQuestion.maxOptions)
        XCTAssertEqual(mapped?.request.questions?.first?.question, "第 0 题\n补充说明")
        XCTAssertEqual(mapped?.request.summary, "第 0 题 补充说明")
        XCTAssertNil(DshTaskMapping.pendingRequest(DshWaterfall(eventId: "e", sessionId: "s", request: .questions([])), live: nil))
    }
}
