//
//  SiteSettings.swift
//  HexoMan
//
//  面向小白的「可视化配置」：把 _config.yml 里最常改的那些键，
//  变成带中文标签和说明的表单。
//
//  为什么要做这个：Hexo 的 _config.yml 有上百个键，大部分是主题内部实现细节。
//  小白看到 `theme: landscape` 根本不知道该填什么，翻文档又慢。
//  这里挑出真正需要人改的那二十来个，其余原样留给「原始文件」页。
//
//  写入策略仍然是**保真优先**：只动目标那一行的值，
//  保留行尾注释、保留键的原有顺序和缩进，绝不重排整个文件。
//

import Foundation

/// 一个可可视化编辑的配置项。
struct SiteField: Identifiable {

    enum ValueKind {
        /// 文本
        case text
        /// 整数
        case integer
        /// 开/关（Hexo 里用 true/false）
        case boolean
        /// 下拉选择
        case choice([(value: String, label: String)])
    }

    var id: String { key }

    /// _config.yml 里的键名
    var key: String
    /// 中文标签
    var label: String
    /// 一句话说明改这个会影响什么
    var hint: String
    var kind: ValueKind
    /// 分组
    var group: Group

    enum Group: String, CaseIterable, Identifiable {
        case basic = "站点信息"
        case appearance = "外观"
        case social = "社交链接"
        case content = "内容与分页"

        var id: String { rawValue }

        var symbolName: String {
            switch self {
            case .basic: return "textformat"
            case .appearance: return "paintbrush"
            case .social: return "person.2"
            case .content: return "doc.on.doc"
            }
        }
    }

    init(_ key: String, _ label: String, _ hint: String, group: Group, kind: ValueKind = .text) {
        self.key = key
        self.label = label
        self.hint = hint
        self.group = group
        self.kind = kind
    }

    /// 常用语言选项。Hexo 本身不校验 lang，主题会用它决定界面语言。
    ///
    /// 注意 `zh-CN` 必须在列表里：Hexo 官方的 `_config.yml` 默认值就是 `zh-CN`，
    /// 而 `hexo new` 生成的站点也都带这个值。少了它的话，
    /// 新建的站点打开「站点语言」就是一个空白下拉，而且选了也存不进去
    /// （SwiftUI 的 Picker 找不到对应 tag 时无法提交）。
    static let languages: [(value: String, label: String)] = [
        ("zh-CN", "简体中文"), ("zh", "简体中文（部分主题用这个）"),
        ("zh-TW", "繁體中文"), ("en", "English"),
        ("ja", "日本語"), ("ko", "한국어"), ("ru", "Русский")
    ]
}

/// 常用配置项清单。
enum SiteSettings {

    /// 收录的配置项。刻意保持精简——塞太多会让「常用」失去意义。
    static let fields: [SiteField] = [
        // 站点信息
        SiteField("title", "站点标题", "显示在浏览器标签页和网站顶部的名字。", group: .basic),
        SiteField("subtitle", "站点副标题", "标题下面那行小字，留空就不显示。", group: .basic),
        SiteField("description", "站点描述", "一句话介绍这个站，搜索引擎会把它当摘要。", group: .basic),
        SiteField("author", "作者名", "文章作者署名和「关于」页显示的名字。", group: .basic),
        SiteField("url", "站点网址", "必须是最终对外的完整地址，结尾的斜杠可省。例：https://example.com。社交链接、RSS 都靠它拼出来。", group: .basic),
        SiteField("language", "站点语言", "决定界面语言，只影响导航和按钮这些文案，不影响文章内容。", group: .basic,
                  kind: .choice(SiteField.languages)),
        SiteField("timezone", "时区", "影响文章日期显示，例：Asia/Shanghai。", group: .basic),

        // 外观
        SiteField("theme", "主题", "站点用的主题包名，例：landscape。装新主题请到「站点管理 → 主题」。", group: .appearance),
        SiteField("avatar", "头像", "图片地址，站内相对路径或完整网址。", group: .appearance),
        SiteField("favicon", "网站图标", "浏览器标签页那个小图标。", group: .appearance),
        SiteField("rss", "生成 RSS", "开启后会在根目录生成 feed.xml。", group: .appearance, kind: .boolean),

        // 内容与分页
        SiteField("per_page", "每页文章数", "首页和归档页一页显示几篇。", group: .content, kind: .integer),
        SiteField("index_generator", "首页文章数", "留空表示不限制。", group: .content, kind: .integer),
        SiteField("archive_generator", "归档页文章数", "留空表示不限制。", group: .content, kind: .integer),
        SiteField("tag_generator", "标签页文章数", "留空表示不限制。", group: .content, kind: .integer),
        SiteField("category_generator", "分类页文章数", "留空表示不限制。", group: .content, kind: .integer),
        SiteField("copy_code", "代码显示复制按钮", "文章里的代码块右上角是否显示「复制」。", group: .content, kind: .boolean),

        // 社交链接
        SiteField("github", "GitHub", "填用户名即可，会拼成 github.com/<你> 的链接。", group: .social),
        SiteField("twitter", "Twitter / X", "填用户名，不带 @。", group: .social),
        SiteField("facebook", "Facebook", "填用户名。", group: .social),
        SiteField("weibo", "微博", "填微博 uid。", group: .social),
        SiteField("zhihu", "知乎", "填知乎用户名。", group: .social)
    ]

