//
//  PostEditorView.swift
//  HexoMan
//
//  文章编辑器。同一套界面服务「编辑已有文章」和「新建文章」两种场景。
//

import AppKit
import SwiftUI

struct PostEditorView: View {

    /// 编辑模式传入原文章；nil 表示新建。
    let post: BlogPost?

    @EnvironmentObject private var model: HexoManModel
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var bodyText: String
    @State private var tagsText: String
    @State private var categoriesText: String
    @State private var date: Date
    @State private var isDraft: Bool

    @FocusState private var titleFocused: Bool

    /// 选了图片文件之后要插入的位置就是正文末尾——`TextEditor` 没有光标 API，
    /// 与其假装知道光标在哪，不如把图插在末尾再让用户自己挪。
    @State private var showingImagePicker = false
    /// Cmd+V 的本地监听：只有剪贴板里是图时才接管，粘文字照旧。
    @State private var pasteMonitor: Any?
    @State private var isDropTargeted = false

    private var isNew: Bool { post == nil }

    // MARK: - 初始化

    init(post: BlogPost? = nil) {
        self.post = post
        _title = State(initialValue: post?.title ?? "")
        _bodyText = State(initialValue: post?.body ?? "")
        _tagsText = State(initialValue: (post?.tags ?? []).joined(separator: ", "))
        _categoriesText = State(initialValue: (post?.categories ?? []).joined(separator: ", "))
        _date = State(initialValue: post?.date ?? Date())
        _isDraft = State(initialValue: post?.isDraft ?? false)
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
            installPasteMonitor()
        }
        .onDisappear { removePasteMonitor() }
        .fileImporter(
            isPresented: $showingImagePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                insertImages(at: urls)
            }
        }
    }

    // MARK: - 标题区

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: isNew ? "doc.badge.plus" : "square.and.pencil")
                .foregroundStyle(.secondary)

            TextField("文章标题", text: $title)
                .font(.title2)
                .textFieldStyle(.plain)
                .focused($titleFocused)

            if isDraft {
                Pill(text: "草稿", tint: .orange)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - 元信息

    private var metaBar: some View {
        HStack(alignment: .center, spacing: 18) {
            DatePicker("日期", selection: $date)
                .datePickerStyle(.compact)
                .labelsHidden()
                .help("发布日期（写入 front-matter 的 date）")

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

            Toggle("草稿", isOn: $isDraft)
                .toggleStyle(.switch)
                .help("草稿文章不会出现在生成结果里")

            Spacer(minLength: 0)

            if let post {
                Text(post.filename)
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
            .overlay(alignment: .center) {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            // 拖图片文件进正文：直接存进 source/images 再插 Markdown。
            .dropDestination(for: URL.self) { urls, _ in
                let images = urls.filter(Self.isImageFile)
                guard !images.isEmpty else { return false }
                insertImages(at: images)
                return true
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }
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

            Button {
                showingImagePicker = true
            } label: {
                Label("editor.insertImage", systemImage: "photo.badge.plus")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("editor.insertImage.help")
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

            Button(isNew ? "创建文章" : "保存") { save() }
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

        if let post {
            // 编辑模式：改的是已有文件的副本。
            var edited = post
            edited.front.setTitle(trimmedTitle)
            edited.front.setTags(tags)
            edited.front.setCategories(categories)
            edited.front.setDraft(isDraft)
            edited.front.set("date", FrontMatter.renderDate(date))
            edited.body = bodyText
            model.savePost(edited)
        } else {
            // 新建模式：日期和草稿标记一次性写进 front-matter，不需要建完再回查补写。
            model.createPost(
                title: trimmedTitle,
                body: bodyText,
                tags: tags,
                categories: categories,
                date: date,
                isDraft: isDraft
            )
        }

        dismiss()
    }

    // MARK: - 插图

    /// 图片落盘后把 Markdown 追加到正文末尾。
    ///
    /// 前后各留一个空行：Markdown 里图片紧贴上一段会被当成行内元素，
    /// 排版出来和人想的不一样。
    private func insertImages(at urls: [URL]) {
        let lines = model.storeImages(at: urls, base: slugBase)
        guard !lines.isEmpty else { return }
        appendMarkdown(lines.joined(separator: "\n\n"))
    }

    private func insertImageData(_ data: Data, filename: String) {
        guard let markdown = model.storeImageData(data, filename: filename, base: slugBase) else { return }
        appendMarkdown(markdown)
    }

    private func appendMarkdown(_ block: String) {
        var text = bodyText
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        if !text.isEmpty && !text.hasSuffix("\n\n") { text += "\n" }
        bodyText = text + block + "\n"
    }

    /// 图片文件名的主干：已有文章用它的 slug，新文章用标题。
    private var slugBase: String {
        if let post, !post.slug.isEmpty { return SiteMedia.sanitize(post.slug) }
        return SiteMedia.sanitize(title)
    }

    private static func isImageFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return SiteMedia.writableExtensions.contains(ext) || ext == "heic" || ext == "heif"
    }

    // MARK: - 粘贴图片

    /// 监听 Cmd+V：**只有**剪贴板里是图的时候才接管。
    ///
    /// 不这么分的话，编辑器里粘一段文字会被自己的监听吃掉。判断依据是
    /// 「有图片数据」且「没有纯文本（或纯文本只是个 URL / HTML，那是从网页
    /// 复制图片时一起带上的）」，其余情况一律放行给 TextEditor。
    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "v"
            else { return event }

            let pasteboard = NSPasteboard.general
            if let text = pasteboard.string(forType: .string),
               !text.isEmpty,
               !text.hasPrefix("http"),
               !text.hasPrefix("<"),
               !text.hasPrefix("data:") {
                return event
            }
            guard let payload = Self.imagePayload(from: pasteboard) else { return event }
            insertImageData(payload.0, filename: payload.1)
            return nil
        }
    }

    private func removePasteMonitor() {
        if let pasteMonitor {
            NSEvent.removeMonitor(pasteMonitor)
            self.pasteMonitor = nil
        }
    }

    private static func imagePayload(from pasteboard: NSPasteboard) -> (Data, String)? {
        // 直接是图（截图、网页复制）。
        if let png = pasteboard.data(forType: .png) {
            return (png, "pasted.png")
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let png = SiteMedia.pngData(from: tiff) {
            return (png, "pasted.png")
        }
        // 复制的是文件（访达里 Cmd+C 一个图片文件）。
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           let first = urls.first(where: isImageFile),
           let data = SiteMedia.data(for: first) {
            return (data, first.lastPathComponent)
        }
        return nil
    }

    // MARK: - 辅助

    /// 与 `BlogPost.wordCount` 保持同一套统计口径。
    private var wordCount: Int {
        bodyText
            .replacingOccurrences(of: "```", with: "")
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .count
    }

    private var modifiedHint: String {
        guard let post else { return "新文章将写入 \(model.currentSite?.folderName ?? "当前站点")" }
        return "最后修改 " + post.modifiedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func split(_ text: String) -> [String] {
        text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
