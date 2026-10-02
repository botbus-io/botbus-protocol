import Foundation

/// 路径形状的平台差异，集中在一处：绝对路径怎么认、「在某目录里」怎么比、分隔符、`PATH` 的键与分隔符、
/// 可执行文件的后缀。macOS / Linux 上每个函数都与原来的写法（`hasPrefix("/")`、`root + "/"`、`split(":")`）逐字等价；
/// Windows 上认盘符与 UNC、`\` 与 `/` 都当分隔符、比较不分大小写（NTFS 默认如此）。
public enum PlatformPath {
    #if os(Windows)
    public static let separator: Character = "\\"
    /// `PATH` 里目录之间的分隔符。
    public static let listSeparator: Character = ";"
    #else
    public static let separator: Character = "/"
    public static let listSeparator: Character = ":"
    #endif

    // MARK: - 绝对路径

    /// POSIX：以 `/` 开头。Windows：`C:\…` / `C:/…`，或 `\\server\share` 这种 UNC。
    public static func isAbsolute(_ path: String) -> Bool {
        #if os(Windows)
        let bytes = Array(path.utf8.prefix(3))
        if bytes.count == 3, (0x41...0x5A).contains(bytes[0] & 0xDF), bytes[1] == UInt8(ascii: ":"),
           bytes[2] == UInt8(ascii: "\\") || bytes[2] == UInt8(ascii: "/") {
            return true
        }
        return path.hasPrefix("\\\\") || path.hasPrefix("//")
        #else
        return path.hasPrefix("/")
        #endif
    }

    // MARK: - 组件与包含关系

    /// 统一分隔符（Windows 把 `/` 换成 `\`），去掉结尾多余的分隔符（根目录本身除外）。POSIX 上只去结尾的 `/`。
    public static func normalized(_ path: String) -> String {
        #if os(Windows)
        var text = path.replacingOccurrences(of: "/", with: "\\")
        while text.count > 3, text.hasSuffix("\\") { text.removeLast() }
        return text
        #else
        var text = path
        while text.count > 1, text.hasSuffix("/") { text.removeLast() }
        return text
        #endif
    }

    /// 两个路径是不是同一个（Windows 不分大小写、不管分隔符写法）。
    public static func same(_ a: String, _ b: String) -> Bool {
        #if os(Windows)
        return normalized(a).caseInsensitiveCompare(normalized(b)) == .orderedSame
        #else
        return a == b
        #endif
    }

    /// 当身份用的写法（项目按 `(agentId, path)` 区分，手机按字符串分组）。Windows 上同一个目录会以 `C:/…`
    /// （Foundation 的 `URL.path`）和 `C:\…`（Claude Code / Codex 报的 cwd、`GetFinalPathNameByHandleW`）两种样子进来，
    /// 这里统一成 `normalized` 的 `\` 写法、盘符大写；不是 Windows 绝对路径的（空串、相对路径）与 POSIX 上一律原样返回。
    public static func canonical(_ path: String) -> String {
        #if os(Windows)
        guard isAbsolute(path) else { return path }
        var text = normalized(path)
        if let first = text.first, first.isLetter, text.dropFirst().hasPrefix(":") {
            text = first.uppercased() + text.dropFirst()
        }
        return text
        #else
        return path
        #endif
    }

    /// `path` 严格在 `root` 之下（按路径组件比，`/proj` 不包含 `/proj2/x`）。等于 `root` 不算。
    public static func isInside(_ path: String, root: String) -> Bool {
        relativePath(of: path, under: root) != nil
    }

