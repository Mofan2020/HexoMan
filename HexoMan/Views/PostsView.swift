//
//  PostsView.swift
//  HexoMan
//
//  文章列表：左列表 + 右详情。数据全部来自 HexoManModel，不直接碰文件系统。
//

import SwiftUI

struct PostsView: View {

    @EnvironmentObject private var model: HexoManModel

    /// 列表选中项。存的是 BlogPost.id，也就是文件绝对路径。
    @State private var selectedPostID: String?
    /// 新建文章对话框
    @State private var showingNewPost = false
    /// 正在编辑的文章，nil 表示没有打开编辑器
    @State private var editingPost: BlogPost?
    /// 删除二次确认
    @State private var showingDeleteConfirm = false

    // MARK: - 布局

    var body: some View {
        HSplitView {
            listColumn
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 520)
            detailColumn
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showingNewPost) {
            NewPostSheet()
                .environmentObject(model)
        }
        .sheet(item: $editingPost) { post in
            PostEditorView(post: post)
                .environmentObject(model)
        }
        .onChange(of: model.posts.map(\.id)) { _, ids in
            // 站点切换或删除后，清理掉已经失效的选中项
            if let id = selectedPostID, !ids.contains(id) {
                selectedPostID = nil
            }
        }
    }

    // MARK: - 左：列表

    private var listColumn: some View {
        VStack(spacing: 0) {
            listToolbar

            Divider()

            postList

            Divider()

            listFooter
        }
    }

    private var listToolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("搜索标题、正文或标签", text: $model.postSearch)
                    .textFieldStyle(.plain)
                    .font(.callout)

                if model.postSearch.isEmpty == false {
                    Button {
                        model.postSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清空搜索")
                }

                Button {
                    showingNewPost = true
                } label: {
                    Label("新建", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                        .font(.callout)
                }
                .help("新建文章")
            }

            Picker("", selection: $model.postFilter) {
                ForEach(HexoManModel.PostFilter.allCases) { filter in
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
    private var postList: some View {
        if model.posts.isEmpty {
            EmptyHint(
                systemImage: "doc.badge.plus",
                title: "还没有文章",
                message: "这个站点目前没有 Markdown 文章。点左上角「新建」写第一篇，或者直接用 `hexo new <标题>` 创建。"
            )
        } else if model.filteredPosts.isEmpty {
            EmptyHint(
                systemImage: "line.3.horizontal.decrease.circle",
                title: "没有匹配的文章",
                message: "当前筛选「\(model.postFilter.title)」加搜索词「\(model.postSearch)」没有命中任何文章，换个条件试试。"
            )
        } else {
            List(selection: $selectedPostID) {
                ForEach(model.filteredPosts) { post in
                    PostRow(post: post)
                        .tag(post.id)
                        .contextMenu {
                            Button("编辑…") { editingPost = post }
                            Button(post.isDraft ? "发布" : "转为草稿") { model.toggleDraft(post) }
                            Button("在访达中显示") { PostStore.reveal(post) }
                            Divider()
                            Button("删除…", role: .destructive) {
                                selectedPostID = post.id
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
            Text("共 \(model.posts.count) 篇文章")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.filteredPosts.count != model.posts.count {
                Text("· 显示 \(model.filteredPosts.count) 篇")
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
        if let post = selectedPost {
            detail(post)
        } else {
            EmptyHint(
                systemImage: "doc.text",
                title: "选一篇文章",
                message: "从左侧列表选择一篇，这里会显示标题、标签、摘要和可执行的操作。"
            )
        }
    }

    private func detail(_ post: BlogPost) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(post)

                    Divider()

                    meta(post)

                    Divider()

                    preview(post)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            actions(post)
        }
        .confirmationDialog(
            "删除这篇文章？",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible,
            presenting: post
        ) { target in
            Button("移到废纸篓", role: .destructive) {
                model.deletePost(target)
            }
            Button("取消", role: .cancel) {}
        } message: { target in
            Text("\(target.filename) 会被移到废纸篓，不会立刻消失，可以从废纸篓恢复。")
        }
    }

    private func header(_ post: BlogPost) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(post.title)
                    .font(.system(size: 28, weight: .semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if post.isDraft {
                    Pill(text: "草稿", tint: .orange)
                }
            }

            Text(post.excerpt)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(post.filePath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    private func meta(_ post: BlogPost) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailRow(label: "日期", value: post.date.formatted(date: .abbreviated, time: .shortened))
            DetailRow(label: "字数", value: "\(post.wordCount) 字")
            DetailRow(label: "大小", value: ByteCountFormatter.string(fromByteCount: Int64(post.byteSize), countStyle: .file))
            DetailRow(label: "slug", value: post.slug, monospaced: true)
            DetailRow(label: "文件", value: post.filename, monospaced: true)
            DetailRow(
                label: "最后修改",
                value: post.modifiedAt.formatted(date: .abbreviated, time: .shortened)
            )

            if post.tags.isEmpty == false {
                pillRow(label: "标签", values: post.tags, tint: .accentColor)
            }

            if post.categories.isEmpty == false {
                pillRow(label: "分类", values: post.categories, tint: .teal)
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

    private func preview(_ post: BlogPost) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("正文预览")
                .font(.headline)

            if post.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("（正文为空）")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                Text(post.body)
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

    private func actions(_ post: BlogPost) -> some View {
        HStack(spacing: 10) {
            Button {
                editingPost = post
            } label: {
                Label("编辑…", systemImage: "square.and.pencil")
            }
            .keyboardShortcut("e", modifiers: .command)

            Button {
                model.toggleDraft(post)
            } label: {
                Label(
                    post.isDraft ? "发布" : "转为草稿",
                    systemImage: post.isDraft ? "paperplane" : "tray.and.arrow.down"
                )
            }

            Button {
                PostStore.reveal(post)
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

    private var selectedPost: BlogPost? {
        guard let id = selectedPostID else { return nil }
        return model.posts.first { $0.id == id }
    }
}

// MARK: - 列表行

private struct PostRow: View {
    let post: BlogPost

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(post.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 6) {
                Text(post.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ForEach(post.tags.prefix(3), id: \.self) { tag in
                    Pill(text: tag)
                }

                if post.tags.count > 3 {
                    Text("+\(post.tags.count - 3)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if post.isDraft {
                    Pill(text: "草稿", tint: .orange)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - 标签自动换行

/// 详情页里标签数量不定，用一个简单的换行布局排开。
private struct FlexibleTagLayout: View {
    let values: [String]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { value in
                        Pill(text: value, tint: tint)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// 每行最多 4 个，剩下的另起一行。
    private var rows: [[String]] {
        stride(from: 0, to: values.count, by: 4).map {
            Array(values[$0..<min($0 + 4, values.count)])
        }
    }
}

// MARK: - 新建文章对话框

private struct NewPostSheet: View {

    @EnvironmentObject private var model: HexoManModel
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var tagsText = ""
    @State private var categoriesText = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("新建文章")
                    .font(.headline)
                Text("在 \(model.currentSite?.folderName ?? "当前站点") 的 source/_posts 下创建一个 Markdown 文件。")
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

                TextField("标签，逗号分隔，例如 Swift, macOS", text: $tagsText)

                TextField("分类，逗号分隔，例如 技术", text: $categoriesText)
            }
            .formStyle(.grouped)
            .frame(width: 440)

            Divider()

            HStack {
                Text("创建后会直接用编辑器写正文。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 0)

                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("创建") {
                    model.createPost(
                        title: title,
                        body: "",
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

    /// "a, b ,, c" → ["a", "b", "c"]
    private func split(_ text: String) -> [String] {
        text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
