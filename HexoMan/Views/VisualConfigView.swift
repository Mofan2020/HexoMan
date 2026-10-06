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
                    syncSection
                    beginnersGuide
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

    // MARK: - 新手先看这段

/// 开头的三句话说明。
///
/// 这一页是整个工具里最容易让人无从下手的地方：满屏不认识的名词，
/// 于是只能退回去改 YAML——而那正是我们想避免的。
/// 先把「这些名词大概是什么」和「哪个该先填」讲清楚，后面每一项才读得懂。
private var beginnersGuide: some View {
    VStack(alignment: .leading, spacing: 10) {
        Label("第一次用？先看这三句", systemImage: "lightbulb")
            .font(.subheadline.weight(.semibold))

        guideRow(
            "1",
            "这里改的是「站点设置」，不是写文章。",
            "填完点保存，再去「构建与预览」跑一次生成，站点才会变。写文章在「文章」那一页。"
        )
        guideRow(
            "2",
            "不认识的名词，点它下面的「怎么填？」。",
            "每个配置项都带详细说明：这个值是干什么的、该填什么格式、常见错怎么填。"
        )
        guideRow(
            "3",
            "不知道该填什么就先别动，默认值通常能用。",
            "唯一建议现在就填的是「站点标题」和「站点网址」——它们决定站点对外的样子和所有链接。"
        )
    }
    .padding(14)
    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
}

private func guideRow(_ number: String, _ title: String, _ detail: String) -> some View {
    HStack(alignment: .top, spacing: 9) {
        Text(number)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 17, height: 17)
            .background(Color.accentColor, in: Circle())

        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.callout)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
    }
}

// MARK: - 站点配置 ↔ 主题配置

