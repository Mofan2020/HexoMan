//
//  ConfigView.swift
//  HexoMan
//
//  站点配置编辑：左边挑文件，右边改 YAML，带顶层键跳转和保存前校验。
//

import AppKit
import SwiftUI

struct ConfigView: View {

    @EnvironmentObject private var model: HexoManModel

    /// 左侧选中的文件路径。ConfigFile.id 就是 path。
    @State private var selectedID: String?
    /// 编辑中的副本。切文件时才从 model 同步，平时不动，避免吞掉用户正在输入的内容。
    @State private var draft: ConfigFile?
    /// 键跳转请求：目标键 + 请求序号，用来触发同一次跳转的重复点击。
    @State private var jump: EditorJumpRequest?
    /// 保存前的告警，文案见 ConfigValidation。
    @State private var validationIssue: String?

    var body: some View {
        if model.configFiles.isEmpty {
            EmptyHint(
                systemImage: "gearshape",
                title: "没有可编辑的配置文件",
                message: "站点根目录下需要有 _config.yml。HexoMan 只编辑站点根目录里的 _config*.yml，主题目录下的配置不在这页处理。"
            )
        } else {
            HSplitView {
                fileList
                    .frame(minWidth: 210, idealWidth: 240, maxWidth: 320)

                editor
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
            // 首次进入或列表刷新后，兜底选中第一个文件。
            .onAppear(perform: ensureSelection)
            // 只在切换选中项时同步；用户打字不会触发这里。
            .onChange(of: selectedID) { _, _ in syncDraftFromModel() }
            .onChange(of: model.configFiles) { _, _ in
                // 站点切换后 configFiles 会整体换掉，旧选中项不再存在。
                if let selectedID, model.configFiles.contains(where: { $0.id == selectedID }) == false {
                    self.selectedID = model.configFiles.first?.id
                }
                syncDraftFromModel(force: true)
                ensureSelection()
            }
            .alert("保存前请确认", isPresented: Binding(
                get: { validationIssue != nil },
                set: { if $0 == false { validationIssue = nil } }
            )) {
                Button("仍然保存", role: .destructive) {
                    validationIssue = nil
                    saveDraft()
                }
                Button("返回修改", role: .cancel) {
                    validationIssue = nil
                }
            } message: {
                Text(validationIssue ?? "")
            }
        }
    }

    // MARK: - 左侧文件列表

    private var fileList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(model.configFiles) { file in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name)
                                .font(.callout)
                                .lineLimit(1)
                            Text(file.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 6)

                        if file.isModified {
                            // model 里的这一项是「磁盘 vs 上次保存」，右侧草稿的未保存态另算。
                            Pill(text: "未保存", tint: .orange)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(file.id)
                }
            }
            .listStyle(.sidebar)

            Divider()

