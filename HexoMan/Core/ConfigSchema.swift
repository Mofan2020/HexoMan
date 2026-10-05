//
//  ConfigSchema.swift
//  HexoMan
//
//  把 YAML 的任意路径自动变成带中文说明的交互控件。
//
//  设计取向：**不维护一份手工清单**。
//  早先的 SiteSettings 手写了几十个 SiteField，结果两个后果：
//  一是漏——`social:` 是列表、`avatar:` 是嵌套块，压根不在清单里，
//  页面上永远是空白；二是费劲——换个主题（yun/landscape/next）键名完全不同，
//  清单立刻过期。所以上一版「社媒链接和头像解析不对」的根因就在这。
//
//  现在改成：读 YAML 树的形状来定控件。
//  标量给文本框，true/false 给开关，纯数字给数字框，
//  已知语义的键（theme/timezone 之类）额外给出中文说明和候选项，
//  序列给可增删的列表编辑器，嵌套映射自动展开成分组。
//  换任何主题都不用改代码。
//

import Foundation

// MARK: - 字段描述

/// 一个自动推断出来的配置项。
struct ConfigField: Identifiable {

    enum Kind: Equatable {
        /// 文本框
        case text
        /// 整数
        case integer
        /// 开关
        case boolean
        /// 下拉（有候选项时才用）
        case choice([Option])
        /// 颜色
        case color
        /// 图片/资源地址，额外给「去 source 里挑」的辅助
        case asset
        /// 网址
        case url
        /// 多行文本
        case multiline
        /// 只读展示（块文本、流式写法这类不能安全改的）
        case readOnly(String)
    }

    struct Option: Identifiable, Equatable {
        var value: String
        var label: String
        var id: String { value }
    }

    var id: String { path.yamlDisplay }

    /// YAML 路径
    var path: YAMLPath
    /// 中文标签
    var label: String
    /// 一句话说明
    var hint: String
    var kind: Kind
    /// 分组
    var group: String
    /// 当前值（标量才���）
    var value: String?
    /// 这个路径下挂着的子项数量，用于折叠区标题
    var childCount: Int = 0
    /// 是否在 schema 里有已知说明
    var isKnown: Bool = false

    var isWritable: Bool {
        if case .readOnly = kind { return false }
        return true
    }
}

/// 列表里的一项（社媒链接、菜单项这类）。
struct ListField: Identifiable {

    /// 稳定 id：用「路径 + 序号 + 首字段值」拼，避免重排后整列表刷新
    var id: String { "\(path.yamlDisplay)#\(index)" }

    var path: YAMLPath
    var index: Int
    /// 标题（用首字段的值，如「GitHub」）
    var title: String
    /// 这一项下面每个字段的描述
    var fields: [ConfigField]
    /// 是不是标量项（`- https://...`）
    var isScalar: Bool
    var scalarValue: String?
}

// MARK: - 已知键的中文说明

/// 认识的键名。**不认识的键照样能编辑**，只是没有说明文字。
///
/// 这里只收「含义稳定、跨主题基本一致」的键。
/// 主题自���的键（sidebar/banner/menu 这些）由各自的注释行提供上下文，
/// 加上自动推断的控件类型，已经足够小白用了。
enum ConfigKnowledge {

    struct Entry {
        var label: String
        var hint: String
        /// 控件类型。用自己的枚举而不是 `ConfigField.Kind`，
        /// 是因为「知道该用下拉」和「有哪些候选项」是两件事，
        /// 候选项应该单独放 `options`，由 `effectiveKind` 组装。
        enum Control {
            case text, integer, boolean, color, asset, url, multiline, choice
        }

        var control: Control?
        var options: [ConfigField.Option]?

        init(label: String, hint: String, control: Control? = nil, options: [ConfigField.Option]? = nil) {
            self.label = label
            self.hint = hint
            self.control = control
            self.options = options
        }

