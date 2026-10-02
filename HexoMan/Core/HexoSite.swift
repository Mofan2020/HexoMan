//
//  HexoSite.swift
//  HexoMan
//
//  站点模型与探测。回答两个问题：这是不是一个 Hexo 站点，它长什么样。
//

import Foundation

/// 一个被用户纳管的 Hexo 站点。`id` 就是绝对路径，保证唯一。
struct HexoSite: Identifiable, Codable, Hashable {
    /// 站点根目录绝对路径。
    var path: String
    /// 上次打开时间，用于「最近站点」排序。
    var lastOpened: Date

    var id: String { path }

    /// 目录名，作为兜底显示名。
    var folderName: String {
        (path as NSString).lastPathComponent
    }

    init(path: String, lastOpened: Date = Date()) {
        // 统一去掉尾部斜杠，避免同一站点出现两种 path。
        var normalized = path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        self.path = normalized
        self.lastOpened = lastOpened
    }

    /// 文章目录。读 _config.yml 的 `new_dir` 决定，详见 `resolvedPostsDirectory`。
    var postsDirectory: String { resolvedPostsDirectory }
    /// 源码目录。读 _config.yml 的 `source_dir` 决定，详见 `resolvedSourceDirectory`。
    var sourceDirectory: String { resolvedSourceDirectory }
    var publicDirectory: String { (path as NSString).appendingPathComponent("public") }
    var configFile: String { (path as NSString).appendingPathComponent("_config.yml") }
    var packageFile: String { (path as NSString).appendingPathComponent("package.json") }
    var nodeModulesBin: String { (path as NSString).appendingPathComponent("node_modules/.bin/hexo") }
}

/// 站点体检结果。UI 靠它渲染总览卡片。
struct SiteInfo {
    /// `_config.yml` 里的 `title`。
    var title: String = ""
    /// `_config.yml` 里的 `url`。
    var url: String = ""
    /// `_config.yml` 里的 `theme`。
    var theme: String = ""
    /// `package.json` 里声明的 Hexo 版本。
    var hexoVersion: String = ""
    /// 主题声明的版本（若有）。
    var themeVersion: String = ""
    /// `node_modules` 是否已安装。
    var dependenciesInstalled: Bool = false
    /// 是否是 git 仓库。
    var isGitRepository: Bool = false
    /// 远端地址。
    var gitRemote: String = ""
    /// 文章数量。
    var postCount: Int = 0
    /// 已存在构建产物。
    var hasBuildOutput: Bool = false
    /// 构建产物文件数。
    var buildFileCount: Int = 0

    /// 站点能显示的名字：配置标题优先，其次目录名。
    var displayName: String {
        title.isEmpty ? "未命名站点" : title
    }

    /// 总览卡片上的状态摘要。
    var statusSummary: String {
        if !dependenciesInstalled { return "依赖未安装" }
        if postCount == 0 { return "还没有文章" }
        return "\(postCount) 篇文章"
    }

    /// 有没有问题需要用户处理。
    var hasIssues: Bool {
        !dependenciesInstalled
    }
}

/// 站点探测工具。判定标准刻意放宽：只要有 Hexo 依赖的 package.json 和 _config.yml 就算。
enum SiteProbe {

    /// 判断目录是否是 Hexo 站点。
    static func isHexoSite(_ path: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: (path as NSString).appendingPathComponent("package.json")),
              fm.fileExists(atPath: (path as NSString).appendingPathComponent("_config.yml"))
        else { return false }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: (path as NSString).appendingPathComponent("package.json"))),
              let text = String(data: data, encoding: .utf8)
        else { return false }

        // hexo 可能在 dependencies，也可能被 hexo-cli 之类间接声明，
        // 宽松匹配一次关键字即可，避免漏判。
        return text.contains("\"hexo\"")
    }

    /// 采集站点信息。任何单项失败都不影响其他项，缺失字段留空。
    static func inspect(site: HexoSite) -> SiteInfo {
        var info = SiteInfo()

        // 配置
        if let text = try? String(contentsOfFile: site.configFile, encoding: .utf8) {
            let yaml = YAMLScalars.parse(text)
            info.title = yaml["title"] ?? ""
            info.url = yaml["url"] ?? ""
            info.theme = yaml["theme"] ?? ""
        }

        // package.json
        if let data = try? Data(contentsOf: URL(fileURLWithPath: site.packageFile)),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            info.hexoVersion = hexoVersion(in: object) ?? ""
            if !info.theme.isEmpty {
                info.themeVersion = versionOf(named: info.theme, in: object) ?? ""
            }
        }

        info.dependenciesInstalled = FileManager.default.fileExists(atPath: site.nodeModulesBin)

        // git
        let gitDir = (site.path as NSString).appendingPathComponent(".git")
        info.isGitRepository = FileManager.default.fileExists(atPath: gitDir)
        if info.isGitRepository {
            info.gitRemote = (try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("config"), encoding: .utf8))
                .flatMap(parseRemoteFromGitConfig) ?? ""
        }

        // 文章与产物
        info.postCount = PostStore.load(site: site).count
        info.hasBuildOutput = FileManager.default.fileExists(atPath: site.publicDirectory)
        if info.hasBuildOutput {
            info.buildFileCount = (try? FileManager.default.contentsOfDirectory(atPath: site.publicDirectory).count) ?? 0
        }

        return info
    }

    /// 从 package.json 里找 hexo 的版本声明。
    private static func hexoVersion(in object: [String: Any]) -> String? {
        versionOf(named: "hexo", in: object)
    }

    private static func versionOf(named name: String, in object: [String: Any]) -> String? {
        for key in ["dependencies", "devDependencies"] {
            if let deps = object[key] as? [String: Any], let version = deps[name] as? String {
                return version
            }
        }
        return nil
    }

    /// 从 .git/config 里提取第一个 remote url，纯文本解析，不依赖 git 命令。
    private static func parseRemoteFromGitConfig(_ text: String) -> String? {
        var inOrigin = false
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line.contains("remote \"origin\"")
                continue
            }
            if inOrigin, line.hasPrefix("url") {
                if let value = line.split(separator: "=", maxSplits: 1).last {
                    return value.trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }
}

