//
//  FrontMatter.swift
//  HexoMan
//
//  文章 front-matter 的解析与回写。目标是「读到什么样，写回去就还什么样」。
//

import Foundation

/// 一条 front-matter 记录。`rawValue` 保留用户写的原文，避免改一次标题就把格式全洗掉。
struct FrontMatterEntry: Equatable, Hashable {
    var key: String
    /// `key:` 后面的值。块状列表时，这里存的是去掉 `- ` 前缀后用换行连接的条目。
    var rawValue: String
    /// 值是不是「换行 + 缩进 `- item`」的块状写法。
    ///
    /// 必须单独记一个标志：用户手写 `tags:\n  - A` 和内联的 `tags: [A]` 语义相同，
    /// 但保存时都应该保持他原来的样子，不能趁编辑顺手把格式洗掉。
    var isBlockList: Bool
    /// **原样保留**的缩进块（嵌套映射、列表套列表这类）。
    ///
    /// ## 为什么必须有这个字段
    ///
    /// 解析缩进块时如果只认「每行都以 `- ` 开头」，碰到这种 front-matter 就会崩：
    ///
    ///     girls:
    ///       - name: 阿蕾奇诺      ← 收进来
    ///         from: 原神            ← 不是 - 开头，于是循环在这里中断
    ///         reason: "父亲！！！"
    ///       - name: 哥伦比娅        ← 后面全部再也读不到
    ///         ...
    ///
    /// 后果是**保存即删数据**：60 个条目解析出来只剩 1 个，
    /// 用户只是改了页面标题，保存一下就只剩一个人物了。
    ///
    /// 所以这里对拿不准的缩进块一律**整块原样存下来**，
    /// 写回去时逐字节还原。保真优先于「解析得多聪明」。
    var verbatimBlock: String?

    init(key: String, rawValue: String, isBlockList: Bool = false, verbatimBlock: String? = nil) {
        self.key = key
        self.rawValue = rawValue
        self.isBlockList = isBlockList
        self.verbatimBlock = verbatimBlock
    }

    /// 是不是一个「不是简单标量列表」的复杂块。
    var isComplexBlock: Bool { verbatimBlock != nil }

    /// 按原文渲染这一行（块状列表会展开成多行）。
    var rendered: String {
        // 复杂块逐字节还原，一个空格都不动
        if let verbatimBlock {
            return "\(key):\n\(verbatimBlock)"
        }
        if isBlockList {
            let items = rawValue.components(separatedBy: "\n")
                .filter { !$0.isEmpty }
                .map { "  - \($0)" }
                .joined(separator: "\n")
            return "\(key):\n\(items)"
        }
        return rawValue.isEmpty ? "\(key):" : "\(key): \(rawValue)"
    }
}

/// front-matter 的键值集合，保持原始顺序。
struct FrontMatter: Equatable, Hashable {
    var entries: [FrontMatterEntry] = []

    /// 原文是否本来就有 front-matter。
    ///
    /// 少了这个标志，保存一篇「没有 front-matter 的纯正文」时会被补上一个空的
    /// `---` 块——内容没变，但对用户来说文件被无端改动过了。
    var isPresent: Bool = true

    /// 按 key 取原始值。
    func raw(_ key: String) -> String? {
        entries.first { $0.key == key }?.rawValue
    }

