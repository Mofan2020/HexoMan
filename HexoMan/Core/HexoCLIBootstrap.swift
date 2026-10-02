//
//  HexoCLIBootstrap.swift
//  HexoMan
//
//  「创建 Hexo 项目」这一步需要 hexo-cli，但 HexoMan **不自带**任何 node / npm / hexo。
//
//  所以策略是：借用用户自己装的那份工具链，按下面的顺序找一个能用的 hexo，
//  一个都没有才用用户的 npm 把 hexo-cli 装到 HexoMan 自己的目录里。
//
//    1. 用户在设置里手填的路径          —— 最高优先级，用户说了算
//    2. 用户 PATH 里的 hexo             —— npm i -g hexo-cli 装的那种
//    3. HexoMan 自有目录里已装好的      —— 上次创建站点时自己装的那份
//    4. 现场 npm install hexo-cli       —— 兜底，用用户的 npm，装在 HexoMan 目录下
//
//  装在 `~/Library/Application Support/HexoMan/cli` 而不是全局，
//  是为了不污染用户的全局 node_modules：卸载 HexoMan 等于连它一起删干净。
//  另外它不会写进任何 shell 配置文件，用户下次开终端不会莫名其妙多出命令。
//

import Foundation

/// hexo-cli 的定位与自举。
enum HexoCLIBootstrap {

    /// hexo-cli 版本。锁在 4.x 是因为 5.x 目前没有正式发布，4.3.2 是当前可用且稳定的线。
    private static let cliVersion = "^4.3.2"

    /// HexoMan 自有的 hexo-cli 安装目录。
    static var installDirectory: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("HexoMan", isDirectory: true)
            .appendingPathComponent("cli", isDirectory: true)
            .path
    }

    /// 自有安装目录里的 hexo 可执行文件。
    static var managedHexoPath: String {
        (installDirectory as NSString).appendingPathComponent("node_modules/.bin/hexo")
    }

    /// hexo 的来源说明，用于在界面上告诉用户「待会儿用的是哪一个」。
    enum Source: Equatable {
        case custom(String)
        case userPath(String)
        case managed
        case unavailable

        var displayText: String {
            switch self {
            case .custom: return "自定义路径"
            case .userPath(let path): return "系统 PATH（\((path as NSString).lastPathComponent)）"
            case .managed: return "HexoMan 自装"
            case .unavailable: return "未找到"
            }
        }
    }

    /// 找一个现成能用的 hexo，不做任何安装。
    ///
    /// - Parameter customPath: 设置里手填的路径，为空则跳过。
    /// - Parameter runner: 已持有环境缓存的 ShellRunner，用来查用户 PATH。
    static func locateHexo(customPath: String, runner: ShellRunner) -> (path: String, source: Source)? {
        let trimmed = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false, FileManager.default.isExecutableFile(atPath: trimmed) {
            return (trimmed, .custom(trimmed))
        }

        // 用户 PATH 里的 —— npm i -g hexo-cli 装的就是这个
        if let found = runner.resolvedExecutablePath(named: "hexo") {
            return (found, .userPath(found))
        }

        // 之前创建站点时自己装过
        if FileManager.default.isExecutableFile(atPath: managedHexoPath) {
            return (managedHexoPath, .managed)
        }

        return nil
    }

    /// 确保有一份可用的 hexo-cli，必要时用用户的 npm 现场装一份。
    ///
    /// 返回 hexo 可执行文件路径；用户压根没有 node/npm 时返回 nil。
    /// 整个过程只调用用户机器上已有的 npm，HexoMan 自己不携带任何运行时。
    @discardableResult
    static func ensureHexo(customPath: String, runner: ShellRunner) async -> String? {
        if let existing = locateHexo(customPath: customPath, runner: runner) {
            return existing.path
        }

        // 没有现成的，先确认用户有 npm —— 没有的话就别白等一次 npm 报错了。
        guard runner.resolvedExecutablePath(named: "npm") != nil else { return nil }

        // 复用同一个 Task 语义：并发调用只装一次。
        let directory = installDirectory
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let wroteManifest = writeManifest(in: directory)
        guard wroteManifest else { return nil }

        // 用 --no-audit --no-fund 是为了把安装时间压下来，
        // 创建站点本来就要几分钟，网络请求能省则省。
        let result = await runner.run(
            "npm install hexo-cli",
            executable: "npm",
            arguments: ["install", "hexo-cli@\(cliVersion)", "--no-audit", "--no-fund", "--loglevel", "warn"],
            workingDirectory: directory
        )

        guard result.success, FileManager.default.isExecutableFile(atPath: managedHexoPath) else { return nil }
        return managedHexoPath
    }

    /// 写一个最小的 package.json，让 npm 知道这个目录是个包而不是随手建的空目录。
    ///
    /// 缺了它 npm 会照样装，但每次都会顺手生成一个名字叫 `cli` 的包，
    /// 跟用户别的项目混淆。写清楚更省心。
    private static func writeManifest(in directory: String) -> Bool {
        let manifest: [String: Any] = [
            "name": "hexoman-managed-cli",
            "version": "1.0.0",
            "private": true,
            "description": "HexoMan 创建站点时自举的 hexo-cli。删除本目录即可完全卸载。",
            "dependencies": ["hexo-cli": cliVersion]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("package.json")
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 站点本地依赖装好之后，站点里就有自己的 hexo 了，自装的那份可以退休。
    ///
    /// 不主动删 —— 用户可能还有别的站点要靠它建。留着只是个几百 KB 的目录。
    static var managedSizeHint: String {
        let path = (installDirectory as NSString).appendingPathComponent("node_modules")
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return "未安装" }
        var count = 0
        for case let entry as String in enumerator where entry.hasSuffix(".js") {
            count += 1
        }
        return count == 0 ? "已安装" : "已安装（\(count) 个 js 文件）"
    }
}
