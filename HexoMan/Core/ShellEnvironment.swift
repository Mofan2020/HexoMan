//
//  ShellEnvironment.swift
//  HexoMan
//
//  解决一个绕不过去的问题：从 Dock / 访达启动的图形程序，**不读** ~/.zshrc。
//
//  后果非常具体：用户终端里 `node` 是 /opt/homebrew/bin/node（brew shellenv 加的），
//  `hexo` 是 /usr/local/bin/hexo（npm global 装的），而 HexoMan 拿到的 PATH 只有
//  /usr/bin:/bin:/usr/sbin:/sbin —— 于是「明明装了 hexo，HexoMan 却说找不到」。
//
//  这里的做法是：起一个 zsh，按标准顺序把用户自己的 rc 文件 source 一遍，
//  再把 resulting environment 抓下来缓存起来。之后所有子进程直接继承这份环境。
//
//  为什么不每次都 `zsh -lc`？
//  实测用户的 .zshrc 里有 starship init、orbstack、brew shellenv，
//  一次 source 要 1~2 秒。git status 之类的轮询命令每条都付这个代价不可接受。
//  所以只在首次（或用户手动「重新读取」）时 bootstrap 一次，之后走缓存。
//
//  重要前提：HexoMan **不自带** node / npm / git / hexo。
//  一切都用用户自己装的那份，这样版本天然一致，也不会和应用沙箱里的副本打架。
//

import Foundation

/// 一次 shell bootstrap 的产物：用户真实的运行环境。
struct ShellEnvironment: Equatable {
    /// 抓下来的完整环境变量。会作为所有子进程的基础环境。
    var variables: [String: String]
    /// 实际 source 到的 rc 文件顺序（只含真实存在的）。
    var rcFiles: [String]
    /// 解析出的 PATH。
    var path: String

    /// 从 PATH 里找可执行文件。用于同步地判断「hexo 在不在」，省得为一次判断去起子进程。
    func executablePath(named name: String) -> String? {
        // 绝对路径直接放行
        if name.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: name) {
            return name
        }
        // 命令名里带路径分隔符（比如 node_modules/.bin/hexo）就没必要扫 PATH
        if name.contains("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// 给界面看的 PATH 摘要。
    ///
    /// 只挑 3 条最相关的。实测真实 PATH 有 40+ 项，全拼进一行会把
    /// DetailRow 挤成一条省略号，既不好看也看不出问题——用户真正要确认的
    /// 只是「/opt/homebrew/bin 在不在」这一件事。
    var pathSummary: String {
        let entries = path.split(separator: ":").map(String.init)
        // homebrew 最优先，因为它承载着需求点名要保证的 node
        let priority = ["homebrew", ".nvm", "/.local", "node"]
        var picked: [String] = []
        for keyword in priority {
            if let hit = entries.first(where: { $0.contains(keyword) }), picked.contains(hit) == false {
                picked.append(hit)
            }
            if picked.count >= 3 { break }
        }
        if picked.isEmpty {
            picked = Array(entries.prefix(3))
        }
        // 只留尾部两段：完整路径太长，而尾部两段足够区分
        // `/opt/homebrew/bin` 和 `/usr/local/bin` 这类同名末级目录。
        let shortened = picked.map { entry -> String in
            let parts = entry.split(separator: "/")
            return parts.count <= 2 ? entry : "…/" + parts.suffix(2).joined(separator: "/")
        }
        return shortened.joined(separator: " : ") + "（共 \(entries.count) 项）"
    }

    /// rc 文件的可读描述。
    var rcSummary: String {
        rcFiles.isEmpty ? "未找到 rc 文件" : rcFiles.map { ($0 as NSString).lastPathComponent }.joined(separator: " → ")
    }
}

/// 负责把「用户真实的 shell 环境」抓出来。
///
/// 单独一个类型而不是塞进 ShellRunner，是因为它有几条独立的判断逻辑：
/// rc 文件的定位、ZDOTDIR 的处理、哪些环境变量该丢、失败时怎么降级。
enum ShellEnvironmentResolver {

    /// zsh 启动文件，按 zsh 官方的加载顺序。
    /// `.zshenv` zsh 每次启动都读，`.zprofile` 登录 shell 读，`.zshrc` 交互 shell 读。
    private static let rcFileNames = [".zshenv", ".zprofile", ".zshrc"]

    /// 无论用户怎么配，这几个路径都该在 PATH 里。
    ///
    /// Homebrew 在 Apple Silicon 上的默认前缀就是 /opt/homebrew，
    /// 但它是靠 `brew shellenv` 往 PATH 里塞的 —— 用户的 .zprofile 里可能压根没写
    /// 那行（比如只 interactive 的时候才生效）。这里兜底加一次，
    /// 保证「装了 brew node 就一定能用」，这正是需求里点名要保证的事。
    static let fallbackPathEntries = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// 这些变量是 shell 运行时自己的状态，带进子进程只会让行为变怪，全部丢掉。
    ///
    /// 特别是 `SHLVL` / `ZSH_VERSION` / `RPROMPT` 之类，会让某些 npm 脚本以为自己
    /// 跑在交互 shell 里，从而跳过非交互处理直接调 `less` 或 `vim`，把 HexoMan 卡死。
    private static let droppedKeys: Set<String> = [
        "PWD", "OLDPWD", "SHLVL", "_", "ZSH_VERSION", "ZSH_NAME", "ZSH_PATCHLEVEL",
        "ZSH_ARGZERO", "RPROMPT", "RPS1", "PROMPT", "PS1", "COLUMNS", "LINES"
    ]