        /// 兼容从 `ConfigField.Kind` 构造的写法。传 nil 表示「控件由值自动推断」。
        init(label: String, hint: String, kind: ConfigField.Kind?, options: [ConfigField.Option]? = nil) {
            self.label = label
            self.hint = hint
            self.options = options
            guard let kind else {
                self.control = nil
                return
            }
            switch kind {
            case .text: control = .text
            case .integer: control = .integer
            case .boolean: control = .boolean
            case .color: control = .color
            case .asset: control = .asset
            case .url: control = .url
            case .multiline: control = .multiline
            case .choice: control = .choice
            case .readOnly: control = nil
            }
        }
    }

    static let languages: [ConfigField.Option] = [
        .init(value: "zh", label: "简体中文"),
        .init(value: "zh-CN", label: "简体中文"),
        .init(value: "zh-TW", label: "繁體中文"),
        .init(value: "en", label: "English"),
        .init(value: "ja", label: "日本語"),
        .init(value: "ko", label: "한국어")
    ]

    static let timezones: [ConfigField.Option] = [
        .init(value: "Asia/Shanghai", label: "中国标准时间 (Asia/Shanghai)"),
        .init(value: "Asia/Hong_Kong", label: "香港 (Asia/Hong_Kong)"),
        .init(value: "Asia/Taipei", label: "台北 (Asia/Taipei)"),
        .init(value: "Asia/Tokyo", label: "东京 (Asia/Tokyo)"),
        .init(value: "Asia/Singapore", label: "新加坡 (Asia/Singapore)"),
        .init(value: "Europe/London", label: "伦敦 (Europe/London)"),
        .init(value: "America/New_York", label: "纽约 (America/New_York)"),
        .init(value: "America/Los_Angeles", label: "洛杉矶 (America/Los_Angeles)"),
        .init(value: "UTC", label: "协调世界时 (UTC)")
    ]