/// 同步状态与开关。
///
/// 存在的理由：Hexo 站点有两份配置，**主题那份同名键优先**。
/// 用户在这里（站点配置）改头像却没反应，是因为主题配置里还有一份旧值——
/// 不说清楚的话，用户只会反复检查自己有没有保存成功。
private var syncSection: some View {
    let differences = model.configSyncDifferences
    let themeOnly = model.themeOnlyEntries

    return VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label("与主题配置同步", systemImage: "arrow.triangle.2.circlepath")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Toggle("自动同步", isOn: Binding(
                get: { model.syncsThemeConfig },
                set: { model.syncsThemeConfig = $0 }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("""
            头像、标题、网址这类值在 _config.yml 和主题配置里各有一份，
            而主题会优先用它自己那份。开着开关，在这里改这些值会同时写进主题配置。
            关掉之后两个文件各管各的。
            """)
        }
        .padding(.bottom, 8)

        Text("""
        Hexo 站点有两份配置：`_config.yml`（站点配置）和 `_config.<主题>.yml`（主题配置）。\
        **同名的主题配置优先**，所以只改站点配置，头像、标题这类往往不会生效。
        开启自动同步后，这里改这些值会一并写入主题配置。
        """)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        if model.syncsThemeConfig {
            if differences.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Text(themeOnly.isEmpty
                         ? "站点配置和主题配置目前是一致的"
                         : "两边没有冲突")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("有 \(differences.count) 项两边不一致（以站点配置为准）：")
                        .font(.caption)
                        .foregroundStyle(.orange)

                    ForEach(differences) { difference in
                        HStack(alignment: .top, spacing: 6) {
                            Text(difference.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 84, alignment: .leading)
                            Text(difference.siteDisplay)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.green)
                                .lineLimit(1)
                            Image(systemName: "arrow.left")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                            Text(difference.themeDisplay)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }

                    Button {
                        model.syncThemeConfigToSite()
                    } label: {
                        Label("一键把主题配置同步成站点配置的样子", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
                .padding(10)
                .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.top, 6)
            }

            // 只配在主题那一侧的项。这是**正常状态**，不是错误：
            // 很多人就是把头像直接写在 _config.yun.yml 里的。
            // 提示它是为了让用户自己决定要不要搬回站点配置——
            // 搬过去的好处是以后换主题，头像不会丢。
            if themeOnly.isEmpty == false {
                VStack(alignment: .leading, spacing: 6) {
                    Text("有 \(themeOnly.count) 项你只配在了主题配置里：")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("这些值主题会用上，**不会不生效**。要不要搬进站点配置由你决定——搬过去的好处是以后换主题不会丢。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(themeOnly) { entry in
                        HStack(alignment: .center, spacing: 6) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(entry.value)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(entry.siteState.description)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 8)
                            Button("搬到站点配置") {
                                model.pullThemeValueToSite(key: entry.key)
                            }
                            .controlSize(.small)
                        }
                    }

                    Button {
                        model.pullAllThemeValuesToSite()
                    } label: {
                        Label("全部搬到站点配置", systemImage: "arrow.down.doc")
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.top, 6)
            }
        }
    }
    .padding(14)
    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

            // 「怎么填」的详细文档。有就显示，没有就退回原来那行 hint。
            if let doc = ConfigDocs.flatDoc(field.key) {
                ConfigHelpView(doc: doc)
            } else {
                Text(field.hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            // 候选项要补上「当前值」。站点里常见的 language: zh-CN 并不在
            // 手写候选表里，不补的话 Picker 会显示成空白——空白选中态是没法保存的。
            Picker("", selection: choiceBinding(field)) {
                ForEach(ConfigField.mergedOptions(
                    options.map { .init(value: $0.value, label: $0.label) },
                    current: model.siteSettingValues()[field.key]
                )) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320)

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

    /// 下拉框的绑定：**选中即写盘**。
    ///
    /// 这里原来走的是「先存进 `pending`，再靠 `.onChange` 观察
    /// `model.siteSettingValues()` 来提交」——而那个值只有在提交之后才会变，
    /// 于是 onChange 永远不触发，「站点语言」选了等于没选。
    ///
    /// 下拉本身没有「失焦」这个时机（用户点完就去点别处了，
    /// 焦点可能落在同页面别的输入框上），所以正确做法就是选中就存，
    /// 跟开关一样。这类字段都是低风险的枚举值，不存在写到一半的风险。
    private func choiceBinding(_ field: SiteField) -> Binding<String> {
        let key = field.key
        return Binding(
            get: { model.siteSettingValues()[key] ?? "" },
            set: { newValue in
                // 清掉可能残留的草稿，避免之后失焦提交时用旧值覆盖回来
                pending[key] = nil
                guard newValue != model.siteSettingValues()[key] else { return }
                model.updateSiteSetting(newValue, for: key)
            }
        )
    }

    // MARK: - 自定义内容

    private var customContentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("自定义内容", systemImage: "wand.and.stars")
                    .font(.headline)
                Spacer()
                // 状态徽标要说真话：站里已经有注入在跑时，
                // 光看 HexoMan 自己那两个文件会显示「未启用」，但横幅其实天天在显示。
                if model.isCustomContentInstalled {
                    Text("已启用")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else if model.hasAnyInjectScript {
                    Text("已有其他注入脚本")
                        .font(.caption2)
                        .foregroundStyle(.orange)
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

            // 站点里已有的注入脚本。放在最前面，用户必须先知道这件事
            ForEach(model.foreignInjectScripts) { script in
                foreignScriptCard(script)
            }

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

    // MARK: - 已有的注入脚本

/// 站点 `scripts/` 里用户自己写的注入脚本。
///
/// 这一块的存在理由是「如实告知」：这类脚本完全有效、也该保留，
/// 但用户经常不知道它在跑，于是要么以为工具坏了，要么在下面再配一份，
/// 结果同一段内容在页面上出现两次。
private func foreignScriptCard(_ script: DetectedInjectScript) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text("检测到站点里已有注入脚本")
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            Button {
                NSWorkspaceBridge.reveal(script.path)
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }
            .controlSize(.small)
        }

        Text("""
        下面这个脚本已经在往生成好的页面里插东西了。它不是 HexoMan 生成的，\
        但同样有效——**先别在下面重复填一遍**，否则同一段内容会出现两遍。
        """)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 4) {
            infoRow("文件", script.path)
            infoRow("钩子", script.hooks.isEmpty ? "未识别" : script.hooks.joined(separator: ", "))
            if script.insertsInto.isEmpty == false {
                infoRow("插入位置", script.insertsInto.joined(separator: "、") + " 之前")
            }
            if script.externalSources.isEmpty == false {
                infoRow("引用资源", script.sourceDescription)
            }
        }
        .padding(9)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

        Button("重新检测") {
            model.refreshAll()
        }
        .controlSize(.small)
        .help("你刚刚改了 scripts/ 目录时点一下")
    }
    .padding(12)
    .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(.orange.opacity(0.35))
    }
}

private func infoRow(_ title: String, _ value: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
        Text(title)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(width: 56, alignment: .leading)
        Text(value)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
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
