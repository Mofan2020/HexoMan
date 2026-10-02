//
//  HexoEnvironment.swift
//  HexoMan
//
//  node / npm / npx / hexo / git 工具链体检。
//
//  存在的理由是一个很容易踩的坑：从 Dock 或访达启动的 GUI 程序，
//  **不会**自动加载 ~/.zshrc，所以 brew 装的 node 不在 PATH 里。
//  于是终端里 `hexo -v` 好好的，HexoMan 里却找不到 hexo，用户完全不知道问题在哪。
//
//  这里做两件事：
//  1. 通过 ShellEnvironmentResolver 拿到用户真实的 shell 环境（已 source 过 rc 文件）。
//  2. 在这个环境里逐个跑 `--version`，并把「为什么找不到」翻译成人话。
//
//  设计前提：HexoMan **不自带** node / npm / git / hexo。
//  缺什么就如实告诉用户怎么自己装，不在应用里藏一份。
//

import Foundation

/// 单个可执行文件的探测结果。
struct ToolProbe: Equatable, Identifiable {
    var id: String { name }
    var name: String
    /// 解析到的绝对路径。
    var path: String?
    /// 版本号输出（已去掉命令名前缀）。
    var version: String?

    var isAvailable: Bool { path != nil }

    /// 界面上显示的一行摘要。
    var displayVersion: String {
        guard isAvailable else { return "未找到" }
        return version.map { "\($0) · \(shortPath)" } ?? shortPath
    }

    /// 只显示路径尾部三段，完整路径在详情里再看。
    var shortPath: String {
        guard let path else { return "" }
        let parts = (path as NSString).pathComponents
        return parts.suffix(3).joined(separator: "/")
    }
}

/// 工具链整体体检结果。
struct ToolchainInfo: Equatable {
    var node = ToolProbe(name: "node")
    var npm = ToolProbe(name: "npm")
    var npx = ToolProbe(name: "npx")
    /// 全局 hexo 的位置。
    var globalHexo = ToolProbe(name: "hexo")
    /// git。Hexo 本身不用，但 HexoMan 的版本管理功能全靠它。
    var git = ToolProbe(name: "git")

    /// 诊断出来的注意事项，直接展示给用户。
    var warnings: [String] = []

    /// 整体是否具备跑 hexo 的条件。
    var isUsable: Bool {
        node.isAvailable || globalHexo.isAvailable
    }
}

/// 工具链探测。只做只读检查，不改任何环境变量。
enum HexoEnvironment {

    /// 逐个跑 `--version` 拿版本。任何一个失败都只影响自己那一项。
    @MainActor
    static func inspect(using runner: ShellRunner) async -> ToolchainInfo {
        // 先把 shell 环境读进来，后面所有 --version 才有意义
        await runner.prewarmEnvironment()

        // 并发跑，省得用户等四条命令串行加起来的时间
        async let nodeTask = runner.run("node -v", executable: "node", arguments: ["-v"], workingDirectory: NSHomeDirectory())
        async let npmTask = runner.run("npm -v", executable: "npm", arguments: ["-v"], workingDirectory: NSHomeDirectory())
        async let npxTask = runner.run("npx -v", executable: "npx", arguments: ["-v"], workingDirectory: NSHomeDirectory())
        async let hexoTask = runner.run("hexo version", executable: "hexo", arguments: ["version"], workingDirectory: NSHomeDirectory())
        async let gitTask = runner.run("git --version", executable: "git", arguments: ["--version"], workingDirectory: NSHomeDirectory())

        let (node, npm, npx, hexo, git) = await (nodeTask, npmTask, npxTask, hexoTask, gitTask)

        // 只用「命令能不能跑通」判断可用性，不再自己扫一遍 PATH 目录 ——
        // 那种搜索 HexoService 里已经有了，重复一份只会两边结论不一致。
        // 路径从缓存的真实环境里取，这样版本和路径说的是同一个东西。
        func probe(_ name: String, _ result: ShellResult) -> ToolProbe {
            ToolProbe(
                name: name,
                path: result.success ? (runner.resolvedExecutablePath(named: name) ?? name) : nil,
                version: result.cleanVersion
            )
        }

        var info = ToolchainInfo()
        info.node = probe("node", node)
        info.npm = probe("npm", npm)
        info.npx = probe("npx", npx)
        info.globalHexo = probe("hexo", hexo)
        info.git = probe("git", git)
        info.warnings = diagnose(info, runner: runner)
        return info
    }

