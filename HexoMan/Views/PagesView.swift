//
//  PagesView.swift
//  HexoMan
//
//  页面列表：管理 source/ 目录下的页面（非 _posts）。
//  页面和文章的区别：页面不在 _posts 下、没有发布日期、可任意嵌套目录。
//
//  PR4 增强：
//  - 多选 + 批量删除 / 改标签 / 改布局
//  - 排序下拉（修改时间 / 标题 / 文件名 / 字数）
//  - 详情区：front-matter 表格化展示，列出引用此页的文章
//

import SwiftUI

struct PagesView: View {
    @EnvironmentObject private var model: HexoManModel

    @State private var selectedPageID: String?
    @State private var multiSelection: Set<String> = []
    @State private var selectionMode: SelectionMode = .single
    @State private var showingNewPage = false
    @State private var editingPage: BlogPage?
    @State private var showingDeleteConfirm = false
    @State private var showingBatchSheet: BatchAction?
    @State private var pageReferences: [PageReference] = []

    enum SelectionMode {
        case single
        case multi
    }

    enum BatchAction: String, Identifiable {
        case addTag
        case setLayout
        case delete

        var id: String { rawValue }
    }

    var body: some View {
        HSplitView {
            listColumn
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 540)
            detailColumn
                .frame(minWidth: 380, maxHeight: .infinity)
        }
        .sheet(isPresented: $showingNewPage) {
            NewPageSheet()
                .environmentObject(model)
        }
        .sheet(item: $editingPage) { page in
            PageEditorView(page: page)
                .environmentObject(model)
        }
        .sheet(item: $showingBatchSheet) { action in
            BatchActionSheet(action: action, targets: selectedPages) { tag, layout in
                applyBatch(action: action, tag: tag, layout: layout)
            }
            .environmentObject(model)
        }
        .onChange(of: model.pages.map(\.id)) { _, ids in
            // 单选：原行为不变；多选：剔除已不存在的 id。
            switch selectionMode {
            case .single:
                if let id = selectedPageID, !ids.contains(id) {
                    selectedPageID = nil
                }
            case .multi:
                multiSelection = multiSelection.intersection(ids)
            }
        }
        .onChange(of: selectedPageID) { _, _ in
            recomputeReferences()
        }
    }

    // MARK: - 左：列表

    private var listColumn: some View {
        VStack(spacing: 0) {
            listToolbar
            Divider()
            pageList
            Divider()
            listFooter
        }
    }

    private var listToolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("搜索标题、路径或标签", text: $model.pageSearch)
                    .textFieldStyle(.plain)
                    .font(.callout)

                if model.pageSearch.isEmpty == false {
                    Button {
                        model.pageSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清空搜索")
                }

                Button {
                    showingNewPage = true
                } label: {
                    Label("新建页面", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                        .font(.callout)
                }
                .help("新建页面")
            }

            HStack(spacing: 8) {
                Picker("", selection: $model.pageFilter) {
                    ForEach(HexoManModel.PageFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Spacer(minLength: 4)

                Picker("", selection: $model.pageSort) {
                    ForEach(HexoManModel.PageSort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 140)
                .help("排序方式")
            }

            if selectionMode == .multi {
                HStack(spacing: 8) {
                    Button {
                        multiSelection = Set(model.filteredPages.map(\.id))
                    } label: {
                        Label("全选", systemImage: "checkmark.circle")
                            .font(.caption)
                    }
                    .help("全选当前过滤后的页面")

                    Button {
                        multiSelection = []
                    } label: {
                        Label("清空", systemImage: "circle")
                            .font(.caption)
                    }
                    .disabled(multiSelection.isEmpty)

                    Spacer(minLength: 4)

                    Text("已选 \(multiSelection.count) / \(model.filteredPages.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var pageList: some View {
        if model.pages.isEmpty {
            EmptyHint(
                systemImage: "doc.badge.plus",
                title: "还没有页面",
                message: "这个站点目前没有页面。点左上角「新建页面」创建首个页面，页面会放在 source/ 目录下。"
            )
        } else if model.filteredPages.isEmpty {
            EmptyHint(
                systemImage: "line.3.horizontal.decrease.circle",
                title: "没有匹配的页面",
                message: "当前筛选加搜索词没有命中任何页面，换个条件试试。"
            )
        } else {
            switch selectionMode {
            case .single:
                List(selection: $selectedPageID) {
                    ForEach(model.filteredPages) { page in
                        PageRow(page: page)
                            .tag(page.id)
                            .contextMenu {
                                Button("编辑…") { editingPage = page }
                                Button("在访达中显示") { NSWorkspaceBridge.reveal(page.filePath) }
                                Divider()
                                Button("删除…", role: .destructive) {
                                    selectedPageID = page.id
                                    showingDeleteConfirm = true
                                }
                            }
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()

            case .multi:
                List(selection: $multiSelection) {
                    ForEach(model.filteredPages) { page in
                        PageRow(page: page)
                            .tag(page.id)
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }
        }
    }

    private var listFooter: some View {
        HStack(spacing: 8) {
            Picker("", selection: $selectionMode) {
                Text("单选").tag(SelectionMode.single)
                Text("多选").tag(SelectionMode.multi)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)

            Text("共 \(model.pages.count) 个页面")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.filteredPages.count != model.pages.count {
                Text("· 显示 \(model.filteredPages.count) 个")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            if selectionMode == .multi, multiSelection.isEmpty == false {
                Menu {
                    Button("添加标签…") { showingBatchSheet = .addTag }
                    Button("设置布局…") { showingBatchSheet = .setLayout }
                    Divider()
                    Button("删除…", role: .destructive) { showingBatchSheet = .delete }
                } label: {
                    Label("批量 (\(multiSelection.count))", systemImage: "ellipsis.circle")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Button {
                model.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("重新读取磁盘")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: - 右：详情

    @ViewBuilder
    private var detailColumn: some View {
        switch selectionMode {
        case .single:
            if let page = selectedPage {
                singleDetail(page)
            } else {
                EmptyHint(
                    systemImage: "doc.plaintext",
                    title: "选一个页面",
                    message: "从左侧列表选择一个页面，这里会显示标题、布局、永久链接和可执行的操作。"
                )
            }
        case .multi:
            multiSelectionSummary
        }
    }

    private func singleDetail(_ page: BlogPage) -> some View {
        let hasStructured = page.front.entries.contains { $0.isComplexBlock }

        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(page)
                    Divider()
                    meta(page)
                    if hasStructured {
                        Divider()
                        structuredData(page)
                    }
                    Divider()
                    frontMatterTable(page)
                    if pageReferences.isEmpty == false {
                        Divider()
                        referencesSection(page)
                    }
                    Divider()
                    assets(page)
                    Divider()
                    preview(page)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            actions(page)
        }
        .confirmationDialog(
            "删除这个页面？",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible,
            presenting: page
        ) { target in
            Button("移到废纸篓", role: .destructive) {
                model.deletePage(target)
            }
            Button("取消", role: .cancel) {}
        } message: { target in
            Text("\(target.filename) 会被移到废纸篓，不会立刻消失，可以从废纸篓恢复。")
        }
    }

    private var multiSelectionSummary: some View {
        VStack(spacing: 16) {
            Image(systemName: "checklist")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("批量操作模式")
                .font(.headline)
            Text("已选 \(multiSelection.count) 个页面。从列表选择后用左下角「批量」菜单操作。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("切回单选") {
                selectionMode = .single
                multiSelection = []
            }
            .buttonStyle(.bordered)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(_ page: BlogPage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(page.title)
                    .font(.system(size: 28, weight: .semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(page.excerpt)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(page.filePath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    private func meta(_ page: BlogPage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailRow(label: "布局", value: page.layout)
            DetailRow(label: "永久链接", value: page.permalink, monospaced: true)
            DetailRow(label: "字数", value: "\(page.wordCount) 字")
            DetailRow(label: "大小", value: ByteCountFormatter.string(fromByteCount: Int64(page.byteSize), countStyle: .file))
            DetailRow(label: "文件", value: page.filename, monospaced: true)
            DetailRow(
                label: "最后修改",
                value: page.modifiedAt.formatted(date: .abbreviated, time: .shortened)
            )

            if page.tags.isEmpty == false {
                pillRow(label: "标签", values: page.tags, tint: .accentColor)
            }

            if page.categories.isEmpty == false {
                pillRow(label: "分类", values: page.categories, tint: .teal)
            }
        }
    }

    /// front-matter 表格化展示。
    ///
    /// 之前的「结构化数据」只显示块状（girls: [...]），其他简单键（title、layout、tags）
    /// 都看不到。这一版把 front-matter 整张表列出来：键 / 值 / 类型。
    /// 单击 value 复制；单击 key 跳到「原始文件」编辑。
    private func frontMatterTable(_ page: BlogPage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("front-matter", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Text("共 \(page.front.entries.count) 项")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            VStack(spacing: 0) {
                ForEach(Array(page.front.entries.enumerated()), id: \.element.key) { index, entry in
                    if index > 0 { Divider().padding(.vertical, 1) }
                    FrontMatterRow(entry: entry)
                }
            }
            .padding(12)
            .background(
                Color(nsColor: .textBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
    }

    private func referencesSection(_ page: BlogPage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("引用此页的文章", systemImage: "link")
                .font(.headline)
            Text("扫描 _posts/ 找出来的——路径链接、permalink、共享标签都算。")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(Array(pageReferences.enumerated()), id: \.element.id) { index, ref in
                    if index > 0 { Divider().padding(.vertical, 1) }
                    HStack(spacing: 8) {
                        Image(systemName: kindIcon(ref.matchKind))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ref.postTitle)
                                .font(.callout)
                            Text(ref.matchSnippet)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        Button {
                            NSWorkspaceBridge.reveal(ref.postFilePath)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(12)
            .background(
                Color(nsColor: .textBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
    }

    private func kindIcon(_ kind: PageReference.MatchKind) -> String {
        switch kind {
        case .pathLink: return "link"
        case .permalink: return "link.circle"
        case .tag: return "tag"
        }
    }

    private func pillRow(label: String, values: [String], tint: Color) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            FlexibleTagLayout(values: values, tint: tint)
        }
    }

    private func preview(_ page: BlogPage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("正文预览")
                .font(.headline)

            if page.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("（正文为空）")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                Text(page.body)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(
                        Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
            }
        }
    }

    // MARK: - 关联资源

    private func assets(_ page: BlogPage) -> some View {
        let assets = PageAssetScanner.scan(site: model.currentSite!, page: page)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("关联资源", systemImage: "square.on.square")
                    .font(.headline)
                Text("只列本地文件；在线的 CDN 资源不关联")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if assets.isEmpty {
                Text("这个页面没有引用本地的 CSS / JS / 图片。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                        if index > 0 { Divider().padding(.vertical, 1) }
                        assetRow(asset)
                    }
                }
                .padding(12)
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
        }
    }

    private func assetRow(_ asset: PageAsset) -> some View {
        let missing = asset.origin == .missing
        return HStack(spacing: 9) {
            Image(systemName: missing ? "exclamationmark.triangle.fill" : asset.kind.symbolName)
                .font(.system(size: 12))
                .foregroundStyle(missing ? .orange : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(asset.sitePath)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(missing ? .orange : .primary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(missing
                     ? "页面引用了它，但 source 下找不到这个文件——路径可能写错了"
                     : "\(asset.relativePath) · \(asset.sizeDescription)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Pill(text: asset.kind.label, tint: missing ? .orange : .secondary)
            Pill(text: asset.originLabel, tint: missing ? .orange : .accentColor)

            if missing == false {
                Button {
                    NSWorkspaceBridge.reveal(asset.sourcePath)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("在访达中显示")
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 结构化数据（保留旧块状列表）

    private func structuredData(_ page: BlogPage) -> some View {
        let blocks = page.front.entries.filter { $0.isComplexBlock }

        return Group {
            if blocks.isEmpty == false {
                VStack(alignment: .leading, spacing: 8) {
                    Label("结构化数据", systemImage: "square.stack.3d.up")
                        .font(.headline)

                    Text("这些是写在页面头部、但不直接显示在正文里的数据——页面实际渲染出来的内容就是由它们生成的。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(blocks, id: \.key) { entry in
                        blockCard(entry)
                    }
                }
            }
        }
    }

    private func blockCard(_ entry: FrontMatterEntry) -> some View {
        let block = entry.verbatimBlock ?? ""
        let items = block.components(separatedBy: .newlines)
            .filter { $0.trimmingCharacters(in: .whitespaces).isEmpty == false }

        let itemCount = items.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }.count

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.key)
                    .font(.system(size: 12, design: .monospaced))
                    .fontWeight(.semibold)
                if itemCount > 0 {
                    Pill(text: "\(itemCount) 条", tint: .accentColor)
                }
                Spacer(minLength: 8)
                Button("打开文件") {
                    if let page = selectedPage {
                        NSWorkspaceBridge.reveal(page.filePath)
                    }
                }
                .controlSize(.small)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(block)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
            }
            .frame(maxHeight: 190)
            .padding(10)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(12)
        .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - 操作按钮

    private func actions(_ page: BlogPage) -> some View {
        HStack(spacing: 10) {
            Button {
                editingPage = page
            } label: {
                Label("编辑…", systemImage: "square.and.pencil")
            }
            .keyboardShortcut("e", modifiers: .command)

            Button {
                NSWorkspaceBridge.reveal(page.filePath)
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }

            Spacer(minLength: 0)

            Button(role: .destructive) {
                showingDeleteConfirm = true
            } label: {
                Label("删除…", systemImage: "trash")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 辅助

    private var selectedPage: BlogPage? {
        guard let id = selectedPageID else { return nil }
        return model.pages.first { $0.id == id }
    }

    private var selectedPages: [BlogPage] {
        model.pages.filter { multiSelection.contains($0.id) }
    }

    private func recomputeReferences() {
        guard let page = selectedPage, let site = model.currentSite else {
            pageReferences = []
            return
        }
        pageReferences = PageReferenceIndex.references(to: page, in: site)
    }

    private func applyBatch(action: BatchAction, tag: String, layout: String) {
        switch action {
        case .addTag:
            model.addTagToPages(selectedPages, tag: tag)
        case .setLayout:
            model.setLayoutForPages(selectedPages, layout: layout)
        case .delete:
            model.deletePages(selectedPages)
            multiSelection = []
        }
    }
}

// MARK: - 列表行

private struct PageRow: View {
    let page: BlogPage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(page.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 6) {
                Text(page.layout)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.quaternary.opacity(0.5), in: Capsule())

                ForEach(page.tags.prefix(3), id: \.self) { tag in
                    Pill(text: tag)
                }

                if page.tags.count > 3 {
                    Text("+\(page.tags.count - 3)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - 新建页面对话框

private struct NewPageSheet: View {

    @EnvironmentObject private var model: HexoManModel
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var layout = "page"
    @State private var permalink = ""
    @State private var tagsText = ""
    @State private var categoriesText = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("新建页面")
                    .font(.headline)
                Text("在 \(model.currentSite?.folderName ?? "当前站点") 的 source/ 目录下创建一个页面。页面没有发布日期，支持任意嵌套目录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            Form {
                TextField("标题（必填）", text: $title)
                    .focused($titleFocused)

                Picker("布局", selection: $layout) {
                    Text("page（默认页面）").tag("page")
                    Text("post（文章布局）").tag("post")
                    Text("layout（自定义）").tag("layout")
                }
                .frame(width: 300)

                TextField("永久链接（可选，留空自动生成）", text: $permalink)
                    .help("例如：/about/ 或 /contact/。留空则根据标题自动生成。")

                TextField("标签，逗号分隔", text: $tagsText)

                TextField("分类，逗号分隔", text: $categoriesText)
            }
            .formStyle(.grouped)
            .frame(width: 440)

            Divider()

            HStack {
                Text("页面会直接创建在 source/ 目录下，支持子目录。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 0)

                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("创建") {
                    model.createPage(
                        title: title,
                        body: "",
                        layout: layout,
                        permalink: permalink,
                        tags: split(tagsText),
                        categories: split(categoriesText)
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 480)
        .onAppear { titleFocused = true }
    }

    private func split(_ text: String) -> [String] {
        text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - front-matter 行

private struct FrontMatterRow: View {
    let entry: FrontMatterEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(entry.key)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayValue)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.primary)
                if entry.isComplexBlock {
                    Text("复杂块（list / map）")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var displayValue: String {
        let raw = entry.rawValue
        // 太长的值截断。
        if raw.count > 200 {
            return String(raw.prefix(200)) + "…"
        }
        return raw.isEmpty ? "（空）" : raw
    }
}

// MARK: - 批量操作 sheet

private struct BatchActionSheet: View {
    @EnvironmentObject private var model: HexoManModel
    @Environment(\.dismiss) private var dismiss

    let action: PagesView.BatchAction
    let targets: [BlogPage]
    let onConfirm: (_ tag: String, _ layout: String) -> Void

    @State private var tagText = ""
    @State private var layoutText = "page"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 420)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text("将对 \(targets.count) 个页面生效：")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(targets.prefix(6)) { page in
                        Text("• \(page.title)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if targets.count > 6 {
                        Text("…还有 \(targets.count - 6) 个")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxHeight: 80)
        }
    }

    private var title: String {
        switch action {
        case .addTag: return "批量添加标签"
        case .setLayout: return "批量设置布局"
        case .delete: return "批量删除"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch action {
        case .addTag:
            VStack(alignment: .leading, spacing: 4) {
                Text("输入标签名（不含 #）。已存在的标签不会被重复加。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("标签", text: $tagText)
                    .textFieldStyle(.roundedBorder)
            }
        case .setLayout:
            VStack(alignment: .leading, spacing: 4) {
                Text("所有选中页面都会改成这个 layout。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("布局", selection: $layoutText) {
                    Text("page").tag("page")
                    Text("post").tag("post")
                    Text("layout").tag("layout")
                }
                .pickerStyle(.segmented)
            }
        case .delete:
            Text("这些文件会一并移到废纸篓，可以从废纸篓恢复。")
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if action == .delete {
                Button(role: .destructive) {
                    onConfirm("", "")
                    dismiss()
                } label: {
                    Text("删除 \(targets.count) 个")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("应用") {
                    onConfirm(tagText, layoutText)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(action == .addTag && tagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}