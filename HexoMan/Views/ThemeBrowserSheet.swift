//
//  ThemeBrowserSheet.swift
//  HexoMan
//
//  主题市场：三栏布局（已安装 / 市场 / 详情预览）。
//
//  设计要点：
//  - 左栏：已安装主题列表（来自 ThemeManager.installed）。
//  - 中栏：市场列表（精选 + 联网补全）。无联网权限时只显示精选。
//  - 右栏：详情 + 预览（iframe 嵌入主题官方 demo）+ 一键安装按钮。
//
//  首次打开且未同意联网时，中栏会先弹「网络访问说明」sheet，
//  同意后才允许 ThemeRegistry 调 npm search。
//

import SwiftUI

struct ThemeBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: HexoManModel

    /// 安装/切换后回调。`result.installed == false` 表示没成功装。
    let onComplete: (ThemeInstallResult) -> Void

    @State private var selectedRegistryPackage: RegistryPackage?
    @State private var searchQuery = ""
    @State private var registryResults: [RegistryPackage] = []
    @State private var isLoadingRegistry = false
    @State private var showOnlineConsentSheet = false
    @State private var isInstalling = false
    @State private var installError: String?
    @State private var pendingMigration: ThemeMigrationPlan?

    /// 已安装主题缓存。算属性版本每次 body 重算都扫一遍 `themes/` 目录，
    /// 在三栏 sheet 里会推挤 HSplitView 重排——视觉上就是「上下乱窜」。
    /// 现在缓存成 `@State`，由 onAppear + onChange(currentSite) 驱动刷新。
    @State private var installedThemes: [InstalledTheme] = []

    /// 即时过滤用的搜索任务句柄。新查询进来先 cancel 旧的，
    /// 不然快敲几字符会堆一摞 Task 完成时乱序回写 `registryResults`。
    @State private var searchTask: Task<Void, Never>?

    /// 自动获取焦点的开关。sheet 打开后用户直接敲键盘就能搜，
    /// 不必先点搜索框——之前焦点常被 dismiss 按钮抢走，看起来像「没反应」。
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                installedColumn
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
                registryColumn
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 460)
                detailColumn
                    .frame(minWidth: 360, idealWidth: 460)
            }
        }
        .frame(minWidth: 900, idealWidth: 1000, minHeight: 560, idealHeight: 640)
        .sheet(isPresented: $showOnlineConsentSheet) {
            OnlineConsentSheet(
                isPresented: $showOnlineConsentSheet,
                onAllow: {
                    model.onlineThemeSearch = true
                    showOnlineConsentSheet = false
                    scheduleSearch(immediate: true)
                },
                onDeny: {
                    showOnlineConsentSheet = false
                },
                onDontAskAgain: {
                    model.dontAskOnlineConsent = true
                }
            )
            .environmentObject(model)
        }
        .sheet(item: Binding(
            get: { pendingMigration.map { MigrationSheetItem(plan: $0) } },
            set: { pendingMigration = $0?.plan }
        )) { item in
            ThemeMigrationSheet(
                plan: item.plan,
                isPresented: Binding(
                    get: { pendingMigration != nil },
                    set: { if !$0 { pendingMigration = nil } }
                ),
                onApply: { entries in
                    applyMigration(entries)
                }
            )
            .environmentObject(model)
        }
        .onAppear {
            refreshInstalledThemes()
            // 默认进页面时如果有联网权限就直接加载一次，否则给离线精选。
            if model.onlineThemeSearch {
                scheduleSearch(immediate: true)
            } else {
                registryResults = offlineCatalog(query: "")
            }
            // 让搜索框拿到焦点，否则 macOS sheet 默认焦点在「完成」按钮上。
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: model.currentSite?.path) { _, _ in
            refreshInstalledThemes()
            scheduleSearch(immediate: true)
        }
        .onChange(of: model.info?.theme) { _, _ in
            refreshInstalledThemes()
        }
        // 即时过滤：每次 query 变化重排计划。
        .onChange(of: searchQuery) { _, _ in
            scheduleSearch()
        }
        // 用户切到 / 离开页面时清掉未完成的搜索任务，避免完成时乱序回写。
        .onDisappear {
            searchTask?.cancel()
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "paintpalette.fill")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("themeView.browser.title")
                    .font(.title3.weight(.semibold))
                Text("themeView.browser.subtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !model.onlineThemeSearch {
                Button {
                    if model.dontAskOnlineConsent {
                        // 已经勾「不再询问」，直接打开。
                        model.onlineThemeSearch = true
                        scheduleSearch(immediate: true)
                    } else {
                        showOnlineConsentSheet = true
                    }
                } label: {
                    Label("themeView.browser.allowOnline", systemImage: "wifi")
                }
                .help("联网获取更多主题（仅调 npm registry 读包元数据，不上传任何东西）")
            }
            Button("themeView.browser.done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - 左：已安装

    private var installedColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("themeView.browser.installed", systemImage: "checkmark.circle")
            Divider()
            ScrollView {
                LazyVStack(spacing: 6) {
                    if installedThemes.isEmpty {
                        EmptyHint(
                            systemImage: "tray",
                            title: "themeView.browser.installedEmptyTitle",
                            message: "themeView.browser.installedEmptyMessage"
                        )
                        .padding(.vertical, 24)
                    } else {
                        ForEach(installedThemes) { theme in
                            InstalledThemeRow(
                                theme: theme,
                                isActive: theme.name == model.info?.theme
                            )
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
            }
        }
    }

    // MARK: - 中：市场

    private var registryColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("themeView.browser.market", systemImage: "globe")
            Divider()

            searchField

            if isLoadingRegistry {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("themeView.browser.loading")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            } else {
                List(selection: $selectedRegistryPackage) {
                    ForEach(registryResults) { pkg in
                        RegistryPackageRow(pkg: pkg)
                            .tag(Optional(pkg))
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("themeView.browser.searchPlaceholder", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($searchFocused)
                // 保留回车触发——给键盘用户一个「我准备好搜了」的明确手势。
                .onSubmit { scheduleSearch(immediate: true) }
            if searchQuery.isEmpty == false {
                Button {
                    searchQuery = ""
                    // searchQuery 变化会触发 onChange → scheduleSearch，这里不用再手动。
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - 右：详情预览

    private var detailColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("themeView.browser.preview", systemImage: "eye")
            Divider()
            if let pkg = selectedRegistryPackage {
                ThemeDetailPane(
                    pkg: pkg,
                    isInstalling: isInstalling,
                    installError: installError,
                    onInstall: { Task { await install(pkg) } }
                )
            } else {
                EmptyHint(
                    systemImage: "doc.text.magnifyingglass",
                    title: "themeView.browser.detailEmptyTitle",
                    message: "themeView.browser.detailEmptyMessage"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - 数据

    private func refreshInstalledThemes() {
        guard let site = model.currentSite else {
            installedThemes = []
            return
        }
        installedThemes = ThemeManager.installed(site: site, activeName: model.info?.theme)
    }

    /// 离线精选转 RegistryPackage。search() 内部已经做了，
    /// 这里再拆一份供「未开联网权限」首屏直接显示用——
    /// 不希望首屏被网络请求拖延几百毫秒。
    private func offlineCatalog(query: String) -> [RegistryPackage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ThemeCatalog.items
            .filter { item in
                trimmed.isEmpty
                    || item.name.lowercased().contains(trimmed)
                    || item.summaryDescription.contains(trimmed)
                    || (item.author.isEmpty ? false : item.author.lowercased().contains(trimmed))
            }
            .map { item in
                RegistryPackage(
                    name: "hexo-theme-\(item.name)",
                    version: "",
                    description: item.summaryDescription,
                    author: item.author,
                    homepage: item.homepage,
                    weeklyDownloads: nil,
                    date: nil
                )
            }
    }

    private func sectionHeader(_ key: LocalizedStringKey, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(key)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 节流调度：每敲一字符 250ms 内最多发一次网络请求；
    /// immediate=true 时跳过等待（onSubmit / 重置 query / 切换站点用）。
    /// 旧任务会被 cancel——避免快敲字符时多个 Task 完成时乱序回写结果。
    private func scheduleSearch(immediate: Bool = false) {
        searchTask?.cancel()
        searchTask = Task { [searchQuery, onlineThemeSearch = model.onlineThemeSearch] in
            if !immediate {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
            }
            isLoadingRegistry = true
            let results = await ThemeRegistry.shared.search(
                query: searchQuery,
                settings: model.onlineThemeSearchSettings
            )
            if Task.isCancelled { return }
            await MainActor.run {
                self.registryResults = results
                self.isLoadingRegistry = false
            }
        }
    }

    private func install(_ pkg: RegistryPackage) async {
        isInstalling = true
        installError = nil
        defer { isInstalling = false }
        let result = await model.applyTheme(named: pkg.name)
        if result.installed {
            // 跨主题迁移计划：装完后弹给用户决定要不要搬。
            if let migration = result.migration, migration.hasItems {
                pendingMigration = migration
            }
            // 装完后左栏列表和当前激活主题都会变，主动刷新。
            refreshInstalledThemes()
            onComplete(result)
        } else {
            installError = "安装失败，看日志或重试"
        }
    }

    /// 应用用户勾选的迁移项。
    private func applyMigration(_ entries: [ThemeMigrationEntry]) {
        guard let site = model.currentSite else { return }
        let targetConfig = "_config.\(pendingMigration?.toTheme ?? "").yml"
        let targetPath = (site.path as NSString).appendingPathComponent(targetConfig)
        guard let original = try? String(contentsOf: URL(fileURLWithPath: targetPath), encoding: .utf8) else { return }

        var current = original
        for entry in entries {
            // 复用 ConfigSync.applyToTheme 的逻辑：把站点配置的值写到主题配置。
            if let updated = ConfigSync.applyToTheme(entry.key, value: entry.currentValue, in: current) {
                current = updated
            }
        }

        do {
            try current.write(toFile: targetPath, atomically: true, encoding: .utf8)
            model.refreshAll()
        } catch {
            // 写入失败——只在控制台记录，不弹 modal（迁移 sheet 已经关了）。
            print("[HexoMan] migration write failed: \(error)")
        }
    }
}

// MARK: - 已安装主题行

private struct InstalledThemeRow: View {
    let theme: InstalledTheme
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 1) {
                Text(theme.name)
                    .font(.callout.weight(isActive ? .semibold : .regular))
                Text(theme.packageName)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if isActive {
                Pill(text: "themeRow.inUse", tint: .accentColor)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            isActive ? Color.accentColor.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
    }
}

// MARK: - 市场项行

private struct RegistryPackageRow: View {
    let pkg: RegistryPackage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(pkg.shortName.capitalized)
                    .font(.callout.weight(.medium))
                if pkg.weeklyDownloads != nil {
                    // 联网拿到的才有下载量。离线精选没有。
                    Image(systemName: "globe.americas")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                if let version = pkg.version.isEmpty ? nil : pkg.version {
                    Text(version)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(pkg.description.isEmpty ? "—" : pkg.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 详情预览面板

private struct ThemeDetailPane: View {
    let pkg: RegistryPackage
    let isInstalling: Bool
    let installError: String?
    let onInstall: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                Divider()
                previewSection
                Divider()
                actionSection
                if let err = installError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(20)
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(pkg.shortName.capitalized)
                    .font(.title2.weight(.semibold))
                Pill(
                    text: pkg.name,
                    tint: .secondary
                )
            }
            if let author = pkg.author, author.isEmpty == false {
                Text("themeView.browser.author \(author)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(pkg.description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("themeView.browser.previewSection")
                .font(.headline)
            if let url = previewURL {
                ThemePreviewWebView(url: url)
                    .frame(height: ThemePreviewWebView.preferredHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.2))
                    )
            } else {
                Text("themeView.browser.noPreview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let url = previewURL {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Image(systemName: "safari")
                        Text("themeView.browser.openInBrowser")
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var previewURL: URL? {
        // 主页里如果没有 .demo 子域或者 docs 子域，就用 homepage。
        // 部分主题禁用了 iframe（X-Frame-Options），webview 渲染出来会是空白，
        // 提示用户「在浏览器中打开」是降级方案。
        guard let raw = pkg.homepage, raw.isEmpty == false else { return nil }
        return URL(string: raw)
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onInstall) {
                if isInstalling {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("themeView.browser.installing")
                    }
                } else {
                    Label("themeView.browser.installButton", systemImage: "arrow.down.circle.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isInstalling)

            Text("themeView.browser.installHint")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - 首次联网同意 sheet

private struct OnlineConsentSheet: View {
    @EnvironmentObject private var model: HexoManModel
    @Binding var isPresented: Bool
    let onAllow: () -> Void
    let onDeny: () -> Void
    let onDontAskAgain: () -> Void

    @State private var dontAsk = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "wifi.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("consentSheet.title")
                        .font(.headline)
                    Text("consentSheet.subtitle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("consentSheet.body")
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                bullet("consentSheet.bullet1")
                bullet("consentSheet.bullet2")
                bullet("consentSheet.bullet3")
                bullet("consentSheet.bullet4")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)

            Toggle("consentSheet.dontAskAgain", isOn: $dontAsk)
                .font(.caption)
                .toggleStyle(.checkbox)
                .padding(.top, 4)

            Divider()

            HStack {
                Button("consentSheet.deny") {
                    onDeny()
                }
                Spacer()
                Button("consentSheet.allow") {
                    if dontAsk { onDontAskAgain() }
                    onAllow()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func bullet(_ key: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundStyle(.tertiary)
            Text(key).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 主题迁移 sheet

private struct ThemeMigrationSheet: View {
    @EnvironmentObject private var model: HexoManModel
    let plan: ThemeMigrationPlan
    @Binding var isPresented: Bool
    let onApply: ([ThemeMigrationEntry]) -> Void

    @State private var selectedKeys: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("migrationSheet.title")
                    .font(.headline)
                Text("migrationSheet.subtitle \(plan.fromTheme) \(plan.toTheme)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            List(selection: $selectedKeys) {
                ForEach(plan.entries) { entry in
                    MigrationRow(entry: entry)
                        .tag(Optional(entry.key))
                }
            }
            .frame(minHeight: 200, idealHeight: 280, maxHeight: 360)

            Text("migrationSheet.note")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack {
                Button("migrationSheet.skip") {
                    isPresented = false
                }
                Spacer()
                Button("migrationSheet.apply") {
                    let chosen = plan.entries.filter { selectedKeys.contains($0.key) }
                    onApply(chosen)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedKeys.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            // 默认全选——绝大多数用户想把这些值搬过去。
            selectedKeys = Set(plan.entries.map(\.key))
        }
    }
}

private struct MigrationRow: View {
    let entry: ThemeMigrationEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.label)
                    .font(.callout.weight(.medium))
                Text(entry.key)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.quaternary)
            }
            Text(entry.currentValue)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .padding(.vertical, 3)
    }
}

/// Sheet(item:) 需要的包装。Identifiable 是 Sheet(item:) 的硬性要求。
private struct MigrationSheetItem: Identifiable {
    var plan: ThemeMigrationPlan
    var id: String { "\(plan.fromTheme)→\(plan.toTheme)" }
}