    mutating func set(_ key: String, _ value: String) {
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index].rawValue = value
            entries[index].isBlockList = false
            // 改成标量之后，原来那块嵌套结构就没了，必须清掉，
            // 否则 rendered 会优先吐 verbatimBlock，把这次修改吃掉。
            entries[index].verbatimBlock = nil
        } else {
            entries.append(FrontMatterEntry(key: key, rawValue: value))
        }
    }

    /// 整块替换一个复杂缩进块的内容（`girls:` 这类列表套映射）。
    mutating func setBlock(_ key: String, _ block: String) {
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = entries.firstIndex(where: { $0.key == key }) {
            if trimmed.isEmpty {
                entries[index] = FrontMatterEntry(key: key, rawValue: "")
            } else {
                entries[index] = FrontMatterEntry(key: key, rawValue: "", verbatimBlock: block)
            }
        } else if trimmed.isEmpty == false {
            entries.append(FrontMatterEntry(key: key, rawValue: "", verbatimBlock: block))
        }
    }

    mutating func remove(_ key: String) {
        entries.removeAll { $0.key == key }
    }

    // MARK: - 常用字段的强类型访问

    var title: String? { string("title") }

    /// 文章日期。支持 `YYYY-MM-DD HH:mm:ss` 和 `YYYY-MM-DD`。
    var date: Date? { date("date") }

    var tags: [String] { list("tags") }
    var categories: [String] { list("categories") }
    var layout: String? { string("layout") }
    var draft: Bool { bool("draft") }

    mutating func setTitle(_ value: String) { set("title", value) }
    mutating func setTags(_ value: [String]) { set("tags", Self.renderList(value)) }
    mutating func setCategories(_ value: [String]) { set("categories", Self.renderList(value)) }
    mutating func setDraft(_ value: Bool) { set("draft", value ? "true" : "false") }

    /// 新文章 front-matter 的默认模板，顺序贴合 Hexo `hexo new` 的习惯。
    static func template(title: String, date: Date = Date()) -> FrontMatter {
        var front = FrontMatter()
        front.set("title", title)
        front.set("date", Self.renderDate(date))
        front.set("tags", "")
        front.set("categories", "")
        return front
    }

    // MARK: - 标量转换

    /// 取一个键的字符串值（去掉首尾空白，空串返回 nil）。
    ///
    /// 刻意不用 `private`：页面表单要拿 `layout`、`permalink` 这类字段的
    /// 原始值来渲染控件，PageStore 也在用。
    func string(_ key: String) -> String? {
        guard let raw = raw(key) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    func bool(_ key: String) -> Bool {
        guard let raw = raw(key)?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return raw == "true" || raw == "yes" || raw == "1"
    }

    func date(_ key: String) -> Date? {
        guard let raw = string(key) else { return nil }
        return Self.parseDate(raw)
    }

    /// 解析列表。同时认得内联 `[a, b]` 和块状 `换行 - a` 两种写法。
    ///
    /// 块状写法是 `hexo new` 的默认产物，也是绝大多数真实博客的写法，
    /// 只认内联会让标签/分类整片读不出来。
    func list(_ key: String) -> [String] {
        guard let entry = entries.first(where: { $0.key == key }) else { return [] }

        // 块状：解析时已把每项的 `- ` 前缀去掉、按行存好了
        if entry.isBlockList {
            return entry.rawValue
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        let trimmed = entry.rawValue.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            let inner = String(trimmed.dropFirst().dropLast())
            return FrontMatter.splitInlineList(inner)
        }

        return trimmed
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - 渲染辅助

    /// 切分内联列表，**引号内的逗号不算分隔符**。
    ///
    /// `["带,逗号", "普通"]` 必须切出两项而不是三项。
    static func splitInlineList(_ inner: String) -> [String] {
        var items: [String] = []
        var current = ""
        var quote: Character?

        for character in inner {
            if let open = quote {
                // 闭引号后紧跟逗号才说明这一项结束，否则引号本身就是内容
                if character == open {
                    quote = nil
                    current.append(character)
                } else {
                    current.append(character)
                }
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "," {
                let cleaned = current.trimmingCharacters(in: .whitespaces)
                if cleaned.isEmpty == false { items.append(cleaned) }
                current = ""
            } else {
                current.append(character)
            }
        }

        let tail = current.trimmingCharacters(in: .whitespaces)
        if tail.isEmpty == false { items.append(tail) }

        return items
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func renderList(_ values: [String]) -> String {
        values.isEmpty ? "" : "[\(values.joined(separator: ", "))]"
    }

    static func renderDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-ddTHH:mm:ssZ", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

/// 负责把整篇 Markdown 切成 front-matter 和正文。
enum FrontMatterCodec {

    /// 切分。开头没有 `---` 时 front 为 nil，正文是全文。
    static func split(_ text: String) -> (front: FrontMatter?, body: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")

        guard normalized.hasPrefix("---") else {
            return (FrontMatter(entries: [], isPresent: false), normalized)
        }

        let lines = normalized.components(separatedBy: "\n")
        guard let closingIndex = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" })
        else { return (nil, normalized) }

        var entries: [FrontMatterEntry] = []
        var index = 1

        while index < closingIndex {
            let line = lines[index]

            // 只处理第一列的键。缩进行由上一个键的块整体消费（见下），
            // 走到这里的缩进内容说明上面的块没被正确接管——跳过，绝不当成新键。
            guard let first = line.first, first != " ", first != "\t", first != "#" else {
                index += 1
                continue
            }
            guard let colon = line.firstIndex(of: ":") else {
                index += 1
                continue
            }

            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                index += 1
                continue
            }

            // 收集这个键下面**全部**缩进行，而不是遇到非 `-` 行就停。
            //
            // 原实现在第一个不以 `-` 开头的缩进行处 break，
            // 于是 `girls:` 这种「列表套映射」的块只读进第一项的 name，
            // 其余几十项连同 from/reason 全部丢失——保存即删数据。
            if value.isEmpty {
                var blockLines: [String] = []
                var lookahead = index + 1

                while lookahead < closingIndex {
                    let candidate = lines[lookahead]
                    let isBlank = candidate.trimmingCharacters(in: .whitespaces).isEmpty
                    let isIndented = candidate.first == " " || candidate.first == "\t"
                    // 空行属于块的一部分（块状列表里常有），但不能越过后面的新键
                    if isBlank {
                        blockLines.append(candidate)
                        lookahead += 1
                        continue
                    }
                    guard isIndented else { break }
                    blockLines.append(candidate)
                    lookahead += 1
                }

                // 去掉块尾部的空行，避免把下一个键和这个块在文本上粘连
                while blockLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                    blockLines.removeLast()
                }

                if blockLines.isEmpty == false {
                    let meaningful = blockLines.filter { $0.trimmingCharacters(in: .whitespaces).isEmpty == false }

                    // 全部都是「缩进 - 纯文本项」→ 这才是可以当列表编辑的简单块
                    let simpleItems = meaningful.allSatisfy { line in
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("-") else { return false }
                        let item = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                        return item.isEmpty == false && item.contains(": ") == false
                    }

                    if simpleItems {
                        let items = meaningful.map { line -> String in
                            let trimmed = line.trimmingCharacters(in: .whitespaces)
                            return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                        }
                        entries.append(
                            FrontMatterEntry(key: key, rawValue: items.joined(separator: "\n"), isBlockList: true)
                        )
                    } else {
                        // 嵌套映射、列表套映射……原样保存，写回时逐字节还原
                        entries.append(
                            FrontMatterEntry(key: key, rawValue: "", verbatimBlock: blockLines.joined(separator: "\n"))
                        )
                    }

                    index = lookahead
                    continue
                }
            }

            entries.append(FrontMatterEntry(key: key, rawValue: value))
            index += 1
        }

        let bodyStart = closingIndex + 1
        let body = bodyStart < lines.count ? lines[bodyStart...].joined(separator: "\n") : ""
        return (FrontMatter(entries: entries), body)
    }

    /// 回写。没有 front 时不加 `---` 包裹。
    static func render(front: FrontMatter, body: String) -> String {
        // 原文没有 front-matter，保存时也不要给它加一个
        guard front.isPresent else { return body }

        var output = "---\n"
        for entry in front.entries {
            output += entry.rendered + "\n"
        }
        output += "---"
        return output + "\n" + body
    }
}
