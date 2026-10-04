import XCTest
@testable import BotBusConnectors

final class ClaudeDeletionTests: XCTestCase {
    func testUnavailableDataDirectoryIsNotReportedAsSuccessfulDeletion() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("claude-delete-unavailable-\(UUID())")
        let id = UUID().uuidString.lowercased()
        try ClaudeMessageReader.deleteTranscript(sessionID: id, in: path) // Missing data is already deleted.
        try Data("not a directory".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        XCTAssertThrowsError(try ClaudeMessageReader.deleteTranscript(sessionID: id, in: path))
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "not a directory")
    }

    func testDeletesOnlyTranscriptAndPreservesSourceAndOtherSessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-delete-\(UUID())")
        let project = root.appendingPathComponent("encoded-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let transcript = project.appendingPathComponent("\(id).jsonl")
        let other = project.appendingPathComponent("other.jsonl")
        let source = project.appendingPathComponent("main.swift")
        for path in [transcript, other, source] { try Data("sample".utf8).write(to: path) }
        try ClaudeMessageReader.deleteTranscript(sessionID: id, in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcript.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        try ClaudeMessageReader.deleteTranscript(sessionID: id, in: root) // Idempotent.
        XCTAssertThrowsError(try ClaudeMessageReader.deleteTranscript(sessionID: "../main", in: root))
    }

    func testRefusesTranscriptSymlinkOutsideAgentData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-delete-link-\(UUID())")
        let project = root.appendingPathComponent("projects/encoded-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let outside = root.appendingPathComponent("\(id).jsonl")
        try Data("keep".utf8).write(to: outside)
        try makeSymbolicLink(at: project.appendingPathComponent("\(id).jsonl"), withDestinationURL: outside)
        XCTAssertThrowsError(try ClaudeMessageReader.deleteTranscript(sessionID: id, in: root.appendingPathComponent("projects")))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
    }

    /// 项目目录本身是指到外面的软链接：不跟进去，外面的同名文件不删。
    func testIgnoresProjectDirectorySymlinkOutsideAgentData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-delete-dir-link-\(UUID())")
        let projects = root.appendingPathComponent("projects")
        let elsewhere = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let outside = elsewhere.appendingPathComponent("\(id).jsonl")
        try Data("keep".utf8).write(to: outside)
        try makeSymbolicLink(at: projects.appendingPathComponent("encoded-project"), withDestinationURL: elsewhere)
        try? ClaudeMessageReader.deleteTranscript(sessionID: id, in: projects)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
    }
}
