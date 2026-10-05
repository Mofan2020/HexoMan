//
//  YAMLDocument.swift
//  HexoMan
//
//  完整的 YAML 解析与**行级保真回写**。这是整个 HexoMan 配置能力的地基。
//
//  为什么要重写：早先的 YAMLScalars 只认「顶层 + 单行标量」，遇到 `-` 开头的
//  列表和缩进的嵌套块一律跳过。于是像 `social:`（社媒链接列表）、
//  `avatar:`（头像，含 url/rounded/opacity）、`banner:`（首页标语）
//  这类配置在可视化页永远是空白——不是取值错，是压根没进索引。
//
//  这里做三件事：
//  1. 真正解析出「映射 / 序列 / 标量」三层结构，每个节点记住自己在源文件里的行列；
//  2. 提供 `social.0.link` 这种路径式读写，能钻进任意深度；
//  3. 写回时**只动目标那一行的值**，行尾注释、缩进、键的顺序、空行全部原样保留。
//
//  仍然零第三方依赖，遵循项目不引外部库的一贯约束。
//

import Foundation

// MARK: - 路径

/// YAML 路径的一段：`.key("social")` 或 `.index(0)`。
enum YAMLPathComponent: Equatable, Hashable {
    case key(String)
    case index(Int)
}

typealias YAMLPath = [YAMLPathComponent]

extension YAMLPathComponent: ExpressibleByStringLiteral {

    /// 让 `doc.string(at: ["avatar.url"])` 这种写法直接可用——
    /// 嵌套路径在配置代码里会写得极频繁，逐段写 `.key()` 太啰嗦。
    ///
    /// 数字段会自动识别成列表下标，所以 `["social.0.link"]` 也能用。
    init(stringLiteral value: String) {
        self = .key(value)
    }
}

extension Array where Element == YAMLPathComponent {

    /// 从 `"social.0.link"` / `"avatar.url"` 这样的记法解析出路径。
    ///
    /// 点号分段，数字段自动变成列表下标。这样上层写配置项时
    /// 可以直接用字符串描述路径，不必到处 `.key()` `.index()`。
    init(dottedPath path: String) {
        var result: [YAMLPathComponent] = []
        for piece in path.split(separator: ".", omittingEmptySubsequences: true) {
            let text = String(piece)
            if let index = Int(text), String(index) == text {
                result.append(.index(index))
            } else {
                result.append(.key(text))
            }
        }
        self = result
    }
}

extension Array where Element == YAMLPathComponent {

    /// 给人看的路径写法，例如 `social.0.link`。
    var yamlDisplay: String {
        var out = ""
        for component in self {
            switch component {
            case .key(let name):
                out += out.isEmpty ? name : ".\(name)"
            case .index(let index):
                out += "[\(index)]"
            }
        }
        return out
    }

    /// 去掉最后一段。
    var yamlParent: YAMLPath {
        Array(dropLast())
    }

    /// 最后一段的键名（序列下标没有键名）。
    var yamlLastKey: String? {
        guard let last = last else { return nil }
        if case .key(let name) = last { return name }
        return nil
    }
}

// MARK: - 节点

/// 一个标量值。记住原始写法，因为回写时要保持原样。
struct YAMLScalar: Equatable {

    /// 解析后的值（去掉了引号和行尾注释）。
    var value: String
    /// 原样保留的引号字符（`"` / `'` / nil）。
    var quote: Character?
    /// 是不是 `[a, b]` 或 `{a: b}` 这种流式写法。
    var isFlow = false
    /// 是不是 `|` / `>` 块文本。
    var isBlockScalar = false
    /// 空值（`key:` 后面什么都没有）。
    var isNull = true

    static let null = YAMLScalar(value: "", quote: nil)
}

/// 映射里的一项：`key: value`。
struct YAMLMappingEntry {
    var key: String
    var value: YAMLNode
}

/// 序列里的一项：`- xxx`。
struct YAMLSequenceItem {
    var value: YAMLNode
}

/// 解析出来的节点。带源文件位置，写回时靠它精确定位。
struct YAMLNode {

    enum Kind {
        case scalar(YAMLScalar)
        case mapping([YAMLEntry])
        case sequence([YAMLSequenceItem])
    }

    var kind: Kind
    /// 节点声明所在的行号（0 起）。序列项指向它的 `-` 那一行。
    var line: Int
    /// 逻辑缩进列数。
    var indent: Int
    /// 标量值在这一行内占据的列区间。其他类型为 nil。
    var valueColumns: Range<String.Index>?
    /// 该节点及其所有子孙占用的最后一行（含）。
    var endLine: Int

    var scalar: YAMLScalar? {
        if case .scalar(let value) = kind { return value }
        return nil
    }

    var entries: [YAMLEntry]? {
        if case .mapping(let entries) = kind { return entries }
        return nil
    }

    var items: [YAMLSequenceItem]? {
        if case .sequence(let items) = kind { return items }
        return nil
    }

    var isScalar: Bool { scalar != nil }
    var isMapping: Bool { entries != nil }
    var isSequence: Bool { items != nil }
}

struct YAMLEntry {
    var key: String
    var node: YAMLNode
}

// MARK: - 标量写法（回写时的引号策略）

enum YAMLFormat {

    /// 把用户输入的值编码成 YAML 文本。
    ///
    /// - Parameter hint: 字段期望的类型。`text` 会把 `true` / `123` 这类
    ///   看起来像非字符串的值强制加引号，避免 Hexo 那边读成了布尔或数字。
    enum Hint {
        /// 尽量裸写，保持文件清爽
        case auto
        /// 一定是字符串
        case text
        /// 一定是布尔
        case boolean
        /// 一定是整数
        case integer
        /// 原样写入，不加工
        case raw
    }

