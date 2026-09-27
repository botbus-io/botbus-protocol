import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors

/// 对一个真实 dsh 主目录与它的 `dsh web` 的只读冒烟。默认跳过；运行：
/// `BOTBUS_DSH_SMOKE_HOME=<隔离的 dsh 主目录> swift test --filter DshSmokeTests`
///
/// 不发提示词、不回答审批；只列会话、连 `$events`、取一页历史、解一份会话文件。输出只有数量与事件类型，
/// 不打印对话内容与凭据。**不要**指向自己日常用的 `~/.dsh`：会读到真实对话（虽然不打印）。
final class DshSmokeTests: XCTestCase {
    private func home() throws -> DshPaths {
        guard let path = ProcessInfo.processInfo.environment["BOTBUS_DSH_SMOKE_HOME"], !path.isEmpty else {
            throw XCTSkip("set BOTBUS_DSH_SMOKE_HOME")
        }
        return DshPaths(home: URL(fileURLWithPath: path, isDirectory: true))
    }

    func testWebChannelAgainstRunningDshWeb() async throws {
        let paths = try home()
        let instances = DshWebLocator.locate(paths: paths)
        print("dsh web instances for this home: \(instances.map { "pid \($0.pid) ports \($0.ports)" })")
        // 只认给定主目录的那个实例：定位器按 DSH_HOME / HOME 过滤，日常用的 `~/.dsh` 那个 web 不会在这里。
        XCTAssertTrue(instances.allSatisfy { instance in
            SystemDshProcessListing().processes().first { $0.pid == instance.pid }
                .map { DshWebLocator.usesHome(environment: $0.environment, paths: paths) } ?? false
        })
        let endpoint = try XCTUnwrap(instances.first?.endpoints.first, "这个主目录没有在跑的 dsh web")
        let secret = try XCTUnwrap(DshWebCredentials.loadBrowserSessionSecret(paths: paths), "读不到签名密钥")
        let client = DshWebClient(endpoint: endpoint, secret: secret)

        let sessions = try await client.listSessions()
        print("session/list: \(sessions.count) items, running \(sessions.filter(\.running).count), blank \(sessions.filter(\.blank).count), subagent \(sessions.filter(\.isSubagent).count)")

        let mux = DshWebMux(client: client)
        try await mux.connect()
        let events = try await mux.openEvents()
        var iterator = events.items.makeAsyncIterator()
        let first = try await iterator.next()
        guard case .ready(let clientId, _)? = first.map(DshEventsFrame.init(json:)) else {
            return XCTFail("$events 首条不是 ready")
        }
        XCTAssertFalse(clientId.isEmpty)
        await mux.cancel(events.id)

        if let session = sessions.first(where: { !$0.blank && $0.asOfSeq != nil }), let seq = session.asOfSeq {
            let (page, hasMore) = try await client.page(sessionId: session.sessionId, throughSeq: seq, maxMessages: 20)
            let latest = try await client.latestPage(sessionId: session.sessionId, maxMessages: 20)
            print("latestPage: \(latest.events.count) events")
            let types = Dictionary(grouping: page, by: \.type).mapValues(\.count)
            print("session/page: \(page.count) events, hasMore \(hasMore), types \(types.sorted { $0.key < $1.key })")
            let transcript = DshTranscriptParser.entries(from: page)
            print("page → \(transcript.count) transcript entries, roles \(transcript.map(\.message.role.rawValue))")
            XCTAssertFalse(page.isEmpty)
        }
        await mux.close()
    }

    /// 扫盘 + 借 node 解会话文件，再与 web 的 `session/page` 解出来的对话记录逐条比对（web 在的话）。
    func testFilesDecodeLikeTheWebPage() async throws {
        let paths = try home()
        guard let node = DshPaths.selectNode(from: DshPaths.defaultNodeCandidates(), version: DshPaths.probeNodeVersion) else {
            throw XCTSkip("本机没有 22.15 以上的 node")
        }
        let decoder = DshTranscriptDecoder(node: node)
        let scanner = DshSessionScanner(paths: paths, headers: { (try? await decoder.headers($0)) ?? [:] })
        let sessions = await scanner.scan()
        print("scanner: \(sessions.count) sessions, open turn \(sessions.filter(\.hasOpenTurn).count)")
        XCTAssertFalse(sessions.isEmpty)
        let web: DshWebClient? = DshWebLocator.locate(paths: paths).first?.endpoints.first.flatMap { endpoint in
            DshWebCredentials.loadBrowserSessionSecret(paths: paths).map { DshWebClient(endpoint: endpoint, secret: $0) }
        }
        let listed = (try? await web?.listSessions()) ?? []
        for session in sessions {
            let log = try await decoder.read(session.logFile, tailBytes: 0)
            XCTAssertEqual(log.header?.id, session.sessionId)
            let fromFile = DshTranscriptParser.entries(from: log.events)
            let end = DshTranscriptParser.lastTurnEnd(in: log.events)
            let kinds = Set(log.events.filter { $0.type == "user/message" }.compactMap(\.sourceKind)).sorted()
            var line = "  file: \(log.events.count) events → \(fromFile.count) entries, last turn \(end.map { "\($0.reason.status)" } ?? "open"), user kinds \(kinds)"
            if let web, let summary = listed.first(where: { $0.sessionId == session.sessionId }) {
                let page = try await web.latestPage(sessionId: session.sessionId, maxMessages: 500)
                let fromWeb = DshTranscriptParser.entries(from: page.events)
                line += ", web page \(fromWeb.count) entries, same \(fromWeb == fromFile), asOfSeq \(summary.asOfSeq ?? -2) vs last \(log.events.last?.seq ?? -1)"
                XCTAssertEqual(fromWeb, fromFile)
            }
            print(line)
        }
    }
}