    /// 跑一次 bootstrap，把用户真实环境抓下来。
    ///
    /// - Parameters:
    ///   - customRCPath: 用户手动指定的 rc 文件。为空则自动找 $ZDOTDIR 下的标准三件套。
    ///   - workingDirectory: 探测时所在的目录，用站点目录最贴近实际使用场景。
    static func resolve(customRCPath: String = "", workingDirectory: String? = nil) async -> ShellEnvironment? {
        let directory = workingDirectory ?? NSHomeDirectory()
        let script = bootstrapScript(customRCPath: customRCPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        // 给子进程一个干净的起点：只剩 HOME 和最小 PATH，
        // 这样抓回来的 PATH 完全反映 rc 文件写了什么，而不是继承来的。
        process.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "USER": NSUserName(),
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        // rc 文件里的提示（`can not change option: monitor` 之类）在非交互 shell 下很常见，
        // 它们和我们要的结果无关，丢掉才不会污染 HexoMan 的日志面板。
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        return parse(data: data, customRCPath: customRCPath)
    }

    /// 拼出 bootstrap 脚本。
    ///
    /// 关键点：
    /// 1. rc 的输出和报错都丢掉 —— 用户 rc 里的 `echo`、警告不该出现在 HexoMan 日志里。
    /// 2. source 失败不能中断（`|| true`），用户 rc 里一个语法错误不该让整个环境探测失败。
    /// 3. 最后 `env -0` 输出 NUL 分隔的键值对，比 `printenv` 稳（不受 locale 和换行影响）。
    /// 4. 用 `exec env -0` 而不是 `env -0`，让子进程直接取代 shell，减少一层进程。
    nonisolated static func bootstrapScript(customRCPath: String) -> String {
        var lines: [String] = []

        if customRCPath.isEmpty == false {
            // 用户显式指定了 rc 文件，就只用它，不掺自动探测的结果
            lines.append("[ -f \(shellQuote(customRCPath)) ] && . \(shellQuote(customRCPath)) >/dev/null 2>&1 || true")
        } else {
            // ZDOTDIR 是 zsh 自己找 rc 的依据，优先用它，找不到才退回 $HOME。
            // 这里用 Swift raw string（#""#）：脚本里的 $ 和 " 原样输出，
            // 全交给 shell 展开。普通字符串里写 `\$` 是非法转义，容易踩。
            lines.append(#"ZD="${ZDOTDIR:-$HOME}""#)
            for name in rcFileNames {
                lines.append(#"[ -f "$ZD/\#(name)" ] && . "$ZD/\#(name)" >/dev/null 2>&1 || true"#)
            }
        }

        // 兜底 PATH。放在 source 之后**前置**到 PATH 前面 ——
        // 用户显式指定的版本优先，同时 brew 没配进 rc 时的常见前缀也不会漏掉。
        lines.append(#"case ":$PATH:" in"#)
        for entry in fallbackPathEntries {
            lines.append(#"  *":\#(entry):"*) ;;"#)
            lines.append(#"  *) PATH="\#(entry):$PATH" ;;"#)
        }
        lines.append("esac")
        lines.append("export PATH")
        lines.append("exec /usr/bin/env -0")
        return lines.joined(separator: "\n")
    }

    /// 解析 `env -0` 的输出。
    nonisolated static func parse(data: Data, customRCPath: String) -> ShellEnvironment? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var variables: [String: String] = [:]
        for entry in text.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[entry.startIndex..<separator])
            let value = String(entry[entry.index(after: separator)...])
            guard droppedKeys.contains(key) == false else { continue }
            variables[key] = value
        }

        guard let path = variables["PATH"], path.isEmpty == false else { return nil }
        // HOME 必须保留：很多 npm 脚本靠它找 ~/.npmrc 和缓存
        variables["HOME"] = variables["HOME"] ?? NSHomeDirectory()

        return ShellEnvironment(
            variables: variables,
            rcFiles: existingRCFiles(customRCPath: customRCPath),
            path: path
        )
    }

    /// 列出真正被 source 的 rc 文件，用于在界面上如实告诉用户「我读的是哪几个文件」。
    nonisolated static func existingRCFiles(customRCPath: String) -> [String] {
        if customRCPath.isEmpty == false {
            return FileManager.default.fileExists(atPath: customRCPath) ? [customRCPath] : []
        }
        let zdot = ProcessInfo.processInfo.environment["ZDOTDIR"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        return rcFileNames
            .map { (zdot as NSString).appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// 单引号包裹，内部的单引号按 POSIX 惯例转义。
    ///
    /// rc 路径来自用户输入，拼进脚本前必须过这一层，
    /// 否则路径里的引号和 `$` 会被 shell 展开，等于给了自己一个命令注入面。
    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
