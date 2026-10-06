//
//  PageAssets.swift
//  HexoMan
//
//  页面的「关联资源」识别。
//
//  ## 要解决的问题
//
//  现代 Hexo 页面很少再靠 Markdown 正文了。典型长这样：
//
//      ---
//      title: 可爱的女孩子
//      layout: girls
//      girls:
//        - name: 阿蕾奇诺
//          ...
//      ---
//
//      <link rel="stylesheet" href="/css/girls.css">
//      <script src="/js/girls.js"></script>
//
//  正���只有两行，真正的内容在 front-matter 里（渲染时由主题模板 + JS 读出来）。
//  于是页面管理里看起来就是「一个空空如也、只有两行的页面」，
//  用户完全不知道这个页面其实有 53 条数据、还挂着两个本地文件。
//
//  ## 识别规则
//
//  只关联**本地**资源，并且必须在 source 下真实存在：
//
//  - `<link href="/css/girls.css">` → source/css/girls.css  ✔
//  - `<script src="/js/girls.js">`  → source/js/girls.js     ✔
//  - `<script src="https://cdn.jsdelivr.net/...">`          ✘ 在线，不关联
//  - `<script src="//cdn.example.com/x.js">`                ✘ 协议相对，在线，不关联
//  - `<link href="/css/theme.css">`（文件不存在）             ✘ 引用了但没建，不关联
//
//  另外按「同名约定」补一层：`girls/index.md` 会去找 source/css/girls.css、
//  source/js/girls.js。页面正文里不写引用、靠主题 layout 自动引入时靠这条兜住。
//
//  **在线资源不关联**是刻意的：它们不属于这个仓库，改不动也不该在这里编辑。
//

import Foundation

/// 一个和页面关联的本地资源。
struct PageAsset: Identifiable {

    enum Kind {
        case css, js, image, other

        var label: String {
            switch self {
            case .css: return "样式"
            case .js: return "脚本"
            case .image: return "图片"
            case .other: return "其他"
            }
        }

        var symbolName: String {
            switch self {
            case .css: return "paintbrush"
            case .js: return "curlybraces"
            case .image: return "photo"
            case .other: return "doc"
            }
        }
    }

    /// 认出来的时候走的是哪条路。
    enum Origin {
        /// 正文/front-matter 里显式写了 `<link>` / `<script>` 引用
        case explicit
        /// 按页面目录名的同名约定推断出来的
        case convention
        /// 显式写了引用，但文件在 source 下不存在
        case missing
    }

    /// id 用站点内路径——缺失的资源没有磁盘路径，用它才能保持唯一
    var id: String { sitePath }

    /// 站点内路径，如 `/css/girls.css`
    var sitePath: String
    /// 磁盘绝对路径
    var sourcePath: String
    /// 相对 source 的路径
    var relativePath: String
    var kind: Kind
    var origin: Origin
    var byteSize: Int
    var modifiedAt: Date?

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }

    var originDescription: String {
        switch origin {
        case .explicit: return "页面里引用"
        case .convention: return "同名推断"
        case .missing: return "引用了但文件不存在"
        }
    }

    var originLabel: String {
        switch origin {
        case .explicit: return "引用"
        case .convention: return "推断"
        case .missing: return "缺失"
        }
    }
}

/// 页面资源识别。
enum PageAssetScanner {

