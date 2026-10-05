//
//  PageEditorView.swift
//  HexoMan
//
//  页面编辑器。复用文章编辑器的大部分逻辑，但去掉日期和草稿，加上布局和永久链接。
//

import SwiftUI

struct PageEditorView: View {

    let page: BlogPage?

    @EnvironmentObject private var model: HexoManModel
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var bodyText: String
    @State private var tagsText: String
    @State private var categoriesText: String
    @State private var layout: String
    @State private var permalink: String

    @FocusState private var titleFocused: Bool

    private var isNew: Bool { page == nil }

    // MARK: - 初始化

    init(page: BlogPage? = nil) {
        self.page = page
        _title = State(initialValue: page?.title ?? "")
        _bodyText = State(initialValue: page?.body ?? "")
        _tagsText = State(initialValue: (page?.tags ?? []).joined(separator: ", "))
        _categoriesText = State(initialValue: (page?.categories ?? []).joined(separator: ", "))
        _layout = State(initialValue: page?.layout ?? "page")
        _permalink = State(initialValue: page?.permalink ?? "")
    }

    // MARK: - 布局

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            metaBar
            Divider()
            editorArea
            Divider()
            hintLine
            Divider()
            bottomBar
        }
        .frame(minWidth: 720, minHeight: 560)
        .onAppear {
            if isNew { titleFocused = true }
        }
    }

    // MARK: - 标题区

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: isNew ? "doc.badge.plus" : "square.and.pencil")
                .foregroundStyle(.secondary)

            TextField("页面标题", text: $title)
                .font(.title2)
                .textFieldStyle(.plain)
                .focused($titleFocused)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - 元信息

    private var metaBar: some View {
        HStack(alignment: .center, spacing: 18) {
            Picker("布局", selection: $layout) {
                Text("page（默认页面）").tag("page")
                Text("post（文章布局）").tag("post")
                Text("layout（自定义）").tag("layout")
            }
            .frame(width: 200)
            .help("页面使用的布局模板")

            VStack(alignment: .leading, spacing: 3) {
                Text("永久链接")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("/about/", text: $permalink)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
            .help("留空则根据标题自动生成。例如：/about/")

            VStack(alignment: .leading, spacing: 3) {
                Text("标签")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("Swift, macOS", text: $tagsText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("分类")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("技术", text: $categoriesText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
            }

            Spacer(minLength: 0)

            if let page {
                Text(page.filename)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: - 正文

    private var editorArea: some View {
        TextEditor(text: $bodyText)
            .font(.system(size: 13, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hintLine: some View {
        HStack(spacing: 10) {
            Text("Markdown：")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("# 标题　**粗体**　*斜体*　`代码`　> 引用　- 列表　[链接](url)　``` 代码块")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
    }

    // MARK: - 底部

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Text("\(wordCount) 字")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(modifiedHint)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button(isNew ? "创建页面" : "保存") { save() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: - 保存

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            model.showToast("标题不能为空", kind: .failure)
            return
        }

        let tags = split(tagsText)
        let categories = split(categoriesText)

        if let page {
            var edited = page
            edited.front.setTitle(trimmedTitle)
            edited.front.setTags(tags)
            edited.front.setCategories(categories)
            edited.front.set("layout", layout)
            if permalink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                edited.front.remove("permalink")
            } else {
                edited.front.set("permalink", permalink)
            }
            edited.body = bodyText
            model.savePage(edited)
        } else {
            model.createPage(
                title: trimmedTitle,
                body: bodyText,
                layout: layout,
                permalink: permalink,
                tags: tags,
                categories: categories
            )
        }

        dismiss()
    }

    // MARK: - 辅助

    private var wordCount: Int {
        bodyText
            .replacingOccurrences(of: "```", with: "")
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .count
    }

    private var modifiedHint: String {
        guard let page else { return "新页面将写入 \(model.currentSite?.folderName ?? "当前站点")" }
        return "最后修改 " + page.modifiedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func split(_ text: String) -> [String] {
        text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}