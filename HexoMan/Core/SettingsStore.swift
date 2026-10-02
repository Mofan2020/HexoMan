//
//  SettingsStore.swift
//  HexoMan
//
//  本地配置持久化：站点列表、上次选中的站点、预览端口。
//

import Foundation

/// 落盘的设置。放 Application Support，不污染用户 home。
struct AppSettings: Codable {
    /// 已知站点，按上次打开时间倒序存。
    var sites: [HexoSite] = []
    /// 上次打开的站点路径。
    var lastSitePath: String?
    /// 预览端口。
    var serverPort: Int = 4000
    /// 日志是否自动滚动到底。
    var autoScrollLog: Bool = true
    /// 用户手动指定的 hexo 可执行文件路径。空表示用自动探测。
    var customHexoPath: String = ""
    /// 是否通过 zsh 读取用户自己的 rc 文件来获得真实 PATH。
    ///
    /// 默认为 true —— 这是让 brew 装的 node 可见的唯一办法。
    /// 关掉就退回 app 启动时继承到的环境（通常只有系统四个目录），基本等于什么都找不到。
    var usesShellEnvironment: Bool = true
    /// 用户手动指定的 zsh rc 文件路径。空表示自动按 $ZDOTDIR → $HOME 找 .zshenv/.zprofile/.zshrc。
    var customRCPath: String = ""

    static let defaultPort = 4000
}

/// 读写 `~/Library/Application Support/HexoMan/settings.json`。
enum SettingsStore {

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("HexoMan", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    static func save(_ settings: AppSettings) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
