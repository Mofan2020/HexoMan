//
//  ThemeManager.swift
//  HexoMan
//
//  主题的扫描、切换与配置。
//
//  为什么单独做：用户抱怨「能管理的东西太少」，而换主题是 Hexo 用户最高频
//  的操作之一。原来的做法是让人自己去改 `_config.yml` 里的 `theme: yun`，
// 改错了就是白屏，而且装主题要自己去敲 npm 命令。
//
//  关键事实：主题装在 `node_modules/hexo-theme-*`，**不在** `themes/` 目录里。
//  `themes/` 只是空壳，Hexo 会优先找本地主题目录，找不到才用 node_modules。
//  所以扫主题要扫 node_modules，不是扫 themes/。
//

import Foundation

/// 一个已安装的主题。
struct InstalledTheme: Identifiable, Hashable {

    /// 包名去掉 `hexo-theme-` 前缀，如 `hexo-theme-yun` → `yun`
    var name: String
    /// 完整包名
    var packageName: String
    /// 版本号
    var version: String
    /// 一句话描述
    var description: String
    /// 主题自带的示例配置路径（themes/<name>/_config.yml）
    var sampleConfigPath: String?
    /// 这个主题的配置文件在站点根目录叫什么
    var configFileName: String
    /// 是否是当前使用的
    var isActive: Bool

    var id: String { packageName }

    /// 站点里是否已有这个主题的配置文件
    var hasSiteConfig: Bool = false
}

/// 主题市场的精选列表。
///
/// 只给几十个widely used 的主题，而不是全量 npm 搜索——
/// 全量搜索要联网、结果几百个，小白根本选不出来。
/// 这里的每个都是 Hexo 生态里口碑好、文档全的。
struct ThemeCatalog {

    struct Item: Identifiable {
        var name: String
        var packageName: String
        var summary: String
        var author: String
        /// 官网/仓库
        var homepage: String
        var id: String { packageName }
    }

    static let items: [Item] = [
        .init(name: "yun", packageName: "hexo-theme-yun", summary: "现代化三栏主题，亮暗双模式，配色可调，中文文档完善", author: "yunyoujun", homepage: "https://yun.yunyoujun.cn"),
        .init(name: "landscape", packageName: "hexo-theme-landscape", summary: "Hexo 官方默认主题，四栏布局，稳��不出错", author: "hexo", homepage: "https://hexo.io/themes/"),
        .init(name: "next", packageName: "hexo-theme-next", summary: "功能最全的主题，集成站内搜索、动态背景、多说等", author: "theme-next", homepage: "https://theme-next.org"),
        .init(name: "Fluid", packageName: "hexo-theme-fluid", summary: " fluid 风格，首页大图瀑布流，适合图片多的站", author: "fluid-dev", homepage: "https://fluid-dev.github.io"),
        .init(name: "Matery", packageName: "hexo-theme-matery", summary: "Material 风格，分类标签齐全，适合技术博客", author: "Tuigug", homepage: "https://theme.matery.ink"),
        .init(name: "whiskers", packageName: "hexo-theme-whiskers", summary: "简洁清爽，时间线布局", author: "porridge", homepage: "https://github.com/porridge/hexo-theme-whiskers"),
        .init(name: "volantis", packageName: "hexo-theme-volantis", summary: "功能丰富，社交插件多，社区活跃", author: "Etheme", homepage: "https://volantis.theme-best.com"),
        .init(name: "reimu", packageName: "hexo-theme-reimu", summary: "二次元风格，首页角色立绘", author: "TRSS", homepage: "https://github.com/TRSS-Yukari/reimu"),
        .init(name: "solitude", packageName: "hexo-theme-solitude", summary: "简洁的卡片式布局", author: "solitude", homepage: "https://github.com/valor-x"),
        .init(name: "Anima", packageName: "hexo-theme-anima", summary: "暗色为主，动画细腻", author: "anima", homepage: "https://github.com/anima-theme/anima")
    ]

    static func find(_ name: String) -> Item? {
        items.first { $0.name == name }
    }
}

/// 主题相关操作。
enum ThemeManager {