    static let entries: [String: Entry] = [
        // 站点
        "title": .init(label: "站点标题", hint: "浏览器标签页和网站顶部显示的名字。", kind: .text, options: nil),
        "subtitle": .init(label: "站点副标题", hint: "标题下面那行小字，留空不显示。", kind: .text, options: nil),
        "description": .init(label: "站点描述", hint: "一句话介绍，搜索引擎会拿它当摘要。", kind: .text, options: nil),
        "keywords": .init(label: "站点关键词", hint: "多个关键词用英文逗号分隔，留空表示不设。", kind: .text, options: nil),
        "author": .init(label: "作者名", hint: "文章署名和「关于」页显示的名字。", kind: .text, options: nil),
        "language": .init(label: "站点语言", hint: "决定站点界面语言。", control: .choice, options: languages),
        "timezone": .init(label: "时区", hint: "影响文章日期显示。", control: .choice, options: timezones),
        "url": .init(label: "站点网址", hint: "最终对外的完整地址，结尾斜杠可省。社交链接和 RSS 都靠它拼。", kind: .url, options: nil),
        "root": .init(label: "站点根路径", hint: "部署在子目录时用，比如 /blog。", kind: .text, options: nil),
        "permalink": .init(label: "永久链接格式", hint: "文章 URL 的结构。改这个会让所有旧链接失效，谨慎。", kind: .text, options: nil),

        // 外观
        "theme": .init(label: "主题", hint: "当前使用的主题包名。换主题建议去「主题」页操作。", kind: .text, options: nil),
        "favicon": .init(label: "网站图标", hint: "浏览器标签页那个小图标。", kind: .asset, options: nil),
        "avatar": .init(label: "头像", hint: "站点头像设置。", kind: nil, options: nil),
        "logo": .init(label: "Logo", hint: "站点 Logo 图片。", kind: .asset, options: nil),
        "rss": .init(label: "生成 RSS", hint: "开启后在根目录生成 feed.xml。", kind: .boolean, options: nil),
        "mode": .init(label: "亮暗模式", hint: "界面的明暗主题。", control: .choice, options: [
            .init(value: "auto", label: "跟随系统"),
            .init(value: "light", label: "始终亮色"),
            .init(value: "dark", label: "始终暗色"),
            .init(value: "time", label: "按时间自动切换")
        ]),
        "color": .init(label: "主题色", hint: "站点的强调色。", kind: .color, options: nil),
        "colors": .init(label: "配色", hint: "站点配色方案。", kind: nil, options: nil),
        "background": .init(label: "背景图", hint: "站点背景图片。", kind: .asset, options: nil),
        "sidebar": .init(label: "侧边栏", hint: "侧边栏外观设置。", kind: nil, options: nil),
        "banner": .init(label: "首页横幅", hint: "首页顶部大图区域。", kind: nil, options: nil),
        "menu": .init(label: "导航菜单", hint: "站点导航项。", kind: nil, options: nil),
        "social": .init(label: "社交链接", hint: "侧边栏的社交图标，点击跳到对应主页。", kind: nil, options: nil),
        "footer": .init(label: "页脚", hint: "页脚内容。", kind: nil, options: nil),
        "plugins": .init(label: "插件", hint: "主题启用的插件。", kind: nil, options: nil),
        "behance": .init(label: "Behance", hint: "Behance 主页地址。", kind: .url, options: nil),
        "twitter": .init(label: "Twitter / X", hint: "Twitter 或 X 主页地址。", kind: .url, options: nil),
        "github": .init(label: "GitHub", hint: "GitHub 主页地址。", kind: .url, options: nil),
        "facebook": .init(label: "Facebook", hint: "Facebook 主页地址。", kind: .url, options: nil),
        "instagram": .init(label: "Instagram", hint: "Instagram 主页地址。", kind: .url, options: nil),
        "linkedin": .init(label: "LinkedIn", hint: "LinkedIn 主页地址。", kind: .url, options: nil),
        "bilibili": .init(label: "哔哩哔哩", hint: "B 站主页地址。", kind: .url, options: nil),
        "zhihu": .init(label: "知乎", hint: "知乎主页地址。", kind: .url, options: nil),
        "weibo": .init(label: "微博", hint: "微博主页地址。", kind: .url, options: nil),
        "qq": .init(label: "QQ", hint: "QQ 群链接或号码。", kind: .text, options: nil),
        "email": .init(label: "邮箱", hint: "联系邮箱。", kind: .text, options: nil),
        "icp": .init(label: "备案号", hint: "页脚显示的备案号。", kind: .text, options: nil),

        // 内容
        "per_page": .init(label: "每页文章数", hint: "首页和归档页一页显示几篇，0 表示不分页。", kind: .integer, options: nil),
        "pagination_dir": .init(label: "分页目录", hint: "分页文件存放的目录名。", kind: .text, options: nil),
        "index_generator": .init(label: "首页生成设置", hint: "首页显示哪些文章。", kind: nil, options: nil),
        "archive_generator": .init(label: "归档页设置", hint: "归档页显示哪些文章。", kind: nil, options: nil),
        "tag_generator": .init(label: "标签页设置", hint: "标签页显示哪些文章。", kind: nil, options: nil),
        "category_generator": .init(label: "分类页设置", hint: "分类页显示哪些文章。", kind: nil, options: nil),
        "default_layout": .init(label: "默认布局", hint: "hexo new 新建内容时的默认布局。", control: .choice, options: [
            .init(value: "post", label: "文章 (post)"),
            .init(value: "page", label: "页面 (page)"),
            .init(value: "draft", label: "草稿 (draft)")
        ]),
        "new_post_name": .init(label: "新文章文件名规则", hint: "决定 hexo new 生成的文件名。:title 用标题，:year 用年份。", kind: .text, options: nil),
        "filename_case": .init(label: "文件名大小写", hint: "0 不转换，1 转小写，2 转大写。", kind: .integer, options: nil),
        "titlecase": .init(label: "标题转 Title Case", hint: "自动把英文标题首字母大写。", kind: .boolean, options: nil),
        "render_drafts": .init(label: "渲染草稿", hint: "开启后草稿也会出现在站点里。", kind: .boolean, options: nil),
        "post_asset_folder": .init(label: "文章独立资源目录", hint: "每篇文章的图片放在同名子目录里。", kind: .boolean, options: nil),
        "relative_link": .init(label: "使用相对链接", hint: "链接不带域名，方便本地预览。", kind: .boolean, options: nil),
        "future": .init(label: "显示未来文章", hint: "日期未到的文章也显示出来。", kind: .boolean, options: nil),
        "date_format": .init(label: "日期格式", hint: "Moment.js 格式，例：YYYY-MM-DD。", kind: .text, options: nil),
        "time_format": .init(label: "时间格式", hint: "Moment.js 格式，例：HH:mm:ss。", kind: .text, options: nil),
        "updated_option": .init(label: "更新时间取值", hint: "mtime 用文件修改时间，date 用 front-matter 里的 date。", control: .choice, options: [
            .init(value: "mtime", label: "文件修改时间"),
            .init(value: "date", label: "文章日期"),
            .init(value: "empty", label: "不显示")
        ]),
        "default_category": .init(label: "默认分类", hint: "文章没写分类时归到这里。", kind: .text, options: nil),
        "skip_render": .init(label: "跳过渲染的路径", hint: "这些文件原样拷贝，不经模板处理。", kind: .multiline, options: nil),
        "include": .init(label: "包含的文件", hint: "source 下要被处理的文件，留空表示全部。", kind: .multiline, options: nil),
        "exclude": .init(label: "排除的文件", hint: "source 下要跳过的文件。", kind: .multiline, options: nil),
        "ignore": .init(label: "完全忽略的路径", hint: "既不处理也不拷贝。", kind: .multiline, options: nil),
        "external_link": .init(label: "外链处理", hint: "站外链接是否在新标签页打开。", kind: nil, options: nil),
        "highlight": .init(label: "代码高亮", hint: "文章里代码块的显示方式。", kind: nil, options: nil),
        "prismjs": .init(label: "Prism 语法高亮", hint: "代码高亮的具体设置。", kind: nil, options: nil),
        "syntax_highlighter": .init(label: "高亮引擎", hint: "prismjs 或 highlighter。", control: .choice, options: [
            .init(value: "prismjs", label: "Prism.js（推荐）"),
            .init(value: "highlighter", label: "highlight.js")
        ]),
        "copy_code": .init(label: "代码复制按钮", hint: "代码块右上角显示「复制」。", kind: .boolean, options: nil),
        "meta_generator": .init(label: "生成 meta 标签", hint: "自动生成 SEO 相关的 meta 标签。", kind: .boolean, options: nil),
        "search": .init(label: "搜索", hint: "站内搜索功能设置。", kind: nil, options: nil),
        "deploy": .init(label: "部署", hint: "hexo deploy 的目标配置。", kind: nil, options: nil),

        // 目录
        "source_dir": .init(label: "源目录", hint: "存放文章和页面的目录，一般不动。", kind: .text, options: nil),
        "public_dir": .init(label: "输出目录", hint: "生成站点放哪，一般不动。", kind: .text, options: nil),
        "tag_dir": .init(label: "标签目录", hint: "标签页输出目录。", kind: .text, options: nil),
        "archive_dir": .init(label: "归档目录", hint: "归档页输出目录。", kind: .text, options: nil),
        "category_dir": .init(label: "分类目录", hint: "分类页输出目录。", kind: .text, options: nil),
        "code_dir": .init(label: "代码目录", hint: "文章里的下载文件放哪。", kind: .text, options: nil),
        "i18n_dir": .init(label: "多语言目录", hint: ":lang 表示按语言分目录。", kind: .text, options: nil),

        // 列表项里常见的字段
        "name": .init(label: "名称", hint: "显示出来的名字。", kind: .text, options: nil),
        "link": .init(label: "链接", hint: "点击跳转到的地址。", kind: .url, options: nil),
        "icon": .init(label: "图标", hint: "图标类名，形如 ri:github-line。", kind: .text, options: nil),
        
        
        "path": .init(label: "路径", hint: "目标路径。", kind: .text, options: nil),
        "type": .init(label: "类型", hint: "这一项的种类。", kind: .text, options: nil),
        "enable": .init(label: "启用", hint: "关掉后这一段不生效。", kind: .boolean, options: nil),
        
        "value": .init(label: "值", hint: "这一项的值。", kind: .text, options: nil)
    ]

