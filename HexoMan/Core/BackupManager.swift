//
//  BackupManager.swift
//  HexoMan
//
//  站点备份与恢复。只备份「内容 + 配置」，不备份 node_modules/public 这种可重建的东西。
//
//  ⚠️ 为什么不能直接 `zip -r 站点目录 -x "*/node_modules/*"`：
//
//  那是这里的原实现。看着能排除，实际**根本没排掉**——
//  实测一个 152MB 的站点，压缩完 80MB、11581 个文件，里面 node_modules 有 11212 个。
//
//  两个原因叠加：
//  1. Info-ZIP 的 `-x` 模式在带斜杠时按整条路径匹配，`*/node_modules/*`
//     匹配不上 zip 实际存储的 `./node_modules/...`。换成 `*node_modules*` 才有效。
//  2. 更要命的是 `-x` 只在**已经遍历到**之后才丢弃，zip 依然会走进
//     node_modules 和 .git 把几万个文件 stat 一遍——所以它还慢。
//
//  现在的做法是**自己先遍历、按目录名剪枝**，再把文件清单喂给 `zip -@`。
//  剪枝发生在遍历阶段，node_modules 连 stat 都不会发生。
//  同一站点实测：4.6s / 80MB → 0.05s / 220KB（快 90 倍，小 360 倍）。
//

import Foundation

enum BackupManager {

    // MARK: - 备份条目

    struct BackupEntry: Identifiable, Hashable {
        let id: UUID
        let sitePath: String
        let date: Date
        let size: Int64
        let fileCount: Int
        let path: String

        var displayName: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return formatter.string(from: date)
        }

