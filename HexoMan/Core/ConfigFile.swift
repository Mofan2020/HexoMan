//
//  ConfigFile.swift
//  HexoMan
//
//  站点配置文件（_config.yml 及主题配置）的读写。
//

import Foundation

/// 一个可编辑的配置文件。
struct ConfigFile: Identifiable, Hashable {
    /// 绝对路径。
    var path: String
    /// 展示名。
    var name: String
    /// 一句话说明它管什么。
    var subtitle: String = ""
    /// 当前编辑器里的内容。
    var contents: String = ""
    /// 磁盘上的原始内容，用来判断有没有改过。
    fileprivate var originalContents: String = ""

    var id: String { path }

    var isModified: Bool { contents != originalContents }

    /// 顶层配置键，编辑器侧栏用来快速跳转。
    var topLevelKeys: [String] {
        YAMLScalars.parse(contents).keys.sorted()
    }
}

/// 站点根目录下所有 `_config*.yml`。
enum ConfigStore {

    /// 列出站点配置。主配置排第一，主题配置按名字排。
    static func list(site: HexoSite) -> [ConfigFile] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: site.path)

        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return [] }

        let candidates = entries
            .filter { $0.lastPathComponent.hasPrefix("_config") && $0.pathExtension == "yml" }
            .map { $0.lastPathComponent }
            .sorted { lhs, rhs in
                // _config.yml 永远第一
                if lhs == "_config.yml" { return true }
                if rhs == "_config.yml" { return false }
                return lhs < rhs
            }

        return candidates.compactMap { filename -> ConfigFile? in
            let path = root.appendingPathComponent(filename).path
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }

            var file = ConfigFile(path: path, name: filename, contents: contents)
            file.originalContents = contents
            file.subtitle = describe(filename)
            return file
        }
    }

    /// 文件名 → 人话解释。
    private static func describe(_ filename: String) -> String {
        if filename == "_config.yml" { return "站点主配置" }

        let theme = filename
            .replacingOccurrences(of: "_config.", with: "")
            .replacingOccurrences(of: ".yml", with: "")
        return "主题配置（\(theme)）"
    }

    /// 读一个文件。
    static func load(path: String) -> ConfigFile {
        let contents = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var file = ConfigFile(
            path: path,
            name: (path as NSString).lastPathComponent,
            contents: contents
        )
        file.originalContents = contents
        return file
    }

    /// 写回磁盘。写成功后同步 baseline，避免「已保存」却还显示未保存。
    static func save(_ file: ConfigFile) throws {
        // 确保目录存在
        let directory = (file.path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)
        
        // 写入文件
        try file.contents.write(to: URL(fileURLWithPath: file.path), atomically: true, encoding: .utf8)
        
        // 验证写入是否成功
        let savedContent = try String(contentsOfFile: file.path, encoding: .utf8)
        guard savedContent == file.contents else {
            throw ConfigStoreError.writeVerificationFailed(file.path)
        }
    }

    /// 存盘后把新内容设为基准，使 `isModified` 归零。
    static func markSaved(_ file: ConfigFile) -> ConfigFile {
        var updated = file
        updated.originalContents = file.contents
        return updated
    }

    enum ConfigStoreError: LocalizedError {
        case writeVerificationFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .writeVerificationFailed(let path):
                return "文件写入验证失败：\(path) 内容与预期不符"
            }
        }
    }
}
