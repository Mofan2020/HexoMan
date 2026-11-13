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
    /// 是否自动把站点配置里的公共项同步到主题配置。
    ///
    /// 默认为 true。头像、favicon、标题这类值在 `_config.yml` 和
    /// `_config.<主题>.yml` 里各写一份是 Hexo 生态的常态，
    /// 而**主题通常优先读自己那份**——于是用户改了站点配置的头像却发现没反应，
    /// 反复怀疑是不是自己操作错了。默认同步掉这个坑。
    ///
    /// 关掉后两个文件各管各的，适合故意让主题配置覆盖站点配置的场景。
    var syncsThemeConfig: Bool = true

    /// UI 语言档。`"system"` / `"zh-Hans"` / `"en"` / `"ja"`。
    ///
    /// 默认 `"system"`——开箱即用跟系统走，避免新装用户看到一个"语言设置"弹窗。
    /// 用户主动切到某语言后会落到 `settings.json`，下次启动继续生效。
    ///
    /// 字段缺失时 `SettingsStore.load()` 走 decoder 的自动兼容返回默认，
    /// 所以即便旧 settings.json 没这个字段也能跑（见 SettingsStore.load）。
    var language: String = AppLanguage.system.rawValue

    /// 是否允许 HexoMan 在主题市场里联网补全（调 npm registry 拉包元数据）。
    ///
    /// 默认 false——开箱即用是离线模式，避免用户没注意就被联出去。
    /// 用户首次进主题市场时会看到「网络访问说明」sheet，
    /// 同意后才打开此项。详情见 ThemeRegistry.swift 的注释。
    var onlineThemeSearch: Bool = false

    /// 用户是否勾了「不再询问联网同意弹窗」。
    /// 勾了就别再弹——开关仍能在设置项里改回。
    var dontAskOnlineConsent: Bool = false

    /// 预览时是否连草稿一起渲染（`hexo server --draft`）。
    ///
    /// 默认 false：草稿是没写完的东西，默认不进预览更符合直觉。但写草稿的
    /// 时候想看效果，就得有这一档，否则只能先取消草稿标记。
    var previewDrafts: Bool = false

    static let defaultPort = 4000

    init() {}

    /// **逐字段容错解码。**
    ///
    /// Swift 合成的 `init(from:)` 遇到缺字段直接抛 `keyNotFound`，而
    /// `SettingsStore.load()` 一旦抛就退回全套出厂设置——所以只要新版本加了
    /// 一个字段，老用户的站点列表、自定义 hexo 路径、语言选择会一起消失，
    /// 而且没有任何提示。这里每个字段都 `decodeIfPresent`，缺的用默认值。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings()
        sites = try container.decodeIfPresent([HexoSite].self, forKey: .sites) ?? fallback.sites
        lastSitePath = try container.decodeIfPresent(String.self, forKey: .lastSitePath)
        serverPort = try container.decodeIfPresent(Int.self, forKey: .serverPort) ?? fallback.serverPort
        autoScrollLog = try container.decodeIfPresent(Bool.self, forKey: .autoScrollLog) ?? fallback.autoScrollLog
        customHexoPath = try container.decodeIfPresent(String.self, forKey: .customHexoPath) ?? fallback.customHexoPath
        usesShellEnvironment = try container.decodeIfPresent(Bool.self, forKey: .usesShellEnvironment) ?? fallback.usesShellEnvironment
        customRCPath = try container.decodeIfPresent(String.self, forKey: .customRCPath) ?? fallback.customRCPath
        syncsThemeConfig = try container.decodeIfPresent(Bool.self, forKey: .syncsThemeConfig) ?? fallback.syncsThemeConfig
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? fallback.language
        onlineThemeSearch = try container.decodeIfPresent(Bool.self, forKey: .onlineThemeSearch) ?? fallback.onlineThemeSearch
        dontAskOnlineConsent = try container.decodeIfPresent(Bool.self, forKey: .dontAskOnlineConsent) ?? fallback.dontAskOnlineConsent
        previewDrafts = try container.decodeIfPresent(Bool.self, forKey: .previewDrafts) ?? fallback.previewDrafts
    }
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
