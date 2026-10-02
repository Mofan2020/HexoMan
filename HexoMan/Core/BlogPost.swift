//
//  BlogPost.swift
//  HexoMan
//
//  文章模型与文件读写。文章就是 `source/_posts` 下的 Markdown，没有任何数据库。
//

import Foundation

/// 一篇文章。`id` 用文件绝对路径，保证同一篇文章在列表里稳定唯一。
struct BlogPost: Identifiable, Hashable {
    /// 文件绝对路径。
    var filePath: String
    var front: FrontMatter
    var body: String
    /// 文件修改时间。
    var modifiedAt: Date
    /// 文件字节数。
    var byteSize: Int

    var id: String { filePath }

    /// 文件名（含扩展名）。
    var filename: String {
        (filePath as NSString).lastPathComponent
    }

    /// 不含扩展名的文件名，也就是 URL 里的 slug。
    var slug: String {
        (filePath as NSString).deletingPathExtension
    }

    /// 标题：front-matter 优先，缺失时退回文件名。
    var title: String {
        front.title ?? slug
    }

    var date: Date { front.date ?? modifiedAt }
    var tags: [String] { front.tags }
    var categories: [String] { front.categories }
    var isDraft: Bool { front.draft }

    /// 正文字数，剔除 Markdown 标记的粗略统计，用于列表副标题。
    var wordCount: Int {
        body
            .replacingOccurrences(of: "```", with: "")
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .count
    }

    /// 一段短摘要，用作文章列表的预览行。
    var excerpt: String {
        let flattened = body
            .replacingOccurrences(of: "```", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !flattened.isEmpty else { return "（空文章）" }
        return flattened.count <= 80 ? flattened : String(flattened.prefix(80)) + "…"
    }
}

/// 文章文件操作。全部走 FileManager，没有中间数据库。
enum PostStore {

    enum StoreError: LocalizedError {
        case notFound(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let path): return "文件不存在：\(path)"
            case .writeFailed(let reason): return "写入失败：\(reason)"
            }
        }
    }

    /// 读取站点全部文章，按日期倒序（同日按文件名兜底排序）。
    static func load(site: HexoSite) -> [BlogPost] {
        let directory = URL(fileURLWithPath: site.postsDirectory)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .filter { ["md", "markdown"].contains($0.pathExtension.lowercased()) }
            .compactMap(read)
            .sorted { lhs, rhs in
                if lhs.date == rhs.date { return lhs.filename > rhs.filename }
                return lhs.date > rhs.date
            }
    }

    /// 读取单个文件。
    static func read(_ url: URL) -> BlogPost? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        let (front, body) = FrontMatterCodec.split(text)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)

        return BlogPost(
            filePath: url.path,
            front: front ?? FrontMatter(),
            body: body,
            modifiedAt: attributes?[.modificationDate] as? Date ?? Date.distantPast,
            byteSize: attributes?[.size] as? Int ?? text.utf8.count
        )
    }

    /// 新建文章。文件名用标题做 slug，重名时自动追加序号。
    ///
    /// `date` 和 `draft` 一起收进来，是因为编辑器要一次性把新建的元信息写全。
    /// 早先的版本不给这两个参数，导致调用方只能建完文件再回查路径补写一遍 front-matter。
    @discardableResult
    static func create(
        site: HexoSite,
        title: String,
        body: String = "",
        tags: [String] = [],
        categories: [String] = [],
        date: Date = Date(),
        isDraft: Bool = false
    ) throws -> BlogPost {
        let fm = FileManager.default
        try fm.createDirectory(atPath: site.postsDirectory, withIntermediateDirectories: true)

        var front = FrontMatter.template(title: title, date: date)
        if !tags.isEmpty { front.setTags(tags) }
        if !categories.isEmpty { front.setCategories(categories) }
        if isDraft { front.setDraft(true) }

        let url = uniqueURL(in: URL(fileURLWithPath: site.postsDirectory), slug: slugify(title))
        try FrontMatterCodec.render(front: front, body: body).write(to: url, atomically: true, encoding: .utf8)

        guard let post = read(url) else { throw StoreError.writeFailed(url.lastPathComponent) }
        return post
    }

    /// 保存文章（front-matter + 正文一起写回）。
    static func save(_ post: BlogPost) throws {
        let text = FrontMatterCodec.render(front: post.front, body: post.body)
        try text.write(to: URL(fileURLWithPath: post.filePath), atomically: true, encoding: .utf8)
    }

    /// 删除文章。走废纸篓而不是直接 unlink，误删可恢复。
    static func trash(_ post: BlogPost) throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: post.filePath), resultingItemURL: nil)
    }

    /// 把 front-matter 里的 `draft: true` 改成 false，即「发布」。
    static func publish(_ post: BlogPost) throws -> BlogPost {
        var updated = post
        updated.front.setDraft(false)
        try save(updated)
        return read(URL(fileURLWithPath: updated.filePath)) ?? updated
    }

    /// 改成草稿。
    static func unpublish(_ post: BlogPost) throws -> BlogPost {
        var updated = post
        updated.front.setDraft(true)
        try save(updated)
        return read(URL(fileURLWithPath: updated.filePath)) ?? updated
    }

    /// 在访达中显示。
    static func reveal(_ post: BlogPost) {
        NSWorkspaceBridge.reveal(post.filePath)
    }

    // MARK: - 文件名

    /// 标题转文件名。保留中文与字母数字，其余折叠成连字符。
    static func slugify(_ title: String) -> String {
        var result = ""

        for character in title {
            for scalar in character.unicodeScalars {
                // 保留 ASCII 字母数字、中日韩汉字、下划线和连字符
                let isAlnum = (scalar.value >= 48 && scalar.value <= 57)
                    || (scalar.value >= 65 && scalar.value <= 90)
                    || (scalar.value >= 97 && scalar.value <= 122)
                let isCJK = scalar.value >= 0x4E00 && scalar.value <= 0x9FFF

                if isAlnum || isCJK {
                    result.unicodeScalars.append(scalar)
                } else if scalar == " " || scalar == "-" || character.isWhitespace {
                    result.append("-")
                }
            }
        }

        // 折叠连续连字符并去掉首尾
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))

        return result.isEmpty ? "untitled" : result
    }

    /// 避免覆盖同名文件。
    private static func uniqueURL(in directory: URL, slug: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent("\(slug).md")
        var counter = 2

        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(slug)-\(counter).md")
            counter += 1
        }

        return candidate
    }
}
