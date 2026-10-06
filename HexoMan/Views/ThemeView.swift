//
//  ThemeView.swift
//  HexoMan
//
//  主题管理：查看已安装主题、一键切换、安装新主题、配置主题专属配置文件。
//

import SwiftUI

struct ThemeView: View {
    @EnvironmentObject private var model: HexoManModel

    @State private var installedThemes: [InstalledTheme] = []
    @State private var isLoading = false
    @State private var showInstallSheet = false
    @State private var customThemeName = ""
    @State private var selectedThemeForConfig: InstalledTheme?
    @State private var showThemeConfig = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection

            if installedThemes.isEmpty && !isLoading {
                EmptyHint(
                    systemImage: "paintbrush",
                    title: "还没有安装主题",
                    message: "点击右上角「安装主题」从推荐列表选择，或输入 npm 包名安装。"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                themeList
            }
        }
        .padding(20)
        .onAppear {
            Task { await loadThemes() }
        }
        .sheet(isPresented: $showInstallSheet) {
            InstallThemeSheet(onInstall: { name in
                Task { await installTheme(name) }
            })
        }
        .sheet(item: $selectedThemeForConfig) { theme in
            ThemeConfigView(theme: theme)
                .environmentObject(model)
        }
    }

    private var headerSection: some View {
        HStack {
            Label("主题管理", systemImage: "paintbrush")
                .font(.title2.weight(.semibold))

            Spacer()

            Text("当前：\(currentThemeName)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.3), in: Capsule())

            Button {
                showInstallSheet = true
            } label: {
                Label("安装主题", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isBusy)
        }
    }

    private var currentThemeName: String {
        model.info?.theme.isEmpty == false ? model.info!.theme : "未设置"
    }

    private var themeList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if isLoading {
                    ProgressView("扫描已安装主题…")
                        .frame(maxWidth: .infinity)
                        .padding(40)
                } else {
                    ForEach(installedThemes) { theme in
                        ThemeRow(
                            theme: theme,
                            isActive: theme.name == model.info?.theme,
                            onActivate: { activateTheme(theme) },
                            onConfig: { selectedThemeForConfig = theme }
                        )
                    }
                }
            }
        }
    }

    private func loadThemes() async {
        guard let site = model.currentSite else { return }
        isLoading = true
        let themes = ThemeManager.installed(site: site, activeName: model.info?.theme)
        await MainActor.run {
            self.installedThemes = themes
            self.isLoading = false
        }
    }

    private func activateTheme(_ theme: InstalledTheme) {
        guard let site = model.currentSite else { return }
        Task {
            do {
                try ThemeManager.switchTheme(site: site, to: theme)
                model.toast = Toast(text: "已切换到 \(theme.name)", kind: .success)
                await loadThemes()
                model.refreshAll()
            } catch {
                model.toast = Toast(text: "切换失败：\(error.localizedDescription)", kind: .failure)
            }
        }
    }

    private func installTheme(_ name: String) async {
        guard model.currentSite != nil else { return }
        let success = await model.applyTheme(named: name)
        if success {
            await loadThemes()
        } else {
            model.toast = Toast(text: "安装失败", kind: .failure)
        }
    }
}

// MARK: - 单个主题行

struct ThemeRow: View {
    let theme: InstalledTheme
    let isActive: Bool
    let onActivate: () -> Void
    let onConfig: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            // 状态指示
            ZStack {
                Circle()
                    .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 12, height: 12)
                if isActive {
                    Circle()
                        .stroke(Color.accentColor, lineWidth: 2)
                        .frame(width: 20, height: 20)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(theme.name)
                        .font(.callout.weight(.medium))
                    if isActive {
                        Pill(text: "使用中", tint: .accentColor)
                    }
                }

                Text(theme.packageName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if !theme.description.isEmpty {
                    Text(theme.description)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                if !isActive {
                    Button("启用", action: onActivate)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Pill(text: "已启用", tint: .green)
                }

                Button("配置", action: onConfig)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("打开主题专属配置文件。需要先生成配置文件。")
            }
        }
        .padding(12)
        .background(
            isActive ? Color.accentColor.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isActive ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.15),
                    lineWidth: 1
                )
        )
    }

}

// MARK: - 安装主题 Sheet