    static func encode(_ value: String, hint: Hint = .auto, keepQuote: Character? = nil) -> String {
        if hint == .raw { return value }

        // 原文件本来就带引号，或明确要求字符串类型 → 保持加引号
        let mustQuote: Bool
        switch hint {
        case .text:
            mustQuote = looksLikeNonString(value) || value.isEmpty
        case .auto:
            mustQuote = false
        default:
            mustQuote = false
        }

        if keepQuote != nil || mustQuote {
            let quote = keepQuote ?? "\""
            if quote == "'" {
                return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
            }
            return "\"" + value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n") + "\""
        }

        // 裸值安全性检查
        if value.isEmpty { return "\"\"" }
        if value == "true" || value == "false" { return value }
        if Int(value) != nil || Double(value) != nil { return value }

        let dangerous = [": ", " #", "'", "\"", "\n", "[", "]", "{", "}", ",", "&", "*", "!", "|", ">", "%", "@", "`", "#"]
        if dangerous.contains(where: { value.contains($0) }) {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        // 以特殊符号开头也要引号
        if let first = value.first, "-?:,[]{}#&*!|>'\"%@`".contains(first) {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return value
    }

    private static func looksLikeNonString(_ value: String) -> Bool {
        let lowered = value.lowercased()
        if ["true", "false", "yes", "no", "on", "off", "null", "~", "y", "n"].contains(lowered) { return true }
        if Int(value) != nil || Double(value) != nil { return true }
        return false
    }
}

// MARK: - 错误

enum YAMLError: LocalizedError {
    case pathNotFound(YAMLPath)
    case hasBlockChildren(String)
    case isNotSequence(YAMLPath)
    case isNotMapping(YAMLPath)
    case notWritable(String)
    case indexOutOfRange(Int)

    var errorDescription: String? {
        switch self {
        case .pathNotFound(let path):
            return "配置里找不到 \(path.yamlDisplay)，请先在「原始文件」里确认这个键是否存在。"
        case .hasBlockChildren(let key):
            return """
            \(key) 下面挂着一整块多行配置，HexoMan 不会把它压成一行——改坏了会让站点构建失败。
            请到「原始文件」页手动编辑，或者改用下面的子项逐条调整。
            """
        case .isNotSequence(let path):
            return "\(path.yamlDisplay) 不是一个列表，没法按条目编辑。"
        case .isNotMapping(let path):
            return "\(path.yamlDisplay) 不是一组键值，没法这样编辑。"
        case .notWritable(let reason):
            return "这一项暂时不能在可视化页改：\(reason)。请到「原始文件」页编辑。"
        case .indexOutOfRange(let index):
            return "第 \(index + 1) 条不存在了。"
        }
    }
}

// MARK: - 文档

/// 一份 YAML 文本，以及它在内存里的结构。
///
/// 每次修改都会重新解析一遍（配置文件只有几百行，这点开销可以忽略），
/// 换来的是「改完之后内存状态一定和磁盘文本一致」这个强保证——
/// 早先的 bug 教训就是状态和文本不同步会静默清空整站。
struct YAMLDocument {

    let text: String
    private(set) var lines: [String]
    private(set) var root: YAMLNode?

    init(text: String) {
        self.text = text
        self.lines = text.components(separatedBy: .newlines)
        var parser = YAMLParser(lines: self.lines)
        self.root = parser.parseDocument()
    }

    // MARK: 读

    /// 按路径找节点。
    func node(at path: YAMLPath) -> YAMLNode? {
        var current = root
        for component in path {
            guard let node = current else { return nil }
            switch component {
            case .key(let name):
                guard let entries = node.entries,
                      let entry = entries.first(where: { $0.key == name }) else { return nil }
                current = entry.node
            case .index(let index):
                guard let items = node.items, items.indices.contains(index) else { return nil }
                current = items[index].value
            }
        }
        return current
    }

    /// 按路径读标量值。节点不存在或不是标量都返回 nil。
    func string(at path: YAMLPath) -> String? {
        node(at: path)?.scalar?.value
    }

    /// 读标量并去掉首尾空白——列表项里写多空格是常事。
    func trimmedString(at path: YAMLPath) -> String? {
        string(at: path)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func bool(at path: YAMLPath) -> Bool? {
        guard let value = trimmedString(at: path)?.lowercased() else { return nil }
        return ["true", "yes", "on", "1"].contains(value)
    }

    func int(at path: YAMLPath) -> Int? {
        trimmedString(at: path).flatMap(Int.init)
    }

    /// 读一个映射的全部直接子键，保持原顺序。
    func keys(at path: YAMLPath) -> [String] {
        node(at: path)?.entries?.map(\.key) ?? []
    }

    /// 读一个序列的项数。
    func count(at path: YAMLPath) -> Int {
        node(at: path)?.items?.count ?? 0
    }

    /// 读列表里第 index 项的某个字段，例如 `social.0.link`。
    func itemValue(_ index: Int, field: String, at path: YAMLPath) -> String? {
        let itemPath = path + [.index(index), .key(field)]
        return trimmedString(at: itemPath)
    }

    /// 该路径是否存在（不论值的类型）。
    func exists(_ path: YAMLPath) -> Bool {
        node(at: path) != nil
    }

    /// 这个键下面是否挂着多行块——即「不能当成一行标量改」。
    func hasBlockChildren(_ path: YAMLPath) -> Bool {
        guard let node = node(at: path) else { return false }
        if node.isSequence || node.isMapping { return true }
        guard let scalar = node.scalar else { return true }
        return scalar.isFlow || scalar.isBlockScalar
    }

    // MARK: 写

    /// 设置一个标量值。路径不存在时会自动在父级末尾补一行。
    ///
    /// 关键点：绝不重排文件。已有的键只改值，缺省的键只追加一行。
    func set(_ value: String, at path: YAMLPath, hint: YAMLFormat.Hint = .auto) -> Result<YAMLDocument, YAMLError> {
        guard let last = path.last else {
            return .failure(.notWritable("路径为空"))
        }
        let parentPath = path.yamlParent

        if let existing = node(at: path) {
            switch last {
            case .key:
                // 目标键当前挂着一整块 → 拒绝，绝不把它压成一行
                if existing.isSequence || existing.isMapping {
                    return .failure(.hasBlockChildren(keyName(of: last) ?? "该项"))
                }
                if let scalar = existing.scalar, scalar.isFlow || scalar.isBlockScalar {
                    return .failure(.notWritable("这一行是 \([scalar.isFlow ? "方括号流式写法" : "多行块文本"][0])"))
                }
                let quote = existing.scalar?.quote
                return rewriteScalarLine(existing, line: existing.line, value: value, hint: hint, keepQuote: quote)
            case .index(let index):
                if let items = existing.items, items.indices.contains(index) {
                    let item = items[index].value
                    if let scalar = item.scalar, !scalar.isFlow, !scalar.isBlockScalar {
                        return rewriteScalarLine(item, line: item.line, value: value, hint: hint, keepQuote: scalar.quote)
                    }
                    return .failure(.notWritable("列表项是多行结构，请到「原始文件」页编辑"))
                }
                return .failure(.indexOutOfRange(index))
            }
        }

        // 目标不存在 → 要么在父映射末尾补键，要么在父序列末尾补项
        guard let parent = node(at: parentPath) else {
            if path.count == 1, parentPath.isEmpty {
                return appendTopLevelKey(path.yamlLastKey ?? "", value: value, hint: hint)
            }
            return .failure(.pathNotFound(parentPath))
        }

        if parent.isSequence {
            if case .index(let index) = last {
                guard index == (parent.items?.count ?? 0) else { return .failure(.indexOutOfRange(index)) }
                guard let key = keyName(of: path.count >= 2 ? path[path.count - 2] : nil) else { return .failure(.pathNotFound(parentPath)) }
                let newLines = ["- \(key): \(YAMLFormat.encode(value, hint: hint))"]
                return apply([.insertAfter(parent.endLine, indent: parent.indent, newLines)])
            }
            return .failure(.isNotSequence(parentPath))
        }

        if parent.isMapping {
            guard let key = keyName(of: last) else { return .failure(.pathNotFound(parentPath)) }
            let indent = childIndent(of: parent)
            let newLines = [String(repeating: " ", count: indent) + "\(key): \(YAMLFormat.encode(value, hint: hint))"]
            return apply([.insertAfter(parent.endLine, indent: indent, newLines)])
        }

        if parent.isScalar, parent.scalar?.isNull == true, parentPath.count == 1, isKey(last) {
            // `social:` 后面空着，补值
            return rewriteScalarLine(parent, line: parent.line, value: value, hint: hint, keepQuote: nil)
        }

        return .failure(.isNotMapping(parentPath))
    }

    /// 追加一个列表项（形如 `social:` 下的 `- name: …`）。
    func appendItem(_ pairs: [(String, String)], at path: YAMLPath, hint: YAMLFormat.Hint = .auto) -> Result<YAMLDocument, YAMLError> {
        guard !pairs.isEmpty else { return .failure(.notWritable("空的列表项")) }
        let key = pairs[0].0
        let dashIndent: Int
        let insertLine: Int

        if let sequence = node(at: path), sequence.isSequence {
            // 注意用 **sequence 自己的 indent**（短横线所在列），
            // 不能用 items.first.value.indent —— 那是 `name` 的列，比短横线右移两格，
            // 拿来当缩进会把新项顶到列表外面去。
            dashIndent = sequence.indent
            insertLine = sequence.endLine
        } else if let keyNode = node(at: path) {
            // `social:` 存在但下面是空的 → 在这一行下面铺开
            guard keyNode.isScalar, keyNode.scalar?.isNull == true else {
                return .failure(.hasBlockChildren(path.yamlLastKey ?? "该项"))
            }
            dashIndent = keyNode.indent + 2
            insertLine = keyNode.line
        } else {
            return .failure(.pathNotFound(path))
        }

        let fieldIndent = dashIndent + 2
        // 每一行都自己带绝对缩进，交给 apply 原样插入。
        // 之前在这里写相对缩进、再让 apply 补一遍，结果缩进被加了两遍，
        // 新项被顶到和上一个键同级，Hexo 直接读不到。
        var rendered: [String] = []
        let head = String(repeating: " ", count: dashIndent) + "- \(key): \(YAMLFormat.encode(pairs[0].1, hint: hint))"
        rendered.append(head)
        for pair in pairs.dropFirst() {
            rendered.append(String(repeating: " ", count: fieldIndent) + "\(pair.0): \(YAMLFormat.encode(pair.1, hint: hint))")
        }

        return apply([.insertAfter(insertLine, indent: 0, rendered)])
    }

    /// 删除映射里的某个键（含它下面的整块）。
    func removeKey(_ path: YAMLPath) -> Result<YAMLDocument, YAMLError> {
        guard let parent = node(at: path.yamlParent), parent.isMapping,
              let entry = parent.entries?.first(where: { $0.key == path.yamlLastKey }) else {
            return .failure(.pathNotFound(path))
        }
        return apply([.deleteRange(entry.node.line...entry.node.endLine)])
    }

    /// 删除列表里的第 index 项（含它的所有字段行）。
    func removeItem(_ index: Int, at path: YAMLPath) -> Result<YAMLDocument, YAMLError> {
        guard let sequence = node(at: path), let items = sequence.items, items.indices.contains(index) else {
            return .failure(.isNotSequence(path))
        }
        let item = items[index].value
        return apply([.deleteRange(item.line...item.endLine)])
    }

    /// 顶层补一个键（文件末尾追加，不插空行）。
    private func appendTopLevelKey(_ key: String, value: String, hint: YAMLFormat.Hint) -> Result<YAMLDocument, YAMLError> {
        var working = lines
        while let last = working.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            working.removeLast()
        }
        if working.isEmpty {
            return YAMLDocument(text: "\(key): \(YAMLFormat.encode(value, hint: hint))").successResult
        }
        working.append("\(key): \(YAMLFormat.encode(value, hint: hint))")
        return YAMLDocument(text: restoredTrailingNewline(from: text, to: working)).successResult
    }

    /// 拼回文本时保留原文件结尾有没有换行——
    /// 无脑 join 会把「原本以换行结尾」的文件改成不结尾，git diff 里会显示整文件改动。
    private func restoredTrailingNewline(from original: String, to lines: [String]) -> String {
        let joined = lines.joined(separator: "\n")
        let originalEndsWithNewline = original.hasSuffix("\n")
        if originalEndsWithNewline && !joined.hasSuffix("\n") {
            return joined + "\n"
        }
        if !originalEndsWithNewline, joined.hasSuffix("\n") {
            return String(joined.dropLast())
        }
        return joined
    }

    /// 只重写某一行里标量值所在的列区间，其余字符（含行尾注释）原样不动。
    private func rewriteScalarLine(_ node: YAMLNode, line: Int, value: String, hint: YAMLFormat.Hint, keepQuote: Character?) -> Result<YAMLDocument, YAMLError> {
        guard lines.indices.contains(line) else { return .failure(.notWritable("行号越界")) }
        var working = lines

        if let range = node.valueColumns, working[line].indices.contains(range.lowerBound) {
            var text = working[line]
            let encoded = YAMLFormat.encode(value, hint: hint, keepQuote: keepQuote)
            // 替换前先记住「值后面紧跟的那个字符是谁」——
            // 替换之后 range.upperBound 已经指向新文本里别的位置了，不能再用。
            let followsComment = range.upperBound < text.endIndex
                && text[range.upperBound] == "#"
                && range.upperBound > range.lowerBound

            if range.upperBound > text.endIndex {
                text = String(text[text.startIndex..<range.lowerBound]) + encoded
            } else {
                text.replaceSubrange(range, with: encoded)
            }

            // 后面紧跟着行尾注释时补一个空格，否则会粘成 `title: New# 注释`
            if followsComment {
                let insertAt = range.lowerBound < text.endIndex
                    ? text.index(range.lowerBound, offsetBy: encoded.count, limitedBy: text.endIndex) ?? text.endIndex
                    : text.endIndex
                if insertAt < text.endIndex {
                    text.insert(" ", at: insertAt)
                } else {
                    text.append(" ")
                }
            }
            working[line] = text
        } else {
            // 键后面本来就没有值（`keywords:`），补在冒号后
            let text = working[line]
            if let colon = text.firstIndex(of: ":") {
                let after = text.index(after: colon)
                working[line] = String(text[...after]) + " " + YAMLFormat.encode(value, hint: hint, keepQuote: keepQuote)
            } else {
                working[line] = "\(key(from: node, fallback: "value")): \(YAMLFormat.encode(value, hint: hint, keepQuote: keepQuote))"
            }
        }
        return YAMLDocument(text: working.joined(separator: "\n")).successResult
    }

    private func key(from node: YAMLNode, fallback: String) -> String {
        fallback
    }

    /// 子项应该用几格缩进：有兄弟就跟随兄弟，没有就 +2。
    private func childIndent(of node: YAMLNode) -> Int {
        if let entries = node.entries, let first = entries.first {
            return first.node.indent
        }
        if let items = node.items, let first = items.first {
            return first.value.indent
        }
        return node.indent + 2
    }

    // MARK: 补丁

    /// 取路径段里的键名；是列表下标则返回 nil。
    private func keyName(of component: YAMLPathComponent?) -> String? {
        guard let component else { return nil }
        if case .key(let name) = component { return name }
        return nil
    }

    private func isKey(_ component: YAMLPathComponent) -> Bool {
        if case .key = component { return true }
        return false
    }

    private enum Patch {
        case replaceLine(Int, String)
        case insertAfter(Int, indent: Int, [String])
        case deleteRange(ClosedRange<Int>)

        var sortLine: Int {
            switch self {
            case .replaceLine(let line, _): return line
            case .insertAfter(let line, _, _): return line
            case .deleteRange(let range): return range.lowerBound
            }
        }
    }

    private func apply(_ patches: [Patch]) -> Result<YAMLDocument, YAMLError> {
        var working = lines

        // 从后往前改，前面的行号才不会因为插入/删除而漂移
        for patch in patches.sorted(by: { $0.sortLine > $1.sortLine }) {
            switch patch {
            case .replaceLine(let line, let text):
                if working.indices.contains(line) { working[line] = text }
            case .insertAfter(let line, let indent, let newLines):
                guard line >= 0, line < working.count else { continue }
                let indentedLines = newLines.map { rendered($0, indent: indent) }
                working.insert(contentsOf: indentedLines, at: line + 1)
            case .deleteRange(let range):
                let lower = max(0, range.lowerBound)
                let upper = min(working.count - 1, range.upperBound)
                guard lower <= upper else { continue }
                working.removeSubrange(lower...upper)
            }
        }

        return YAMLDocument(text: restoredTrailingNewline(from: text, to: working)).successResult
    }

    /// 补齐缩进。调用方传的是不带前导空格的内容，这里按需加。
    private func rendered(_ content: String, indent: Int) -> String {
        let existing = content.prefix(while: { $0 == " " }).count
        guard existing < indent else { return content }
        return String(repeating: " ", count: indent - existing) + content
    }
}

extension YAMLDocument {

    /// 直接把文档包成 `Result`，省掉一层 unwrap。
    var successResult: Result<YAMLDocument, YAMLError> { .success(self) }
}

// MARK: - 解析器

/// 缩进敏感的递归下降解析器。
///
/// 只覆盖 Hexo 配置实际会出现的语法：嵌套映射、`- ` 序列、单双引号标量、
/// `|`/`>` 块文本、`[...]`/`{...}` 流式集合、注释、`---` 文档标记。
/// 锚点/别名（`&x` `*x`）不做展开，当普通标量处理——Hexo 配置里基本不会出现。
private struct YAMLParser {

    let lines: [String]
    var position = 0
    /// 已经吃掉的最后一行。
    ///
    /// 为什么要单独记：解析 `key:` 下面的嵌套块时，递归会把那几行消费掉，
    /// 但外层的循环光靠自己那个 `index + 1` 是不知道的——它会退回去
    /// 把子块里的行**当成顶层键再解析一遍**，然后因为缩进对不上而中断整个文件。
    /// 这就是「解析到第一个嵌套块之后，后面所有键全丢」的原因。
    var consumedUpTo = -1

    init(lines: [String]) {
        self.lines = lines
    }

    /// 扫出一行开头的 `key:` 结果。会自动跳掉前导空白和列表标记 `- `。
    private struct KeyScan {
        var key: String
        var keyRange: Range<Int>
        /// 冒号正后方的下标（值从这里开始）
        var valueStart: String.Index
        var rawValue: String
    }

    // MARK: 入口

    mutating func parseDocument() -> YAMLNode? {
        guard let first = nextMeaningfulLine(from: 0) else { return nil }
        guard let node = parseNode(at: first, minIndent: indentOf(line(first))) else { return nil }
        return finish(node)
    }

    /// 补齐每个节点的 `endLine`（含自身与所有子孙）。
    private func finish(_ node: YAMLNode) -> YAMLNode {
        var result = node
        var last = node.line

        switch node.kind {
        case .scalar:
            break
        case .mapping(let entries):
            result.kind = .mapping(entries.map { entry in
                var updated = entry
                updated.node = finish(entry.node)
                last = max(last, updated.node.endLine)
                return updated
            })
        case .sequence(let items):
            result.kind = .sequence(items.map { item in
                var updated = item
                updated.value = finish(item.value)
                last = max(last, updated.value.endLine)
                return updated
            })
        }

        result.endLine = last
        return result
    }

    // MARK: 递归

    private mutating func parseNode(at index: Int, minIndent: Int) -> YAMLNode? {
        let indent = indentOf(line(index))
        guard indent >= minIndent else { return nil }

        let parsed: YAMLNode?
        if isSequenceEntry(line(index), indent: indent) {
            parsed = parseSequence(start: index, indent: indent)
        } else if scanKey(line(index)) != nil {
            parsed = parseMapping(start: index, indent: indent)
        } else {
            parsed = nil
        }
        if let parsed {
            consumedUpTo = max(consumedUpTo, parsed.endLine)
        }
        return parsed
    }

    private mutating func parseMapping(start: Int, indent: Int) -> YAMLNode {
        var entries: [YAMLEntry] = []
        var cursor = start
        var endLine = start

        while let index = nextMeaningfulLine(from: cursor) {
            let lineIndent = indentOf(line(index))
            guard lineIndent == indent else { break }
            if isSequenceEntry(line(index), indent: indent) { break }
            guard let scan = scanKey(line(index)) else { break }

            let entry = parseValue(
                after: scan,
                keyLine: index,
                keyIndent: indent
            )
            entries.append(entry)
            endLine = max(endLine, entry.node.endLine)
            consumedUpTo = max(consumedUpTo, entry.node.endLine)
            cursor = max(index, consumedUpTo) + 1
        }

        return YAMLNode(
            kind: .mapping(entries),
            line: start,
            indent: indent,
            valueColumns: nil,
            endLine: max(start, endLine)
        )
    }

    private mutating func parseSequence(start: Int, indent: Int) -> YAMLNode {
        var items: [YAMLSequenceItem] = []
        var cursor = start
        var endLine = start

        while let index = nextMeaningfulLine(from: cursor) {
            let lineIndent = indentOf(line(index))
            guard lineIndent == indent else { break }
            let text = line(index)
            guard let dash = dashIndex(text, at: indent) else { break }

            let afterDash = text.index(after: dash)
            let rest = String(text[afterDash...])
            let item: YAMLNode

            if rest.trimmingCharacters(in: .whitespaces).isEmpty {
                // 光秃秃一个 `-`，内容在下面
                item = parseNestedBlock(after: index, parentIndent: indent)
            } else if let scan = scanKeyInLine(text, after: afterDash) {
                // `- key: value`，内容从 key 所在列开始算缩进
                let contentIndent = text.distance(from: text.startIndex, to: afterDash) + leadingSpaces(rest)
                item = parseInlineMapping(
                    firstLine: index,
                    scan: scan,
                    indent: contentIndent
                )
            } else {
                // `- 普通标量`
                item = parseInlineScalar(
                    text: text,
                    start: afterDash,
                    line: index,
                    indent: indent
                )
            }

            items.append(YAMLSequenceItem(value: item))
            endLine = max(endLine, item.endLine)
            consumedUpTo = max(consumedUpTo, item.endLine)
            cursor = max(index, consumedUpTo) + 1
        }

        return YAMLNode(
            kind: .sequence(items),
            line: start,
            indent: indent,
            valueColumns: nil,
            endLine: max(start, endLine)
        )
    }

    /// `- ` 后面直接跟 `key: value` 的列表项，键的列位置在原行里偏右。
    ///
    /// `scan` 已经是**按原行坐标**扫出来的，所以这里的列区间可以直接用于回写。
    private mutating func parseInlineMapping(
        firstLine: Int,
        scan: KeyScan,
        indent: Int
    ) -> YAMLNode {
        var entries: [YAMLEntry] = []

        let first = parseValue(after: scan, keyLine: firstLine, keyIndent: indent)
        entries.append(first)
        var endLine = first.node.endLine

        // 后续同缩进的键属于同一个列表项
        var cursor = max(firstLine, consumedUpTo) + 1
        while let index = nextMeaningfulLine(from: cursor) {
            let lineIndent = indentOf(line(index))
            guard lineIndent == indent else { break }
            if isSequenceEntry(line(index), indent: indent) { break }
            guard let nextScan = scanKey(line(index)) else { break }
            let entry = parseValue(after: nextScan, keyLine: index, keyIndent: indent)
            entries.append(entry)
            endLine = max(endLine, entry.node.endLine)
            consumedUpTo = max(consumedUpTo, entry.node.endLine)
            cursor = max(index, consumedUpTo) + 1
        }

        return YAMLNode(
            kind: .mapping(entries),
            line: firstLine,
            indent: indent,
            valueColumns: nil,
            endLine: max(firstLine, endLine)
        )
    }

    private func parseInlineScalar(text: String, start: String.Index, line: Int, indent: Int) -> YAMLNode {
        let parsed = parseScalar(from: text, at: start)
        return YAMLNode(
            kind: .scalar(parsed.scalar),
            line: line,
            indent: indent,
            valueColumns: parsed.start..<parsed.end,
            endLine: line
        )
    }

    /// `- ` 独占一行、内容在下面一层。
    private mutating func parseNestedBlock(after index: Int, parentIndent: Int) -> YAMLNode {
        guard let next = nextMeaningfulLine(from: index + 1) else {
            return YAMLNode(kind: .scalar(.null), line: index, indent: parentIndent, valueColumns: nil, endLine: index)
        }
        let nextIndent = indentOf(line(next))
        guard nextIndent > parentIndent else {
            return YAMLNode(kind: .scalar(.null), line: index, indent: parentIndent, valueColumns: nil, endLine: index)
        }
        guard let node = parseNode(at: next, minIndent: nextIndent) else {
            return YAMLNode(kind: .scalar(.null), line: index, indent: parentIndent, valueColumns: nil, endLine: index)
        }
        return node
    }

    /// 解析 `key:` 之后的部分。
    private mutating func parseValue(after scan: KeyScan, keyLine: Int, keyIndent: Int) -> YAMLEntry {
        let text = line(keyLine)
        let trimmed = scan.rawValue.trimmingCharacters(in: .whitespaces)

        // `key:` 后面空着，或整段只是个注释 → 可能是嵌套块
        //
        // 注意别把 `#aabbcc` 当注释：YAML 里 `#` 只有在前面是空白时才是注释，
        // 颜色值（`color: #181717`）必须当值处理。
        let isBareComment = trimmed.hasPrefix("#")
            && (trimmed.count == 1 || trimmed.dropFirst().first?.isWhitespace == true)
        if trimmed.isEmpty || isBareComment {
            let valueStart = scan.valueStart
            if let next = nextMeaningfulLine(from: keyLine + 1), indentOf(line(next)) > keyIndent {
                let nextIndent = indentOf(line(next))
                let child = parseNode(at: next, minIndent: nextIndent)
                    ?? YAMLNode(kind: .scalar(.null), line: keyLine, indent: keyIndent, valueColumns: nil, endLine: keyLine)
                return YAMLEntry(key: scan.key, node: child)
            }
            // 空值：列区间落在冒号之后
            return YAMLEntry(
                key: scan.key,
                node: YAMLNode(
                    kind: .scalar(.null),
                    line: keyLine,
                    indent: keyIndent,
                    valueColumns: valueStart..<valueStart,
                    endLine: keyLine
                )
            )
        }

        // 块文本 `|` / `>`
        if let marker = trimmed.first, marker == "|" || marker == ">" {
            var endLine = keyLine
            var cursor = keyLine + 1
            while cursor < lines.count {
                let current = line(cursor)
                // 空行**可能**属于块文本，但块尾的连续空行不属于——
                // 把它们算进来会让 endLine 越界，删除和追加就会错位到下一段配置。
                if current.trimmingCharacters(in: .whitespaces).isEmpty {
                    // 往后看还有没有更深的行；有就说明空行是块内容中间的分隔
                    var lookahead = cursor + 1
                    var belongsToBlock = false
                    while lookahead < lines.count {
                        let ahead = line(lookahead)
                        if ahead.trimmingCharacters(in: .whitespaces).isEmpty { lookahead += 1; continue }
                        belongsToBlock = indentOf(ahead) > keyIndent
                        break
                    }
                    guard belongsToBlock else { break }
                    endLine = cursor
                    cursor += 1
                    continue
                }
                guard indentOf(current) > keyIndent else { break }
                endLine = cursor
                cursor += 1
            }
            let scalar = YAMLScalar(
                value: String(text[scan.valueStart..<text.endIndex]).trimmingCharacters(in: .whitespaces),
                quote: nil,
                isFlow: false,
                isBlockScalar: true,
                isNull: false
            )
            return YAMLEntry(
                key: scan.key,
                node: YAMLNode(kind: .scalar(scalar), line: keyLine, indent: keyIndent, valueColumns: nil, endLine: endLine)
            )
        }

        // 直接用扫描时记下的冒号后位置，别自己用偏移推算——
        // 这里差一格就会把 `url: xxx` 改写成 `url:xxx`，肉眼很难发现。
        let valueStart = scan.valueStart
        let parsed = parseScalar(from: text, at: valueStart)
        // 列区间要用**跳掉前导空白之后**的位置。用冒号位置当起点的话，
        // 替换会把冒号后那个分隔空格一起吃掉，写出来就成了 `url:xxx`。
        return YAMLEntry(
            key: scan.key,
            node: YAMLNode(
                kind: .scalar(parsed.scalar),
                line: keyLine,
                indent: keyIndent,
                valueColumns: parsed.start..<parsed.end,
                endLine: keyLine
            )
        )
    }

    // MARK: 标量

    private struct ParsedScalar {
        var scalar: YAMLScalar
        /// 跳掉前导空白后，值真正开始的列
        var start: String.Index
        /// 值在行内的结束下标
        var end: String.Index
    }

    private func parseScalar(from text: String, at start: String.Index) -> ParsedScalar {
        var index = start
        // 跳过冒号后的空白
        while index < text.endIndex, text[index] == " " || text[index] == "\t" {
            index = text.index(after: index)
        }

        if index >= text.endIndex {
            return ParsedScalar(scalar: .null, start: index, end: index)
        }
        // 只有「# 前面是空白」才是注释。`key: #aabbcc` 里的 # 是值（颜色），
        // 走到这里前导空白已跳过，所以这里直接看第一个字符即可。

        // 块文本 / 流式集合：整行原样保留，不可改
        if text[index] == "|" || text[index] == ">" {
            return ParsedScalar(
                scalar: YAMLScalar(
                    value: String(text[index...]).trimmingCharacters(in: .whitespaces),
                    quote: nil,
                    isFlow: false,
                    isBlockScalar: true,
                    isNull: false
                ),
                start: index,
                end: text.endIndex
            )
        }
        if text[index] == "[" || text[index] == "{" {
            let raw = String(text[index...]).trimmingCharacters(in: .whitespaces)
            return ParsedScalar(
                scalar: YAMLScalar(value: raw, quote: nil, isFlow: true, isBlockScalar: false, isNull: false),
                start: index,
                end: text.endIndex
            )
        }

        if text[index] == "\"" || text[index] == "'" {
            let quote = text[index]
            var cursor = text.index(after: index)
            var raw = ""
            while cursor < text.endIndex {
                let character = text[cursor]
                if quote == "\"" && character == "\\" {
                    let next = text.index(after: cursor)
                    if next < text.endIndex {
                        raw.append(unescape(text[next]))
                        cursor = text.index(after: next)
                        continue
                    }
                }
                if character == quote {
                    if quote == "'", text.index(after: cursor) < text.endIndex, text[text.index(after: cursor)] == "'" {
                        raw.append("'")
                        cursor = text.index(after: cursor)
                        cursor = text.index(after: cursor)
                        continue
                    }
                    return ParsedScalar(
                        scalar: YAMLScalar(value: raw, quote: quote, isFlow: false, isBlockScalar: false, isNull: false),
                        start: index,
                        end: text.index(after: cursor)
                    )
                }
                raw.append(character)
                cursor = text.index(after: cursor)
            }
            return ParsedScalar(
                scalar: YAMLScalar(value: raw, quote: nil, isFlow: false, isBlockScalar: false, isNull: false),
                start: index,
                end: text.endIndex
            )
        }

        // 裸标量：遇到「前面是空白的 #」或行尾就停
        //
        // 关键点：`previous` 必须初始化成一个**非空白**字符。
        // 若初始化成空格，循环第一次判断就会成立，值开头的 `#` 被当注释吃掉——
        // 于是 `color: #181717` 读出来是空字符串，颜色项在表单里永远没值。
        var cursor = index
        var previous: Character = text[index]
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "#" && cursor > index && previous.isWhitespace { break }
            previous = character
            cursor = text.index(after: cursor)
        }

        var value = String(text[index..<cursor])
        while value.hasSuffix(" ") || value.hasSuffix("\t") { value.removeLast() }
        return ParsedScalar(
            scalar: YAMLScalar(value: value, quote: nil, isFlow: false, isBlockScalar: false, isNull: false),
            start: index,
            end: cursor
        )
    }

    private func unescape(_ character: Character) -> Character {
        switch character {
        case "n": return "\n"
        case "t": return "\t"
        default: return character
        }
    }

    // MARK: 逐行工具

    private func line(_ index: Int) -> String {
        lines.indices.contains(index) ? lines[index] : ""
    }

    private func indentOf(_ text: String) -> Int {
        text.prefix(while: { $0 == " " }).count
    }

    private func leadingSpaces(_ text: String) -> Int {
        text.prefix(while: { $0 == " " || $0 == "\t" }).count
    }

    private func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func isComment(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).hasPrefix("#")
    }

