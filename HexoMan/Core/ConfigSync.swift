//
//  ConfigSync.swift
//  HexoMan
//
//  站点配置（_config.yml）与主题配置（_config.<主题>.yml）之间的公共项同步。
//
//  ## 为什么要做这个
//
//  Hexo 的站点有两份配置：
//
//      _config.yml            站点配置。Hexo 自己读的键在这里。
//      _config.yun.yml        主题配置。主题**优先读自己这份**，同名键会盖掉站点配置。
//
//  于是头像、favicon、标题、副标题这类「两边都想写」的值就要写两遍。
//  而用户几乎只会去改 `_config.yml`——因为它就叫「站点配置」，最显眼。
//
//  结果就是：改完头像，站点没反应。用户会反复检查自己有没有保存成功、
//  有没有重新生成，最后怀疑是工具坏了。**这是本功能要消灭的体验。**
//
//  ## 原则
//
//  - **站点配置是唯一权威源**。改站点配置 → 自动把同样的值写到主题配置。
//  - 只同步「两边含义一致」的键。sidebar / banner / menu 这类主题私有结构
//    绝不同步——同步过去大概率把主题配置改坏。
//  - 用户可以手动关掉。关掉后两个文件各管各的。
//

import Foundation

// MARK: - 同步引擎

enum ConfigSync {

    /// 一个需要双份保持一致的键。
    struct SharedKey {
        /// 键名（两边同名）
        var key: String
        /// 中文标签
        var label: String
        /// 说明为什么要同步
        var note: String

        init(_ key: String, _ label: String, _ note: String) {
            self.key = key
            self.label = label
            self.note = note
        }
    }

    /// 会自动同步的键。
    ///
    /// 收录标准：两边含义一致、值是标量、且用户确实会去站点配置里改它。
    ///
    /// `key` 可以写成 `父键.子键`：`avatar` 在两份配置里都是**嵌套块**
    /// （底下有 url / gravatar / rounded / rotated），整体搬会破坏缩进结构，
    /// 所以只按叶子键逐个同步。
    static let sharedKeys: [SharedKey] = [
        SharedKey("title", "站点标题", "主题优先读自己配置里的标题，不同步的话浏览器标签和站名会不一致"),
        SharedKey("subtitle", "站点副标题", "同上"),
        SharedKey("description", "站点描述", "主题和 SEO 都会用"),
        SharedKey("keywords", "站点关键词", "SEO 用，同步后主题侧也能拿到"),
        SharedKey("author", "作者名", "文章署名和「关于」页都用它"),
        SharedKey("url", "站点网址", "社交链接、RSS、文章末尾的版权链接全靠它拼"),
        SharedKey("root", "站点根路径", "部署在子目录时两处都要一致，否则内页全 404"),
        SharedKey("language", "站点语言", "界面语言，主题覆盖后用户会以为没生效"),
        SharedKey("timezone", "时区", "日期显示"),
        SharedKey("favicon", "网站图标", "主题侧有自己的 logo 配置，不同步就只改了一半"),
        SharedKey("logo", "Logo", "同上"),
        SharedKey("rss", "生成 RSS", "开关状态"),
        SharedKey("per_page", "每页文章数", "分页数量"),
        SharedKey("mode", "亮暗模式", "主题侧常自己定义了一套"),

        // 嵌套块：只同步叶子键
        SharedKey("avatar.url", "头像地址", "主题侧 avatar 优先级高于站点配置，不同步就会「改了没反应」"),
        SharedKey("avatar.gravatar", "头像 Gravatar 邮箱", "同上"),
        SharedKey("avatar.rounded", "头像圆形", "同上"),
        SharedKey("avatar.rotated", "头像跟随鼠标转动", "同上"),
        SharedKey("codeblock.copy_btn", "代码复制按钮", "主题侧几乎总会有一份自己的")
    ]

    /// 只按顶层键比较、且值为标量的键才参与同步。
    static func isSyncable(_ key: String) -> Bool {
        sharedKeys.contains { $0.key == key }
    }

    static func label(for key: String) -> String? {
        sharedKeys.first { $0.key == key }?.label
    }

    // MARK: - 差异检测

    /// 一处「两边不一样」。
    struct Difference: Identifiable {
        var id: String { key }
        var key: String
        var label: String
        var note: String
        /// 站点配置（权威源）里的值
        var siteValue: String
        /// 主题配置里的值
        var themeValue: String

        var siteDisplay: String { siteValue.isEmpty ? "（未设置）" : siteValue }
        var themeDisplay: String { themeValue.isEmpty ? "（未设置）" : themeValue }
    }

