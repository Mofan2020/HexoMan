//
//  PageStore.swift
//  HexoMan
//
//  「页面」的管理：扫描 source 下除文章外的内容，新建、编辑、删除。
//
//  为什么要单独做这一块：Hexo 的站点不只有文章。`source/about/index.md`、
//  `source/friends/index.md` 这些「页面」是几乎每个博客都有的一部分，
//  但原来的 HexoMan 只能管 `_posts` 里的文章，页面完全管不到。
//  用户抱怨「能管理的东西太少」，这是最大的一块缺口。
//
//  两类页面都要能管：
//  1. HexoMan 新建的页面——带上完整的交互式表单（标题/布局/日期/草稿/排序…）
//  2. 用户已有的页面——扫出来、能编辑，表单按它**实际有的字段**生成，
//     缺哪个字段就补哪个，不强迫用户改写成 HexoMan 的格式。
//

import Foundation

/// 一个页面文件。
struct PageFile: Identifiable, Hashable {

    enum Kind: String {
        /// `about/index.md` 这种带 index 的，URL 就是目录名
        case indexed
        /// `about.md` 这种，URL 带 .html
        case standalone
        /// 主题自带的资源（图片、css 等），不该当内容编辑
        case asset

        var label: String {
            switch self {
            case .indexed: return "独立页面"
            case .standalone: return "单页"
            case .asset: return "静态资源"
            }
        }
    }

    var path: String
    /// 相对 source 的路径，如 `about/index.md`
    var relativePath: String
    /// 从路径推出来的名字，如 `about`
    var slug: String
    var title: String
    var kind: Kind
    /// 是否在 `_posts` 目录里（文章，不是页面）
    var isPost: Bool
    var hasFrontMatter: Bool
    /// 文件修改时间
    var modifiedAt: Date?
    /// 文件大小（字节）
    var size: Int

    var id: String { path }

    /// 这个页面在站点里的访问路径。
    var url: String {
        let name = (relativePath as NSString).deletingPathExtension
        let cleaned = name.hasSuffix("/index") ? String(name.dropLast("/index".count)) : name
        return cleaned.isEmpty ? "/" : "/\(cleaned)/"
    }
}

/// 页面 front-matter 里的一个字段描述。
///
/// 和 ConfigSchema 的区别：页面字段大多不在任何已知键表里（各主题自定义的都有），
/// 所以这里是「**先看文件里实际有什么**，再决定给什么控件」。
struct PageField: Identifiable {

    enum Kind: Equatable {
        case text
        case multiline
        case integer
        case boolean
        case date
        case list
        case choice([ConfigField.Option])
        /// 文件里有、但我们不认识的键，只读展示
        case passthrough
    }

    var id: String { key }

    var key: String
    var label: String
    var hint: String
    var kind: Kind
    /// 标量当前值
    var value: String
    /// 列表当前值
    var items: [String] = []
    /// 是不是 HexoMan 认识的字段（决定表单给不给控件）
    var isKnown: Bool = true
    /// 这个字段值是否非空
    var isEmpty: Bool { value.isEmpty && items.isEmpty }
}

/// 页面里字段的中文说明。覆盖 Hexo 通用字段 + 常见主题页面字段。
enum PageFieldKnowledge {

    struct Entry {
        var label: String
        var hint: String
        var kind: PageField.Kind
    }