    /// `path` 相对 `root` 的部分（不带开头的分隔符）；不在 `root` 之下（或就是 `root`）返回 nil。
    public static func relativePath(of path: String, under root: String) -> Substring? {
        #if os(Windows)
        let base = normalized(root)
        let full = normalized(path)
        let prefix = base.hasSuffix("\\") ? base : base + "\\"
        guard full.count > prefix.count,
              full.prefix(prefix.count).caseInsensitiveCompare(prefix) == .orderedSame else { return nil }
        return full.dropFirst(prefix.count)
        #else
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix), path.count > prefix.count else { return nil }
        return path.dropFirst(prefix.count)
        #endif
    }

    /// 路径的各段（空段丢掉）。Windows 上 `\` 与 `/` 都算分隔符，盘符 `C:` 是第一段。
    public static func components(_ path: String) -> [Substring] {
        #if os(Windows)
        return path.split(whereSeparator: { $0 == "\\" || $0 == "/" })
        #else
        return path.split(separator: "/")
        #endif
    }

    /// `root` 下接一段相对路径。
    public static func join(_ root: String, _ relative: String) -> String {
        let trimmed = root.hasSuffix(String(separator)) ? String(root.dropLast()) : root
        #if os(Windows)
        return trimmed + "\\" + relative.replacingOccurrences(of: "/", with: "\\")
        #else
        return trimmed + "/" + relative
        #endif
    }

    /// 根目录本身（`/`，或 Windows 的 `C:\`、`\\server\share`）。
    public static func isRoot(_ path: String) -> Bool {
        #if os(Windows)
        let text = normalized(path)
        if text.count <= 3, text.dropFirst().hasPrefix(":") { return true }
        return text.hasPrefix("\\\\") && components(text).count <= 2
        #else
        return path == "/"
        #endif
    }

    // MARK: - 环境变量

    /// 环境变量表里 `PATH` 实际用的键。Windows 的环境变量不分大小写，Foundation 交出来的通常是 `Path`。
    public static func pathKey(in environment: [String: String]) -> String {
        #if os(Windows)
        return environment.keys.first { $0.caseInsensitiveCompare("PATH") == .orderedSame } ?? "Path"
        #else
        return "PATH"
        #endif
    }

    /// 取 `PATH`（Windows 上不分大小写）。
    public static func searchPath(in environment: [String: String]) -> String? {
        environment[pathKey(in: environment)]
    }

    public static func splitSearchPath(_ value: String) -> [String] {
        value.split(separator: listSeparator).map(String.init).filter { !$0.isEmpty }
    }

    public static func joinSearchPath(_ directories: [String]) -> String {
        directories.joined(separator: String(listSeparator))
    }

    /// 把 `PATH` 设成 `value`：Windows 上先去掉别的大小写写法的同名键，免得子进程拿到两份。
    public static func setSearchPath(_ value: String, in environment: inout [String: String]) {
        let key = pathKey(in: environment)
        #if os(Windows)
        for other in environment.keys where other != key && other.caseInsensitiveCompare("PATH") == .orderedSame {
            environment.removeValue(forKey: other)
        }
        #endif
        environment[key] = value
    }

    // MARK: - 可执行文件

    /// 找可执行文件时一个名字要试的文件名。POSIX 就是它自己；Windows 上没写扩展名时按 `.exe`、`.cmd`、`.bat` 依次试
    /// （npm 全局装的命令是 `.cmd` 包装），最后才试原名。
    public static func executableFileNames(_ name: String) -> [String] {
        #if os(Windows)
        guard (name as NSString).pathExtension.isEmpty else { return [name] }
        return [name + ".exe", name + ".cmd", name + ".bat", name]
        #else
        return [name]
        #endif
    }

    /// 在一组目录里找可执行文件（Windows 上带后缀地试）。
    public static func findExecutable(_ name: String, in directories: [String],
                                      fileManager: FileManager = .default) -> String? {
        for directory in directories {
            for file in executableFileNames(name) {
                let candidate = (directory as NSString).appendingPathComponent(file)
                if isExecutableFile(candidate, fileManager: fileManager) { return candidate }
            }
        }
        return nil
    }

    /// Windows 上 `isExecutableFile` 对任何存在的文件都是 true，这里只认可执行的后缀与普通文件。
    public static func isExecutableFile(_ path: String, fileManager: FileManager = .default) -> Bool {
        #if os(Windows)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        return ["exe", "cmd", "bat", "com"].contains((path as NSString).pathExtension.lowercased())
        #else
        return fileManager.isExecutableFile(atPath: path)
        #endif
    }
}