struct InstallThemeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onInstall: (String) -> Void

    @State private var selectedTheme: ThemeCatalog.Item?
    @State private var customName = ""
    @State private var mode: InstallMode = .catalog

    enum InstallMode: String, CaseIterable, Identifiable {
        case catalog = "从推荐列表选"
        case custom = "输入包名"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("安装新主题")
                .font(.headline)

            Picker("", selection: $mode) {
                ForEach(InstallMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if mode == .catalog {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(ThemeCatalog.items) { item in
                            ThemeCatalogRow(item: item, isSelected: selectedTheme?.name == item.name) {
                                selectedTheme = item
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("例如：hexo-theme-yun", text: $customName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                    Text("输入完整的 npm 包名，支持 hexo-theme-xxx 或 @scope/hexo-theme-xxx 格式")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button {
                    let name: String
                    if mode == .catalog, let selected = selectedTheme {
                        name = selected.packageName
                    } else {
                        name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    guard !name.isEmpty else { return }
                    onInstall(name)
                    dismiss()
                } label: {
                    Text(mode == .catalog ? "安装" : "安装")
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    mode == .catalog ? selectedTheme == nil : customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

// MARK: - 主题配置视图

struct ThemeConfigView: View {
    @EnvironmentObject private var model: HexoManModel
    @Environment(\.dismiss) private var dismiss

    let theme: InstalledTheme

    @State private var configContent: String = ""
    @State private var hasConfig = false
    @State private var tab: Tab = .visual

    enum Tab: String, CaseIterable, Identifiable {
        case visual = "可视化编辑"
        case raw = "原始文件"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()

            if !hasConfig {
                emptyState
            } else {
                // 页签而不是左右分栏。
                //
                // 原来用 HSplitView 把可视化表单和原始文件并排放，结果两半都被挤成
                // 几百像素宽——原始文件那侧一行放不下几个字符，滚动条横着来回拉，
                // 「右边原始文件看不全」就是这么来的。主题配置（_config.yun.yml）
                // 本来就上百行，并排谁也读不了。页签一次只显示一份，各自都是全宽。
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Group {
                    switch tab {
                    case .visual:
                        SchemaThemeConfigView(
                            theme: theme,
                            configContent: $configContent,
                            onSave: saveConfig
                        )
                    case .raw:
                        ThemeRawConfigView(
                            content: $configContent,
                            onSave: saveConfig
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 720, idealWidth: 860, minHeight: 520, idealHeight: 620)
        .onAppear(perform: loadConfig)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("配置 \(theme.name)")
                    .font(.headline)
                HStack(spacing: 6) {
                    Text(theme.packageName)
                    if hasConfig {
                        Text("·")
                        Text(theme.configFileName)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("完成") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("该主题还没有专属配置文件")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("点击下方按钮，HexoMan 会复制主题自带的示例配置（如果有）或创建一个空配置模板。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            Button {
                createConfig()
            } label: {
                Label("生成配置文件", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadConfig() {
        guard let site = model.currentSite else { return }
        let path = site.path + "/" + theme.configFileName
        hasConfig = FileManager.default.fileExists(atPath: path)
        if hasConfig, let content = try? String(contentsOfFile: path, encoding: .utf8) {
            configContent = content
        }
    }

    private func createConfig() {
        guard let site = model.currentSite else { return }
        do {
            let content = try ThemeManager.createSiteConfig(site: site, for: theme)
            configContent = content
            hasConfig = true
            // 刚生成的是一份模板，直接进原始文件页比进空表单更直观
            tab = .raw
        } catch {
            model.toast = Toast(text: "生成失败：\(error.localizedDescription)", kind: .failure)
        }
    }

    private func saveConfig() {
        guard let site = model.currentSite else { return }
        let path = site.path + "/" + theme.configFileName
        do {
            try configContent.write(toFile: path, atomically: true, encoding: .utf8)
            hasConfig = true
            model.toast = Toast(text: "配置已保存，重新生成站点后生效", kind: .success)
        } catch {
            model.toast = Toast(text: "保存失败：\(error.localizedDescription)", kind: .failure)
        }
    }
}

// MARK: - 主题配置的 Schema 驱动编辑器

struct SchemaThemeConfigView: View {
    let theme: InstalledTheme
    @Binding var configContent: String
    let onSave: () -> Void

    @State private var schemaFields: [ConfigField] = []
    @State private var pendingValues: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("可视化编辑", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if schemaFields.isEmpty {
                        Text("""
                        这份配置里没有推断出可编辑的项——通常是因为它整块都是列表或嵌套结构。
                        切到「原始文件」页直接编辑。
                        """)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                    } else {
                        ForEach(schemaFields) { field in
                            if field.isWritable {
                                ThemeConfigFieldView(
                                    field: field,
                                    value: Binding(
                                        get: { pendingValues[field.path.yamlDisplay] ?? field.value ?? "" },
                                        set: { pendingValues[field.path.yamlDisplay] = $0 }
                                    ),
                                    onCommit: { value in
                                        pendingValues[field.path.yamlDisplay] = value
                                        updateConfig(field.path.yamlDisplay, value)
                                    }
                                )
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(.quaternary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .onAppear { inferSchema() }
        // 在「原始文件」页改过内容之后，可视化页要跟着重新推断，
        // 否则字段值和说明都停留在打开窗口那一刻的快照——
// 尤其 choice 类型，旧值不在候选里就会显示成空白（跟之前语言存不进去同一个病根）。
        .onChange(of: configContent) { _, _ in inferSchema() }
    }

    private func inferSchema() {
        let doc = YAMLDocument(text: configContent)
        schemaFields = ConfigSchema.fields(in: doc)
        // 内容整体被外部改过时，暂存值已经不可信了，清掉让它回到磁盘/内存的真实值
        pendingValues = pendingValues.filter { key, _ in
            schemaFields.contains { $0.path.yamlDisplay == key }
        }
    }

    private func updateConfig(_ path: String, _ value: String) {
        let result = YAMLPathEngine.shared.set(path, to: value, in: configContent)
        if case .success(let newContent) = result {
            configContent = newContent
        }
    }
}

struct ThemeConfigFieldView: View {
    let field: ConfigField
    @Binding var value: String
    let onCommit: (String) -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(field.label)
                    .font(.callout)
                Text(field.path.yamlDisplay)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.quaternary)
                Spacer(minLength: 8)
            }

            controlView

            // 「怎么填」文档。和站点配置页、结构化页用同一个组件，
            // 保证同一个键在三个页面上给出的说明完全一致。
            if let doc = field.doc, doc.isEmpty == false {
                ConfigHelpView(doc: doc)
            } else if !field.hint.isEmpty {
                Text(field.hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var controlView: some View {
        switch field.kind {
        case .text, .url, .asset:
            TextField("留空表示不设置", text: $value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .focused($isFocused)
                .onSubmit { onCommit(value) }

        case .color:
            TextField("#RRGGBB", text: $value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .focused($isFocused)
                .onSubmit { onCommit(value) }

        case .boolean:
            Toggle("", isOn: Binding(
                get: { value.lowercased() == "true" },
                set: { onCommit($0 ? "true" : "false") }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

        case .integer:
            TextField("数字", text: $value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .focused($isFocused)
                .onSubmit { onCommit(value) }

        case .multiline:
            TextEditor(text: $value)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 80)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)

        case .choice(let options):
            // 补上当前值，否则自定义枚举值（换主题、改过配置留下的）
            // 会让下拉显示成空白，且无法保存
            Picker("", selection: $value) {
                ForEach(ConfigField.mergedOptions(options, current: value)) { opt in
                    Text(opt.label).tag(opt.value)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320)
            .onChange(of: value) { _, new in
                onCommit(new)
            }

        case .readOnly(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - 主题原始配置编辑器

struct ThemeRawConfigView: View {
    @Binding var content: String
    let onSave: () -> Void

    @State private var draft: String = ""
    @State private var showSaveAlert = false
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("原始文件", systemImage: "doc.text")
                    .font(.headline)
                Text(themeFileNameHint)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    draft = content
                } label: {
                    Label("撤销", systemImage: "arrow.uturn.backward")
                }
                .disabled(!isModified)
                Button {
                    onSave()
                    // 保存成功后 content 已由外部更新，同步草稿，
                    // 否则「保存」按钮会一直亮着，像是还没存上。
                    draft = content
                } label: {
                    Label("保存", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isModified)
                .keyboardShortcut("s", modifiers: .command)
            }

            TextEditor(text: $draft)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.2))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            // 关键：草稿必须先从实际内容初始化。
            // 原实现里 draft 是空串且从不赋值，于是编辑器一打开是**全空**，
            // 同时 isModified（draft != content）为 true、「保存」是亮的——
            // 用户看到空文件很可能直接点保存，就把整个主题配置覆盖成空了。
            guard didLoad == false else { return }
            didLoad = true
            draft = content
        }
    }

    private var themeFileNameHint: String {
        let lines = draft.components(separatedBy: .newlines).count
        return "\(lines) 行"
    }

    private var isModified: Bool {
        draft != content
    }
}

// MARK: - 主题目录行

struct ThemeCatalogRow: View {
    let item: ThemeCatalog.Item
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name.capitalized)
                    .font(.callout.weight(.medium))
                Text(item.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}