    /// 根据探测结果给出人话诊断。
    @MainActor
    private static func diagnose(_ info: ToolchainInfo, runner: ShellRunner) -> [String] {
        var warnings: [String] = []

        // 先说环境本身对不对，这决定了后面所有结论是否可信。
        if let environment = runner.environment {
            if environment.rcFiles.isEmpty {
                warnings.append("""
                没有找到任何 zsh 配置文件，HexoMan 只能看到系统自带的几个命令目录。
                如果你用 Homebrew 装的 node，这里会显示「未找到」。可以在下面手动指定 rc 文件路径。
                """)
            }
        } else if runner.usesShellEnvironment {
            warnings.append("读取 shell 环境失败，命令可能找不到。检查一下 rc 文件路径是否填对。")
        }

        if !info.node.isAvailable {
            // 重点怀疑 GUI 环境丢了 PATH，这几乎总能对上 brew / nvm 的使用方式
            if let nodePath = brewOrNvmNodePath() {
                warnings.append("""
                系统里能找到 node（\(nodePath)），但它不在 HexoMan 当前的 PATH 里。
                常见原因是 brew 的环境变量写在 .zprofile 或 .zshrc 里，没被读到。
                请在下面确认「读取 zsh 配置」是打开的、rc 路径填对。
                """)
            } else {
                warnings.append("""
                没找到 node。HexoMan 不自带 Node.js，请自己先装一个（建议 18 以上）：
                Homebrew 用 `brew install node`，或去 nodejs.org 装官方安装包。
                装完点「重新检测」即可。
                """)
            }
        } else if !info.globalHexo.isAvailable {
            warnings.append("""
            找到 node，但没找到全局 hexo。这不影响管理已有站点——站点本地装了依赖就能用。
            需要「创建新站点」时，HexoMan 会用你的 npm 现场装一份 hexo-cli，不用你手动操作。
            """)
        }

        if !info.git.isAvailable {
            warnings.append("""
            没找到 git，「Git」页面的提交 / 推送 / 拉取会不可用。
            Xcode 自带一份（`xcode-select --install`），或者 `brew install git`。
            """)
        }

        if let node = info.node.version, !isRecentEnough(node) {
            warnings.append("Node 版本是 \(node)，Hexo 8 建议 18 以上，可能会有兼容问题。")
        }

        return warnings
    }

    /// 在几个常见安装位置里找 node，用来判断「装了但 PATH 里没有」还是「压根没装」。
    private static func brewOrNvmNodePath() -> String? {
        let home = NSHomeDirectory()
        var candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node"
        ]

        // nvm 装了多个版本时取最后一个目录
        let versionsRoot = "\(home)/.nvm/versions/node"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: versionsRoot),
           let latest = entries.sorted().last {
            candidates.append("\(versionsRoot)/\(latest)/bin/node")
        }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 从 `v26.8.1` / `26.8.1` 里取出主版本号。
    private static func isRecentEnough(_ version: String) -> Bool {
        let cleaned = version.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        guard let major = Int(cleaned.split(separator: ".").first ?? "") else { return true }
        return major >= 18
    }
}

private extension ShellResult {
    /// 取输出里第一行，剥掉 v 前缀和多余空白。
    var cleanVersion: String? {
        guard success else { return nil }
        let first = output
            .split(separator: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) }?
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        return (first?.isEmpty ?? true) ? nil : first
    }
}
