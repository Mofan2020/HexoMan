//
//  HexoManModel.swift
//  HexoMan
//
//  应用状态中枢。所有界面只跟这一个对象打交道，不各自去碰文件系统。
//

import Foundation
import SwiftUI

/// 侧边栏入口。
enum SidebarItem: String, CaseIterable, Identifiable {
    case overview
    case posts
    case pages
    case build
    case config
    case theme
    case git
    case backup
    case diagnostics
    case sites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "总览"
        case .posts: return "文章"
        case .pages: return "页面"
        case .build: return "构建与预览"
        case .config: return "配置"
        case .theme: return "主题"
        case .git: return "Git"
        case .backup: return "备份"
        case .diagnostics: return "诊断"
        case .sites: return "站点管理"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .posts: return "doc.text"
        case .pages: return "doc.plaintext"
        case .build: return "hammer"
        case .config: return "gearshape"
        case .theme: return "paintbrush"
        case .git: return "arrow.triangle.branch"
        case .backup: return "externaldrive"
        case .diagnostics: return "stethoscope"
        case .sites: return "folder"
        }
    }
}

/// 一次性提示条。
struct Toast: Identifiable, Equatable {
    enum Kind: Equatable {
        case success
        case failure
        case info
    }

    let id = UUID()
    var text: String
    var kind: Kind = .info
}

/// 全局状态中枢。
@MainActor
final class HexoManModel: ObservableObject {

    // MARK: - 站点

    @Published private(set) var sites: [HexoSite] = []
    @Published private(set) var currentSite: HexoSite?
    @Published private(set) var info: SiteInfo?
    /// 站点目录已消失时置位，界面据此提示。
    @Published private(set) var currentSiteMissing = false

    // MARK: - 内容

    @Published private(set) var posts: [BlogPost] = []
    @Published private(set) var pages: [BlogPage] = []
    @Published private(set) var configFiles: [ConfigFile] = []
    @Published private(set) var gitStatus: GitStatus?
    @Published private(set) var commits: [GitCommit] = []
    @Published private(set) var remotes: [String] = []

    // MARK: - 界面

    @Published var selection: SidebarItem = .overview
    @Published var postSearch = ""
    @Published var postFilter: PostFilter = .all
    @Published var pageSearch = ""
    @Published var pageFilter: PageFilter = .all
    @Published var serverPort: Int = AppSettings.defaultPort
    @Published var toast: Toast?
    @Published var isBusy = false

    /// 命令输出。独立成一个对象，这样日志刷新不会带动整个界面重绘。
    let shell = ShellRunner()

    /// 预览服务句柄，非空表示正在跑。
    @Published private(set) var serverJobID: String?

    private var settings = AppSettings()