    static let entries: [String: Entry] = [
        "title": .init(label: "标题", hint: "页面显示的标题。", kind: .text),
        "date": .init(label: "日期", hint: "页面的创建时间，会影响排序。", kind: .date),
        "updated": .init(label: "更新时间", hint: "最后修改时间。", kind: .date),
        "layout": .init(label: "布局", hint: "用哪个模板渲染这个页面。", kind: .choice([
            .init(value: "", label: "（跟随主题默认）"),
            .init(value: "page", label: "page（通用页面）"),
            .init(value: "post", label: "post（按文章渲染）"),
            .init(value: "draft", label: "draft（草稿，不发布）"),
            .init(value: "about", label: "about（关于页）"),
            .init(value: "friends", label: "friends（友链页）"),
            .init(value: "links", label: "links（链接页）")
        ])),
        "permalink": .init(label: "固定链接", hint: "指定这个页面的 URL。不填就按文件路径生成。", kind: .text),
        "draft": .init(label: "草稿", hint: "勾上后不会出现在站点里。", kind: .boolean),
        "published": .init(label: "已发布", hint: "与「草稿」作用相反，勾上才发布。", kind: .boolean),
        "comments": .init(label: "开启评论", hint: "这个页面要不要显示评论区。", kind: .boolean),
        "toc": .init(label: "显示目录", hint: "根据标题自动生成页内目录。", kind: .boolean),
        "mathjax": .init(label: "数学公式", hint: "启用 LaTeX 公式渲染。", kind: .boolean),
        "mermaid": .init(label: "流程图", hint: "启用 mermaid 图表。", kind: .boolean),
        "chart": .init(label: "图表", hint: "启用图表渲染。", kind: .boolean),
        "emoji": .init(label: "Emoji", hint: "启用表情渲染。", kind: .boolean),
        "password": .init(label: "访问密码", hint: "留空表示不加密。填了之后访问要输密码。", kind: .text),
        "excerpt": .init(label: "摘要", hint: "列表页显示的摘要文字。", kind: .text),
        "description": .init(label: "描述", hint: "SEO 描述。", kind: .text),
        "keywords": .init(label: "关键词", hint: "SEO 关键词，多个用逗号分隔。", kind: .text),
        "sticky": .init(label: "置顶", hint: "数字越大越靠前。", kind: .integer),
        "order": .init(label: "排序权重", hint: "数字越小越靠前。", kind: .integer),
        "cover": .init(label: "封面图", hint: "页面顶部大图的地址。", kind: .text),
        "banner": .init(label: "横幅图", hint: "部分主题用的横幅背景。", kind: .text),
        "avatar": .init(label: "头像", hint: "部分主题支持单独的头像。", kind: .text),
        "type": .init(label: "类型", hint: "部分主题用它区分页面种类。", kind: .text),
        "sidebar": .init(label: "侧边栏", hint: "是否显示侧边栏。", kind: .boolean),
        "comments_count": .init(label: "评论数", hint: "部分主题手动指定。", kind: .integer),
        "extend": .init(label: "扩展字段", hint: "主题自定义配置，可能是多行。", kind: .multiline),

        // 文章专有，页面里出现时一并显示
        "tags": .init(label: "标签", hint: "页面的标签。", kind: .list),
        "categories": .init(label: "分类", hint: "页面的分类。", kind: .list)
    ]

    static func lookup(_ key: String) -> Entry? { entries[key] }
}

/// 页面管理。
enum PageStore {

    /// 支持的页面文件扩展名。
    private static let markdownExtensions = ["md", "markdown"]

