//
//  ThemeRegistry.swift
//  HexoMan
//
//  HexoMan 主题市场 = 内置精选 + 联网补全。
//
//  联网行为有边界：
//  - 只读 npm registry（registry.npmjs.org）拿主题包元数据
//  - 不传用户站点信息
//  - 不写、不传 Cookie
//  - 完全离线也能用离线精选列表
//
//  「是否允许联网补全」由用户在设置项里放明——默认关（首次进主题市场时弹窗
//  同意一次），后面可去设置里再次切换。具体策略见 NetworkAccessPolicy.plist
//  和首次同意 sheet 的文案（ThemeBrowserSheet.swift 里有完整描述）。
//
//  npm registry 协议：
//  GET https://registry.npmjs.org/-/v1/search?text=keywords:hexo-theme&size=20
//  响应是 JSON，items[] 是搜索结果，每个 item 含 package.{name, version,
//  description, keywords, links, publisher, date}。
//
//  详见 references 中如果以后补的 PRD；这里只实现"按关键词搜 + 取 top N"。
//

import Foundation

/// npm registry 上的单个主题包。
///
/// 不是 npm 的完整 schema，只取 HexoMan 关心几个字段，避免包太大。
struct RegistryPackage: Identifiable, Codable, Hashable {
    /// 包名（含 hexo-theme- 前缀）。
    var name: String
    /// 当前发布版本。
    var version: String
    /// 一句话描述（来自 package.json 的 description 字段）。
    var description: String
    /// 作者名（可能空——npm 上很多人不写 publisher）。
    var author: String?
    /// 官网/仓库（npm 抓的 homepage 字段）。
    var homepage: String?
    /// npm 上的周下载量。用来给候选做「下载量优先」排序。
    var weeklyDownloads: Int?
    /// 上次发布日期。
    var date: String?

    var id: String { name }

    /// 主题短名（去掉 hexo-theme- 前缀）。
    var shortName: String {
        ThemeManager.shortName(from: name)
    }
}

/// npm registry 搜索响应的子集。
struct RegistrySearchResponse: Codable, Hashable {
    var objects: [RegistryObject]

    /// 单个搜索结果。
    struct RegistryObject: Codable, Hashable {
        var package: RegistryPackageFields
        /// 下载量在 npm 搜索 API 里用 score.detail.popularity 表达。
        var score: Score?

        struct RegistryPackageFields: Codable, Hashable {
            var name: String?
            var version: String?
            var description: String?
            var links: Links?
            var publisher: String?
            var date: String?

            enum CodingKeys: String, CodingKey {
                case name, version, description, links, publisher, date
            }

            struct Links: Codable, Hashable {
                var homepage: String?
                var npm: String?
            }
        }

        struct Score: Codable, Hashable {
            var detail: Detail?

            struct Detail: Codable, Hashable {
                var popularity: Double?
            }
        }
    }
}

/// 联网访问主题库的开关状态。
///
/// 默认关——首次进主题页时弹首次同意 sheet，让用户决定。
/// 同意后存到 `AppSettings.onlineThemeSearch` 持久化。
struct OnlineThemeSearchSettings {
    var enabled: Bool
    /// 是否不再询问（用户勾了「不再提醒」后的标志）。
    var dontAskAgain: Bool
}

