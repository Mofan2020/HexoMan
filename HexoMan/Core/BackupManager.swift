//
//  BackupManager.swift
//  HexoMan
//
//  站点备份与恢复。只备份「内容 + 配置」，不备份 node_modules/public 这种可重建的东西。
//

import Foundation

enum BackupManager {

    /// 备份条目
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

    /// 默认备份目录
    static var backupDirectory: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("HexoMan/Backups", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 创建备份
    static func createBackup(for site: HexoSite) async throws -> BackupEntry {
        let fm = FileManager.default
        let timestamp = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let timeStr = dateFormatter.string(from: timestamp)

        let siteName = site.folderName
        let backupName = "\(siteName)-\(timeStr).zip"
        let backupURL = backupDirectory.appendingPathComponent(backupName)

        // 使用 zip 递归压缩当前目录，排除不需要的目录/文件
        // 这样避免 "nothing to select from" 错误：不显式指定包含模式，而是全量备份再排除
        let zipArgs = [
            "-r", backupURL.path,
            ".",
            "-x", "*/node_modules/*",
            "-x", "*/public/*",
            "-x", "*/.git/*",
            "-x", "*/*.log",
            "-x", "*/.DS_Store"
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = zipArgs
        process.currentDirectoryURL = URL(fileURLWithPath: site.path)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? "未知错误"
            throw BackupError.zipFailed(output)
        }

        let attributes = try fm.attributesOfItem(atPath: backupURL.path)
        let size = attributes[.size] as? Int64 ?? 0

        // 统计文件数（近似）：解压列表数一下
        let countProcess = Process()
        countProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        countProcess.arguments = ["-l", backupURL.path]
        let countPipe = Pipe()
        countProcess.standardOutput = countPipe
        try countProcess.run()
        countProcess.waitUntilExit()
        var fileCount = 0
        if countProcess.terminationStatus == 0 {
            let data = countPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            // unzip -l 输出最后一行包含总文件数
            fileCount = output.split(separator: "\n").last?.split(separator: " ").first.flatMap { Int($0) } ?? 0
        }

        return BackupEntry(
            id: UUID(),
            sitePath: site.path,
            date: timestamp,
            size: size,
            fileCount: fileCount,
            path: backupURL.path
        )
    }

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

    /// 恢复备份
    static func restoreBackup(_ entry: BackupEntry, to sitePath: String) async throws {
        let fm = FileManager.default
        let siteURL = URL(fileURLWithPath: sitePath)

        // 解压到临时目录
        let tempDir = fm.temporaryDirectory.appendingPathComponent("hexoman-restore-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", entry.path, "-d", tempDir.path]
        process.currentDirectoryURL = siteURL

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? "未知错误"
            throw BackupError.unzipFailed(output)
        }

        // 复制文件到站点目录（覆盖）
        let sourceDir = tempDir.appendingPathComponent((sitePath as NSString).lastPathComponent)
        let restoredFiles = try fm.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil)
        for file in restoredFiles {
            let dest = siteURL.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: file, to: dest)
        }

        // 清理临时目录
        try? fm.removeItem(at: tempDir)
    }

    /// 删除备份
    static func deleteBackup(_ entry: BackupEntry) throws {
        try FileManager.default.removeItem(atPath: entry.path)
    }

    enum BackupError: LocalizedError {
        case zipFailed(String)
        case unzipFailed(String)
        case invalidBackup

        var errorDescription: String? {
            switch self {
            case .zipFailed(let msg): return "备份压缩失败：\(msg)"
            case .unzipFailed(let msg): return "备份解压失败：\(msg)"
            case .invalidBackup: return "无效的备份文件"
            }
        }
    }
}