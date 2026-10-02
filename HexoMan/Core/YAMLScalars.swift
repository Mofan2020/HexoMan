//
//  YAMLScalars.swift
//  HexoMan
//
//  极简 YAML 顶层标量解析。不引第三方库，只够读 Hexo 配置里关心的那几十个键。
//

import Foundation

/// 只解析 YAML 的**顶层 `key: value`**，不处理嵌套结构、锚点、多文档等。
///
/// 存在的意义是「零依赖」：HexoMan 不值得为了读三行配置拖进一个 YAML 库。
/// 嵌套的 `permalink:`、`highlight:` 这类配置块会被跳过，因为 HexoMan 不改它们。
enum YAMLScalars {

    /// 把 YAML 文本解析成 `[顶层键: 标量值]`。
    ///
    /// - 缩进行一律跳过（属于嵌套块）
    /// - `key:` 后面没值记为空串（后面通常跟缩进列表）
    /// - 行尾注释会被剥掉，但引号内的 `#` 会保留
    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]

        for rawLine in text.components(separatedBy: .newlines) {
            // 顶层键必须在第一列，缩进行直接跳过
            guard let first = rawLine.first, first != " ", first != "\t", first != "#", first != "-" else { continue }
            guard !rawLine.hasPrefix("---"), !rawLine.hasPrefix("...") else { continue }
            guard let colon = rawLine.firstIndex(of: ":") else { continue }

            let key = String(rawLine[rawLine.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            var value = String(rawLine[rawLine.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            value = stripComment(value)

            result[key] = unquote(value)
        }

        return result
    }

    /// 剥掉行尾注释。引号内的 `#` 不算注释。
    private static func stripComment(_ value: String) -> String {
        var inSingle = false
        var inDouble = false

        for (index, character) in value.enumerated() {
            switch character {
            case "'" where !inDouble: inSingle.toggle()
            case "\"" where !inSingle: inDouble.toggle()
            case "#" where !inSingle && !inDouble:
                // 只有 # 前面是空白才是注释，避免砍掉 URL 里的 #
                if index == 0 || value[value.index(before: value.index(value.startIndex, offsetBy: index))].isWhitespace {
                    return String(value[value.startIndex..<value.index(value.startIndex, offsetBy: index)])
                        .trimmingCharacters(in: .whitespaces)
                }
            default:
                continue
            }
        }

        return value
    }

    /// 去掉成对引号，并把常见转义还原。
    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }

        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\"", with: "\"")
        }
        if value.hasPrefix("'") && value.hasSuffix("'") {
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }
        return value
    }
}