    /// 扩展名 → 类别。
    private static func kind(for path: String) -> PageAsset.Kind {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "css": return .css
        case "js", "mjs", "cjs": return .js
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "ico": return .image
        default: return .other
        }
    }

    /// 扫描一个页面的关联资源。
    ///
    /// - Parameters:
    ///   - site: 站点（用来定位 source 目录）
    ///   - page: 页面
    static func scan(site: HexoSite, page: BlogPage) -> [PageAsset] {

        let fm = FileManager.default
        let sourceRoot = (site.path as NSString).appendingPathComponent("source")

        // 页面目录名：girls/index.md → girls
        var dirName = (page.filePath as NSString).deletingLastPathComponent
        dirName = (dirName as NSString).lastPathComponent
        // 单页写法 about.md → about
        if dirName == "source" {
            dirName = (page.filename as NSString).deletingPathExtension
        }

        var found: [String: PageAsset] = [:]

        func add(_ sitePath: String, origin: PageAsset.Origin) {
            // 已经在「同名推断」阶段收录过，就不要被显式引用降级
            if let existing = found[sitePath], existing.origin == .convention, origin == .explicit {
                found[sitePath] = PageAsset(
                    sitePath: existing.sitePath, sourcePath: existing.sourcePath,
                    relativePath: existing.relativePath, kind: existing.kind,
                    origin: .explicit, byteSize: existing.byteSize, modifiedAt: existing.modifiedAt
                )
            } else if found[sitePath] == nil {
                found[sitePath] = make(sitePath: sitePath, origin: origin, sourceRoot: sourceRoot, fm: fm)
            }
        }

        // 1. 正文 + front-matter 里显式引用的本地资源
        for reference in localReferences(in: page.body) {
            add(reference, origin: .explicit)
        }
        for entry in page.front.entries {
            for reference in localReferences(in: entry.verbatimBlock ?? entry.rawValue) {
                add(reference, origin: .explicit)
            }
        }

        // 2. 同名约定兜底：girls/index.md → /css/girls.css、/js/girls.js
        if dirName.isEmpty == false, dirName != "." {
            for folder in ["css", "js"] {
                let candidate = "/\(folder)/\(dirName).\(folder == "css" ? "css" : "js")"
                add(candidate, origin: .convention)
            }
        }

        // 显式引用但文件不存在的，标成「缺失」而不是直接丢掉——
        // 那通常是路径写错了，页面在浏览器里就是白板。藏起来等于帮倒忙。
        for asset in found.values where asset.sourcePath.isEmpty && asset.origin == .explicit {
            found[asset.sitePath] = PageAsset(
                sitePath: asset.sitePath,
                sourcePath: "",
                relativePath: asset.relativePath,
                kind: asset.kind,
                origin: .missing,
                byteSize: 0,
                modifiedAt: nil
            )
        }

        return found.values
            .filter { $0.origin != .convention || $0.sourcePath.isEmpty == false }
            .sorted { lhs, rhs in
                // 缺失的排最后，正常的第一屏
                let lm = lhs.origin == .missing ? 1 : 0
                let rm = rhs.origin == .missing ? 1 : 0
                if lm != rm { return lm < rm }
                if lhs.kind.label != rhs.kind.label { return lhs.kind.label < rhs.kind.label }
                return lhs.sitePath < rhs.sitePath
            }
    }

    /// 造一个 PageAsset；本地文件不存在时返回 sourcePath 为空的实例（调用方过滤掉）。
    private static func make(
        sitePath: String,
        origin: PageAsset.Origin,
        sourceRoot: String,
        fm: FileManager
    ) -> PageAsset {

        // /css/girls.css → source/css/girls.css
        let relative = String(sitePath.dropFirst()).trimmingCharacters(in: .whitespaces)
        let full = (sourceRoot as NSString).appendingPathComponent(relative)

        let attrs = try? fm.attributesOfItem(atPath: full)
        let exists = attrs != nil

        return PageAsset(
            sitePath: sitePath,
            sourcePath: exists ? full : "",
            relativePath: relative,
            kind: kind(for: sitePath),
            origin: origin,
            byteSize: (attrs?[.size] as? Int) ?? 0,
            modifiedAt: attrs?[.modificationDate] as? Date
        )
    }

    /// 从一段 HTML/Markdown 里挑出**本地**资源引用。
    ///
    /// 只认 `href=` / `src=`，且只认以 `/` 开头的站内绝对路径。
    /// `https://`、`//cdn...`、`data:` 一律排除——在线内容不属于这个仓库。
    static func localReferences(in text: String) -> [String] {
        guard text.isEmpty == false else { return [] }

        let pattern = "(?:href|src)\\s*=\\s*[\"']([^\"']+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var results: [String] = []

        for match in regex.matches(in: text, range: range) {
            guard let capture = Range(match.range(at: 1), in: text) else { continue }
            let raw = String(text[capture]).trimmingCharacters(in: .whitespaces)

            // 只要站内绝对路径。// 开头的是协议相对地址，属于在线资源，排除。
            guard raw.hasPrefix("/"), raw.hasPrefix("//") == false else { continue }
            // 排除路由链接（/archives/ 这种不是资源）
            guard kind(for: raw) != .other else { continue }

            if results.contains(raw) == false { results.append(raw) }
        }

        return results
    }
}