    private func nextMeaningfulLine(from start: Int) -> Int? {
        var index = start
        while index < lines.count {
            let text = line(index)
            if !isBlank(text) && !isComment(text) { return index }
            index += 1
        }
        return nil
    }

    private func isSequenceEntry(_ text: String, indent: Int) -> Bool {
        let stripped = String(text.dropFirst(indent))
        if stripped == "-" { return true }
        return stripped.hasPrefix("- ") || stripped.hasPrefix("-\t")
    }

    private func dashIndex(_ text: String, at indent: Int) -> String.Index? {
        guard text.indices.contains(text.index(text.startIndex, offsetBy: indent)) else { return nil }
        let index = text.index(text.startIndex, offsetBy: indent)
        guard text[index] == "-" else { return nil }
        let next = text.index(after: index)
        if next == text.endIndex { return index }
        return text[next] == " " || text[next] == "\t" ? index : nil
    }

    /// 扫出一行开头的 `key:`。会自动跳掉前导空白和列表标记 `- `。
    private func scanKey(_ text: String) -> KeyScan? {
        var index = text.startIndex

        // 跳掉列表标记
        while index < text.endIndex, text[index] == " " || text[index] == "\t" { index = text.index(after: index) }
        if index < text.endIndex, text[index] == "-" {
            let next = text.index(after: index)
            if next < text.endIndex, text[next] == " " || text[next] == "\t" {
                index = text.index(after: next)
                while index < text.endIndex, text[index] == " " || text[index] == "\t" { index = text.index(after: index) }
            }
        }

        return scanKeyInLine(text, after: index)
    }