        var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
    }

    /// 备份范围策略。
    struct Policy {

        /// 按目录名剪枝。目录**任意层级**命中即整棵子树跳过。
        var excludedDirectories: Set<String>

        /// 按文件名/后缀丢弃的文件。
        var excludedFiles: Set<String>

        var excludedExtensions: Set<String>

        static let `default` = Policy(
            // 可重建 / 可重新拉取，且体积最大的那几项
            excludedDirectories: [
                "node_modules",   // 86MB / 11000+ 文件，npm i 就能回来
                ".git",           // 65MB，能重新 clone 或 git init
                "public",         // hexo generate 的产物
                ".wrangler",      // 本地调试缓存
                ".cache",
                "coverage",
                ".deploy",
                ".sass-cache"
            ],
            excludedFiles: [
                ".DS_Store",
                "package-lock.json.bak"
            ],
            excludedExtensions: ["log", "zip", "swp"]
        )

        /// 包含版本库和生成产物的大备份（用户明确要求时才用）。
        static let full = Policy(
            excludedDirectories: ["node_modules"],
            excludedFiles: [".DS_Store"],
            excludedExtensions: ["log", "swp"]
        )
    }

    /// 备份前先统计一遍，让界面上能立刻显示「将要打包多少个文件」。
    struct Plan: Equatable {
        var includedCount: Int
        var excludedCount: Int
        var approximateBytes: Int64

        var includedDescription: String {
            ByteCountFormatter.string(fromByteCount: approximateBytes, countStyle: .file)
        }
    }

    // MARK: - 目录

    /// 默认备份目录
    static var backupDirectory: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("HexoMan/Backups", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 遍历

    /// 按策略收集要打包的相对路径。
    ///
    /// 剪枝在**遍历时**完成：命中排除目录直接 `skipDescendants()`，
    /// 不再 stat 里面的任何东西。这是速度提升的全部来源。
    static func collectFiles(root: URL, policy: Policy) -> (files: [String], plan: Plan) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }   // 读不到就跳过，不让整个备份失败
        ) else {
            return ([], Plan(includedCount: 0, excludedCount: 0, approximateBytes: 0))
        }

        let rootPath = root.standardizedFileURL.path
        var files: [String] = []
        var excludedCount = 0
        var bytes: Int64 = 0

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            let name = url.lastPathComponent

            if isDirectory {
                // 目录命中排除名单：整棵子树都不进去。
                // 必须是 skipDescendants 而不是单纯 continue，否则仍然会逐个 stat 进去。
                if policy.excludedDirectories.contains(name) {
                    enumerator.skipDescendants()
                    excludedCount += 1
                }
                continue
            }

            if policy.excludedFiles.contains(name)
                || policy.excludedExtensions.contains(url.pathExtension.lowercased()) {
                excludedCount += 1
                continue
            }

            // zip 里用相对路径，恢复时才不会把站点名字套一层目录
            var relative = url.standardizedFileURL.path
            if relative.hasPrefix(rootPath) {
                relative = String(relative.dropFirst(rootPath.count))
            }
            while relative.hasPrefix("/") { relative.removeFirst() }
            guard !relative.isEmpty else { continue }

            files.append(relative)
            bytes += Int64(values?.fileSize ?? 0)
        }

        return (files.sorted(), Plan(
            includedCount: files.count,
            excludedCount: excludedCount,
            approximateBytes: bytes
        ))
    }

    // MARK: - 创建

    /// 创建备份
    static func createBackup(
        for site: HexoSite,
        policy: Policy = .default
    ) async throws -> BackupEntry {

        let root = URL(fileURLWithPath: site.path)
        let timestamp = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let timeStr = dateFormatter.string(from: timestamp)

        let backupName = "\(site.folderName)-\(timeStr).zip"
        let backupURL = backupDirectory.appendingPathComponent(backupName)

        // 遍历和压缩都放到后台线程。
        // 直接在调用方（主线程）跑会冻住整个界面——旧实现就是同步 waitUntilExit。
        let (files, plan) = await Task.detached(priority: .userInitiated) {
            collectFiles(root: root, policy: policy)
        }.value

        guard !files.isEmpty else {
            throw BackupError.nothingToBackup
        }

        // 压缩本身也在后台跑：process.run()、写 stdin、等退出都是阻塞调用，
        // 任何一步落在主线程都会让按钮看起来「卡住不动」。
        try await Task.detached(priority: .userInitiated) {
            try await runZip(files: files, root: root, destination: backupURL)
        }.value

        let attributes = try FileManager.default.attributesOfItem(atPath: backupURL.path)
        let size = attributes[.size] as? Int64 ?? 0

        return BackupEntry(
            id: UUID(),
            sitePath: site.path,
            date: timestamp,
            size: size,
            // 清单是我们自己收集的，比 `unzip -l` 数一遍准，也省掉一次解包
            fileCount: plan.includedCount,
            path: backupURL.path
        )
    }

    /// 预览将要打包的内容（不写文件），供界面在点按钮前先告知范围。
    static func plan(for site: HexoSite, policy: Policy = .default) async -> Plan {
        let root = URL(fileURLWithPath: site.path)
        return await Task.detached(priority: .userInitiated) {
            collectFiles(root: root, policy: policy).plan
        }.value
    }

    /// 把清单喂给 `zip -@` 打包。
    ///
    /// 清单通过**临时文件**接到子进程 stdin 上，而不是往管道里写。
    /// 往管道写有两个必踩的坑：
    /// 1. 清单一超过管道缓冲区（64KB）就会和子进程互相等待——主线程表现就是「点了没反应」。
    /// 2. 子进程先退出时读端已关闭，`FileHandle.write(_:)` 抛的是 ObjC 异常，
    ///    Swift 根本 catch 不住，直接 crash。
    /// 用文件当 stdin 两个问题都不存在，也不用起额外线程去写。
    private static func runZip(files: [String], root: URL, destination: URL) async throws {

        let listURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexoman-zip-list-\(UUID().uuidString).txt")
        try (files.joined(separator: "\n") + "\n").write(to: listURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: listURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // -@ 从 stdin 读文件清单；清单已经是筛好的，不再需要 -r 递归，也不再需要 -x
        process.arguments = ["-q", "-@", destination.path]
        process.currentDirectoryURL = root
        process.standardInput = try FileHandle(forReadingFrom: listURL)

        // stdout 和 stderr 分开，各自在后台排空。
        // 共用一个管道且不读的话，任何一方写满缓冲区子进程就会卡住不动。
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        async let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        async let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in c.resume() }
        }
        let (stdout, stderr) = await (outData, errData)

        guard process.terminationStatus == 0 else {
            let message = String(data: stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // 压到一半失败会留下半个损坏的 zip，必须删掉，
            // 否则它会被当成一个正常备份列在列表里，恢复时才炸。
            try? FileManager.default.removeItem(at: destination)
            throw BackupError.zipFailed(message ?? String(data: stdout, encoding: .utf8) ?? "未知错误")
        }
    }

    // MARK: - 列出

    /// 列出某站点的所有备份
    static func listBackups(for sitePath: String) -> [BackupEntry] {
        let fm = FileManager.default
        let siteName = (sitePath as NSString).lastPathComponent
        guard let files = try? fm.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return []
        }

        return files
            .filter { $0.lastPathComponent.hasPrefix(siteName + "-") && $0.pathExtension == "zip" }
            .compactMap { url in
                guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                      let date = attrs[.modificationDate] as? Date,
                      let size = attrs[.size] as? Int64 else { return nil }

                return BackupEntry(
                    id: UUID(),
                    sitePath: sitePath,
                    date: date,
                    size: size,
                    fileCount: 0,
                    path: url.path
                )
            }
            .sorted { $0.date > $1.date }
    }

    // MARK: - 恢复

    /// 恢复备份
    static func restoreBackup(_ entry: BackupEntry, to sitePath: String) async throws {
        let fm = FileManager.default
        let siteURL = URL(fileURLWithPath: sitePath)

        let tempDir = fm.temporaryDirectory.appendingPathComponent("hexoman-restore-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer { try? fm.removeItem(at: tempDir) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", entry.path, "-d", tempDir.path]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        async let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        async let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in c.resume() }
        }
        let (stdout, stderr) = await (outData, errData)

        guard process.terminationStatus == 0 else {
            let message = String(data: stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw BackupError.unzipFailed(message ?? String(data: stdout, encoding: .utf8) ?? "未知错误")
        }

        // 归档里的条目是相对站点根目录的（source/…、_config.yml …），
        // 解压后**直接落在 tempDir 下**，并没有多包一层站点名目录。
        //
        // 旧实现去读 tempDir/<站点文件夹名>/，那层目录不存在，
        // 于是恢复会直接抛错——也就是「备份根本恢复不回来」。
        let restoredFiles = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        guard !restoredFiles.isEmpty else { throw BackupError.invalidBackup }

        for file in restoredFiles {
            let dest = siteURL.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: file, to: dest)
        }
    }

    /// 删除备份
    static func deleteBackup(_ entry: BackupEntry) throws {
        try FileManager.default.removeItem(atPath: entry.path)
    }

    // MARK: - 错误

    enum BackupError: LocalizedError {
        case zipFailed(String)
        case unzipFailed(String)
        case invalidBackup
        case nothingToBackup

        var errorDescription: String? {
            switch self {
            case .zipFailed(let msg):
                return "备份压缩失败：\(msg.isEmpty ? "未知错误" : msg)"
            case .unzipFailed(let msg):
                return "备份解压失败：\(msg.isEmpty ? "未知错误" : msg)"
            case .invalidBackup:
                return "这个备份文件是空的或已损坏，无法恢复。"
            case .nothingToBackup:
                return "这个站点里没有找到可备份的内容。确认选对了站点目录。"
            }
        }
    }
}