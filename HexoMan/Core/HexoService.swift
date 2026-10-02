//
//  HexoService.swift
//  HexoMan
//
//  把 hexo 命令封装成高层动作，并解决「到底该用哪个 hexo」的问题。
//

import Foundation

/// 站点当前可用的 hexo 调用方式。
struct HexoInvocation: Equatable {
    /// 实际执行的程序。
    var executable: String
    /// 程序后面的固定参数。
    var prefixArguments: [String]
    /// 展示给用户看的来源说明。
    var source: String

    /// 拼出完整命令行。
    func arguments(_ extra: [String]) -> [String] {
        prefixArguments + extra
    }
}

/// hexo 动作集合。每个方法只负责组装命令，具体执行交给 ShellRunner。
enum HexoService {

    /// 找出这个站点该用哪个 hexo。
    ///
    /// 优先级是刻意的：**用户显式指定 > 站点本地依赖 > 用户 PATH > 自装 > npx 下载**。
    /// 直接用 `npx hexo` 会在没装依赖的站点上触发一次联网安装，那不是「管理」该有的行为。
    ///
    /// 这里查的是 ShellRunner 缓存下来的**用户真实 PATH**（已经 source 过 .zshrc/.zprofile），
    /// 所以 brew 装的 node、全局 npm 装的 hexo 都能被认出来；
    /// 实在一个都没有才退到 npx，保证功能不会整个瘫掉。
    static func resolveInvocation(
        site: HexoSite,
        customPath: String? = nil,
        runner: ShellRunner? = nil
    ) -> HexoInvocation {
        if let customPath, customPath.isEmpty == false, FileManager.default.isExecutableFile(atPath: customPath) {
            return HexoInvocation(executable: customPath, prefixArguments: [], source: "自定义路径")
        }

        let local = site.nodeModulesBin
        if FileManager.default.isExecutableFile(atPath: local) {
            return HexoInvocation(executable: local, prefixArguments: [], source: "站点本地依赖")
        }

        // 用户 PATH 里的 hexo。这是绝大多数装了 hexo-cli 的用户走的那条。
        if let found = runner?.resolvedExecutablePath(named: "hexo") {
            return HexoInvocation(executable: found, prefixArguments: [], source: "用户 PATH")
        }

        if let found = lookupGlobalHexo() {
            return HexoInvocation(executable: found, prefixArguments: [], source: "全局安装")
        }

        // HexoMan 自装的那份（创建站点时自举出来的）
        if FileManager.default.isExecutableFile(atPath: HexoCLIBootstrap.managedHexoPath) {
            return HexoInvocation(executable: HexoCLIBootstrap.managedHexoPath, prefixArguments: [], source: "HexoMan 自装")
        }

        return HexoInvocation(executable: "npx", prefixArguments: ["hexo"], source: "npx（将临时下载）")
    }

    /// 在常见位置找全局 hexo，不走 `which`，避免 shell 配置差异。
    private static func lookupGlobalHexo() -> String? {
        var candidates: [String] = []

        // Homebrew / npm global / nvm 等常见前缀
        let home = NSHomeDirectory()
        candidates.append("/usr/local/bin/hexo")
        candidates.append("/opt/homebrew/bin/hexo")
        candidates.append("\(home)/.nvm/versions/node/\(currentNodeVersionFolder() ?? "")/bin/hexo")

        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            for directory in envPath.split(separator: ":") {
                candidates.append("\(directory)/hexo")
            }
        }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func currentNodeVersionFolder() -> String? {
        // 只取 ~/.nvm 下最后一个版本目录，够用且不用跑 node 去问
        let versions = "\(NSHomeDirectory())/.nvm/versions/node"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: versions),
              let latest = entries.sorted().last
        else { return nil }
        return latest
    }

    // MARK: - 动作

    /// `hexo clean` —— 清掉 db.json 和 public。
    ///
    /// customPath / runner 必须由调用方传进来。
    /// 之前这里自己调 resolveInvocation(site:) 拿默认参数，结果用户在设置里手填的
    /// 路径对真实命令完全不生效 —— 界面显示「自定义路径」，跑起来却是另一个 hexo。
    static func clean(
        site: HexoSite,
        customPath: String? = nil,
        runner: ShellRunner? = nil
    ) -> (executable: String, arguments: [String]) {
        let invocation = resolveInvocation(site: site, customPath: customPath, runner: runner)
        return (invocation.executable, invocation.arguments(["clean"]))
    }

    /// `hexo generate`
    static func generate(
        site: HexoSite,
        customPath: String? = nil,
        runner: ShellRunner? = nil
    ) -> (executable: String, arguments: [String]) {
        let invocation = resolveInvocation(site: site, customPath: customPath, runner: runner)
        return (invocation.executable, invocation.arguments(["generate"]))
    }

    /// `hexo server`
    static func server(
        site: HexoSite,
        port: Int,
        customPath: String? = nil,
        runner: ShellRunner? = nil
    ) -> (executable: String, arguments: [String]) {
        let invocation = resolveInvocation(site: site, customPath: customPath, runner: runner)
        return (invocation.executable, invocation.arguments(["server", "-p", String(port)]))
    }

    /// 服务可访问地址。
    static func previewURL(port: Int) -> URL {
        URL(string: "http://localhost:\(port)")!
    }
}