    /// 从 `start` 之后开始扫 `key:`，**所有下标都保持原行坐标**。
    ///
    /// 列表项第一行（`- name: GitHub`）必须走这里而不是先切子串再扫：
    /// 切子串会让列偏移失真，回写时就会改错位置——`name` 的值会被写成 `: GitHub`。
    private func scanKeyInLine(_ text: String, after start: String.Index) -> KeyScan? {
        var inSingle = false
        var inDouble = false
        var index = start

        while index < text.endIndex, text[index] == " " || text[index] == "\t" {
            index = text.index(after: index)
        }
        let keyStart = index

        while index < text.endIndex {
            let character = text[index]
            if character == "'" && !inDouble { inSingle.toggle() }
            else if character == "\"" && !inSingle { inDouble.toggle() }
            else if character == ":" && !inSingle && !inDouble {
                let next = text.index(after: index)
                if next == text.endIndex || text[next] == " " || text[next] == "\t" {
                    var key = String(text[keyStart..<index]).trimmingCharacters(in: .whitespaces)
                    if key.count >= 2,
                       (key.hasPrefix("\"") && key.hasSuffix("\"")) || (key.hasPrefix("'") && key.hasSuffix("'")) {
                        key = String(key.dropFirst().dropLast())
                    }
                    guard !key.isEmpty else { return nil }
                    return KeyScan(
                        key: key,
                        keyRange: text.distance(from: text.startIndex, to: keyStart)
                            ..< text.distance(from: text.startIndex, to: index),
                        valueStart: next,
                        rawValue: String(text[next...])
                    )
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

/// MARK: - 简单路径引擎（给上层配置 UI 用）

/// 统一的 YAML 路径读写入口。把 `avatar.url`、`social.0.name` 这种字符串路径
/// 转成 `YAMLPath`，再调用 `YAMLDocument` 的真实实现。
final class YAMLPathEngine {
    static let shared = YAMLPathEngine()

    private init() {}

    /// 读取路径对应的值。不存在返回 nil。
    func get(_ path: String, in text: String) -> String? {
        let doc = YAMLDocument(text: text)
        return doc.string(at: YAMLPath(dottedPath: path))
    }

    /// 写入路径对应的值。成功返回新的完整文本，失败返回 YAMLError。
    func set(_ path: String, to value: String, in text: String) -> Result<String, YAMLError> {
        var doc = YAMLDocument(text: text)
        let yamlPath = YAMLPath(dottedPath: path)
        return doc.set(value, at: yamlPath).map { $0.text }
    }

    /// 读取列表项数。路径不存在或不是序列返回 0。
    func listCount(_ path: String, in text: String) -> Int {
        let doc = YAMLDocument(text: text)
        return doc.count(at: YAMLPath(dottedPath: path))
    }

    /// 读取列表第 index 项的某个字段值。
    func listItemValue(_ path: String, index: Int, field: String, in text: String) -> String? {
        let doc = YAMLDocument(text: text)
        return doc.itemValue(index, field: field, at: YAMLPath(dottedPath: path))
    }

    /// 读取列表所有项的某个字段值。
    func listItemValues(_ path: String, field: String, in text: String) -> [String] {
        let doc = YAMLDocument(text: text)
        let count = doc.count(at: YAMLPath(dottedPath: path))
        return (0..<count).compactMap { doc.itemValue($0, field: field, at: YAMLPath(dottedPath: path)) }
    }
}
