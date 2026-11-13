//
//  SiteMedia.swift
//  HexoMan
//
//  往站点里放图片：存到 source/images/<年>/，并把 Markdown 引用拼出来。
//
//  为什么要有这一层：Hexo 的图片有两种写法——`![](/images/x.png)`（放
//  source/images 下，任何主题都认）和 `{% asset_img %}`（文章资源文件夹，
//  要求 post_asset_folder 打开）。后者依赖配置，前者永远能用，所以这里一律
//  写前者。
//

import AppKit
import Foundation

enum SiteMedia {

    /// 一次插图的结果。
    struct Stored {
        /// 磁盘上的绝对路径。
        let url: URL
        /// 相对站点根目录的路径，以 `/` 开头，如 `/images/2026/hello-1.png`。
        let relativePath: String
        /// 直接能贴进正文的 Markdown。
        let markdown: String
    }

    /// 支持直接落盘的扩展名。HEIC/HEIF 例外——浏览器不认，得转 PNG。
    static let writableExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "avif"]

    // MARK: - 路径

    /// `<site>/source/images/<yyyy>`。Hexo 的 `source/` 就是站点根，主题怎么换
    /// 这个路径都不变。
    static func imageDirectory(site: URL, date: Date = Date(), calendar: Calendar = .current) -> URL {
        let year = String(calendar.component(.year, from: date))
        return site
            .appendingPathComponent("source", isDirectory: true)
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(year, isDirectory: true)
    }

    /// 在目录里挑一个没被占用的文件名：`base-1.png`、`base-2.png`……
    ///
    /// **不覆盖已有文件**。同名图很常见（截图全叫「截屏2026-11-13」），覆盖掉
    /// 的话正文里先插的那张会在用户不知情的时候换掉。
    static func uniqueDestination(in directory: URL, base: String, ext: String,
                                  fileManager: FileManager = .default) -> URL {
        let stem = sanitize(base)
        let suffix = ext.lowercased()
        var index = 1
        while true {
            let candidate = directory.appendingPathComponent("\(stem)-\(index).\(suffix)")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
            if index > 9999 { break }
        }
        // 一万张同名图是不可能的，兜底给个唯一名字，别转死循环。
        let random = UUID().uuidString.prefix(8)
        return directory.appendingPathComponent("\(stem)-\(random).\(suffix)")
    }

    /// 文件名里能用的字符：字母数字、汉字、`-`、`_`。其余折成 `-`。
    static func sanitize(_ raw: String) -> String {
        let allowed = raw.unicodeScalars.map { scalar -> Character in
            let isWordChar = CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet(charactersIn: "-_").contains(scalar)
            return isWordChar ? Character(scalar) : "-"
        }
        var out = String(allowed)
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
        if out.isEmpty { out = "image" }
        return String(out.prefix(60))
    }

    // MARK: - 存图

    /// 把一张图写进站点，返回可以直接插进正文的 Markdown。
    ///
    /// - Parameters:
    ///   - data: 图片字节。
    ///   - filename: 原始文件名（用来取扩展名和 alt 文案）。
    ///   - base: 文件名主干，通常传文章 slug；空则用 `image`。
    static func store(
        data: Data,
        filename: String,
        site: URL,
        base: String,
        date: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> Stored {
        let (payload, ext) = normalize(data: data, filename: filename)
        let directory = imageDirectory(site: site, date: date)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let stem = base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "image" : base
        let destination = uniqueDestination(in: directory, base: stem, ext: ext,
                                            fileManager: fileManager)
        try payload.write(to: destination, options: .atomic)

        let year = directory.lastPathComponent
        let relativePath = "/images/\(year)/\(destination.lastPathComponent)"
        return Stored(
            url: destination,
            relativePath: relativePath,
            markdown: markdown(relativePath: relativePath, alt: altText(from: filename))
        )
    }

    /// Markdown 引用。前后各留一个空行由调用方决定——这里只给这一行。
    static func markdown(relativePath: String, alt: String) -> String {
        let trimmed = alt.trimmingCharacters(in: .whitespacesAndNewlines)
        return "![\(trimmed.isEmpty ? "图片" : trimmed)](\(relativePath))"
    }

    static func altText(from filename: String) -> String {
        let stem = (filename as NSString).deletingPathExtension
        return stem.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 格式归一

    /// 返回要写盘的字节和建议扩展名。
    ///
    /// HEIC/HEIF 是 iPhone 截图的默认格式，浏览器不认；原样插进去只会得到
    /// 一张裂图。这里统一转成 PNG，用户看不出区别。
    static func normalize(data: Data, filename: String) -> (Data, String) {
        let rawExt = (filename as NSString).pathExtension.lowercased()
        let ext = rawExt.isEmpty ? sniffExtension(data) : rawExt

        if ext == "heic" || ext == "heif" {
            if let converted = pngData(from: data) {
                return (converted, "png")
            }
            return (data, "png")   // 转不动也照写，至少名字是对的
        }
        if ext == "jpeg" { return (data, "jpg") }
        if writableExtensions.contains(ext) { return (data, ext) }
        return (data, sniffExtension(data))
    }

    /// 数据本身的第一段字节就够判断常见图片格式了。
    static func sniffExtension(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if bytes.count >= 12,
           bytes[0...3] == [0x52, 0x49, 0x46, 0x46],
           bytes[8...11] == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        return "png"
    }

    /// 交给 ImageIO 解码再编成 PNG；解不开就返回 nil。
    static func pngData(from data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// 读磁盘上的图片并归一（拖进来的文件走这条）。
    static func data(for url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return data
    }
}