            Text("共 \(model.configFiles.count) 个文件")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
        }
    }

    // MARK: - 右侧编辑器

    @ViewBuilder
    private var editor: some View {
        if let draft {
            VStack(spacing: 0) {
                header(for: draft)
                Divider()
                keyBar(for: draft)
                Divider()
                textArea(for: draft)
                Divider()
                toolbar(for: draft)
            }
        } else {
            EmptyHint(
                systemImage: "doc.text",
                title: "选一个配置文件",
                message: "左边挑一个 _config*.yml 就能开始编辑。"
            )
        }
    }

    private func header(for file: ConfigFile) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(file.name)
                    .font(.headline)

                if file.isModified {
                    Pill(text: "未保存", tint: .orange)
                } else {
                    Pill(text: "与磁盘一致", tint: .green)
                }

                Spacer(minLength: 8)

                Text("\(lineCount) 行")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text(file.path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// 顶层键快捷跳转。点击后编辑器滚动并选中该键所在行。
    private func keyBar(for file: ConfigFile) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if file.topLevelKeys.isEmpty {
                    Text("没有解析到顶层键")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(file.topLevelKeys, id: \.self) { key in
                        Button {
                            jumpToKey(key, in: file)
                        } label: {
                            Text(key)
                                .font(.system(size: 11, design: .monospaced))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                        }
                        .buttonStyle(.plain)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                        .help("跳转到 \(key)")
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func textArea(for file: ConfigFile) -> some View {
        TextEditor(text: contentsBinding(for: file))
            .font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            // 放在背景里的隐形控制器：SwiftUI 的 TextEditor 没有暴露跳转 API，
            // 这里借 AppKit 的 NSTextView 完成滚动 + 选中。
            .background(EditorJumpController(request: $jump, text: file.contents))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toolbar(for file: ConfigFile) -> some View {
        HStack(spacing: 10) {
            Button {
                saveDraft()
            } label: {
                Label("保存", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!file.isModified)
            .keyboardShortcut("s", modifiers: .command)
            .help("写回磁盘（⌘S）。保存后建议跑一次 hexo generate 才会生效")

            Button {
                model.revertConfig(file)
                syncDraftFromModel(force: true)
            } label: {
                Label("放弃改动", systemImage: "arrow.uturn.backward")
            }
            .disabled(!file.isModified)
            .help("丢弃编辑器里的改动，回到磁盘上的内容")

            Button {
                if model.currentSite != nil {
                    model.refreshAll()
                }
                syncDraftFromModel(force: true)
            } label: {
                Label("重新读取", systemImage: "arrow.clockwise")
            }
            .help("重新从磁盘读取该文件。编辑器里有未保存内容时会被覆盖")

            Button {
                NSWorkspaceBridge.reveal(file.path)
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }

            Spacer(minLength: 8)

            Text("保存后建议在「构建与预览」跑一次生成，配置才会生效")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - 状态同步

    private func ensureSelection() {
        guard selectedID == nil else { return }
        selectedID = model.configFiles.first?.id
    }

    /// 把 model 里的最新内容灌进编辑副本。
    /// - Parameter force: 站点切换、重新读取、放弃改动后必须强制覆盖；
    ///   否则保留草稿（此时用户可能正在打字）。
    private func syncDraftFromModel(force: Bool = false) {
        guard let selectedID, let latest = model.configFiles.first(where: { $0.id == selectedID }) else {
            draft = nil
            return
        }

        if force == false, let draft, draft.id == latest.id {
            // 文件没换：不碰用户正在编辑的内容。
            return
        }

        draft = latest
    }

    private func contentsBinding(for file: ConfigFile) -> Binding<String> {
        Binding(
            get: { draft?.contents ?? file.contents },
            set: { newValue in
                guard var current = draft else { return }
                current.contents = newValue
                draft = current
            }
        )
    }

    private func jumpToKey(_ key: String, in file: ConfigFile) {
        guard let line = ConfigValidation.lineIndex(ofTopLevelKey: key, in: file.contents) else {
            model.showToast("没找到 \(key) 所在的行", kind: .info)
            return
        }
        jump = EditorJumpRequest(line: line)
    }

    // MARK: - 保存

    private func saveDraft() {
        guard let draft else { return }

        if let issue = ConfigValidation.issue(for: draft.contents) {
            validationIssue = issue
            return
        }

        model.saveConfig(draft)
        // saveConfig 会用 ConfigStore.markSaved 重置基准，这里把新值取回来，
        // 否则编辑器还会一直显示「未保存」。
        syncDraftFromModel(force: true)
    }

    private var lineCount: Int {
        (draft?.contents ?? "").isEmpty ? 0 : (draft?.contents ?? "").components(separatedBy: .newlines).count
    }
}

// MARK: - 跳转请求

/// 一次键跳转。`line` 是 0 起的行号，`stamp` 让重复点同一个键也能再次触发。
struct EditorJumpRequest: Equatable {
    var line: Int
    var stamp: Int = EditorJumpRequest.nextStamp()

    private static var counter = 0

    private static func nextStamp() -> Int {
        counter += 1
        return counter
    }
}

// MARK: - AppKit 跳转控制器

/// 在窗口里找到承载 TextEditor 的 NSTextView，然后滚动并选中目标行。
/// 找不到就什么都不做，不影响正常使用。
struct EditorJumpController: NSViewRepresentable {

    @Binding var request: EditorJumpRequest?
    /// 当前编辑器文本，用来在窗口里辨认出正确的那个 NSTextView。
    var text: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        /// 已经处理过的请求，防止用户继续打字时反复把选区拉回去。
        var appliedStamp: Int?
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let request, context.coordinator.appliedStamp != request.stamp else { return }
        context.coordinator.appliedStamp = request.stamp

        // 布局还没完成时 NSTextView 可能还没进窗口树，推迟一拍再动。
        DispatchQueue.main.async {
            guard let textView = Self.findTextView(in: view.window, matching: text) else { return }

            let nsText = text as NSString
            let location = min(max(0, request.line), max(0, nsText.length - 1))
            let range = NSRange(location: location, length: nsText.length > location ? 1 : 0)

            textView.scrollRangeToVisible(range)
            textView.setSelectedRange(range)
            view.window?.makeFirstResponder(textView)
        }
    }

    /// 深度优先找内容前缀一致、可编辑的 NSTextView。
    private static func findTextView(in window: NSWindow?, matching text: String) -> NSTextView? {
        // 隐形视图可能还没挂上窗口，退回到当前活动窗口再找一次。
        let target = window ?? NSApp.keyWindow ?? NSApp.mainWindow
        guard let root = target?.contentView else { return nil }
        return search(root, matching: text)
    }

    private static func search(_ view: NSView, matching text: String) -> NSTextView? {
        if let textView = view as? NSTextView, textView.isEditable {
            let current = textView.string
            if current == text || text.hasPrefix(current) || current.hasPrefix(text) {
                return textView
            }
        }

        for subview in view.subviews {
            if let found = search(subview, matching: text) { return found }
        }

        return nil
    }
}

// MARK: - 保存前校验

/// 只做能确定判断的几件事。真正的 YAML 语法校验需要第三方解析器，
/// 这里宁可少报也不误报：只有明显破坏才会拦。
enum ConfigValidation {

    /// 有问题时返回告警文案，没有问题返回 nil。
    static func issue(for text: String) -> String? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "内容是空的。保存会把这个配置文件清空，Hexo 之后读不到任何配置。"
        }

        if text.contains("\t") {
            return "内容里出现了制表符（Tab）。YAML 只能用空格缩进，Tab 很可能让 Hexo 解析失败。"
        }

        if let line = firstSuspiciousLine(in: text) {
            return "第 \(line) 行的缩进看起来不对（不是空格倍数）。保存后建议立刻跑一次 hexo generate 验证。"
        }

        return nil
    }

    /// 顶层键（第一列的 `key:`）所在的 0 起始行号。找不到返回 nil。
    static func lineIndex(ofTopLevelKey key: String, in text: String) -> Int? {
        let lines = text.components(separatedBy: .newlines)
        let prefix = "\(key):"

        for (index, line) in lines.enumerated() {
            guard line.hasPrefix(prefix) else { continue }
            let rest = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            // 顶层键后面紧跟别的键名，说明这是嵌套的同名键，继续往下找。
            if rest.hasPrefix("\"") || rest.hasPrefix("'") { continue }
            return index
        }

        return nil
    }

    /// 缩进不是空格倍数的行（跳过注释和空行）。
    private static func firstSuspiciousLine(in text: String) -> Int? {
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let indent = line.prefix { $0 == " " }.count
            if indent % 2 != 0 { return index + 1 }
        }

        return nil
    }
}