    /// 找键的说明。没登记就返回 nil，调用方据此降级成「只有自动推断的控件」。
    static func lookup(_ key: String) -> Entry? {
        entries[key]
    }
}

// MARK: - Schema 生成

/// 从 YAML 文档生成可交互的配置结构。
enum ConfigSchema {

    /// 生成整个文件的字段列表（顶层 + 一层嵌套展开）。
    ///
    /// 只展开一层是刻意的：Hexo 配置最深也就两三层，
    /// 全展平会让页面变成一堵看不到头的墙。
    static func fields(in document: YAMLDocument) -> [ConfigField] {
        guard let root = document.node(at: []) else { return [] }
        var result: [ConfigField] = []

        for entry in root.entries ?? [] {
            appendField(entry: entry, path: [.key(entry.key)], into: &result, document: document)
        }
        return result
    }

    /// 单个顶层键的字段（含其子项）。
    private static func appendField(
        entry: YAMLEntry,
        path: YAMLPath,
        into result: inout [ConfigField],
        document: YAMLDocument
    ) {
        let key = entry.key
        let known = ConfigKnowledge.lookup(key)

        // 标量：直接给控件
        if let scalar = entry.node.scalar {
            let kind = inferKind(key: key, scalar: scalar, known: known)
            result.append(ConfigField(
                path: path,
                label: known?.label ?? humanize(key),
                hint: known?.hint ?? "",
                kind: kind,
                group: group(of: key),
                value: scalar.value,
                isKnown: known != nil
            ))
            return
        }

        // 列表：给列表编辑器
        if entry.node.isSequence {
            result.append(ConfigField(
                path: path,
                label: known?.label ?? humanize(key),
                hint: known?.hint ?? "共 \(entry.node.items?.count ?? 0) 项",
                kind: .readOnly("列表"),
                group: group(of: key),
                value: nil,
                childCount: entry.node.items?.count ?? 0,
                isKnown: known != nil
            ))
            return
        }

        // 嵌套映射：建一个分组，子项单独成字段
        let children = entry.node.entries ?? []
        result.append(ConfigField(
            path: path,
            label: known?.label ?? humanize(key),
            hint: known?.hint ?? "\(children.count) 项设置",
            kind: .readOnly("分组"),
            group: group(of: key),
            value: nil,
            childCount: children.count,
            isKnown: known != nil
        ))

        // 子项**不看**已知键表。
        //
        // 为什么要区分：`url` 在顶层是「站点网址」，在 avatar 下面是「头像文件」；
        // `language` 在顶层是站点语言，在 creative_commons 下面是「许可证种类」。
        // 拿同一份说明套所有层级，就会出现「头像的地址项写着站点网址」这种
        // 明显不对的标签——小白看到会以为填错了地方。
        // 所以嵌套子项一律按**值形状**自动推断，标签用通用译名。
        for child in children {
            if child.node.scalar == nil { continue }   // 再深一层就不收了
            let childPath = path + [.key(child.key)]
            let childKnown = nestedKeyHint(child.key)
            result.append(ConfigField(
                path: childPath,
                label: childKnown?.label ?? humanize(child.key),
                hint: childKnown?.hint ?? "",
                kind: inferKind(key: child.key, scalar: child.node.scalar!, known: childKnown),
                group: known?.label ?? humanize(key),
                value: child.node.scalar?.value,
                childCount: 0,
                isKnown: childKnown != nil
            ))
        }
    }

