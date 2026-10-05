//
//  PagesView.swift
//  HexoMan
//
//  页面列表：管理 source/ 目录下的页面（非 _posts）。
//  页面和文章的区别：页面不在 _posts 下、没有发布日期、可任意嵌套目录。
//

import SwiftUI

struct PagesView: View {
    @EnvironmentObject private var model: HexoManModel

    @State private var selectedPageID: String?
    @State private var showingNewPage = false
    @State private var editingPage: BlogPage?
    @State private var showingDeleteConfirm = false

    var body: some View {
        HSplitView {
            listColumn
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 520)
            detailColumn
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showingNewPage) {
            NewPageSheet()
                .environmentObject(model)
        }
        .sheet(item: $editingPage) { page in
            PageEditorView(page: page)
                .environmentObject(model)
        }
        .onChange(of: model.pages.map(\.id)) { _, ids in
            if let id = selectedPageID, !ids.contains(id) {
                selectedPageID = nil
            }
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

            Picker("", selection: $model.pageFilter) {
                ForEach(HexoManModel.PageFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
        }
    }

    private var listFooter: some View {
        HStack(spacing: 8) {
            Text("共 \(model.pages.count) 个页面")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.filteredPages.count != model.pages.count {
                Text("· 显示 \(model.filteredPages.count) 个")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

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
        if let page = selectedPage {
            detail(page)
        } else {
            EmptyHint(
                systemImage: "doc.plaintext",
                title: "选一个页面",
                message: "从左侧列表选择一个页面，这里会显示标题、布局、永久链接和可执行的操作。"
            )
        }
    }

    private func detail(_ page: BlogPage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(page)

                    Divider()

                    meta(page)

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