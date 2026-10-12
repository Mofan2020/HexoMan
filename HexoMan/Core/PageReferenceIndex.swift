//
//  PageReferenceIndex.swift
//  HexoMan
//
//  扫描 `source/_posts/*.md`，找出哪些文章引用了某个页面。
//
//  判定方法：扫描每篇文章的正文 + front-matter，找：
//  1. 相对链接 /about/、./about/、../about/ —— 对应 source/about.md 或
//     source/about/index.md（Hexo 默认行为）。
//  2. Markdown 链接 [text](permalink) 形式，permalink 是页面 front-matter 里
//     permalink: 字段的值。
//  3. permalink 相等（front-matter 里直接写 permalink: /xxx/）。
//
//  这是一个 O(N*M) 的扫描。Hexo 站点文章数量通常 < 1000，每次 PagesView
//  切换选中页时跑一次没问题。如果未来要支持 10000+ 文章，再考虑缓存。
//

import Foundation

struct PageReference: Identifiable {
    var postTitle: String
    var postFilePath: String
    /// 链接形式（路径/permalink/标签）
    var matchKind: MatchKind
    var matchSnippet: String

    enum MatchKind {
        case pathLink
        case permalink
        case tag
    }

    var id: String { "\(postFilePath)#\(matchSnippet)" }
}

enum PageReferenceIndex {

    /// 找出所有引用了 `page` 的文章。
    static func references(to page: BlogPage, in site: HexoSite) -> [PageReference] {
        let postsDir = site.resolvedPostsDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: postsDir) else {
            return []
        }

        // 计算 page 在 source 下的相对路径（不含 .md 后缀）。
        let pageRelPath = relativeSourcePath(of: page.filePath, siteRoot: site.path)
        let pagePermalink = page.front.entries.first(where: { $0.key == "permalink" })?
            .rawValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // 这个 page 自己拥有的标签——任何带这些标签的文章都算「关联」。
        let pageTags = Set(page.tags.map { $0.lowercased() })

        var results: [PageReference] = []

        for entry in entries {
            guard entry.hasSuffix(".md") else { continue }
            let postPath = (postsDir as NSString).appendingPathComponent(entry)
            guard let (front, body) = loadPost(at: postPath) else { continue }
            // 跳过自己（页面文件如果恰好被放在 _posts 里）
            if postPath == page.filePath { continue }

            // 1. 路径链接
            if pageRelPath.isEmpty == false,
               body.contains(pageRelPath) {
                results.append(PageReference(
                    postTitle: titleFrom(front: front, fallback: entry),
                    postFilePath: postPath,
                    matchKind: .pathLink,
                    matchSnippet: pageRelPath
                ))
                continue
            }

            // 2. permalink
            if pagePermalink.isEmpty == false,
               body.contains(pagePermalink) {
                results.append(PageReference(
                    postTitle: titleFrom(front: front, fallback: entry),
                    postFilePath: postPath,
                    matchKind: .permalink,
                    matchSnippet: pagePermalink
                ))
                continue
            }

            // 3. 标签交集
            let postTags = front.tags.map { $0.lowercased() }
            if pageTags.isEmpty == false,
               postTags.contains(where: pageTags.contains) {
                let shared = postTags.first(where: pageTags.contains) ?? ""
                results.append(PageReference(
                    postTitle: titleFrom(front: front, fallback: entry),
                    postFilePath: postPath,
                    matchKind: .tag,
                    matchSnippet: shared
                ))
            }
        }

        return results
    }

    // MARK: - 私有

    /// 把页面的绝对路径转成 `source/` 下的相对路径，去掉 `.md`。
    /// `/path/to/site/source/about.md` → `about`
    /// `/path/to/site/source/about/index.md` → `about`
    private static func relativeSourcePath(of pagePath: String, siteRoot: String) -> String {
        let sourceDir = (siteRoot as NSString).appendingPathComponent("source")
        guard pagePath.hasPrefix(sourceDir) else { return "" }
        var rel = String(pagePath.dropFirst(sourceDir.count + 1))
        if rel.hasSuffix(".md") { rel = String(rel.dropLast(3)) }
        // about/index → about
        if rel.hasSuffix("/index") { rel = String(rel.dropLast("/index".count)) }
        return rel
    }

    private static func loadPost(at path: String) -> (FrontMatter, String)? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        // 用 FrontMatter.split：返回 (front?, body)，front 可能为 nil（极少见，缺 ---）。
        let (frontOpt, body) = FrontMatterCodec.split(text)
        guard let front = frontOpt else { return nil }
        return (front, body)
    }

    private static func titleFrom(front: FrontMatter, fallback: String) -> String {
        // FrontMatter 是从 FrontMatterEntry 列表里查 title。
        if let entry = front.entries.first(where: { $0.key == "title" }) {
            let raw = entry.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty == false {
                return raw
            }
        }
        return (fallback as NSString).deletingPathExtension
    }
}