    enum PostFilter: String, CaseIterable, Identifiable {
        case all
        case published
        case draft

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "全部"
            case .published: return "已发布"
            case .draft: return "草稿"
            }
        }
    }

    enum PageFilter: String, CaseIterable, Identifiable {
        case all
        case post
        case page
        case draft

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "全部"
            case .post: return "文章"
            case .page: return "页面"
            case .draft: return "草稿"
            }
        }
    }

    // MARK: - 生命周期

    /// 用户手动指定的 hexo 路径。改动立刻落盘，下次启动继续生效。
    @Published var customHexoPath: String = "" {
        didSet {
            guard customHexoPath != oldValue else { return }
            settings.customHexoPath = customHexoPath
            SettingsStore.save(settings)
            // hexo 来源可能因此变了，重新体检一遍
            Task { await refreshToolchain() }
        }
    }

    /// 工具链体检结果。
    @Published private(set) var toolchain: ToolchainInfo?
    @Published private(set) var isInspectingToolchain = false

    /// 是否读取用户自己的 zsh 配置文件来获得真实 PATH。
    ///
    /// 这是「装了 brew node 却说找不到」的解药，改动立刻生效并落盘。
    @Published var usesShellEnvironment: Bool = true {
        didSet {
            guard usesShellEnvironment != oldValue else { return }
            settings.usesShellEnvironment = usesShellEnvironment
            SettingsStore.save(settings)
            shell.usesShellEnvironment = usesShellEnvironment
            shell.invalidateEnvironment()
            Task { await refreshToolchain() }
        }
    }

    /// 手动指定 zsh rc 文件路径。空 = 自动按 $ZDOTDIR → $HOME 找 .zshenv/.zprofile/.zshrc。
    @Published var customRCPath: String = "" {
        didSet {
            guard customRCPath != oldValue else { return }
            settings.customRCPath = customRCPath
            SettingsStore.save(settings)
            shell.customRCPath = customRCPath
            shell.invalidateEnvironment()
            Task { await refreshToolchain() }
        }
    }

    /// rc 文件问题的提示文案，没有问题返回 nil。
    var customRCPathProblem: String? {
        let trimmed = customRCPath.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard FileManager.default.fileExists(atPath: trimmed) else {
            return "找不到这个文件。留空则自动读取 .zshenv / .zprofile / .zshrc。"
        }
        return nil
    }

    /// 实际读到的 rc 文件摘要，给界面显示。
    var resolvedRCSummary: String {
        shell.environment?.rcSummary ?? "尚未读取"
    }

    /// 实际生效的 PATH 摘要。
    var resolvedPathSummary: String {
        shell.environment?.pathSummary ?? "尚未读取"
    }

    init() {
        settings = SettingsStore.load()
        serverPort = settings.serverPort
        customHexoPath = settings.customHexoPath
        sites = settings.sites.sorted { $0.lastOpened > $1.lastOpened }

        // shell 环境相关设置必须先落到 shell 上，之后任何一条命令才对得上 PATH。
        // 直接赋值不走 didSet（避免 init 期间触发体检任务）。
        usesShellEnvironment = settings.usesShellEnvironment
        customRCPath = settings.customRCPath
        shell.usesShellEnvironment = usesShellEnvironment
        shell.customRCPath = customRCPath

        // 恢复上次站点。目录可能已经被删掉或改名，这时候不该崩。
        if let path = settings.lastSitePath, let match = sites.first(where: { $0.path == path }) {
            selectSite(match)
        }

        // 后台先把 shell 环境读出来。用户在界面上点任何按钮时缓存已经就绪，
        // 不用等那 1~2 秒的 rc 加载。
        Task { await shell.prewarmEnvironment() }
    }

    /// 退出前落盘。
    func persist() {
        settings.sites = sites
        settings.lastSitePath = currentSite?.path
        settings.serverPort = serverPort
        SettingsStore.save(settings)
    }

    // MARK: - 站点管理

    /// 加入站点。传入的是站点根目录。
    @discardableResult
    func addSite(at path: String) async -> Bool {
        let site = HexoSite(path: path)

        guard SiteProbe.isHexoSite(site.path) else {
            toast = Toast(text: "这不像一个 Hexo 站点：缺少 hexo 依赖或 _config.yml", kind: .failure)
            return false
        }

        if let index = sites.firstIndex(where: { $0.path == site.path }) {
            sites[index].lastOpened = Date()
        } else {
            sites.append(site)
        }

        sortSites()
        persist()
        selectSite(sites.first { $0.path == site.path } ?? site)
        toast = Toast(text: "已添加站点", kind: .success)
        return true
    }

    /// 从列表移除（不删磁盘上的文件）。
    func removeSite(_ site: HexoSite) {
        sites.removeAll { $0.path == site.path }

        if currentSite?.path == site.path {
            currentSite = nil
            info = nil
            posts = []
            configFiles = []
            gitStatus = nil
            commits = []
        }

        persist()
    }

    /// 切换当前站点并拉取全部数据。
    func selectSite(_ site: HexoSite) {
        currentSite = site
        currentSiteMissing = false

        if let index = sites.firstIndex(where: { $0.path == site.path }) {
            sites[index].lastOpened = Date()
        }
        sortSites()
        persist()

        refreshAll()
    }

    private func sortSites() {
        sites.sort { $0.lastOpened > $1.lastOpened }
    }

    /// 站点目录是否还在。
    var currentSiteExists: Bool {
        guard let currentSite else { return false }
        return FileManager.default.fileExists(atPath: currentSite.configFile)
    }

    /// 拉取当前站点的所有数据。
    func refreshAll() {
        guard let site = currentSite else { return }

        if !currentSiteExists {
            currentSiteMissing = true
            info = nil
            posts = []
            pages = []
            configFiles = []
            return
        }

        currentSiteMissing = false
        info = SiteProbe.inspect(site: site)
        posts = PostStore.load(site: site)
        // Load pages (excluding posts)
        let pageFiles = PageStore.pagesOnly(site: site)
        pages = pageFiles.compactMap { pf in
            let (front, body) = PageStore.load(pf)
            return BlogPage(
                filePath: pf.path,
                front: front,
                body: body,
                modifiedAt: pf.modifiedAt ?? Date(),
                byteSize: pf.size
            )
        }
        configFiles = ConfigStore.list(site: site)
        remotes = GitService.remotes(site: site)

        Task { await refreshGit() }
    }

    // MARK: - 文章

    /// 经过搜索和筛选后的文章列表。
    var filteredPosts: [BlogPost] {
        var result = posts

        switch postFilter {
        case .all: break
        case .published: result = result.filter { !$0.isDraft }
        case .draft: result = result.filter(\.isDraft)
        }

        let keyword = postSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !keyword.isEmpty else { return result }

        return result.filter { post in
            post.title.lowercased().contains(keyword)
                || post.body.lowercased().contains(keyword)
                || post.tags.contains { $0.lowercased().contains(keyword) }
        }
    }

    /// 经过搜索和筛选后的页面列表。
    var filteredPages: [BlogPage] {
        var result = pages

        switch pageFilter {
        case .all: break
        case .post: result = result.filter { $0.layout == "post" }
        case .page: result = result.filter { $0.layout == "page" }
        case .draft: result = result.filter(\.isDraft)
        }

        let keyword = pageSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !keyword.isEmpty else { return result }

        return result.filter { page in
            page.title.lowercased().contains(keyword)
                || page.body.lowercased().contains(keyword)
                || page.tags.contains { $0.lowercased().contains(keyword) }
        }
    }

    /// 新建文章。返回创建出来的文章，编辑器可以拿它直接进编辑态。
    @discardableResult
    func createPost(
        title: String,
        body: String = "",
        tags: [String] = [],
        categories: [String] = [],
        date: Date = Date(),
        isDraft: Bool = false
    ) -> BlogPost? {
        guard let site = currentSite else {
            toast = Toast(text: "请先选择站点", kind: .failure)
            return nil
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            toast = Toast(text: "标题不能为空", kind: .failure)
            return nil
        }

        do {
            let post = try PostStore.create(
                site: site,
                title: trimmed,
                body: body,
                tags: tags,
                categories: categories,
                date: date,
                isDraft: isDraft
            )
            posts = PostStore.load(site: site)
            info = SiteProbe.inspect(site: site)
            toast = Toast(text: "已创建 \(post.filename)", kind: .success)
            selection = .posts
            return post
        } catch {
            toast = Toast(text: "创建失败：\(error.localizedDescription)", kind: .failure)
            return nil
        }
    }

    /// 删除文章，文件进废纸篓。
    func deletePost(_ post: BlogPost) {
        do {
            try PostStore.trash(post)
            posts = PostStore.load(site: currentSite ?? HexoSite(path: ""))
            if let site = currentSite { info = SiteProbe.inspect(site: site) }
            toast = Toast(text: "\(post.filename) 已移到废纸篓", kind: .success)
        } catch {
            toast = Toast(text: "删除失败：\(error.localizedDescription)", kind: .failure)
        }
    }

    /// 发布 / 转草稿。
    func toggleDraft(_ post: BlogPost) {
        do {
            _ = try post.isDraft ? PostStore.unpublish(post) : PostStore.publish(post)
            if let site = currentSite { posts = PostStore.load(site: site) }
            toast = Toast(text: post.isDraft ? "已发布" : "已转为草稿", kind: .success)
        } catch {
            toast = Toast(text: "操作失败：\(error.localizedDescription)", kind: .failure)
        }
    }

    /// 保存编辑器里的改动。
    func savePost(_ post: BlogPost) {
        do {
            try PostStore.save(post)
            if let site = currentSite { posts = PostStore.load(site: site) }
            toast = Toast(text: "已保存", kind: .success)
        } catch {
            toast = Toast(text: "保存失败：\(error.localizedDescription)", kind: .failure)
        }
    }

    // MARK: - 页面

    /// 新建页面。返回创建出来的页面，编辑器可以拿它直接进编辑态。
    @discardableResult
    func createPage(
        title: String,
        body: String = "",
        layout: String = "page",
        permalink: String = "",
        tags: [String] = [],
        categories: [String] = []
    ) -> BlogPage? {
        guard let site = currentSite else {
            toast = Toast(text: "请先选择站点", kind: .failure)
            return nil
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            toast = Toast(text: "标题不能为空", kind: .failure)
            return nil
        }

        do {
            // Build slug from title
            let slug = PageStore.sanitize(trimmed)
            let page = try PageStore.create(
                site: site,
                slug: slug,
                title: trimmed,
                layout: layout,
                extraFrontMatter: [
                    "permalink": permalink.isEmpty ? "" : permalink,
                    "tags": FrontMatter.renderList(tags),
                    "categories": FrontMatter.renderList(categories)
                ]
            )
            // Convert PageFile to BlogPage
            let (front, bodyText) = PageStore.load(page)
            let blogPage = BlogPage(
                filePath: page.path,
                front: front,
                body: bodyText,
                modifiedAt: page.modifiedAt ?? Date(),
                byteSize: page.size
            )
            pages = PageStore.pagesOnly(site: site).compactMap { pf in
                let (front, body) = PageStore.load(pf)
                return BlogPage(
                    filePath: pf.path,
                    front: front,
                    body: body,
                    modifiedAt: pf.modifiedAt ?? Date(),
                    byteSize: pf.size
                )
            }
            toast = Toast(text: "已创建 \((page.path as NSString).lastPathComponent)", kind: .success)
            selection = .pages
            return blogPage
        } catch {
            toast = Toast(text: "创建失败：\(error.localizedDescription)", kind: .failure)
            return nil
        }
    }

    /// 删除页面，文件进废纸篓。
    func deletePage(_ page: BlogPage) {
        // Need to find the PageFile
        guard let site = currentSite else { return }
        let pageFiles = PageStore.scan(site: site)
        guard let pageFile = pageFiles.first(where: { $0.path == page.filePath }) else { return }

        do {
            try PageStore.delete(pageFile)
            pages = PageStore.pagesOnly(site: site).compactMap { pf in
                let (front, body) = PageStore.load(pf)
                return BlogPage(
                    filePath: pf.path,
                    front: front,
                    body: body,
                    modifiedAt: pf.modifiedAt ?? Date(),
                    byteSize: pf.size
                )
            }
            if let site = currentSite { info = SiteProbe.inspect(site: site) }
            toast = Toast(text: "\(page.filename) 已移到废纸篓", kind: .success)
        } catch {
            toast = Toast(text: "删除失败：\(error.localizedDescription)", kind: .failure)
        }
    }

    /// 保存编辑器里的页面改动。
    func savePage(_ page: BlogPage) {
        guard let site = currentSite else { return }
        let pageFiles = PageStore.scan(site: site)
        guard let pageFile = pageFiles.first(where: { $0.path == page.filePath }) else { return }

        do {
            try PageStore.save(pageFile, front: page.front, body: page.body)
            pages = PageStore.pagesOnly(site: site).compactMap { pf in
                let (front, body) = PageStore.load(pf)
                return BlogPage(
                    filePath: pf.path,
                    front: front,
                    body: body,
                    modifiedAt: pf.modifiedAt ?? Date(),
                    byteSize: pf.size
                )
            }
            toast = Toast(text: "已保存", kind: .success)
        } catch {
            toast = Toast(text: "保存失败：\(error.localizedDescription)", kind: .failure)
        }
    }

    /// 保存某个配置文件。
    func saveConfig(_ file: ConfigFile) {
        do {
            try ConfigStore.save(file)
            if let index = configFiles.firstIndex(where: { $0.id == file.id }) {
                configFiles[index] = ConfigStore.markSaved(file)
            }
            if let site = currentSite { info = SiteProbe.inspect(site: site) }
            toast = Toast(text: "已保存 \(file.name)", kind: .success)
        } catch {
            toast = Toast(text: "保存失败：\(error.localizedDescription)", kind: .failure)
        }
    }

    /// 放弃改动。
    func revertConfig(_ file: ConfigFile) {
        if let index = configFiles.firstIndex(where: { $0.id == file.id }) {
            // 必须走 load 而不是直接改 contents —— load 会填上 subtitle，
            // 直接用内存里那份的话放弃改动后左侧副标题会变空。
            configFiles[index] = ConfigStore.load(path: file.path)
        }
    }

    // MARK: - 可视化配置

    /// 站点主配置。找不到时返回 nil，界面上引导用户先建站。
    var mainConfig: ConfigFile? {
        configFiles.first { $0.name == "_config.yml" }
    }

    /// 读出所有常用配置项的当前值。
    func siteSettingValues() -> [String: String] {
        guard let config = mainConfig else { return [:] }
        return SiteSettings.values(in: config.contents)
    }

    /// 某个键在当前站点里是不是多行块。界面上据此决定能不能编辑。
    func isNestedSetting(_ key: String) -> Bool {
        guard let config = mainConfig else { return false }
        return SiteSettings.isNestedBlock(key: key, in: config.contents)
    }

    /// 写一个常用配置项并立即存盘。
    ///
    /// 直接落盘而不是走 draft，理由是这类字段都是「填了就生效」的低风险操作，
    /// 让用户每改一个字都点一次保存反而更容易丢。
    func updateSiteSetting(_ value: String, for key: String) {
        guard let config = mainConfig else {
            toast = Toast(text: "找不到 _config.yml", kind: .failure)
            return
        }

        switch SiteSettings.setValue(value, for: key, in: config.contents) {
        case .failure(let error):
            toast = Toast(text: error.localizedDescription, kind: .failure)
        case .success(let updated):
            var next = config
            next.contents = updated
            saveConfig(ConfigStore.markSaved(next))
        }
    }

    // MARK: - 通用配置更新（供 SchemaConfigView 使用）

    /// 更新任意配置文件的任意 YAML 路径。
    /// - Parameters:
    ///   - filePath: 配置文件的绝对路径
    ///   - yamlPath: YAML 路径，如 `avatar.url` 或 `social[0].name`
    ///   - value: 要写入的值（YAML 片段，如 `true`、`42`、`"text"` 或多行块）
    func updateConfigAt(path filePath: String, yamlPath: String, value: String) {
        guard let index = configFiles.firstIndex(where: { $0.path == filePath }) else {
            showToast("找不到配置文件", kind: .failure)
            return
        }
        var file = configFiles[index]

        let result = YAMLPathEngine.shared.set(yamlPath, to: value, in: file.contents)
        switch result {
        case .success(let newContents):
            file.contents = newContents
            saveConfig(ConfigStore.markSaved(file))
        case .failure(let error):
            showToast("写入失败：\(error.localizedDescription)", kind: .failure)
        }
    }

    /// 读取任意配置文件的任意 YAML 路径的当前值。
    func configValue(at filePath: String, path: String) -> String? {
        guard let file = configFiles.first(where: { $0.path == filePath }) else { return nil }
        return YAMLPathEngine.shared.get(path, in: file.contents)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 自定义内容（banner / 统计 / CSS 放哪）

    /// 站点当前的自定义注入内容。
    var customContent: CustomContent {
        guard let site = currentSite else { return CustomContent() }
        return CustomContentStore.load(site: site)
    }

    /// 自定义注入是否已启用。
    var isCustomContentInstalled: Bool {
        guard let site = currentSite else { return false }
        return CustomContentStore.isInstalled(site: site)
    }

    /// 保存自定义内容，并自动装好注入脚本。
    func saveCustomContent(_ content: CustomContent) {
        guard let site = currentSite else {
            toast = Toast(text: "请先选择站点", kind: .failure)
            return
        }

        do {
            // 内容全空 = 用户清空了，等同于关掉。直接把文件删掉，
            // 留着两个空文件只会让站点里多出看不懂的东西。
            if content.isEmpty {
                try CustomContentStore.remove(site: site)
                toast = Toast(text: "已关闭自定义内容", kind: .info)
            } else {
                try CustomContentStore.save(content, site: site)
                toast = Toast(text: "已保存，重新生成站点后生效", kind: .success)
            }
        } catch {
            toast = Toast(text: "保存失败：\(error.localizedDescription)", kind: .failure)
        }
    }

    /// 关掉自定义内容，删掉注入文件。
    func removeCustomContent() {
        guard let site = currentSite else { return }
        do {
            try CustomContentStore.remove(site: site)
            toast = Toast(text: "已删除注入文件，站点回到未改动状态", kind: .success)
        } catch {
            toast = Toast(text: "删除失败：\(error.localizedDescription)", kind: .failure)
        }
    }

    // MARK: - 构建

    /// 站点用的 hexo 来自哪。
    var hexoSource: String {
        guard let site = currentSite else { return "—" }
        return HexoService.resolveInvocation(site: site, customPath: customHexoPath, runner: shell).source
    }

    /// 实际命令行预览。
    var hexoCommandPreview: String {
        guard let site = currentSite else { return "—" }
        let invocation = HexoService.resolveInvocation(site: site, customPath: customHexoPath, runner: shell)
        return ShellRunner.displayCommand("hexo", invocation.arguments([]))
    }

    func runClean() async {
        guard let site = currentSite else { return }
        let command = HexoService.clean(site: site, customPath: customHexoPath, runner: shell)
        isBusy = true
        let result = await shell.run("hexo clean", executable: command.executable, arguments: command.arguments, workingDirectory: site.path)
        isBusy = false
        if let site = currentSite { info = SiteProbe.inspect(site: site) }
        toast = result.success ? Toast(text: "已清理", kind: .success) : Toast(text: "清理失败，见日志", kind: .failure)
    }

    func runGenerate() async {
        guard let site = currentSite else { return }
        let command = HexoService.generate(site: site, customPath: customHexoPath, runner: shell)
        isBusy = true
        let result = await shell.run("hexo generate", executable: command.executable, arguments: command.arguments, workingDirectory: site.path)
        isBusy = false
        if let site = currentSite { info = SiteProbe.inspect(site: site) }
        if result.success {
            if let site = currentSite { posts = PostStore.load(site: site) }
            toast = Toast(text: "生成完成", kind: .success)
        } else {
            toast = Toast(text: "生成失败，见日志", kind: .failure)
        }
    }

    /// 开启预览。已在跑就先停，避免端口冲突。
    func startServer() async {
        guard let site = currentSite, serverJobID == nil else { return }

        if !(info?.dependenciesInstalled ?? false) {
            toast = Toast(text: "站点依赖未安装，请到「站点管理」点「安装依赖」", kind: .failure)
            return
        }

        // startService 是同步的，所以先把 shell 环境读出来再解析 hexo 路径。
        // 少了这步，缓存未建立时会退回继承环境，brew 装的 hexo 就找不到。
        await shell.prewarmEnvironment()

        let command = HexoService.server(site: site, port: serverPort, customPath: customHexoPath, runner: shell)
        let id = shell.startService(
            label: "hexo server",
            executable: command.executable,
            arguments: command.arguments,
            workingDirectory: site.path
        )

        if id.isEmpty {
            toast = Toast(text: "预览服务启动失败，见日志", kind: .failure)
            return
        }

        serverJobID = id
        toast = Toast(text: "预览已启动：\(HexoService.previewURL(port: serverPort).absoluteString)", kind: .success)
    }

    func stopServer() {
        guard let id = serverJobID else { return }
        shell.stop(jobID: id)
        serverJobID = nil
    }

    var isServerRunning: Bool { serverJobID != nil }

    var previewURL: URL { HexoService.previewURL(port: serverPort) }

    // MARK: - Git

    func refreshGit() async {
        guard let site = currentSite, info?.isGitRepository ?? false else {
            gitStatus = nil
            commits = []
            return
        }

        gitStatus = await GitService.status(site: site, runner: shell)
        commits = await GitService.log(site: site, runner: shell)
    }

    func commit(message: String) async {
        guard let site = currentSite else { return }

        guard !(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else {
            toast = Toast(text: "提交信息不能为空", kind: .failure)
            return
        }

        isBusy = true
        let result = await GitService.commit(site: site, message: message, runner: shell)
        isBusy = false
        await refreshGit()

        if result.success {
            toast = Toast(text: "已提交", kind: .success)
        } else {
            toast = Toast(text: "提交失败：\(result.errorSummary ?? "未知错误")", kind: .failure)
        }
    }

    func push() async {
        guard let site = currentSite else { return }
        isBusy = true
        let result = await GitService.push(site: site, runner: shell)
        isBusy = false
        await refreshGit()

        toast = result.success
            ? Toast(text: "已推送", kind: .success)
            : Toast(text: "推送失败：\(result.errorSummary ?? "未知错误")", kind: .failure)
    }

    func pull() async {
        guard let site = currentSite else { return }
        isBusy = true
        let result = await GitService.pull(site: site, runner: shell)
        isBusy = false
        refreshAll()
        await refreshGit()

        toast = result.success
            ? Toast(text: "已拉取", kind: .success)
            : Toast(text: "拉取失败：\(result.errorSummary ?? "未知错误")", kind: .failure)
    }

    // MARK: - 工具链体检

    /// 探测 node / npm / npx / hexo / git，并在构建页展示诊断结论。
    ///
    /// - Parameter reloadShellEnvironment: 用户刚在终端里装完东西（比如 `brew install node`）时传 true，
    ///   强制丢掉缓存的 PATH 重新读一遍 rc 文件，否则结论会停留在旧环境上。
    func refreshToolchain(reloadShellEnvironment: Bool = false) async {
        guard !isInspectingToolchain else { return }
        isInspectingToolchain = true
        if reloadShellEnvironment {
            shell.invalidateEnvironment()
        }
        toolchain = await HexoEnvironment.inspect(using: shell)
        isInspectingToolchain = false
    }

    /// 自定义路径填了但文件不存在——这是最常见的填错方式，单独提示比让它静默失效好。
    var customHexoPathProblem: String? {
        let trimmed = customHexoPath.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard FileManager.default.isExecutableFile(atPath: trimmed) else {
            return "这个路径不存在或不可执行，HexoMan 会继续用自动探测的结果。"
        }
        return nil
    }

    // MARK: - 提示

    func showToast(_ text: String, kind: Toast.Kind = .info) {
        toast = Toast(text: text, kind: kind)
    }

    func dismissToast() {
        toast = nil
    }

    // MARK: - 新建站点

    /// 创建新站点的完整流程。抽成方法是为了让 wizard 只管收集输入，不碰命令细节。
    ///
    /// - Returns: 成功返回站点根目录；失败返回 nil（此时不会把站点加进列表）。
    func createSite(
        name: String,
        parentDirectory: String,
        template: HexoTemplate,
        installDependencies: Bool
    ) async -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedParent = parentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)

        guard isValidSiteName(trimmedName) else {
            toast = Toast(text: "项目名不能为空，也不能包含 /", kind: .failure)
            return nil
        }
        guard !trimmedParent.isEmpty else {
            toast = Toast(text: "请先选择父目录", kind: .failure)
            return nil
        }
        guard FileManager.default.fileExists(atPath: trimmedParent) else {
            toast = Toast(text: "父目录不存在：\(trimmedParent)", kind: .failure)
            return nil
        }

        let target = (trimmedParent as NSString).appendingPathComponent(trimmedName)
        // 已存在就不要再 init 一次：hexo init 往已有目录里塞文件会污染用户手写的内容。
        guard FileManager.default.fileExists(atPath: target) == false else {
            toast = Toast(text: "\(target) 已存在，换个名字或先删掉它", kind: .failure)
            return nil
        }

        isBusy = true
        defer { isBusy = false }

        // 先确保有一份 hexo-cli。HexoMan 自己不带任何运行时，这一步是拿用户的 npm 装的
        // （或者直接用用户 PATH 里现成的那份）。之前用 `npx --yes hexo-cli`，
        // 那会在创建站点时偷偷从网上下一份到 npm 缓存，慢且不可控。
        let hexo = await HexoCLIBootstrap.ensureHexo(customPath: customHexoPath, runner: shell)
        guard let hexo else {
            toast = Toast(
                text: "创建失败：找不到 hexo-cli，而且没有 npm 可以安装它。请先装 Node.js（brew install node），再重试。",
                kind: .failure
            )
            return nil
        }

        // hexo init 必须在父目录里跑，它自己会生成以项目名命名的子目录。
        let initResult = await shell.run(
            "hexo init \(trimmedName)",
            executable: hexo,
            arguments: template.initArguments(name: trimmedName),
            workingDirectory: trimmedParent
        )

        guard initResult.success else {
            toast = Toast(text: "创建失败：\(initResult.errorSummary ?? "未知错误")", kind: .failure)
            return nil
        }

        // 退出码 0 不代表目录真建出来了（有些环境只吐警告），落一次盘检查再继续。
        guard FileManager.default.fileExists(atPath: target) else {
            toast = Toast(text: "创建失败：没有生成目录 \(target)", kind: .failure)
            return nil
        }

        // 依赖装不上不算创建失败：站点已经在了，只是暂时跑不了 hexo。
        var dependencyFailed = false
        if installDependencies {
            // 站点自带的 package.json 里就有 hexo，装完 hexo 就成了「站点本地依赖」，
            // 之后所有 hexo 命令都走它，不依赖全局安装。--no-audit/--no-fund 纯粹是省时间。
            let dependencyResult = await shell.run(
                "npm install",
                executable: "npm",
                arguments: ["install", "--no-audit", "--no-fund", "--loglevel", "warn"],
                workingDirectory: target
            )
            dependencyFailed = dependencyResult.success == false
        }

        // 只有 init 真的成功才纳入管理，避免留下「已添加但坏掉」的站点。
        let added = await addSite(at: target)
        guard added else {
            toast = Toast(text: "\(target) 已生成，但没有通过 Hexo 站点校验，未加入列表", kind: .failure)
            return nil
        }

        // addSite 自己也弹了 toast，这里补一句真正需要用户知道的事。
        if dependencyFailed {
            toast = Toast(
                text: "站点已创建，但依赖安装失败，可稍后在站点管理里点「安装依赖」重试",
                kind: .info
            )
        }
        return target
    }

    /// 项目名合法性：非空、无路径分隔符、不以点开头（避免 `.` `..` 这类怪路径）。
    private func isValidSiteName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        return name.contains("/") == false
    }

    // MARK: - 依赖

    /// 在当前站点目录跑 `npm install`。返回是否成功。
    ///
    /// clone 下来的 Hexo 站经常没有 node_modules，hexo 命令直接不可用；
    /// 给一个一键修复入口比让用户自己开终端猜命令靠谱。
    func installDependencies() async -> Bool {
        guard let site = currentSite else {
            toast = Toast(text: "请先选择站点", kind: .failure)
            return false
        }
        guard FileManager.default.fileExists(atPath: site.packageFile) else {
            toast = Toast(text: "该目录没有 package.json，不像是 Node 项目", kind: .failure)
            return false
        }

        isBusy = true
        let result = await shell.run(
            "npm install",
            executable: "npm",
            arguments: ["install", "--no-audit", "--no-fund", "--loglevel", "warn"],
            workingDirectory: site.path
        )
        isBusy = false

        // 装完依赖状态和 hexo 来源都会变（本地依赖优先），必须整体重刷。
        refreshAll()

        if result.success {
            toast = Toast(text: "依赖安装完成", kind: .success)
        } else {
            toast = Toast(text: "依赖安装失败：\(result.errorSummary ?? "见日志")", kind: .failure)
        }
        return result.success
    }

    // MARK: - 主题

    /// 给当前站点套上主题：装 `hexo-theme-<name>` 包并改写 `_config.yml` 的 `theme`。
    ///
    /// 单独提供而不是并进 createSite，是为了让「先建站、后挑主题」这种顺序也能用。
    func applyTheme(named rawName: String) async -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard name.isEmpty == false, name.rangeOfCharacter(from: allowed.inverted) == nil else {
            toast = Toast(text: "主题名只能包含字母、数字、- 和 _", kind: .failure)
            return false
        }
        guard let site = currentSite else {
            toast = Toast(text: "请先选择站点", kind: .failure)
            return false
        }

        isBusy = true
        defer { isBusy = false }

        // 先装包再改配置：配置指向一个装不上的主题，站点会直接构建报错。
        let installResult = await shell.run(
            "npm install hexo-theme-\(name)",
            executable: "npm",
            arguments: ["install", "hexo-theme-\(name)", "--no-audit", "--no-fund", "--loglevel", "warn"],
            workingDirectory: site.path
        )
        guard installResult.success else {
            toast = Toast(text: "主题 \(name) 安装失败：\(installResult.errorSummary ?? "见日志")", kind: .failure)
            return false
        }

        do {
            try writeTheme(named: name, into: site.configFile)
        } catch {
            toast = Toast(text: "写入 theme 失败：\(error.localizedDescription)", kind: .failure)
            return false
        }

        refreshAll()
        toast = Toast(text: "已切换到主题 \(name)", kind: .success)
        return true
    }

    /// 只改 `_config.yml` 里的顶层 `theme:` 一行。读不到文件就原样建一个。
    private func writeTheme(named name: String, into path: String) throws {
        let line = "theme: \(name)"

        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            // 配置文件读不到（不存在或编码异常）时，补一个最小配置而不是放弃。
            try line.write(toFile: path, atomically: true, encoding: .utf8)
            return
        }

        var lines = text.components(separatedBy: "\n")
        var replaced = false

        for index in lines.indices {
            let candidate = lines[index]
            guard candidate.hasPrefix("theme:") else { continue }
            lines[index] = line
            replaced = true
            break
        }

        if replaced == false {
            lines.append(line)
        }

        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