    /// 扫描站点里已安装的所有主题。
    ///
    /// 扫 `node_modules/hexo-theme-*`，而不是 `themes/`——
    /// 后者通常是空的，扫了等于没扫。
    static func installed(site: HexoSite, activeName: String?) -> [InstalledTheme] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: site.path)
        let modules = root.appendingPathComponent("node_modules")
        let themesDir = root.appendingPathComponent("themes")

        var themes: [InstalledTheme] = []

        // node_modules 里的（npm 装的）
        if let entries = try? fm.contentsOfDirectory(at: modules, includingPropertiesForKeys: nil) {
            for entry in entries {
                let packageName = entry.lastPathComponent
                guard packageName.hasPrefix("hexo-theme-") else { continue }
                let name = String(packageName.dropFirst("hexo-theme-".count))
                let meta = readPackageJSON(entry.appendingPathComponent("package.json"))
                let configName = "_config.\(name).yml"
                themes.append(InstalledTheme(
                    name: name,
                    packageName: packageName,
                    version: meta?.version ?? "未知",
                    description: meta?.description ?? "",
                    sampleConfigPath: sampleConfigPath(themesDir: themesDir, name: name),
                    configFileName: configName,
                    isActive: name == activeName,
                    hasSiteConfig: fm.fileExists(atPath: root.appendingPathComponent(configName).path)
                ))
            }
        }

        // themes/ 目录里的（手动放的）也要认
        if let entries = try? fm.contentsOfDirectory(at: themesDir, includingPropertiesForKeys: nil) {
            for entry in entries {
                let name = entry.lastPathComponent
                guard name != ".gitkeep", !name.hasPrefix(".") else { continue }
                guard !themes.contains(where: { $0.name == name }) else { continue }
                let configName = "_config.\(name).yml"
                themes.append(InstalledTheme(
                    name: name,
                    packageName: "hexo-theme-\(name)",
                    version: "本地",
                    description: "themes 目录里的本地主题",
                    sampleConfigPath: entry.appendingPathComponent("_config.yml").path,
                    configFileName: configName,
                    isActive: name == activeName,
                    hasSiteConfig: fm.fileExists(atPath: root.appendingPathComponent(configName).path)
                ))
            }
        }

        // 当前主题排最前
        themes.sort { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return lhs.name < rhs.name
        }
        return themes
    }

    /// 主题自带示例配置（npm 包里只有 `_config.yml`，不带包名前缀）。
    private static func sampleConfigPath(themesDir: URL, name: String) -> String? {
        let path = themesDir.appendingPathComponent("\(name)/_config.yml").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// 读 package.json 的两个字段。
    private struct PackageMeta {
        var version: String
        var description: String
    }

    private static func readPackageJSON(_ url: URL) -> PackageMeta? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return PackageMeta(
            version: object["version"] as? String ?? "未知",
            description: object["description"] as? String ?? ""
        )
    }

    /// 切换主题：改主配置里的 `theme:` 键。
    ///
    /// 只改 `theme` 这一个键，别的一概不碰——
    /// 换主题时如果顺手重排了整个 `_config.yml`，用户没法 review，出了问题也难回滚。
    static func switchTheme(site: HexoSite, to theme: InstalledTheme) throws {
        let configPath = site.path + "/_config.yml"
        let text = try String(contentsOfFile: configPath, encoding: .utf8)
        var document = YAMLDocument(text: text)

        let result = document.set(theme.name, at: ["theme"], hint: .text)
        switch result {
        case .success(let updated):
            try updated.text.write(toFile: configPath, atomically: true, encoding: .utf8)
        case .failure(let error):
            throw error
        }
    }

    /// 把主题的示例配置复制成站点的 `_config.<name>.yml`。
    ///
    /// 没有这一步的话，用户切到新主题后打开配置页会发现「这个主题没有配置文件」，
    /// 所有设置都没地方改——这是换主题最常见的后续困惑。
    static func createSiteConfig(site: HexoSite, for theme: InstalledTheme) throws -> String {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: site.path)
        let target = root.appendingPathComponent(theme.configFileName)

        if let sample = theme.sampleConfigPath,
           let contents = try? String(contentsOfFile: sample, encoding: .utf8) {
            let header = """
            # \(theme.packageName) 主题配置
            # 这份文件由 HexoMan 从主题自带示例复制而来，你可以按注释逐条修改。
            # 也可以到 https://hexo.io/themes/ 查该主题的完整配置说明。
            # 删除这个文件不会影响站点，只是不再加载主题设置。

            """
            try (header + contents).write(to: target, atomically: true, encoding: .utf8)
            return target.path
        }

        // 主题包里没有示例配置，就造一个带注释的骨架
        let skeleton = """
        # \(theme.packageName) 主题配置
        # 这个主题没有提供示例配置，下面是通用骨架。
        # 具体支持哪些键，请参考该主题的官方文档。

        # 主题主色
        color: "#0078E7"

        # 站点图标
        favicon:

        # 头像
        avatar:
          enable: true
          url:
          rounded: true

        # 社交链接
        social: []

        """
        try skeleton.write(to: target, atomically: true, encoding: .utf8)
        _ = fm
        return target.path
    }

    /// 某主题的配置是否已存在。
    static func siteConfigExists(site: HexoSite, theme: InstalledTheme) -> Bool {
        FileManager.default.fileExists(atPath: site.path + "/" + theme.configFileName)
    }

    /// 推荐的主题（没装任何主题时的引导）。
    static func recommended() -> [ThemeCatalog.Item] {
        Array(ThemeCatalog.items.prefix(3))
    }
}
