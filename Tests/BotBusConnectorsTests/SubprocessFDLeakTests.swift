import Foundation
import XCTest
@testable import BotBusConnectorKit
@testable import BotBusConnectors
import BotBusProtocol

#if os(Linux)
/// Linux 上连接器起子进程不能漏文件描述符。
///
/// swift-corelibs-foundation 读到 EOF 不会替你关管道的读端，`Process` / `Pipe` 又常常活得比这次调用久，
/// 每起一个子进程就漏一两个描述符。不只是资源问题：Swift 6.4 的 `Process.run()` 读 `/proc/self/fd` 时整份拷贝
/// `dirent`，描述符多到上千会读越界、SIGSEGV（上游 main 已修，6.4.x 还没带上）。长期跑的 daemon 只要有泄漏，迟早撞上。
///
/// 每个用例用假的可执行文件（`/bin/sh` 脚本）把真实的启动器跑几十上百次，比较前后 `/proc/self/fd` 的项数。
final class SubprocessFDLeakTests: XCTestCase {
    private var directory: URL!
    private static let slack = 30

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fd-leak-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func openDescriptors() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd").count) ?? -1
    }

    private func script(_ name: String, _ body: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// `Process.run()` 要取调用线程的 `RunLoop.current`：Linux 上一条线程第一次起子进程就建一个 CFRunLoop，
    /// 占 3 个描述符（epoll、eventfd、timerfd），跟线程活得一样久。协作线程池最多 CPU 数条线程，所以这是一次性的，
    /// 不算泄漏；可用例里的任务换到一条还没起过子进程的池线程上，就会冒出 3 个来，并发跑时一下子十几条线程，
    /// 看着像漏了几十个。计数前先并发起子进程，把池里的线程都用一遍，直到描述符数不再涨。
    ///
    /// 每个任务同步等子进程退出、不让出线程，后面的任务只好落到别的池线程上。
    private func warmUpThreadRunLoops() async throws {
        var previous = openDescriptors()
        for _ in 0..<10 {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<(4 * ProcessInfo.processInfo.activeProcessorCount) {
                    group.addTask {
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/bin/sh")
                        process.arguments = ["-c", "exit 0"]
                        try process.run()
                        process.waitUntilExit()
                    }
                }
                try await group.waitForAll()
            }
            let current = openDescriptors()
            if current <= previous { return }
            previous = current
        }
    }

    /// 先预热（池线程的 run loop、线程池、懒加载的全局状态也会占 fd），再跑 `runs` 次，等读线程退出后比较。
    private func assertNoLeak(_ what: String, runs: Int, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async throws {
        try await warmUpThreadRunLoops()
        try await body()
        try await Task.sleep(for: .milliseconds(300))
        let before = openDescriptors()
        for _ in 0..<runs { try await body() }
        // 读线程最多一个 poll 间隔（200 ms）后退出并关 fd。
        try await Task.sleep(for: .milliseconds(500))
        let after = openDescriptors()
        // 泄漏时每次 1–3 个（50 次起步就是 +50 以上）；整套测试一起跑时别的用例的后台任务还在开关描述符，留 30 的余量。
        XCTAssertLessThan(after - before, Self.slack, "\(runs) 次 \(what) 之后多出了 \(after - before) 个描述符",
                          file: file, line: line)
    }

    // MARK: - Codex app-server / ACP agent（同一个 `CodexSubprocess`）

    /// 进程自己退出（崩了、ACP agent 自己走了）：stdout / stderr 读到 EOF，stdin 在退出时关掉。
    func testCodexSubprocessThatExitsDoesNotLeak() async throws {
        let launcher = CodexSubprocessLauncher(executablePath: "/bin/sh",
                                               arguments: ["-c", "echo '{\"id\":1}'; echo oops >&2; exit 3"])
        try await assertNoLeak("codex 子进程自己退出", runs: 100) {
            let handle = try launcher.launch()
            while try await handle.readStdout() != nil {}
            let exit = await handle.waitForExit()
            XCTAssertEqual(exit.status, 3)
        }
    }

    /// 我们关掉它（空闲、停用、重启）：写过 stdin，再 terminate。
    func testCodexSubprocessThatIsTerminatedDoesNotLeak() async throws {
        let launcher = CodexSubprocessLauncher(executablePath: "/bin/sh", arguments: ["-c", "exec cat"])
        try await assertNoLeak("codex 子进程被 terminate", runs: 100) {
            let handle = try launcher.launch()
            try await handle.writeStdin(Data("ping\n".utf8))
            let echoed = try await handle.readStdout()
            XCTAssertEqual(echoed.map { String(decoding: $0, as: UTF8.self) }, "ping\n")
            handle.terminate()
            while try await handle.readStdout() != nil {}
            _ = await handle.waitForExit()
        }
    }

    /// 进程没了之后再写 stdin：报错，不崩（写端已经关了）。
    func testCodexSubprocessWriteAfterExitThrows() async throws {
        let launcher = CodexSubprocessLauncher(executablePath: "/bin/sh", arguments: ["-c", "exit 0"])
        let handle = try launcher.launch()
        while try await handle.readStdout() != nil {}
        _ = await handle.waitForExit()
        do {
            try await handle.writeStdin(Data("late\n".utf8))
            XCTFail("进程退出后写 stdin 应该报错")
        } catch {}
    }

    // MARK: - Hermes

    private func runHermes(_ executable: String) async throws {
        let exited = OneShotContinuation<Int32>()
        let request = HermesLaunchRequest(executable: executable, arguments: [], workingDirectory: directory.path,
                                          environment: ProcessInfo.processInfo.environment)
        _ = try HermesSubprocessLauncher().launch(request, output: { _ in }, exit: { exited.resume(returning: $0) })
        _ = try await exited.value()
    }

    func testHermesLauncherDoesNotLeak() async throws {
        let hermes = try script("hermes", """
            echo '{"type":"system","subtype":"init","session_id":"s"}'
            echo '{"type":"result","exit_code":0}'
            """)
        try await assertNoLeak("hermes", runs: 100) { try await runHermes(hermes) }
    }

    /// 孙进程攥着 stdout、EOF 不来：排空超时之后读端也得关掉。并发跑，免得每次都等 2 秒。
    ///
    /// 孙进程只能攥 stdout，别的继承来的描述符得关掉：Linux 上 Foundation 靠子进程继承的一个 socket 得知它退出，
    /// 孙进程也攥着这个 socket 的话，`terminationHandler` 要等孙进程退出才来，那时 EOF 也到了，排空超时根本走不到。
    /// Hermes 是 Python，`subprocess` 默认 `close_fds`，它起的后台进程本来就只继承 stdio。dash 不认两位数的 fd，用 bash 关。
    func testHermesLauncherClosesStdoutWhenEOFNeverComes() async throws {
        let hermes = try script("hermes-bg", """
            echo '{"type":"result","exit_code":0}'
            bash -c 'for fd in /proc/$$/fd/*; do n=${fd##*/}; [ "$n" -gt 2 ] && eval "exec $n>&-"; done; exec sleep 4' &
            exit 0
            """)
        try await warmUpThreadRunLoops()
        try await runHermes(try script("hermes-warm", "exit 0"))
        try await Task.sleep(for: .milliseconds(300))
        let before = openDescriptors()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<80 { group.addTask { try await self.runHermes(hermes) } }
            try await group.waitForAll()
        }
        try await Task.sleep(for: .milliseconds(500))
        let after = openDescriptors()
        XCTAssertLessThan(after - before, Self.slack, "80 次 EOF 不来的 hermes 之后多出了 \(after - before) 个描述符")
    }

    // MARK: - Pi

    func testPiLauncherDoesNotLeak() async throws {
        let pi = try script("pi", #"echo '{"type":"session","id":"p"}'"#)
        let request = PiLaunchRequest(executable: pi, arguments: [], workingDirectory: directory.path,
                                      environment: ProcessInfo.processInfo.environment)
        try await assertNoLeak("pi", runs: 100) {
            let exited = OneShotContinuation<Int32>()
            let handle = try PiSubprocessLauncher().launch(request, onOutput: { _ in },
                                                           onExit: { exited.resume(returning: $0) })
            _ = try await exited.value()
            _ = handle
        }
    }

    // MARK: - DeepSeek Harness（node 解会话记录、问 node 版本）

    func testDshTranscriptRunnerDoesNotLeak() async throws {
        try await assertNoLeak("dsh 的 node 解码", runs: 100) {
            let data = try await DshTranscriptDecoder.runProcess("/bin/sh", ["-c", "echo decoded"], 10)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "decoded\n")
        }
    }

    func testDshNodeVersionProbeDoesNotLeak() async throws {
        let node = try script("node", "echo v24.1.0")
        try await assertNoLeak("node --version", runs: 100) {
            XCTAssertNotNil(DshPaths.probeNodeVersion(node))
        }
    }

    // MARK: - Claude Code

    func testClaudeHelpProbeDoesNotLeak() async throws {
        let claude = try script("claude-help", "printf '%s\\n' '  --effort <level>  Effort level (low, medium, high, max)'")
        try await assertNoLeak("claude --help", runs: 100) {
            XCTAssertEqual(ClaudeModels.efforts(forBinary: claude), ["low", "medium", "high", "max"])
        }
    }

    /// 手机发起的一轮 `claude -p`：stdout 读到 EOF 关读端、`result` 之后关 stdin（假 claude 要读到 stdin 的 EOF 才退出）。
    func testClaudeTurnDoesNotLeak() async throws {
        let claude = try script("claude", """
            if [ "$1" = "--help" ]; then exit 0; fi
            head -n 1 > /dev/null
            echo '{"type":"system","subtype":"init","session_id":"sess-'"$$"'"}'
            echo '{"type":"result","subtype":"success","result":"done"}'
            cat > /dev/null
            """)
        let store = TaskStore(identity: AgentIdentity(agentId: "agent-1"),
                              connectors: ConnectorRegistry(descriptors: [
                                  ConnectorDescriptor(kind: .claude, displayName: "Claude Code", defaultEnabled: true) {
                                      ConnectorProbe(available: true, status: .ok)
                                  },
                              ]))
        let connector = ClaudeConnector(store: store,
                                        paths: ClaudePaths(claudeHome: URL(fileURLWithPath: "/nonexistent")),
                                        binary: { claude })
        let project = directory.path
        try await assertNoLeak("claude -p", runs: 50) {
            let outcome = try await connector.start(projectPath: project, prompt: "hi")
            await assertEventually(timeout: 5) {
                await store.task(id: "claude:\(outcome.taskId)")?.status == .completed
            }
        }
        await connector.stop()
    }
}
#endif