    /// 生成列表编辑器需要的结构。
    ///
    /// 标量项（`- https://...`）和映射项（`- name: GitHub`）都能处理，
    /// 映射项的字段名从**这一项实际有的键**里读，不写死——
    /// 不同主题的列表项字段差别很大（yun 是 name/link/icon/color，
    /// landscape 只有 link/label）。
    static func listFields(in document: YAMLDocument, at path: YAMLPath) -> [ListField] {
        guard let sequence = document.node(at: path), let items = sequence.items else { return [] }
        var result: [ListField] = []

        for (index, item) in items.enumerated() {
            if let scalar = item.value.scalar {
                result.append(ListField(
                    path: path,
                    index: index,
                    title: scalar.value.isEmpty ? "第 \(index + 1) 项" : scalar.value,
                    fields: [],
                    isScalar: true,
                    scalarValue: scalar.value
                ))
                continue
            }

            guard let entries = item.value.entries else {
                result.append(ListField(path: path, index: index, title: "第 \(index + 1) 项", fields: [], isScalar: false, scalarValue: nil))
                continue
            }

            let itemPath = path + [.index(index)]
            let fields: [ConfigField] = entries.map { child in
                let childPath = itemPath + [.key(child.key)]
                let known = ConfigKnowledge.lookup(child.key)
                return ConfigField(
                    path: childPath,
                    label: known?.label ?? humanize(child.key),
                    hint: known?.hint ?? "",
                    kind: inferKind(key: child.key, scalar: child.node.scalar, known: known),
                    group: "",
                    value: child.node.scalar?.value,
                    isKnown: known != nil
                )
            }

            // 标题取第一个文本类字段的值；取不到就退回序号
            let candidate = fields.first(where: { isTextual($0.kind) })?.value
                ?? fields.first?.value
            let title = (candidate?.isEmpty == false) ? candidate! : "第 \(index + 1) 项"

            result.append(ListField(
                path: path,
                index: index,
                title: title,
                fields: fields,
                isScalar: false,
                scalarValue: nil
            ))
        }

        return result
    }