    /// 只在**主题配置**里设了、站点配置里没有的键。
    ///
    /// ## 为什么不能当成「差异」自动抹平
    ///
    /// 很多人（尤其是先玩主题、再学 Hexo 的人）是把头像、logo 这些
    /// **直接写在主题配置里的**，站点配置压根没有这个键。
    /// 这种情况绝不能按「站点配置是权威源」去把主题的值清掉——
    /// 那等于用户配好的头像当场消失，而且他还不知道为什么。
    ///
    /// 所以这里单独列出来，只**告知**，由用户决定要不要搬回站点配置。
    /// 搬过去的好处是：以后换主题，头像不会丢。
    struct ThemeOnlyEntry: Identifiable {
        var id: String { key }
        var key: String
        var label: String
        /// 主题配置里的值
        var value: String
        /// 站点配置里这个键的状态
        var siteState: SiteState

        enum SiteState {
            /// 站点配置里完全没有这个键
            case missing
            /// 站点配置里有这个键但是空的
            case empty

            var description: String {
                switch self {
                case .missing: return "站点配置里没有这一项"
                case .empty: return "站点配置里是空的"
                }
            }
        }
    }

    /// 找出「只在主题配置里配了」的公共项。
    static func themeOnlyEntries(siteConfig: String, themeConfig: String) -> [ThemeOnlyEntry] {

        let engine = YAMLPathEngine.shared
        var result: [ThemeOnlyEntry] = []

        for shared in sharedKeys {
            guard let themeValue = engine.get(shared.key, in: themeConfig)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  themeValue.isEmpty == false
            else { continue }

            // 区分「键不存在」和「键存在但是空的」——前者写回时要新建，后者只要填值
            let rawSite = engine.get(shared.key, in: siteConfig)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard rawSite?.isEmpty != false else { continue }   // 站点侧有值 → 不是这一类

            result.append(ThemeOnlyEntry(
                key: shared.key,
                label: shared.label,
                value: themeValue,
                siteState: rawSite == nil ? .missing : .empty
            ))
        }

        return result
    }

    /// 把一个键的值从**主题配置搬回站点配置**。
    ///
    /// 用于「我只在主题配置里配了，帮我搬到站点配置，以后换主题不丢」这种诉求。
    static func applyToSite(
        _ key: String,
        value: String,
        in siteConfig: String
    ) -> String? {

        guard isSyncable(key) else { return nil }
        return writeNested(key: key, value: value, in: siteConfig)
    }

    /// 写入一个可能带点号的路径，**必要时先把缺失的父级块建出来**。
    ///
    /// ## 为什么不能直接丢给 YAMLPathEngine
    ///
    /// 引擎只会在「父级已经是映射」时补子键。站点配置里压根没有 `avatar:` 这一段时，
    /// `set("avatar.url", …)` 直接返回 `pathNotFound`——而且是**静默失败**。
    ///
    /// 而这恰恰是最常见的情况：用户只在 `_config.yun.yml` 里配了头像，
    /// `_config.yml` 里连 `avatar:` 这行都没有（实测就是这个站点）。
    /// 不处理的话，「搬到站点配置」按钮点了跟没点一样。
    private static func writeNested(key: String, value: String, in text: String) -> String? {

        let engine = YAMLPathEngine.shared
        let parts = key.split(separator: ".").map(String.init)

        // 顶层标量：引擎自己能处理（含自动追加到文件末尾）
        if parts.count == 1 {
            if case .success(let updated) = engine.set(key, to: value, in: text) { return updated }
            return nil
        }

        let parentPath = parts.dropLast().joined(separator: ".")

        // 父级已经是正常映射 → 交给引擎，它会插到父块末尾，位置最自然
        if let parent = YAMLDocument(text: text).node(at: YAMLPath(dottedPath: parentPath)),
           parent.isMapping {
            if case .success(let updated) = engine.set(key, to: value, in: text) { return updated }
            return nil
        }

        // 父键存在但后面空着（`avatar:` 裸一行）→ 先给它补一个占位子键，
        // 让它在 YAML 意义上成为映射，引擎才能安全地往里写叶子。
        // 用真实的键值行而不是注释：注释不会让它变成映射。
        if let seeded = seedEmptyParent(parentPath, in: text) {
            if case .success(let updated) = engine.set(key, to: value, in: seeded) {
                return stripPlaceholder(updated)
            }
        }

        // 父路径整个不存在 → 直接在文件末尾追加整块
        return appendBlock(parts, value: value, to: text)
    }

    /// 占位子键的名字。写完叶子之后要把它删掉。
    private static let placeholderKey = "__hexoman_tmp__"

