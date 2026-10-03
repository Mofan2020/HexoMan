//
//  VisualConfigView.swift
//  HexoMan
//
//  配置页的「可视化」那一半。
//
//  目标很直接：让一个不懂 YAML 的人也能改完站点最常改的东西，
//  并且能回答「我想加个 banner，该去哪加」这种最常见的问题。
//
//  两块内容：
//  1. 常用配置表单——站点信息 / 外观 / 内容分页 / 社交链接，带中文说明
//  2. 自定义内容——head 和 body 两段 HTML，配 10 条一键插入的常见代码
//

import SwiftUI

struct VisualConfigView: View {

    @EnvironmentObject private var model: HexoManModel

    /// 自定义内容的本地草稿。刻意不直接写 model：
    /// 用户可能一口气贴一大段代码，中途按 ⌘S 比必须点按钮再保存顺手。
    @State private var headDraft: String = ""
    @State private var bodyDraft: String = ""

    /// 正在填占位符的片段。nil 表示没有弹窗。
    @State private var pendingSnippet: Snippet?
    /// 片段占位符的临时输入。
    @State private var placeholderValues: [String: String] = [:]

    /// 站点切换时重新载入自定义内容。
    @State private var loadedSitePath: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.mainConfig == nil {
                    EmptyHint(
                        systemImage: "gearshape",
                        title: "没有可编辑的站点配置",
                        message: "站点根目录下需要有 _config.yml。"
                    )
                    .frame(minHeight: 240)
                } else {
                    settingsSection
                    customContentSection
                }
            }
            .padding(20)
        }
        .onAppear(perform: reloadDrafts)
        .onChange(of: model.currentSite?.path) { _, _ in reloadDrafts() }
        // 焦点离开某个输入框时提交它。这是「什么时候落盘」的唯一切换点，
        // 靠它保证用户点 ⌘生成 或切页签之前改动已经进了配置文件。
        .onChange(of: focusedField) { old, _ in
            if let old { commitPending(old) }
        }
        .sheet(item: $pendingSnippet) { snippet in
            placeholderSheet(snippet)
        }
    }

    // MARK: - 常用配置

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("常用配置", systemImage: "slider.horizontal.3")
                .font(.headline)

            Text("这些是大多数人唯一需要改的东西。改完立即保存，重新生成站点后生效。")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(SiteField.Group.allCases) { group in
                groupCard(group)
            }
        }
    }

    private func groupCard(_ group: SiteField.Group) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(group.rawValue, systemImage: group.symbolName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 0) {
                let fields = SiteSettings.fields(in: group)
                ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                    if index > 0 { Divider().padding(.vertical, 2) }
                    fieldRow(field)
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: SiteField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(field.label)
                    .font(.callout)
                Text(field.key)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.quaternary)
                Spacer(minLength: 8)
            }

            // 嵌套块：只读展示 + 引导去原始文件页。
            // 硬给一个输入框的话，用户填什么都必然失败，那比不给更糟。
            if model.isNestedSetting(field.key) {
                HStack(spacing: 8) {
                    Text("这个配置下面还有多行子项，请到「原始文件」页修改")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer(minLength: 8)
                }
            } else {
                control(for: field)
            }

            Text(field.hint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func control(for field: SiteField) -> some View {
        switch field.kind {
        case .boolean:
            Toggle("", isOn: boolBinding(field))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)

        case .integer:
            TextField("留空表示不限制", text: textBinding(field))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .focused($focusedField, equals: field.key)
                .onSubmit { commitPending(field.key) }

        case .choice(let options):
            Picker("", selection: textBinding(field)) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
            .onChange(of: model.siteSettingValues()[field.key]) { _, new in
                // Picker 是立即生效的，没有失焦概念，这里直接提交
                if new != pending[field.key] {
                    pending[field.key] = new
                    commitPending(field.key)
                }
            }

        case .text:
            TextField("留空表示不设置", text: textBinding(field))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .focused($focusedField, equals: field.key)
                .onSubmit { commitPending(field.key) }
        }
    }

    // MARK: - 绑定

    /// 当前正在编辑的键。失焦时提交。
    @FocusState private var focusedField: String?

    /// 编辑中的临时值。键是配置项的 key。
    ///
    /// 为什么不直接双向绑到 model：TextField 每击一次键都会调 setter，
    /// 一次改字就要写一次 _config.yml，用户打到一半去点「生成」就会读到半截内容。
    @State private var pending: [String: String] = [:]

    /// 文本类字段的绑定。输入只进 `pending`，失焦才真正落盘。
    private func textBinding(_ field: SiteField) -> Binding<String> {
        let key = field.key
        let stored = model.siteSettingValues()[key] ?? ""

        return Binding(
            get: { pending[key] ?? stored },
            set: { pending[key] = $0 }
        )
    }

    /// 失焦时把暂存值写进配置文件。
    private func commitPending(_ key: String) {
        guard let value = pending[key] else { return }
        pending[key] = nil
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = model.siteSettingValues()[key] ?? ""
        guard current != trimmed else { return }
        model.updateSiteSetting(trimmed, for: key)
    }

    private func boolBinding(_ field: SiteField) -> Binding<Bool> {
        let key = field.key
        return Binding(
            get: { (model.siteSettingValues()[key] ?? "") == "true" },
            set: { model.updateSiteSetting($0 ? "true" : "false", for: key) }
        )
    }

    // MARK: - 自定义内容

    private var customContentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("自定义内容", systemImage: "wand.and.stars")
                    .font(.headline)
                Spacer()
                if model.isCustomContentInstalled {
                    Text("已启用")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else {
                    Text("未启用")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Text("""
            想加 banner、统计代码、自定义 CSS 或 JS，都填在这里。
            不用去 themes/ 目录改模板——那会在重新安装依赖时丢失。
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(Snippet.Target.allCases) { target in
                injectionEditor(target)
            }

            HStack(spacing: 10) {
                Button {
                    model.saveCustomContent(CustomContent(head: headDraft, body: bodyDraft))
                } label: {
                    Label("保存", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.currentSite == nil)

                Button("撤销改动") {
                    reloadDrafts()
                }
                .disabled(model.currentSite == nil)

                Spacer()

                if model.isCustomContentInstalled {
                    Button(role: .destructive) {
                        model.removeCustomContent()
                        reloadDrafts()
                    } label: {
                        Label("完全关闭", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func injectionEditor(_ target: Snippet.Target) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(target == .head ? "插在 </head> 前" : "插在 </body> 前")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(target == .head ? "CSS、统计脚本、字体" : "banner 挂件、悬浮按钮")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            TextEditor(text: binding(for: target))
                .font(.system(size: 11.5, design: .monospaced))
                .frame(height: 120)
                .padding(6)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.tertiary.opacity(0.3))
                }

            snippetBar(for: target)
        }
        .padding(12)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// 一键插入的常见代码。
    private func snippetBar(for target: Snippet.Target) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("常见需求，一键插入")
                .font(.caption)
                .foregroundStyle(.secondary)

            FlowLayout(spacing: 6) {
                ForEach(SnippetLibrary.snippets(for: target)) { snippet in
                    Button {
                        insert(snippet)
                    } label: {
                        Text(snippet.title)
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(snippet.summary)
                }
            }
        }
    }

    private func binding(for target: Snippet.Target) -> Binding<String> {
        Binding(
            get: { target == .head ? headDraft : bodyDraft },
            set: { value in
                if target == .head { headDraft = value } else { bodyDraft = value }
            }
        )
    }

    private func insert(_ snippet: Snippet) {
        // 没有占位符的直接插；需要的先问一遍，避免插一堆 __XXX__ 进去再让用户自己找
        if snippet.placeholders.isEmpty {
            append(snippet.code, to: snippet.target)
            return
        }
        placeholderValues = [:]
        pendingSnippet = snippet
    }

    private func append(_ code: String, to target: Snippet.Target) {
        let separator: String
        if target == .head { separator = headDraft } else { separator = bodyDraft }
        let trimmed = separator.trimmingCharacters(in: .whitespacesAndNewlines)

        let combined: String
        if trimmed.isEmpty {
            combined = code
        } else {
            // 空两行分段，一眼能看出是几段独立内容
            combined = trimmed + "\n\n" + code
        }

        if target == .head { headDraft = combined } else { bodyDraft = combined }
    }

    // MARK: - 占位符弹窗

    private func placeholderSheet(_ snippet: Snippet) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snippet.title)
                    .font(.headline)
                Text(snippet.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(snippet.placeholders) { placeholder in
                VStack(alignment: .leading, spacing: 4) {
                    Text(placeholder.title)
                        .font(.callout)
                    TextField(placeholder.hint, text: Binding(
                        get: { placeholderValues[placeholder.id] ?? "" },
                        set: { placeholderValues[placeholder.id] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                }
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { pendingSnippet = nil }
                Button("插入") {
                    let (code, missing) = SnippetLibrary.instantiate(snippet, values: placeholderValues)
                    guard missing.isEmpty else {
                        model.showToast("还差：\(missing.joined(separator: "、"))", kind: .failure)
                        return
                    }
                    append(code, to: snippet.target)
                    pendingSnippet = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    // MARK: - 草稿同步

    /// 从磁盘重新载入自定义内容。
    ///
    /// 只在站点切换或显式撤销时调用；平时用户编辑的是本地 draft，
    /// 不会因为 model 刷新（比如别处触发了站点探测）而被冲掉。
    private func reloadDrafts() {
        let path = model.currentSite?.path ?? ""
        guard path != loadedSitePath else { return }
        loadedSitePath = path
        let content = model.customContent
        headDraft = content.head
        bodyDraft = content.body
    }
}

// MARK: - 自动换行的按钮流

/// 简单的流式布局。SwiftUI 自带的 Layout 在 macOS 26 上行为够用，
/// 但为了不引入任何第三方依赖也不写一整套 Layout 协议，这里手写一个。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var total = CGSize(width: 0, height: 0)

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                total.width = max(total.width, rowWidth - spacing)
                total.height += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        total.width = max(total.width, rowWidth - spacing)
        total.height += rowHeight
        return total
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