    // MARK: 推断

    /// 从键名、已知说明和值的实际形状推断控件类型。
    static func inferKind(key: String, scalar: YAMLScalar?, known: ConfigKnowledge.Entry?) -> ConfigField.Kind {
        if known?.control != nil, let options = known?.options, !options.isEmpty {
            return .choice(options)
        }
        if let control = known?.control { return kind(for: control) }
        guard let scalar else { return .text }

        if scalar.isBlockScalar || scalar.isFlow {
            return .readOnly(scalar.isFlow ? "行内写法 [ ] 或 { }" : "多行块文本")
        }

        let value = scalar.value.trimmingCharacters(in: .whitespaces)
        let lowered = value.lowercased()

        if ["true", "false"].contains(lowered) { return .boolean }
        if !value.isEmpty, Int(value) != nil { return .integer }
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") { return .url }
        if looksLikeHexColor(value) { return .color }
        if isImagePath(value) { return .asset }
        if value.contains("\n") { return .multiline }
        return .text
    }

    /// 已知键给了候选项就用候选项，否则用推断结果。
    static func effectiveKind(_ field: ConfigField, known: ConfigKnowledge.Entry?) -> ConfigField.Kind {
        if let control = known?.control {
            if let options = known?.options, !options.isEmpty { return .choice(options) }
            return kind(for: control)
        }
        return field.kind
    }

    private static func kind(for control: ConfigKnowledge.Entry.Control) -> ConfigField.Kind {
        switch control {
        case .text: return .text
        case .integer: return .integer
        case .boolean: return .boolean
        case .color: return .color
        case .asset: return .asset
        case .url: return .url
        case .multiline: return .multiline
        case .choice: return .choice([])
        }
    }

    private static func isTextual(_ kind: ConfigField.Kind) -> Bool {
        switch kind {
        case .text, .url, .color, .asset: return true
        default: return false
        }
    }

    private static func looksLikeHexColor(_ value: String) -> Bool {
        guard value.hasPrefix("#") else { return false }
        let body = value.dropFirst()
        guard [3, 4, 6, 8].contains(body.count) else { return false }
        return body.allSatisfy { $0.isHexDigit }
    }