/// 在线搜索 + 离线 fallback 混合层。
///
/// 离线时直接返回 `ThemeCatalog.items`（内置精选）；
/// 在线时往 npm registry 查关键词，结果合并：
/// 1. 离线精选排前面（永远在那儿）
/// 3. 联网结果按 weeklyDownloads 排序、去重
/// 4. 不覆盖用户的"已安装主题"——那是单独的 `installed()` API
actor ThemeRegistry {

    static let shared = ThemeRegistry()

    /// npm 搜索 API。固定 endpoint，不让用户改（避免被投毒）。
    /// 选 `-/v1/search` 而不是 `/-/v1/search?text=...` 的 `keyword:` 过滤
    /// 是因为 hexo 主题的 keywords 字段不一定填 hexo-theme，文本匹配更可靠。
    private static let searchEndpoint = URL(string: "https://registry.npmjs.org/-/v1/search")!

    /// 单页结果数。npm 上限是 250，hexo 主题总共不到 100 个，
    /// 25 个一页就能搜出几乎所有。
    private static let pageSize = 25

    /// 搜索 hexo 主题。
    ///
    /// - Parameters:
    ///   - query: 关键词（空字符串 = 取前 25 个）。
    ///   - settings: 用户在设置项里放明的联网偏好。
    /// - Returns: 联网结果 + 离线精选的合并列表。
    func search(query: String, settings: OnlineThemeSearchSettings) async -> [RegistryPackage] {
        // 离线模式：直接返回精选。
        guard settings.enabled else {
            return offlineCatalog(query: query)
        }

        do {
            let online = try await fetchOnline(query: query)
            // 合并：离线精选永远在最前（用户已经知道/信任的），后面是联网结果。
            // 重名时**离线精选胜**——内置里写的是经手工核对过元数据的，npm 上同名包
            // 信息可能有延迟或不一致。
            var seen = Set<String>()
            var merged: [RegistryPackage] = []
            for entry in offlineCatalog(query: query) {
                let pkg = RegistryPackage(
                    name: "hexo-theme-\(entry.name)",
                    version: "",
                    description: "",
                    author: entry.author,
                    homepage: entry.homepage,
                    weeklyDownloads: nil,
                    date: nil
                )
                if seen.insert(pkg.name).inserted {
                    merged.append(pkg)
                }
            }
            for entry in online {
                if seen.insert(entry.name).inserted {
                    merged.append(entry)
                }
            }
            return merged
        } catch {
            // 联网失败（断网、超时、JSON 解析错）一律退化到离线模式。
            // 用户体验比显示错误好——主题页本来就有「离线」按钮文案。
            return offlineCatalog(query: query)
        }
    }

    // MARK: - 离线精选

    /// 把内置 `ThemeCatalog.items` 转成 `RegistryPackage`。
    /// 这里**不**查 npm——本地数据，下载量永远是 nil。
    private func offlineCatalog(query: String) -> [RegistryPackage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ThemeCatalog.items
            .filter { item in
                trimmed.isEmpty || item.matches(trimmed)
            }
            .map { item in
                RegistryPackage(
                    name: "hexo-theme-\(item.name)",
                    version: "",
                    description: item.summaryDescription,
                    author: item.author,
                    homepage: item.homepage,
                    weeklyDownloads: nil,
                    date: nil
                )
            }
    }

    // MARK: - 联网

    /// 调 npm search。
    ///
    /// URL: https://registry.npmjs.org/-/v1/search?text=...&size=...
    ///
    /// 文本匹配关键词（不是 keywords: 字段过滤）：
    /// - hexo 主题的 keywords 不一定含 hexo-theme（很多主题用 `blog` `static` 等）
    /// - 让 npm 自己打分排序
    private func fetchOnline(query: String) async throws -> [RegistryPackage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(url: Self.searchEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "text", value: trimmed.isEmpty ? "hexo-theme" : trimmed),
            URLQueryItem(name: "size", value: "\(Self.pageSize)")
        ]
        guard let url = components.url else {
            throw RegistryError.invalidURL
        }

        var request = URLRequest(url: url)
        // npm 要求带 Accept 头才能返回 JSON（否则返回 HTML）。
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("HexoMan/0.4 (macOS; +https://github.com/Mofan2020/HexoMan)",
                     forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw RegistryError.badStatus
        }

        let decoder = JSONDecoder()
        let parsed = try decoder.decode(RegistrySearchResponse.self, from: data)

        return parsed.objects.compactMap { obj -> RegistryPackage? in
            guard let rawName = obj.package.name,
                  rawName.hasPrefix("hexo-theme-")
            else { return nil }

            let popularity = obj.score?.detail?.popularity ?? 0
            // npm popularity 是 0~1，乘 10 万估下载量（粗估，仅用于排序）。
            let weeklyDownloads = Int(popularity * 100_000)

            return RegistryPackage(
                name: rawName,
                version: obj.package.version ?? "",
                description: obj.package.description ?? "",
                author: obj.package.publisher,
                homepage: obj.package.links?.homepage,
                weeklyDownloads: weeklyDownloads,
                date: obj.package.date
            )
        }
    }

    enum RegistryError: Error {
        case invalidURL
        case badStatus
    }
}

// MARK: - ThemeCatalog 的本地化文本访问

/// `ThemeCatalog.Item` 的 summary 是 `LocalizedStringKey`，
/// 不能直接给非 SwiftUI 上下文（如纯字符串拼接）用。
/// 这里给个 "本地化键 → 字符串" 的回退路径——用于离线目录的描述文本展示。
extension ThemeCatalog.Item {

    /// 离线场景下展示给用户的主题描述（走 Bundle 查 xcstrings）。
    ///
    /// 实现细节：`LocalizedStringKey` 是个 opaque struct，反射拿不到原字面量。
    /// 所以维护一份 `name → key` 的映射表（见 `literalKey`），
    /// 再用 `Bundle.localizedString(forKey:)` 拿翻译结果。
    /// 查不到 key（value == key 表示 miss）时回落 "主题包" 占位。
    var summaryDescription: String {
        let key = literalKey
        guard key.isEmpty == false else { return "主题包" }
        let primary = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        return primary == key ? "主题包" : primary
    }

    /// Item 关联的本地化 key 字符串。必须在 xcstrings 里也填上 `theme.<key>.summary`。
    /// 加新精选主题时记得同时在这里加一行。
    ///
    /// key 统一用**小写**短名。xcstrings 里的键是 `theme.fluid.summary` /
    /// `theme.anima.summary` / `theme.matery.summary`，全小写；这里之前写的是
    /// `theme.Fluid.summary`（跟着 `Item.name` 的大写走），于是查不到、
    /// 回落成通用的「主题包」，那三条主题的描述和搜索匹配全废。
    /// 不再靠 switch 硬编码：改成统一小写后查，省得以后加主题又漏一个。
    var literalKey: String {
        let key = name.lowercased()
        guard key.isEmpty == false else { return "" }
        return "theme.\(key).summary"
    }

    /// 离线搜索的匹配判定。查询词已 lowercased。
    ///
    /// 覆盖用户真会敲的东西：主题短名、完整包名（`hexo-theme-yun`）、
    /// 作者、描述。以前只比 name / description / author 三个字段，
    /// 于是敲 `hexo-theme-` 这种前缀全查不到——用户以为搜索坏了。
    /// `haystack` 统一小写，中英文都能命中（描述走的是当前语言）。
    func matches(_ query: String) -> Bool {
        let haystacks = [
            name,
            "hexo-theme-\(name)",
            author,
            homepage,
            summaryDescription
        ]
        return haystacks.contains { $0.lowercased().contains(query) }
    }
}