    /// 给一个「裸着的」父键补一个占位子键。
    private static func seedEmptyParent(_ parentPath: String, in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        let head = parentPath.split(separator: ".").last.map(String.init) ?? parentPath

        var found: Int?
        for (index, line) in lines.enumerated() {
            guard line.hasPrefix("\(head):") else { continue }
            // 已经带值了就不是空壳，交给引擎自己判断
            let rest = line.dropFirst(head.count + 1).trimmingCharacters(in: .whitespaces)
            guard rest.isEmpty else { return nil }
            found = index
            break
        }
        guard let insertAt = found else { return nil }

        var copy = lines
        copy.insert("  \(placeholderKey): true", at: insertAt + 1)
        return copy.joined(separator: "\n")
    }

    /// 把占位子键那行删掉。
    private static func stripPlaceholder(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { $0.trimmingCharacters(in: .whitespaces) != "\(placeholderKey): true" }
            .joined(separator: "\n")
    }

    /// 在文件末尾追加一整块嵌套结构。
    private static func appendBlock(_ parts: [String], value: String, to text: String) -> String? {
        guard parts.count >= 2 else { return nil }

        var lines = text.components(separatedBy: .newlines)
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        guard lines.isEmpty == false else { return nil }

        // 沿用文件里已有的缩进宽度（2 或 4 空格都可能）
        let step = detectIndentWidth(lines) ?? 2

        var depth = 0
        for part in parts.dropLast() {
            lines.append(String(repeating: " ", count: depth * step) + "\(part):")
            depth += 1
        }
        let leaf = parts[parts.count - 1]
        lines.append(String(repeating: " ", count: depth * step) + "\(leaf): \(formatScalar(value))")

        return lines.joined(separator: "\n")
    }

    /// 从已有的缩进里猜一个缩进宽度，猜不到就用 2。
    private static func detectIndentWidth(_ lines: [String]) -> Int? {
        var smallest: Int?
        for line in lines {
            guard let first = line.first, first == " " else { continue }
            let count = line.prefix { $0 == " " }.count
            guard count > 0 else { continue }
            if smallest == nil || count < smallest! { smallest = count }
        }
        guard let width = smallest, width > 0, width <= 8 else { return nil }
        return width
    }

    /// 值要不要加引号。规则跟 SiteSettings 保持一致。
    private static func formatScalar(_ value: String) -> String {
        if value.isEmpty { return "\"\"" }
        if value == "true" || value == "false" { return value }
        if Int(value) != nil { return value }

        let dangerous = [": ", " #", "'", "\"", "\n", "[", "]", "{", "}", ",", "&", "*", "!", "|", ">", "%", "@", "`"]
        if dangerous.contains(where: { value.contains($0) }) {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return value
    }

    /// 比较两份配置，找出需要同步的差异。
    ///
    /// 只比较**两边都有值**的键：
    /// - 主题配置里没这个键 = 主题不关心它，不是冲突（很多主题压根不读 `keywords`）
    /// - 站点配置里没这个键 = 用户没设置，不要去覆盖主题侧已有的值
    static func differences(siteConfig: String, themeConfig: String) -> [Difference] {

        let engine = YAMLPathEngine.shared
        var result: [Difference] = []

        for shared in sharedKeys {
            let themeValue = engine.get(shared.key, in: themeConfig)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let themeValue else { continue }

            let siteValue = (engine.get(shared.key, in: siteConfig) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard siteValue != themeValue, siteValue.isEmpty == false else { continue }

            result.append(Difference(
                key: shared.key,
                label: shared.label,
                note: shared.note,
                siteValue: siteValue,
                themeValue: themeValue
            ))
        }

        return result
    }

    // MARK: - 写入

    /// 把某个键的值从站点配置复制到主题配置。
    ///
    /// 返回 nil 表示**不需要写**（值本来就一样，或者主题配置里没这个键）。
    /// 调用方据此决定要不要真的落盘、要不要弹「已同步」提示。
    static func applyToTheme(
        _ key: String,
        value: String,
        in themeConfig: String
    ) -> String? {

        guard isSyncable(key) else { return nil }

        let engine = YAMLPathEngine.shared
        // 主题配置里压根没这个路径：不擅自新增结构
        guard let current = engine.get(key, in: themeConfig)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              current != value
        else { return nil }

        if case .success(let updated) = engine.set(key, to: value, in: themeConfig) {
            return updated
        }
        return nil
    }

    /// 把一份主题配置整体对齐到站点配置，返回所有发生变化的键。
    @discardableResult
    static func syncAll(
        siteConfig: String,
        themeConfig: String
    ) -> (config: String, changedKeys: [String]) {

        var result = themeConfig
        var changed: [String] = []

        for difference in differences(siteConfig: siteConfig, themeConfig: themeConfig) {
            if let updated = applyToTheme(difference.key, value: difference.siteValue, in: result) {
                result = updated
                changed.append(difference.label)
            }
        }

        return (result, changed)
    }
}