    private static func isImagePath(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return [".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".avif", ".ico"]
            .contains { lowered.hasSuffix($0) }
    }

    // MARK: 命名

    /// 分组。跟 ConfigKnowledge 的语义分组对齐，让表单读起来有结构。
    private static func group(of key: String) -> String {
        switch key {
        case "title", "subtitle", "description", "keywords", "author", "language", "timezone", "url", "root", "permalink", "index_generator", "per_page", "pagination_dir", "default_category", "tag_generator", "category_generator", "archive_generator", "new_post_name", "default_layout", "filename_case", "titlecase", "render_drafts", "post_asset_folder", "relative_link", "future", "date_format", "time_format", "updated_option", "skip_render", "include", "exclude", "ignore", "meta_generator", "search":
            return "内容"
        case "theme", "favicon", "avatar", "logo", "rss", "mode", "color", "colors", "background", "sidebar", "banner", "menu", "footer", "plugins", "external_link", "highlight", "prismjs", "syntax_highlighter", "copy_code":
            return "外观"
        case "source_dir", "public_dir", "tag_dir", "archive_dir", "category_dir", "code_dir", "i18n_dir":
            return "目录"
        case "deploy":
            return "部署"
        default:
            return "其他"
        }
    }

    /// 嵌套层级里**语义与上下文无关**的键，才配固定说明。
    ///
    /// 收录标准很简单：不管它出现在 avatar 下面还是 banner 下面，含义都一样。
    /// 凡是「url」「title」这种会随父级变义的键，一律不进这里。
    static func nestedKeyHint(_ key: String) -> ConfigKnowledge.Entry? {
        switch key {
        case "enable": return ConfigKnowledge.entries["enable"]
        case "icon": return ConfigKnowledge.entries["icon"]
        case "name": return ConfigKnowledge.entries["name"]
        case "type": return ConfigKnowledge.entries["type"]
        case "value": return ConfigKnowledge.entries["value"]
        case "label": return ConfigKnowledge.entries["label"]
        default: return nil
        }
    }

    /// 把 `trailing_index` 变成「Trailing Index」这种可读标签。
    ///
    /// 翻译不出中文的键就退回英文原样——**宁可给英文也不要瞎翻译**，
    /// 猜错含义比不给说明更糟。
    static func humanize(_ key: String) -> String {
        let spaced = key.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return spaced.split(separator: " ").map { word -> String in
            let lower = word.lowercased()
            if let chinese = chineseNames[lower] { return chinese }
            return word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    /// 常见英文键的中文对照。覆盖不到的直接显示英文。
    private static let chineseNames: [String: String] = [
        "enable": "启用", "enabled": "启用", "disable": "禁用",
        "true": "开", "false": "关",
        "link": "链接", "path": "路径", "dir": "目录",
        "name": "名称", "title": "标题", "desc": "描述", "description": "描述",
        "icon": "图标", "color": "颜色", "bg": "背景", "background": "背景",
        "image": "图片", "img": "图片", "avatar": "头像", "logo": "标志",
        "opacity": "不透明度", "rounded": "圆角", "position": "位置",
        "size": "尺寸", "width": "宽度", "height": "高度", "radius": "圆角",
        "margin": "外边距", "padding": "内边距", "font": "字体", "weight": "字重",
        "text": "文字", "border": "边框", "shadow": "阴影",
        "animation": "动画", "duration": "时长", "delay": "延迟",
        "type": "类型", "value": "值", "label": "标签", "target": "目标",
        "count": "数量", "limit": "上限", "offset": "偏移", "depth": "深度",
        "index": "序号", "order": "排序", "orderby": "排序字段",
        "per": "每页", "page": "页", "list": "列表", "item": "条目",
        "content": "内容", "text2": "文字", "html": "HTML", "code": "代码",
        "locale": "语言", "format": "格式",
        "theme": "主题", "layout": "布局", "template": "模板", "widget": "挂件",
        "search": "搜索", "tag": "标签", "category": "分类", "archive": "归档",
        "post": "文章", "page2": "页面", "draft": "草稿", "published": "已发布",
        "password": "访问密码", "toc": "目录", "mathjax": "数学公式",
        "chart": "图表", "mermaid": "流程图", "emoji": "表情",
        "truncate": "截断", "excerpt": "摘要", "summary": "摘要",
        "sticky": "置顶", "top": "置顶", "hot": "热门", "reward": "打赏",
        "comment": "评论", "share": "分享", "reward2": "打赏"
    ]
}
