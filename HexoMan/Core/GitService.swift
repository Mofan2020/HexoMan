//
//  GitService.swift
//  HexoMan
//
//  git 常用动作。命令都带 `-C <site>`，不切用户当前目录。
//

import Foundation

/// 一条提交记录。
struct GitCommit: Identifiable, Hashable {
    var shortHash: String
    var subject: String
    var author: String
    var date: Date?

    var id: String { shortHash }
}

/// 仓库当前状态。
struct GitStatus: Equatable {
    var branch: String = ""
    var upstream: String?
    var ahead: Int = 0
    var behind: Int = 0
    /// 已暂存的文件。
    var staged: [String] = []
    /// 已修改未暂存。
    var modified: [String] = []
    /// 未跟踪。
    var untracked: [String] = []
    /// 是否有冲突。
    var conflicted: [String] = []

    var isClean: Bool {
        staged.isEmpty && modified.isEmpty && untracked.isEmpty && conflicted.isEmpty
    }

    var changeCount: Int {
        staged.count + modified.count + untracked.count + conflicted.count
    }

    /// 工作区一句话摘要。
    var summary: String {
        if isClean { return "工作区干净" }
        var parts: [String] = []
        if !staged.isEmpty { parts.append("已暂存 \(staged.count)") }
        if !modified.isEmpty { parts.append("已修改 \(modified.count)") }
        if !untracked.isEmpty { parts.append("未跟踪 \(untracked.count)") }
        if !conflicted.isEmpty { parts.append("冲突 \(conflicted.count)") }
        return parts.joined(separator: " · ")
    }
}

/// git 命令封装。
enum GitService {

    /// 读一次状态。用 porcelain v2 格式，字段稳定好解析。
    static func status(site: HexoSite, runner: ShellRunner) async -> GitStatus? {
        let result = await runner.run(
            "git status",
            executable: "git",
            arguments: ["-C", site.path, "status", "--porcelain=v2", "--branch"],
            workingDirectory: site.path
        )

        guard result.success else { return nil }
        return parsePorcelainV2(result.output)
    }

    /// 解析 `git status --porcelain=v2 --branch` 的输出。
    static func parsePorcelainV2(_ output: String) -> GitStatus {
        var status = GitStatus()

        for line in output.components(separatedBy: .newlines) {
            // 头部三行形如 `# branch.head main`。
            // 注意必须先按已知前缀切掉再取值——早先按第一个空格切，
            // 结果把「branch.head」当成了分支名。
            if line.hasPrefix("# branch.head") {
                let value = Self.value(after: "# branch.head", in: line)
                status.branch = value == "(detached)" ? "游离 HEAD" : value
                continue
            }
            if line.hasPrefix("# branch.upstream") {
                let value = Self.value(after: "# branch.upstream", in: line)
                status.upstream = value.isEmpty ? nil : value
                continue
            }
            if line.hasPrefix("# branch.ab") {
                // 形如 `# branch.ab +1 -2`，分别是 ahead / behind
                let rest = Self.value(after: "# branch.ab", in: line)
                for token in rest.split(separator: " ") {
                    let text = String(token)
                    if text.hasPrefix("+") { status.ahead = Int(text.dropFirst()) ?? 0 }
                    if text.hasPrefix("-") { status.behind = Int(text.dropFirst()) ?? 0 }
                }
                continue
            }

            // 普通条目：XY <path> 或 XY <from> -> <to>
            guard let first = line.first else { continue }
            let index = line.firstIndex(of: " ")
            guard let space = index else { continue }
            let code = String(line[line.startIndex..<space])
            var path = String(line[line.index(after: space)...])
            if let arrow = path.range(of: " -> ") {
                path = String(path[arrow.upperBound...])
            }

            switch first {
            case "?":
                status.untracked.append(path)
            case "u":
                status.conflicted.append(path)
            case "1", "2":
                // 普通变更：X 是暂存区状态，Y 是工作区状态
                let chars = Array(code)
                guard chars.count >= 2 else { continue }
                if chars[0] != "." { status.staged.append(path) }
                if chars[1] != "." { status.modified.append(path) }
            default:
                continue
            }
        }

        return status
    }

    /// 切掉已知前缀，返回剩下的值并去掉两端空白。
    private static func value(after prefix: String, in line: String) -> String {
        guard line.hasPrefix(prefix) else { return "" }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// 读最近提交。
    static func log(site: HexoSite, runner: ShellRunner, limit: Int = 20) async -> [GitCommit] {
        let result = await runner.run(
            "git log",
            executable: "git",
            arguments: ["-C", site.path, "log", "-\(limit)", "--pretty=format:%h%x09%an%x09%ad%x09%s", "--date=short"],
            workingDirectory: site.path
        )

        guard result.success else { return [] }

        return result.output.components(separatedBy: .newlines).compactMap { line in
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 4 else { return nil }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            return GitCommit(
                shortHash: fields[0],
                subject: fields[3],
                author: fields[1],
                date: formatter.date(from: fields[2])
            )
        }
    }

    /// 暂存全部改动后提交。
    static func commit(site: HexoSite, message: String, runner: ShellRunner) async -> ShellResult {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ShellResult(exitCode: 1, output: "提交信息为空")
        }

        let add = await runner.run(
            "git add",
            executable: "git",
            arguments: ["-C", site.path, "add", "-A"],
            workingDirectory: site.path
        )
        guard add.success else { return add }

        return await runner.run(
            "git commit",
            executable: "git",
            arguments: ["-C", site.path, "commit", "-m", trimmed],
            workingDirectory: site.path
        )
    }

    static func push(site: HexoSite, runner: ShellRunner) async -> ShellResult {
        await runner.run(
            "git push",
            executable: "git",
            arguments: ["-C", site.path, "push"],
            workingDirectory: site.path
        )
    }

    static func pull(site: HexoSite, runner: ShellRunner) async -> ShellResult {
        await runner.run(
            "git pull",
            executable: "git",
            arguments: ["-C", site.path, "pull", "--rebase"],
            workingDirectory: site.path
        )
    }

    /// 列出远端。
    static func remotes(site: HexoSite) -> [String] {
        let gitConfig = (site.path as NSString).appendingPathComponent(".git/config")
        guard let text = try? String(contentsOfFile: gitConfig, encoding: .utf8) else { return [] }

        var remotes: [String] = []
        var current: String?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[remote") {
                if let name = line
                    .replacingOccurrences(of: "[remote \"", with: "")
                    .replacingOccurrences(of: "\"]", with: "")
                    .components(separatedBy: " ").first {
                    current = name
                }
                continue
            }
            if let remote = current, line.hasPrefix("url") {
                if let url = line.split(separator: "=", maxSplits: 1).last {
                    remotes.append("\(remote) → \(url.trimmingCharacters(in: .whitespaces))")
                }
                current = nil
            }
        }

        return remotes
    }
}
