import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BotBusConnectorKit

/// hook 密钥：同机别的用户能连回环，但读不到 0600 的密钥文件，所以伪造不了 hook。
final class LocalHookServerSecretTests: XCTestCase {
    private let temporaryDirectories = Locked<[URL]>([])

    override func tearDown() {
        for url in temporaryDirectories.current { try? FileManager.default.removeItem(at: url) }
        temporaryDirectories.withLock { $0 = [] }
        super.tearDown()
    }

    private func makeSupportDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("botbus-hooksecret-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.withLock { $0.append(url) }
        return url
    }

    private func startServer(_ enforcement: LocalHookServer.SharedSecret.Enforcement?,
                             directory: URL? = nil,
                             handled: Locked<Int> = Locked(0)) async throws -> (server: LocalHookServer, port: UInt16) {
        let server = LocalHookServer(supportDirectory: directory ?? makeSupportDirectory(),
                                     sharedSecret: enforcement.map { LocalHookServer.SharedSecret(enforcement: $0) }) { _ in
            handled.withLock { $0 += 1 }
            return .now(.json(#"{"ok":true}"#))
        }
        addTeardownBlock { await server.stop() }
        let port = try await server.start()
        return (server, port)
    }

    /// 走 URLSession：请求本身是合法的 HTTP，这里要测的只是头。
    private func post(port: UInt16, secret: String?) async throws -> Int {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hooks/claude")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret { request.setValue(secret, forHTTPHeaderField: LocalHookServer.SharedSecret.headerName) }
        let (_, response) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(response as? HTTPURLResponse).statusCode
    }

    private func secret(of server: LocalHookServer) async throws -> String {
        let value = await server.activeSecret
        return try XCTUnwrap(value)
    }

    // MARK: -

    func testRequiredRejectsMissingAndWrongSecret() async throws {
        let handled = Locked(0)
        let started = try await startServer(.required, handled: handled)
        let secret = try await secret(of: started.server)

        let missing = try await post(port: started.port, secret: nil)
        XCTAssertEqual(missing, 403)
        let wrong = try await post(port: started.port, secret: String(repeating: "0", count: 64))
        XCTAssertEqual(wrong, 403)
        let short = try await post(port: started.port, secret: String(secret.prefix(10)))
        XCTAssertEqual(short, 403)
        XCTAssertEqual(handled.current, 0, "被拒的请求不该交给 handler")

        let right = try await post(port: started.port, secret: secret)
        XCTAssertEqual(right, 200)
        XCTAssertEqual(handled.current, 1)
    }

    /// macOS 的兼容模式：老脚本不带头放行，带错照样拒绝。
    func testWhenPresentAcceptsMissingButRejectsWrong() async throws {
        let started = try await startServer(.whenPresent)
        let secret = try await secret(of: started.server)
        let missing = try await post(port: started.port, secret: nil)
        XCTAssertEqual(missing, 200)
        let wrong = try await post(port: started.port, secret: "nope")
        XCTAssertEqual(wrong, 403)
        let right = try await post(port: started.port, secret: secret)
        XCTAssertEqual(right, 200)
    }

    /// 不开密钥的实例（工具服务器、Codex 桥）照旧：带不带头都收，也不写密钥文件。
    func testNoSecretByDefault() async throws {
        let directory = makeSupportDirectory()
        let started = try await startServer(nil, directory: directory)
        XCTAssertNil(started.server.secretFileURL)
        let plain = try await post(port: started.port, secret: nil)
        XCTAssertEqual(plain, 200)
        let arbitrary = try await post(port: started.port, secret: "whatever")
        XCTAssertEqual(arbitrary, 200)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files, [LocalHookServer.portFileName])
    }

    func testPlatformDefaultRequiresSecretOffApple() {
        #if canImport(Darwin)
        XCTAssertEqual(LocalHookServer.SharedSecret.platformDefault.enforcement, .whenPresent)
        #else
        XCTAssertEqual(LocalHookServer.SharedSecret.platformDefault.enforcement, .required)
        #endif
    }

    /// 密钥文件：0600、curl 配置格式、在端口文件旁边；每次 start 换新的，stop 删掉。
    func testSecretFileIsPrivateRotatesAndIsRemovedOnStop() async throws {
        let directory = makeSupportDirectory()
        let started = try await startServer(.required, directory: directory)
        let url = try XCTUnwrap(started.server.secretFileURL)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(url.lastPathComponent, LocalHookServer.SharedSecret.defaultFileName)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        #if !canImport(Darwin)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700, "Linux 上支持目录收紧到 0700")
        #endif

        let first = try await secret(of: started.server)
        XCTAssertEqual(first.count, 64)
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8),
                       "header = \"\(LocalHookServer.SharedSecret.headerName): \(first)\"\n")

        await started.server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let cleared = await started.server.activeSecret
        XCTAssertNil(cleared)

        let port = try await started.server.start()
        let second = try await secret(of: started.server)
        XCTAssertNotEqual(first, second, "每次 start 换一个密钥")
        let stale = try await post(port: port, secret: first)
        XCTAssertEqual(stale, 403, "上一轮的密钥作废")
        let fresh = try await post(port: port, secret: second)
        XCTAssertEqual(fresh, 200)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [], "原子写的临时文件不能留下")
    }

    /// 上一轮崩掉留下的旧文件（哪怕权限宽）被新的 0600 文件整个替换掉。
    func testOverwritesStaleSecretFile() async throws {
        let directory = makeSupportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = directory.appendingPathComponent(LocalHookServer.SharedSecret.defaultFileName)
        try Data("old".utf8).write(to: stale)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stale.path)

        let started = try await startServer(.required, directory: directory)
        let secret = try await secret(of: started.server)
        XCTAssertTrue(try String(contentsOf: stale, encoding: .utf8).contains(secret))
        let attributes = try FileManager.default.attributesOfItem(atPath: stale.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(LocalHookServer.constantTimeEquals("abc", "abc"))
        XCTAssertTrue(LocalHookServer.constantTimeEquals("", ""))
        XCTAssertFalse(LocalHookServer.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(LocalHookServer.constantTimeEquals("abc", "abcd"))
        XCTAssertFalse(LocalHookServer.constantTimeEquals("", "a"))
    }
}