    /// 按分组整理，顺序与 `Group.allCases` 一致。
    static func fields(in group: SiteField.Group) -> [SiteField] {
        fields.filter { $0.group == group }
    }

    /// 读出所有收录项的当前值。
    static func values(in config: String) -> [String: String] {
        YAMLScalars.parse(config)
    }

    /// 这个键在当前配置里是不是一个「多行块」。
    ///
    /// 为什么要单独判断：`index_generator` 这类键，在不同站点里形态不一样 ——
    /// 有人写 `per_page: 10` 一行搞定，有人展开成
    ///
    ///     index_generator:
    ///       per_page: 10
    ///       order_by: -date
    ///
    /// 展开的情况下 HexoMan 绝不能去改它（会把整个块改坏），
    /// 界面上也应该只读展示并引导去「原始文件」页，而不是给一个改了必然报错的输入框。
    static func isNestedBlock(key: String, in config: String) -> Bool {
        let lines = config.components(separatedBy: .newlines)
        guard let index = lines.firstIndex(where: { topLevelKey(of: $0) == key }) else { return false }

        // 往后找第一个非空行：中间隔了空行也还是这个键的块
        var cursor = index + 1
        while cursor < lines.count {
            let line = lines[cursor]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                cursor += 1
                continue
            }
            return isIndented(line)
        }
        return false
    }

    /// 把一个键的值写回 YAML 文本。
    ///
    /// 三种情况分别处理：
    /// 1. 已有 `key: value` → 只换值，行尾注释保留
    /// 2. 已有 `key:` 但下面跟缩进块 → **拒绝写入**并说明原因。
    ///    硬改会把整个嵌套结构搞坏，这是这里最重要的安全边界。
    /// 3. 没有这个键 → 追加到文件末尾
    static func setValue(_ rawValue: String, for key: String, in config: String) -> Result<String, SiteSettingsError> {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = config.components(separatedBy: .newlines)

        if let index = lines.firstIndex(where: { topLevelKey(of: $0) == key }) {
            // 下面隔几行空行也算挂着块，所以要跳过空行再判断
            var cursor = index + 1
            while cursor < lines.count, lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty {
                cursor += 1
            }
            if cursor < lines.count, isIndented(lines[cursor]) {
                return .failure(.keyHasNestedBlock(key))
            }
            lines[index] = rewrite(line: lines[index], key: key, value: value)
            return .success(lines.joined(separator: "\n"))
        }

        // 文件末尾追加。刻意**不**在前面插空行：
        // 可视化页一次可能写回十几个键，每行都插一个空行会让文件凭空多出二十多行。
        // 先把末尾空行收干净，再直接追加，跟人在编辑器里手动加一行是一回事。
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        if lines.isEmpty {
            return .success("\(key): \(format(value))")
        }
        lines.append("\(key): \(format(value))")
        return .success(lines.joined(separator: "\n"))
    }

    /// 改一个键的写入失败原因。
    enum SiteSettingsError: LocalizedError {
        case keyHasNestedBlock(String)

        var errorDescription: String? {
            switch self {
            case .keyHasNestedBlock(let key):
                return """
                \(key) 下面挂着多行配置块，HexoMan 不会动它——改坏了会让整个站点构建失败。
                请到「原始文件」页手动编辑，或者换一个顶层标量键。
                """
            }
        }
    }

    // MARK: - 行处理

    /// 取一行的顶层键名。缩进行、注释行、`---` 都返回 nil。
    private static func topLevelKey(of line: String) -> String? {
        guard let first = line.first, first != " ", first != "\t", first != "#", first != "-" else { return nil }
        guard line.hasPrefix("---") == false, line.hasPrefix("...") == false else { return nil }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    private static func isIndented(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        return first == " " || first == "\t"
    }

    /// 替换一行的值，保留行尾注释和原有缩进习惯。
    private static func rewrite(line: String, key: String, value: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "\(key): \(format(value))" }

        let before = String(line[line.startIndex..<colon])
        let afterColon = line.index(after: colon)
        let tail = String(line[afterColon...])

        // 行尾注释只在 # 前是空白时才算注释，否则可能是 URL 里的锚点
        if let hash = commentStart(in: tail) {
            let comment = String(tail[hash...])
            return "\(before): \(format(value)) \(comment)"
        }
        return "\(before): \(format(value))"
    }

    /// 找出 ` #` 注释的起始下标，没有则返回 nil。
    private static func commentStart(in tail: String) -> String.Index? {
        var inSingle = false
        var inDouble = false
        var previous: Character = " "

        for index in tail.indices {
            let character = tail[index]
            switch character {
            case "'" where !inDouble: inSingle.toggle()
            case "\"" where !inSingle: inDouble.toggle()
            case "#" where !inSingle && !inDouble && previous.isWhitespace:
                return index
            default: break
            }
            previous = character
        }
        return nil
    }

    /// 决定写入时要不要加引号。
    ///
    /// YAML 里裸值只要不含 `: ` `#` 开头、`#` 空格、引号、换行就不会被误解析，
    /// 所以尽量保持裸值——用户看 _config.yml 时更清爽。
    private static func format(_ value: String) -> String {
        if value.isEmpty { return "" }
        if value == "true" || value == "false" { return value }
        if Int(value) != nil { return value }

        let dangerous = [": ", " #", "'", "\"", "\n", "[", "]", "{", "}", ",", "&", "*", "!", "|", ">", "%", "@", "`"]
        if dangerous.contains(where: { value.contains($0) }) {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return value
    }
}
