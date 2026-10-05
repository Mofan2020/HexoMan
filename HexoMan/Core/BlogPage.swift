//
//  BlogPage.swift
//  HexoMan
//
//  页面模型。复用 BlogPost 的结构但字段适配页面（无 date/draft，有 layout/permalink）。
//

import Foundation

/// 一个页面。复用 BlogPost 的大部分字段，但去掉 date/draft，加上 layout/permalink。
struct BlogPage: Identifiable, Hashable {

    var filePath: String
    var front: FrontMatter
    var body: String
    var modifiedAt: Date
    var byteSize: Int

    var id: String { filePath }

    var filename: String {
        (filePath as NSString).lastPathComponent
    }

    var slug: String {
        (filePath as NSString).deletingPathExtension
    }

    var title: String {
        front.title ?? slug
    }

    var layout: String { front.string("layout") ?? "page" }
    var permalink: String { front.string("permalink") ?? "" }
    var tags: [String] { front.tags }
    var categories: [String] { front.categories }
    var isDraft: Bool { front.draft }

    var wordCount: Int {
        body
            .replacingOccurrences(of: "```", with: "")
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .count
    }

    var excerpt: String {
        let flattened = body
            .replacingOccurrences(of: "```", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !flattened.isEmpty else { return "（空页面）" }
        return flattened.count <= 80 ? flattened : String(flattened.prefix(80)) + "…"
    }
}