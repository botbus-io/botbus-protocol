#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif
import Foundation
import BotBusProtocol

/// 从 Agent 的回复里认出可以让手机取回的本机文件（协议 2.9 的 `Message.files`，spec §3.5）。
///
/// 这是手机读 Mac 文件的唯一入口，所以规则收得很紧：只认图片、视频、PDF；
/// 解析掉软链接后必须仍在任务的项目目录内；项目内路径上任何一段以 `.` 开头都不认（挡住 `.env`、`.git/`）。
/// `FileFetchService` 执行前会用同一套规则再校验一遍。
///
/// 分两步：`candidates(in:)` 只看文字、不碰磁盘（读取器里调用）；`resolve` / `validate` 才去查文件（分发器里调用），
/// 因为读取器不知道任务的项目目录，而且"文件还在不在"要在发消息那一刻判断。
public enum TranscriptFileRefs {
    public static let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "mp4", "mov", "m4v", "pdf"]
    /// 协议规定每条消息最多 4 个文件卡片。
    public static let maxFilesPerMessage = 4
    /// 比 `PATH_MAX` 还长的不可能是本机路径，省得对一大段乱码做后面的判断。
    public static let maxCandidateLength = 1024
    /// 每条回复最多给这么多候选。后面每个都要 realpath、查磁盘，贴一整段 `ls` 的回复不该拖慢整页；
    /// 真正会出卡片的只有前 `maxFilesPerMessage` 个合法的，32 个足够跳过其中不存在或不合规的。
    public static let maxCandidates = 32

    // MARK: - 识别（只看文字）

    /// Markdown 链接的目标：`](path)`、`](<带 空格 的路径>)`，允许带 `"标题"`。图片链接 `![…](…)` 同样命中。
    private static let linkPattern = try! NSRegularExpression(
        pattern: #"\]\(\s*(?:<([^<>\n]+)>|([^\s()<>]+))(?:\s+(?:"[^"\n]*"|'[^'\n]*'))?\s*\)"#)
    /// 行内代码。内容里可以有空格——带空格的路径只有放进反引号或尖括号才认。
    private static let codePattern = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)
    /// 裸路径：一段连续的"路径字符"。中日韩文字与全角标点也当分隔——中文句子里路径常常紧贴着字写
    /// （"保存在out/a.png了"），代价是带中文名的文件要写在反引号里才认得出。
    private static let barePattern = try! NSRegularExpression(
        pattern: #"[^\s"'`<>()\[\]{}|,;*“”‘’…\u3000-\u303F\uFF00-\uFFEF\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]+"#)
    /// `https:`、`file:` 这类带 scheme 的都不是本机路径。
    private static let schemePattern = try! NSRegularExpression(pattern: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#)

    /// 回复里看起来像媒体文件路径的文本，按出现顺序、去重，最多 `maxCandidates` 个。**不查磁盘**，结果未经校验。
    ///
    /// 三种来源：Markdown 链接目标、反引号里的整段内容、裸路径（绝对、`~/` 开头或相对）。
    /// 反引号里整段不像路径、或带空格时（例如 `open a.png`），里面的内容按裸路径再扫一遍。
    public static func candidates(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let string = text as NSString
        let whole = NSRange(location: 0, length: string.length)
        var found: [(location: Int, value: String)] = []
        // 已经按链接或代码认过的区间，裸路径扫描跳过它们：不然 `](<a b.png>)` 会再被拆出一个 `b.png`，
        // `](https://x/y.png)` 会冒出一个 `//x/y.png`。
        var claimed: [NSRange] = []

        for match in linkPattern.matches(in: text, range: whole) {
            claimed.append(match.range)
            let target = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            if let value = accept(string.substring(with: target)) { found.append((match.range.location, value)) }
        }
        for match in codePattern.matches(in: text, range: whole) where !overlaps(match.range, claimed) {
            guard let value = accept(string.substring(with: match.range(at: 1))) else { continue }
            found.append((match.range.location, value))
            // 带空格的整段可能是一条命令（`open out/a.png`），不占区间，里面的路径照样按裸路径再认一遍；
            // 多出来的候选（`my shots/a b.png` 里的 `b.png`）不存在就会在 resolve 时被丢掉。
            if !value.contains(where: \.isWhitespace) { claimed.append(match.range) }
        }
        for match in barePattern.matches(in: text, range: whole) where !overlaps(match.range, claimed) {
            if let value = accept(trimTrailingPunctuation(string.substring(with: match.range))) {
                found.append((match.range.location, value))
            }
        }

        var seen: Set<String> = []
        return Array(found.sorted { $0.location < $1.location }.map(\.value).filter { seen.insert($0).inserted }
            .prefix(maxCandidates))
    }

    /// 一段文本能不能当候选：单行、不带 scheme、扩展名是媒体类型、扩展名前面有文件名。
    private static func accept(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value.count <= maxCandidateLength, !value.contains(where: \.isNewline),
              !value.contains("://"),
              schemePattern.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) == nil
        else { return nil }
        let name = (value as NSString).lastPathComponent as NSString
        guard extensions.contains(name.pathExtension.lowercased()), !name.deletingPathExtension.isEmpty else { return nil }
        return value
    }

    /// 句末的英文标点不算路径（"见 out/a.png." 里的点）。开头不用处理：扫描本来就从分隔符之后开始。
    private static func trimTrailingPunctuation(_ value: String) -> String {
        var result = Substring(value)
        while let last = result.last, ".:!?".contains(last) { result = result.dropLast() }
        return String(result)
    }

    private static func overlaps(_ range: NSRange, _ ranges: [NSRange]) -> Bool {
        ranges.contains { NSIntersectionRange($0, range).length > 0 }
    }

    // MARK: - 校验（查磁盘）

    /// 把候选变成文件卡片：逐个 `validate`，按真实路径去重，最多 `maxFilesPerMessage` 个。
    /// `artifactId` 不在这里填（要查取回索引，归分发器）。项目目录为空或不存在时一个都不给。
    public static func resolve(_ candidates: [String], projectPath: String) -> [MessageFileRef] {
        guard !candidates.isEmpty, let root = projectRoot(projectPath) else { return [] }
        var refs: [MessageFileRef] = []
        var seen: Set<String> = []
        for candidate in candidates {
            guard refs.count < maxFilesPerMessage else { break }
            guard let url = validate(candidate, root: root), seen.insert(url.path).inserted,
                  let size = regularFileSize(url.path) else { continue }
            refs.append(MessageFileRef(path: url.path, name: url.lastPathComponent,
                                       contentType: MediaType.contentType(forPathExtension: url.pathExtension),
                                       size: size))
        }
        return refs
    }

    /// 单个路径的完整校验，`resolve` 与 `fetchFile` 共用。通过时返回解析掉软链接后的真实路径。
    ///
    /// 相对路径按项目目录解析；`~/` 展开成本机 home（`~user` 这种别人的 home 不认）。
    public static func validate(path: String, projectPath: String) -> URL? {
        guard let root = projectRoot(projectPath) else { return nil }
        return validate(path, root: root)
    }

    /// 项目目录的真实路径。必须是存在的目录，且不能太宽（见 `isAcceptableProjectRoot`）。
    public static func projectRoot(_ projectPath: String) -> String? {
        let trimmed = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), let real = realPath(trimmed),
              isAcceptableProjectRoot(real, home: currentHome) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return real
    }

    /// 等于或包含这些目录的"项目"一律不认：在 home、`/Users` 里开的会话（Claude / Codex 在终端里随手一开就是），
    /// 项目根就成了整个用户目录，`~/Documents/合同.pdf`、`~/Desktop/证件.jpg` 全都"在项目里"。
    /// `/System/Volumes/Data` 一组是 firmlink 的另一侧，同样装着 `/Users`。`/tmp`、`/var` 本身是软链接，
    /// realpath 之后不会原样出现，列着只为规则一眼看全。
    public static let broadRoots = ["/", "/Users", "/System", "/System/Volumes/Data", "/System/Volumes/Data/Users",
                             "/Volumes", "/private", "/private/var", "/private/tmp", "/tmp", "/var", "/Library",
                             "/Applications", "/opt", "/usr"]

    /// 当前用户 home 的真实路径。realpath 失败（几乎不会）就用原样，照样挡得住。
    private static var currentHome: String {
        let path = FileManager.default.homeDirectoryForCurrentUser.path
        return realPath(path) ?? path
    }

    /// `realRoot`（已 realpath）等于或是 home / `broadRoots` 里任一路径的祖先时拒绝。**只拦本身与祖先，不拦后代**：
    /// home 下的子目录、`/private/var/folders/...` 的临时目录、`/Volumes/盘/项目` 都照常可用。
    /// 按路径组件比，`/Users/alice2` 不是 `/Users/alice` 的祖先。
    public static func isAcceptableProjectRoot(_ realRoot: String, home: String) -> Bool {
        guard realRoot.hasPrefix("/") else { return false }
        return !(broadRoots + [home]).contains { forbidden in
            forbidden == realRoot || realRoot == "/" || forbidden.hasPrefix(realRoot + "/")
        }
    }

    /// `root` 已是真实路径。
    private static func validate(_ raw: String, root: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else { return nil }
        let absolute: String
        if trimmed.hasPrefix("~/") {
            absolute = FileManager.default.homeDirectoryForCurrentUser.path + trimmed.dropFirst()
        } else if trimmed.hasPrefix("~") {
            return nil
        } else if trimmed.hasPrefix("/") {
            absolute = trimmed
        } else {
            absolute = root + "/" + trimmed
        }
        // realpath 同时挡住三种逃逸：`../`、指向项目外的软链接、以及不存在的文件（返回 nil）。
        // 前缀按路径组件比：带上结尾的 `/`，`/proj` 不会匹配 `/proj2/x.png`。
        guard let real = realPath(absolute), real.hasPrefix(root + "/") else { return nil }
        // 只看项目根以下的各段：项目本身放在 `~/.work/` 之类的点目录里是用户的选择，不该因此整个用不了。
        let relative = real.dropFirst(root.count + 1)
        guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return nil }
        // 扩展名按真实文件判断：项目里一个叫 `a.png` 的软链接指向 `notes.txt` 也不认。
        guard extensions.contains((real as NSString).pathExtension.lowercased()),
              regularFileSize(real) != nil else { return nil }
        return URL(fileURLWithPath: real)
    }

    /// 普通文件的大小；目录、设备、FIFO 等一律 nil。传入的应是真实路径（`attributesOfItem` 不跟随软链接）。
    public static func regularFileSize(_ path: String) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return (attributes[.size] as? NSNumber)?.intValue
    }

    /// POSIX `realpath`：解析全部软链接与 `.`/`..`，不存在就 nil。
    /// 不用 `URL.resolvingSymlinksInPath()`：它会把 `/private/var` 改写成 `/var`，路径不存在时还原样返回。
    public static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