    /// 扫描站点 source 下所有页面。
    ///
    /// 会连 `_posts` 里的文章一起扫出来（文章也是「页面」的一种），
    /// 这样用户在一个列表里能看到全部内容，不用先想「这是文章还是页面」。
    static func scan(site: HexoSite) -> [PageFile] {
        let fm = FileManager.default
        let sourceDir = site.path + "/source"
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: sourceDir),
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        ) else { return [] }

        var results: [PageFile] = []
        let sourceRoot = (site.path as NSString).appendingPathComponent("source")

        while let url = enumerator.nextObject() as? URL {
            // 取相对于 source 目录的路径
            let relative = url.path.replacingOccurrences(of: sourceRoot + "/", with: "")
            if let file = makePageFile(relative: relative, sourceRoot: sourceRoot) {
                results.append(file)
            }
        }

        // 文章在前，其余按修改时间倒序
        results.sort { lhs, rhs in
            if lhs.isPost != rhs.isPost { return lhs.isPost }
            return (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast)
        }
        return results
    }

    /// 把扫描到的一个相对路径转成 PageFile。不是内容文件就返回 nil。
    private static func makePageFile(relative: String, sourceRoot: String) -> PageFile? {
        // 跳过隐藏文件与依赖目录
        if relative.hasPrefix(".") { return nil }
        if relative.contains("/.") { return nil }

        let fm = FileManager.default
        let full = sourceRoot + "/" + relative

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: full, isDirectory: &isDirectory), isDirectory.boolValue == false else { return nil }

        let ext = (relative as NSString).pathExtension.lowercased()
        let isMarkdown = markdownExtensions.contains(ext)

        if !isMarkdown {
            // 有同名 markdown 的不重复收录（用户想编辑的是 md 那个）
            let sibling = (full as NSString).deletingPathExtension + ".md"
            if fm.fileExists(atPath: sibling) { return nil }
            guard ["html", "htm", "txt"].contains(ext) else { return nil }
        }

        let attributes = try? fm.attributesOfItem(atPath: full)
        let modified = attributes?[.modificationDate] as? Date
        let size = (attributes?[.size] as? Int) ?? 0

        let isPost = relative.hasPrefix("_posts/") || relative.hasPrefix("_posts\\")

        var title = defaultTitle(from: relative)
        var hasFront = false

        if isMarkdown {
            if let text = try? String(contentsOfFile: full, encoding: .utf8) {
                let split = FrontMatterCodec.split(text)
                hasFront = split.front?.isPresent == true
                if let front = split.front, let t = front.title, t.isEmpty == false {
                    title = t
                }
            }
        }

        let name = (relative as NSString).deletingPathExtension
        let kind: PageFile.Kind
        if !isMarkdown {
            kind = .asset
        } else if name.hasSuffix("/index") || name == "index" {
            kind = .indexed
        } else {
            kind = .standalone
        }

        return PageFile(
            path: full,
            relativePath: relative,
            slug: slug(from: relative),
            title: title,
            kind: kind,
            isPost: isPost,
            hasFrontMatter: hasFront,
            modifiedAt: modified,
            size: size
        )
    }

    /// 只取页面（不含文章）。
    static func pagesOnly(site: HexoSite) -> [PageFile] {
        scan(site: site).filter { $0.isPost == false }
    }

    /// 从相对路径推出 slug。
    static func slug(from relative: String) -> String {
        var name = (relative as NSString).deletingPathExtension
        if name.hasSuffix("/index") { name = String(name.dropLast("/index".count)) }
        if name == "index" { name = "" }
        return name.isEmpty ? "首页" : name
    }

    /// 没有 title 时的兜底显示名。
    private static func defaultTitle(from relative: String) -> String {
        let name = slug(from: relative)
        if name == "首页" { return "首页" }
        // 路径里可能有中文，直接拿来当标题比转拼音友好
        return name
    }

    // MARK: - 新建

    /// 新建页面。
    ///
    /// 默认建成 `source/<slug>/index.md`（`about/index.md`），
    /// 这是「关于」「友链」这类页面最常见的写法，URL 就是 `/about/`，
    /// 比 `about.md` 生成 `/about.html` 好看得多。
    static func create(
        site: HexoSite,
        slug: String,
        title: String,
        layout: String,
        extraFrontMatter: [String: String] = [:]
    ) throws -> PageFile {
        let fm = FileManager.default
        let cleanSlug = sanitize(slug)
        guard cleanSlug.isEmpty == false else {
            throw PageStoreError.invalidSlug
        }

        let directory = site.path + "/source/\(cleanSlug)"
        let filePath = directory + "/index.md"

        guard fm.fileExists(atPath: filePath) == false else {
            throw PageStoreError.alreadyExists("\(cleanSlug)/index.md")
        }

        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)

        var front = FrontMatter()
        front.set("title", YAMLFormat.encode(title, hint: .text))
        front.set("date", FrontMatter.renderDate(Date()))
        if layout.isEmpty == false {
            front.set("layout", layout)
        }
        for (key, value) in extraFrontMatter.sorted(by: { $0.key < $1.key }) {
            front.set(key, value)
        }

        let body = """

        在这里写页面内容，支持 Markdown。

        """
        try FrontMatterCodec.render(front: front, body: body)
            .write(toFile: filePath, atomically: true, encoding: .utf8)

        return PageFile(
            path: filePath,
            relativePath: "\(cleanSlug)/index.md",
            slug: cleanSlug,
            title: title,
            kind: .indexed,
            isPost: false,
            hasFrontMatter: true,
            modifiedAt: Date(),
            size: (try? fm.attributesOfItem(atPath: filePath))?[.size] as? Int ?? 0
        )
    }

    /// 把用户输入的路径片段洗成安全的目录名。
    ///
    /// 小白很容易在名字里打空格、中文、甚至 `../`。
    /// 这里统一处理：中文和字母数字保留，其余换成短横线，`..` 一律拒绝。
    static func sanitize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "" }
        guard trimmed.contains("..") == false else { return "" }

        // 按「非字母数字/连字符/下划线/中文」切分
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_"))
            .union(CharacterSet(charactersIn: "一"..."龥"))

        let cleaned = String(trimmed.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(String(scalar)) : "-"
        })

        return String(cleaned)
            .replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// 文件名是否合法。
    static func isValidSlug(_ raw: String) -> Bool {
        let cleaned = sanitize(raw)
        return cleaned.isEmpty == false && cleaned == raw.trimmingCharacters(in: .whitespaces)
            || (cleaned.isEmpty == false && sanitize(cleaned) == cleaned)
    }

    // MARK: - 读

    /// 读一个页面的完整内容。
    static func load(_ page: PageFile) -> (front: FrontMatter, body: String) {
        guard let text = try? String(contentsOfFile: page.path, encoding: .utf8) else {
            return (FrontMatter(), "")
        }
        let split = FrontMatterCodec.split(text)
        return (split.front ?? FrontMatter(entries: [], isPresent: false), split.body)
    }

    /// 生成页面的交互式表单字段。
    ///
    /// 顺序策略：**HexoMan 认识的常用字段排前面**，用户自己加的字段排后面。
    /// 这样打开一个已有页面，最需要改的几项一屏可见，不用往下翻。
    static func fields(for front: FrontMatter) -> [PageField] {
        let knownOrder = [
            "title", "layout", "date", "updated", "permalink", "draft", "published",
            "cover", "banner", "description", "excerpt", "keywords", "sticky", "order",
            "toc", "comments", "mathjax", "mermaid", "chart", "emoji", "password", "sidebar"
        ]

        var known: [PageField] = []
        var unknown: [PageField] = []

        for entry in front.entries {
            let info = PageFieldKnowledge.lookup(entry.key)
            let value = entry.rawValue
            let listItems = entry.isBlockList
                ? value.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.isEmpty == false }
                : FrontMatter.splitInlineList(value.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))

            let kind: PageField.Kind = info?.kind ?? (entry.isBlockList ? .list : .passthrough)

            let field = PageField(
                key: entry.key,
                label: info?.label ?? entry.key,
                hint: info?.hint ?? (info == nil ? "这个字段 HexoMan 不认识，会原样保留。你可以直接改它的值。" : ""),
                kind: kind,
                value: entry.isBlockList ? "" : value,
                items: listItems,
                isKnown: info != nil
            )

            if info != nil { known.append(field) } else { unknown.append(field) }
        }

        // 按常用顺序排
        known.sort { lhs, rhs in
            let li = knownOrder.firstIndex(of: lhs.key) ?? Int.max
            let ri = knownOrder.firstIndex(of: rhs.key) ?? Int.max
            if li != ri { return li < ri }
            return false
        }

        return known + unknown
    }

    // MARK: - 写

    /// 保存页面。
    ///
    /// 策略是**只改被显式修改的字段**：`changedKeys` 里没出现的键一律保持原样。
    /// 整份 front-matter 重新渲染的话，块状列表会被洗成内联、注释会丢，
    /// 用户改一个标题却看到整个文件都变了——这是最招人烦的一类体验。
    static func save(
        _ page: PageFile,
        front: FrontMatter,
        body: String
    ) throws {
        try FrontMatterCodec.render(front: front, body: body)
            .write(to: URL(fileURLWithPath: page.path), atomically: true, encoding: .utf8)
    }

    /// 只改一个 front-matter 字段，正文完全不动。
    ///
    /// 这是最安全的改法：只重渲染 front-matter 那几行，
    /// 正文一个字节都不碰，也不存在「把别的键洗掉」的风险。
    static func updateField(_ page: PageFile, key: String, value: String, kind: PageField.Kind) throws {
        let (front, body) = load(page)
        var updated = front

        switch kind {
        case .list:
            let items = FrontMatter.splitInlineList(value.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
                .filter { $0.isEmpty == false }
            updated.set(key, FrontMatter.renderList(items))
        case .boolean:
            let lowered = value.trimmingCharacters(in: .whitespaces).lowercased()
            updated.set(key, ["true", "yes", "1", "on"].contains(lowered) ? "true" : "false")
        case .integer:
            updated.set(key, Int(value.trimmingCharacters(in: .whitespaces)).map(String.init) ?? "0")
        case .date:
            updated.set(key, value)
        case .choice, .text, .multiline, .passthrough:
            updated.set(key, value)
        }

        try save(page, front: updated, body: body)
    }

    /// 删除 front-matter 里的某个键。
    static func removeField(_ page: PageFile, key: String) throws {
        let (front, body) = load(page)
        var updated = front
        updated.remove(key)
        try save(page, front: updated, body: body)
    }

    /// 新增一个 front-matter 字段。
    static func addField(_ page: PageFile, key: String, value: String) throws {
        let (front, body) = load(page)
        var updated = front
        updated.set(key, value)
        try save(page, front: updated, body: body)
    }

    // MARK: - 删除

    /// 删除页面文件。
    ///
    /// 连带删掉它独占的目录——`source/about/index.md` 删了之后，
    /// 留一个空的 `source/about/` 目录在仓库里很难看。
    /// 但目录里还有别的文件就不动，避免误删。
    static func delete(_ page: PageFile) throws {
        let fm = FileManager.default
        let directory = (page.path as NSString).deletingLastPathComponent
        try fm.removeItem(atPath: page.path)

        let sourceRoot = directory + "/../"
        let parent = (directory as NSString).deletingLastPathComponent
        guard parent == sourceRoot || parent.hasSuffix("/source") else { return }

        if let remaining = try? fm.contentsOfDirectory(atPath: directory), remaining.isEmpty {
            try? fm.removeItem(atPath: directory)
        }
    }
}

enum PageStoreError: LocalizedError {
    case invalidSlug
    case alreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .invalidSlug:
            return """
            页面名不合法。只能用中英文、数字、短横线和下划线。
            试试「about」「关于」「friends」这样的名字。
            """
        case .alreadyExists(let name):
            return "已经有一个 \(name) 了，换个名字或者直接去编辑它。"
        }
    }
}