// MARK: - 目录解析

extension HexoSite {

    /// 站点实际的文章目录。优先读 _config.yml 的 `new_dir`，
    /// 退化到 `<source_dir>/_posts`；配置读不到就按默认目录算，**不让探测失败**。
    ///
    /// 「只要是 hexo 项目就能管」是产品底线：Hexo 允许把 `new_dir` / `source_dir` 改成任意目录，
    /// 硬编码 `source/_posts` 会让定制过的站点在 HexoMan 里显示成零篇文章。
    var resolvedPostsDirectory: String {
        SitePathCache.shared.resolve(for: self).posts
    }

    /// 站点实际的源码目录，默认 `source`。
    var resolvedSourceDirectory: String {
        SitePathCache.shared.resolve(for: self).source
    }
}

/// 目录解析结果。`posts` 已展开成绝对路径。
struct ResolvedSitePaths {
    var source: String
    var posts: String
}

/// 目录解析结果的进程内缓存。
///
/// 为什么需要缓存：`postsDirectory` 会被 `PostStore.load` 在每次刷新时调用多次，
/// 每次都读一遍 _config.yml 属于白白浪费 I/O。缓存用配置文件修改时间做钥匙，
/// 用户在编辑器里改完 `new_dir` 再刷新即可自动失效，不需要手动清缓存。
private final class SitePathCache {

    static let shared = SitePathCache()

    private struct Entry {
        var stamp: Date?
        var paths: ResolvedSitePaths
    }

    private let lock = NSLock()
    private var storage: [String: Entry] = [:]

    func resolve(for site: HexoSite) -> ResolvedSitePaths {
        let key = site.configFile
        let stamp = Self.modificationDate(ofPath: key)

        lock.lock()
        let cached = storage[key]
        lock.unlock()

        if let cached, cached.stamp == stamp {
            return cached.paths
        }

        let resolved = Self.compute(for: site)

        lock.lock()
        storage[key] = Entry(stamp: stamp, paths: resolved)
        lock.unlock()
        return resolved
    }

    /// 配置读不到就整条退回默认路径，绝不抛错。
    private static func compute(for site: HexoSite) -> ResolvedSitePaths {
        var source = site.sourceDirectoryDefault
        var newDir = "_posts"

        if let text = try? String(contentsOfFile: site.configFile, encoding: .utf8) {
            let yaml = YAMLScalars.parse(text)
            if let raw = cleaned(yaml["source_dir"]) {
                source = absolute(raw, relativeTo: site.path)
            }
            if let raw = cleaned(yaml["new_dir"]) {
                newDir = raw
            }
        }

        return ResolvedSitePaths(source: source, posts: absolute(newDir, relativeTo: source))
    }

    /// 相对路径挂到 base 下；绝对路径（`/` 或 `~` 开头）自己展开。
    private static func absolute(_ value: String, relativeTo base: String) -> String {
        if value.hasPrefix("/") {
            return expandTilde(value)
        }
        return (base as NSString).appendingPathComponent(value)
    }

    private static func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return (NSHomeDirectory() as NSString).appendingPathComponent(
            path == "~" ? "" : String(path.dropFirst(2))
        )
    }

    /// 去掉首尾空白和成对引号，空值返回 nil（`key:` 后面没值是 YAML 的正常写法）。
    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func modificationDate(ofPath path: String) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date
    }
}

private extension HexoSite {
    /// Hexo 的 `source_dir` 默认值。解析时作为兜底基准。
    var sourceDirectoryDefault: String {
        (path as NSString).appendingPathComponent("source")
    }
}

// MARK: - 模板

/// `hexo init` 可用的模板。
enum HexoTemplate: String, CaseIterable, Identifiable {
    /// hexo 官方示例模板（git 仓库），带一些示例文章，适合上手。
    case starter
    /// hexo-cli 内置的空白模板。
    case standard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .starter: return "hexo-starter（示例模板）"
        case .standard: return "hexo（默认空白模板）"
        }
    }

    var subtitle: String {
        switch self {
        case .starter: return "从 git 拉取官方示例站，含示例文章和默认主题配置"
        case .standard: return "只生成骨架目录和 _config.yml，最干净"
        }
    }

    /// 传给 `hexo init` 的 `--template` 值。内置模板没有这个参数。
    var initArgument: String? {
        switch self {
        case .starter: return "hexo-starter"
        case .standard: return nil
        }
    }

    /// 拼出完整参数。抽出来是为了让向导预览的命令和真正执行的命令同源。
    func initArguments(name: String) -> [String] {
        var arguments = ["init", name]
        if let initArgument {
            arguments.append(contentsOf: ["--template", initArgument])
        }
        return arguments
    }
}
