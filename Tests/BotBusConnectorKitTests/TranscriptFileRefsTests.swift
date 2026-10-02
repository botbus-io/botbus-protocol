import XCTest
@testable import BotBusConnectorKit
import BotBusProtocol

/// 手机读 Mac 文件的唯一入口：识别要宽一点（认得出 Agent 的各种写法），校验必须严（项目外、软链接逃逸、隐藏路径一律不给）。
final class TranscriptFileRefsTests: XCTestCase {
    /// 临时目录的真实路径。macOS 上 `/var` 是 `/private/var` 的软链接，比较前两边都要 resolve。
    private var sandbox: URL!
    private var project: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("TranscriptFileRefsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        sandbox = URL(fileURLWithPath: try XCTUnwrap(TranscriptFileRefs.realPath(base.path)))
        addTeardownBlock { [sandbox] in try? FileManager.default.removeItem(at: sandbox!) }
        project = sandbox.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    @discardableResult
    private func file(_ relative: String, in root: URL? = nil, bytes: Int = 5) throws -> URL {
        let url = (root ?? project).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    private func resolve(_ candidates: [String], projectPath: String? = nil) -> [MessageFileRef] {
        TranscriptFileRefs.resolve(candidates, projectPath: projectPath ?? project.path)
    }

    // MARK: - candidates(in:)

    func testCandidatesFromCodeLinksAndBarePathsInOrder() {
        let text = "已保存到 `out/a.png`，另见 [视频](./out/b.mp4) 和 /abs/c.pdf、~/d.jpg"
        XCTAssertEqual(TranscriptFileRefs.candidates(in: text), ["out/a.png", "./out/b.mp4", "/abs/c.pdf", "~/d.jpg"])
    }

    func testCandidatesAreDeduplicated() {
        XCTAssertEqual(TranscriptFileRefs.candidates(in: "`a.png` 然后 a.png，再说一次 [图](a.png)"), ["a.png"])
    }

    /// 一条回复里列几百个文件名（例如贴了一段 `ls`）也只给前 32 个：后面还要逐个 realpath，别让一条消息拖慢整页。
    func testCandidatesAreCappedAtThirtyTwoAfterDeduplication() {
        let text = (0..<40).map { "`a\($0).png` 与 a0.png" }.joined(separator: "，")
        let found = TranscriptFileRefs.candidates(in: text)
        XCTAssertEqual(found.count, TranscriptFileRefs.maxCandidates)
        XCTAssertEqual(TranscriptFileRefs.maxCandidates, 32)
        XCTAssertEqual(found, (0..<32).map { "a\($0).png" }, "按出现顺序去重后再截断")
    }

    func testCandidatesIgnoreURLs() {
        XCTAssertEqual(TranscriptFileRefs.candidates(in: "看 https://x/y.png 和 [链接](https://x/z.png)"), [])
        XCTAssertEqual(TranscriptFileRefs.candidates(in: "file:///abs/c.png 与 `file:///abs/d.png`"), [])
        XCTAssertEqual(TranscriptFileRefs.candidates(in: "见https://x/y.png"), [], "紧贴中文的 URL 也不算")
    }

    func testCandidatesNeedAMediaExtension() {
        XCTAssertEqual(TranscriptFileRefs.candidates(in: "改了 `src/main.swift` 和 src/app.ts，见 notes.txt"), [])
        XCTAssertEqual(TranscriptFileRefs.candidates(in: "`.png` 不是文件名"), [])
    }

    func testCandidateExtensionIsCaseInsensitive() {
        XCTAssertEqual(TranscriptFileRefs.candidates(in: "截图在 out/A.PNG 和 `B.Mov`"), ["out/A.PNG", "B.Mov"])
    }

    func testSurroundingPunctuationIsNotPartOfThePath() {
        XCTAssertEqual(TranscriptFileRefs.candidates(in: "（见 out/a.png）。另见 b.jpg，c.pdf、d.gif."),
                       ["out/a.png", "b.jpg", "c.pdf", "d.gif"])
        XCTAssertEqual(TranscriptFileRefs.candidates(in: "(see out/a.png), or b.png!"), ["out/a.png", "b.png"])
        XCTAssertEqual(TranscriptFileRefs.candidates(in: "保存在out/a.png了"), ["out/a.png"], "紧贴中文也认得出")
        XCTAssertEqual(TranscriptFileRefs.candidates(in: "**out/bold.png**"), ["out/bold.png"])
    }

    func testPathsWithSpacesInCodeOrAngleBrackets() {
        XCTAssertEqual(TranscriptFileRefs.candidates(in: "见 `my shots/a b.png`"), ["my shots/a b.png", "b.png"],
                       "带空格的整段另按裸路径扫一遍，多出的 b.png 不存在时在 resolve 里丢掉")
        XCTAssertEqual(TranscriptFileRefs.candidates(in: "见 [图](<my shots/c d.png>) 与 ![x](<./e f.jpg> \"标题\")"),
                       ["my shots/c d.png", "./e f.jpg"])
        XCTAssertEqual(TranscriptFileRefs.candidates(in: "见 `截图/结果 图.png`"), ["截图/结果 图.png"],
                       "中文文件名写在反引号里能认")
    }

    func testCodeSpanThatIsNotAPathIsScannedForBarePaths() {
        XCTAssertEqual(TranscriptFileRefs.candidates(in: "运行 `open out/a.png` 看看"), ["open out/a.png", "out/a.png"],
                       "整段有媒体扩展名就整段当候选，带空格时里面的路径也认")
        XCTAssertEqual(TranscriptFileRefs.candidates(in: "运行 `cp out/a.png x` 看看"), ["out/a.png"])
    }

    // MARK: - resolve

    func testRelativePathResolvesToRealFileInsideProject() throws {
        try file("out/a.png", bytes: 12)
        let refs = resolve(["out/a.png"])
        XCTAssertEqual(refs, [MessageFileRef(path: project.appendingPathComponent("out/a.png").path, name: "a.png",
                                             contentType: "image/png", size: 12)])
        XCTAssertNil(refs.first?.artifactId)
    }

    func testContentTypesComeFromTheExtension() throws {
        try file("v.mp4"); try file("d.pdf"); try file("m.mov"); try file("p.JPG")
        XCTAssertEqual(resolve(["v.mp4", "d.pdf", "m.mov", "p.JPG"]).map(\.contentType),
                       ["video/mp4", "application/pdf", "video/quicktime", "image/jpeg"])
    }

    func testAbsoluteAndDotSlashPathsInsideProjectAreAccepted() throws {
        let url = try file("out/a.png")
        XCTAssertEqual(resolve([url.path]).map(\.path), [url.path])
        XCTAssertEqual(resolve(["./out/a.png"]).map(\.path), [url.path])
        XCTAssertEqual(resolve(["out/../out/a.png"]).map(\.path), [url.path], "../ 仍落在项目里就行")
    }

    func testTemporaryDirectorySymlinkOnBothSidesStillMatches() throws {
        // 用 `/var/...`（软链接的那一侧）写项目路径与文件路径，realpath 后都在 `/private/var` 下。
        let url = try file("out/a.png")
        guard sandbox.path.hasPrefix("/private/var/") else { throw XCTSkip("临时目录不在 /private/var 下") }
        let viaLink = String(project.path.dropFirst("/private".count))
        XCTAssertEqual(resolve([viaLink + "/out/a.png"], projectPath: viaLink).map(\.path), [url.path])
    }

    func testAbsolutePathOutsideProjectIsDropped() throws {
        let outside = try file("secret.png", in: sandbox)
        XCTAssertEqual(resolve([outside.path, "/etc/hosts"]), [])
    }

    func testHomePathOutsideProjectIsDropped() {
        XCTAssertEqual(resolve(["~/d.jpg", "~root/x.png", "~"]), [])
    }

    func testSymlinkInsideProjectPointingOutsideIsDropped() throws {
        let outside = try file("secret.png", in: sandbox)
        try makeSymbolicLink(at: project.appendingPathComponent("link.png"),
                                                   withDestinationURL: outside)
        try makeSymbolicLink(at: project.appendingPathComponent("linked-dir"),
                                                   withDestinationURL: sandbox)
        XCTAssertEqual(resolve(["link.png", "linked-dir/secret.png"]), [])
    }

    func testSymlinkInsideProjectPointingInsideResolvesToTheRealFile() throws {
        let real = try file("out/real.png")
        try makeSymbolicLink(at: project.appendingPathComponent("alias.png"), withDestinationURL: real)
        XCTAssertEqual(resolve(["alias.png"]).map(\.path), [real.path])
        XCTAssertEqual(resolve(["alias.png"]).first?.name, "real.png")
    }

    func testSymlinkWithMediaNameToNonMediaFileIsDropped() throws {
        let notes = try file("notes.txt")
        try makeSymbolicLink(at: project.appendingPathComponent("notes.png"), withDestinationURL: notes)
        XCTAssertEqual(resolve(["notes.png"]), [], "扩展名按真实文件判断")
    }

    func testParentTraversalOutOfProjectIsDropped() throws {
        try file("secret.png", in: sandbox)
        try file("proj2/x.png", in: sandbox)
        XCTAssertEqual(resolve(["../secret.png", "../proj2/x.png", "out/../../secret.png"]), [])
    }

    func testPrefixComparisonIsByPathComponent() throws {
        let sibling = try file("proj2/x.png", in: sandbox)
        XCTAssertTrue(sibling.path.hasPrefix(project.path), "前提：字符串前缀相同")
        XCTAssertEqual(resolve([sibling.path]), [])
    }

    func testHiddenComponentsInsideProjectAreDropped() throws {
        try file(".hidden/x.png"); try file(".env.png"); try file(".git/x.png"); try file("a/.cache/b/x.png")
        XCTAssertEqual(resolve([".hidden/x.png", ".env.png", ".git/x.png", "a/.cache/b/x.png"]), [])
        let real = try file("out/x.png")
        try makeSymbolicLink(at: project.appendingPathComponent("out/.alias.png"), withDestinationURL: real)
        XCTAssertEqual(resolve(["out/.alias.png"]).map(\.path), [real.path],
                       "判断的是 realpath 之后的路径：隐藏的软链接指向普通文件时，给出的是那个普通文件")
        let hiddenTarget = try file(".secret/y.png")
        try makeSymbolicLink(at: project.appendingPathComponent("y.png"), withDestinationURL: hiddenTarget)
        XCTAssertEqual(resolve(["y.png"]), [], "普通名字的软链接指向隐藏目录也不行")
    }

    func testProjectInsideAHiddenParentDirectoryStillWorks() throws {
        let hiddenProject = sandbox.appendingPathComponent(".work/proj")
        try FileManager.default.createDirectory(at: hiddenProject, withIntermediateDirectories: true)
        let url = try file("out/a.png", in: hiddenProject)
        XCTAssertEqual(resolve(["out/a.png"], projectPath: hiddenProject.path).map(\.path), [url.path])
    }

    func testMissingDirectoriesAndSpecialFilesAreDropped() throws {
        try FileManager.default.createDirectory(at: project.appendingPathComponent("dir.png"), withIntermediateDirectories: true)
        #if os(Windows)
        // Windows 的文件系统里没有 FIFO。
        XCTAssertEqual(resolve(["missing.png", "dir.png"]), [])
        #else
        let fifo = project.appendingPathComponent("pipe.png")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertEqual(resolve(["missing.png", "dir.png", "pipe.png"]), [])
        #endif
    }

    func testAtMostFourAndDuplicatesByRealPathCountOnce() throws {
        for name in ["a", "b", "c", "d", "e"] { try file("\(name).png") }
        XCTAssertEqual(resolve(["a.png", "./a.png", project.path + "/a.png", "b.png", "c.png", "d.png", "e.png"])
                           .map(\.name), ["a.png", "b.png", "c.png", "d.png"])
    }

    func testEmptyOrMissingProjectPathDropsEverything() throws {
        let url = try file("a.png")
        XCTAssertEqual(resolve([url.path], projectPath: ""), [])
        XCTAssertEqual(resolve([url.path], projectPath: sandbox.appendingPathComponent("nope").path), [])
        XCTAssertEqual(resolve([url.path], projectPath: "relative/proj"), [])
        XCTAssertEqual(resolve([url.path], projectPath: "/"), [], "整台电脑不算项目")
        XCTAssertEqual(resolve([url.path], projectPath: url.path), [], "项目路径是文件也不行")
    }

    // MARK: - 项目根

    /// home 本身、`/Users`、firmlink 那一侧的 `/System/Volumes/Data` 都太宽：当项目根等于把整个用户目录交出去。
    func testOverlyBroadProjectRootsGiveNoCards() throws {
        let home = try XCTUnwrap(TranscriptFileRefs.realPath(FileManager.default.homeDirectoryForCurrentUser.path))
        for root in [home, "/Users", "/System/Volumes/Data", "/private/var", "/tmp", "/Volumes"] {
            XCTAssertNil(TranscriptFileRefs.projectRoot(root), root)
            XCTAssertEqual(resolve(["x.png", root + "/x.png"], projectPath: root), [], root)
            XCTAssertNil(TranscriptFileRefs.validate(path: "x.png", projectPath: root), root)
        }
        // 临时目录在 `/private/var/folders/...`：是 `/private/var` 的后代，不是祖先，照样可用。
        let url = try file("a.png")
        XCTAssertEqual(resolve(["a.png"]).map(\.path), [url.path])
    }

    #if os(Windows)
    /// Windows：盘符根、`C:\Users`、系统目录与 home 本身（及它们的祖先）不行；它们的后代可以。不分大小写、不管分隔符写法。
    func testAcceptableProjectRootRule() {
        let home = "C:\\Users\\alice"
        for root in ["C:\\", "D:\\", "C:\\Users", "c:\\users", "C:\\Windows", "C:\\Program Files", "C:\\ProgramData", home,
                     "C:/Users/alice"] {
            XCTAssertFalse(TranscriptFileRefs.isAcceptableProjectRoot(root, home: home), root)
        }
        XCTAssertTrue(TranscriptFileRefs.isAcceptableProjectRoot(home + "\\code\\app", home: home))
        XCTAssertTrue(TranscriptFileRefs.isAcceptableProjectRoot("D:\\work\\proj", home: home))
        XCTAssertTrue(TranscriptFileRefs.isAcceptableProjectRoot("C:\\Users\\alice2", home: home))
        XCTAssertFalse(TranscriptFileRefs.isAcceptableProjectRoot("relative\\proj", home: home))
    }
    #else
    func testAcceptableProjectRootRule() {
        let home = "/Users/alice"
        // 固定集合本身与它们的祖先一律不行。
        for root in ["/", "/Users", "/System", "/System/Volumes", "/System/Volumes/Data", "/System/Volumes/Data/Users",
                     "/Volumes", "/private", "/private/var", "/private/tmp", "/tmp", "/var", "/Library",
                     "/Applications", "/opt", "/usr"] {
            XCTAssertFalse(TranscriptFileRefs.isAcceptableProjectRoot(root, home: home), root)
        }
        // home 本身不行，home 下的子目录可以。
        XCTAssertFalse(TranscriptFileRefs.isAcceptableProjectRoot(home, home: home))
        XCTAssertTrue(TranscriptFileRefs.isAcceptableProjectRoot(home + "/code/app", home: home))
        XCTAssertTrue(TranscriptFileRefs.isAcceptableProjectRoot(home + "/Desktop", home: home))
        // 固定集合的后代可以（临时目录、外接盘上的项目、/opt 下的工作区）。
        XCTAssertTrue(TranscriptFileRefs.isAcceptableProjectRoot("/private/var/folders/ab/T/proj", home: home))
        XCTAssertTrue(TranscriptFileRefs.isAcceptableProjectRoot("/Volumes/Work/proj", home: home))
        XCTAssertTrue(TranscriptFileRefs.isAcceptableProjectRoot("/opt/work", home: home))
        // 别的用户的 home：`/Users` 的后代，不是当前 home 的祖先——规则上不拦（读得到读不到归文件权限）。
        XCTAssertTrue(TranscriptFileRefs.isAcceptableProjectRoot("/Users/bob/proj", home: home))
        // 按路径组件比：`/Users/alice2` 不是 home 的祖先。
        XCTAssertTrue(TranscriptFileRefs.isAcceptableProjectRoot("/Users/alice2", home: home))
        // home 放在别处时（例如 `/Volumes/Home/alice`），它的祖先 `/Volumes/Home` 也不行。
        XCTAssertFalse(TranscriptFileRefs.isAcceptableProjectRoot("/Volumes/Home", home: "/Volumes/Home/alice"))
    }
    #endif

    // MARK: - validate

    func testValidateReturnsRealURLOrNil() throws {
        let url = try file("out/a.png")
        XCTAssertEqual(TranscriptFileRefs.validate(path: "out/a.png", projectPath: project.path)?.path, url.path)
        XCTAssertEqual(TranscriptFileRefs.validate(path: url.path, projectPath: project.path)?.path, url.path)
        XCTAssertNil(TranscriptFileRefs.validate(path: "/etc/hosts", projectPath: project.path))
        XCTAssertNil(TranscriptFileRefs.validate(path: ".git/x.png", projectPath: project.path))
        XCTAssertNil(TranscriptFileRefs.validate(path: "", projectPath: project.path))
        XCTAssertNil(TranscriptFileRefs.validate(path: url.path, projectPath: ""))
    }
}
