//
//  DiagnosticsView.swift
//  HexoMan
//
//  站点健康诊断：一键检查常见问题、配置错误、性能隐患。
//

import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var model: HexoManModel

    @State private var results: [DiagnosticResult] = []
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection

            if results.isEmpty && !isRunning {
                EmptyHint(
                    systemImage: "stethoscope",
                    title: "还没有运行诊断",
                    message: "点击「开始诊断」检查站点的常见问题、配置错误和性能隐患。"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                resultsList
            }
        }
        .padding(20)
        .onAppear {
            if results.isEmpty {
                runDiagnostics()
            }
        }
    }

    private var headerSection: some View {
        HStack {
            Label("站点诊断", systemImage: "stethoscope")
                .font(.title2.weight(.semibold))

            Spacer()

            let errorCount = results.filter { $0.severity == .error }.count
            let warningCount = results.filter { $0.severity == .warning }.count
            let infoCount = results.filter { $0.severity == .info }.count

            HStack(spacing: 12) {
                if errorCount > 0 {
                    Pill(text: "\(errorCount) 错误", tint: .red)
                }
                if warningCount > 0 {
                    Pill(text: "\(warningCount) 警告", tint: .orange)
                }
                if infoCount > 0 {
                    Pill(text: "\(infoCount) 提示", tint: .blue)
                }
            }

            Button {
                runDiagnostics()
            } label: {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("开始诊断", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.currentSite == nil || isRunning)
        }
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if isRunning {
                    ProgressView("正在诊断…")
                        .frame(maxWidth: .infinity)
                        .padding(40)
                } else {
                    ForEach(results) { result in
                        DiagnosticRow(result: result)
                    }
                }
            }
        }
    }

    private func runDiagnostics() {
        guard let site = model.currentSite else { return }
        isRunning = true
        results = []

        Task {
            let siteResults = await runSiteDiagnostics(site: site)
            await MainActor.run {
                self.results = siteResults
                self.isRunning = false
            }
        }
    }

    private func runSiteDiagnostics(site: HexoSite) async -> [DiagnosticResult] {
        var allResults: [DiagnosticResult] = []

        // 1. 配置文件检查
        allResults.append(contentsOf: checkConfigFiles(site: site))

        // 2. 依赖检查
        allResults.append(contentsOf: checkDependencies(site: site))

        // 3. 主题检查
        allResults.append(contentsOf: checkTheme(site: site))

        // 4. 文章/页面检查
        allResults.append(contentsOf: checkContent(site: site))

        // 5. Git 状态检查
        allResults.append(contentsOf: checkGit(site: site))

        // 5. 构建输出检查
        allResults.append(contentsOf: checkBuildOutput(site: site))

        // 6. 性能/大小检查
        allResults.append(contentsOf: checkPerformance(site: site))

        return allResults
    }

    private func checkConfigFiles(site: HexoSite) -> [DiagnosticResult] {
        var results: [DiagnosticResult] = []

        // 主配置
        let mainConfig = site.path + "/_config.yml"
        if !FileManager.default.fileExists(atPath: mainConfig) {
            results.append(DiagnosticResult(
                title: "缺少 _config.yml",
                message: "站点根目录没有找到 _config.yml，Hexo 无法工作。",
                severity: .error,
                category: "配置",
                fixAction: "在站点管理里重新选择正确的站点目录"
            ))
        } else {
            // 检查关键配置
            if let content = try? String(contentsOfFile: mainConfig, encoding: .utf8) {
                if !content.contains("url:") || content.contains("url: ") && !content.contains("url: http") {
                    results.append(DiagnosticResult(
                        title: "site.url 未配置或为空",
                        message: "很多功能（RSS、Sitemap、社交链接）依赖 site.url，建议设置完整的站点地址。",
                        severity: .warning,
                        category: "配置",
                        fixAction: "在配置 → 结构化 里设置 url"
                    ))
                }
            }

            results.append(DiagnosticResult(
                title: "主配置文件存在",
                message: "_config.yml 位于站点根目录。",
                severity: .info,
                category: "配置"
            ))
        }

        // 主题配置
        if let theme = model.info?.theme, !theme.isEmpty {
            let themeConfig = site.path + "/_config.\(theme).yml"
            if FileManager.default.fileExists(atPath: themeConfig) {
                results.append(DiagnosticResult(
                    title: "主题配置文件存在",
                    message: "_config.\(theme).yml 已找到。",
                    severity: .info,
                    category: "配置"
                ))
            } else {
                results.append(DiagnosticResult(
                    title: "缺少主题配置文件",
                    message: "主题 \(theme) 的 _config.\(theme).yml 不存在，主题可能使用默认配置。",
                    severity: .info,
                    category: "配置",
                    fixAction: "在主题页点击「配置」生成配置文件"
                ))
            }
        }

        return results
    }

    private func checkDependencies(site: HexoSite) -> [DiagnosticResult] {
        var results: [DiagnosticResult] = []

        let nodeModules = site.path + "/node_modules"
        let packageJson = site.path + "/package.json"

        if !FileManager.default.fileExists(atPath: nodeModules) {
            results.append(DiagnosticResult(
                title: "依赖未安装",
                message: "node_modules 目录不存在，hexo 命令无法运行。",
                severity: .error,
                category: "依赖",
                fixAction: "在终端执行 npm install，或在总览页点击「安装依赖」"
            ))
        } else {
            results.append(DiagnosticResult(
                title: "依赖已安装",
                message: "node_modules 目录存在。",
                severity: .info,
                category: "依赖"
            ))

            // 检查 package.json 中的 hexo 版本
            if let content = try? String(contentsOfFile: packageJson, encoding: .utf8) {
                if content.contains("\"hexo\"") {
                    results.append(DiagnosticResult(
                        title: "package.json 包含 hexo 依赖",
                        message: "项目正确声明了 hexo 依赖。",
                        severity: .info,
                        category: "依赖"
                    ))
                } else {
                    results.append(DiagnosticResult(
                        title: "package.json 缺少 hexo 依赖",
                        message: "建议在 dependencies 或 devDependencies 中添加 hexo。",
                        severity: .warning,
                        category: "依赖",
                        fixAction: "运行 npm install hexo --save"
                    ))
                }
            }
        }

        return results
    }

    private func checkTheme(site: HexoSite) -> [DiagnosticResult] {
        var results: [DiagnosticResult] = []

        guard let theme = model.info?.theme, !theme.isEmpty else {
            results.append(DiagnosticResult(
                title: "未设置主题",
                message: "_config.yml 中没有设置 theme，将使用默认主题 landscape。",
                severity: .warning,
                category: "主题",
                fixAction: "在配置 → 结构化 里设置 theme，或在主题页安装新主题"
            ))
            return results
        }

        let themeDir = site.path + "/node_modules/hexo-theme-\(theme)"
        let localThemeDir = site.path + "/themes/\(theme)"

        if FileManager.default.fileExists(atPath: themeDir) {
            results.append(DiagnosticResult(
                title: "主题已安装",
                message: "主题 \(theme) 在 node_modules 中找到。",
                severity: .info,
                category: "主题"
            ))
        } else if FileManager.default.fileExists(atPath: localThemeDir) {
            results.append(DiagnosticResult(
                title: "使用本地主题",
                message: "主题 \(theme) 在 themes/ 目录中找到（非 npm 安装）。",
                severity: .info,
                category: "主题"
            ))
        } else {
            results.append(DiagnosticResult(
                title: "主题未安装",
                message: "配置了 theme: \(theme) 但在 node_modules 和 themes/ 都找不到。",
                severity: .error,
                category: "主题",
                fixAction: "在主题页点击「安装主题」安装 hexo-theme-\(theme)"
            ))
        }

        return results
    }

    private func checkContent(site: HexoSite) -> [DiagnosticResult] {
        var results: [DiagnosticResult] = []

        let postsDir = site.path + "/source/_posts"
        let pagesCount = model.pages.filter { $0.layout != "post" }.count
        let postsCount = model.posts.count

        if !FileManager.default.fileExists(atPath: postsDir) {
            results.append(DiagnosticResult(
                title: "source/_posts 目录不存在",
                message: "文章目录缺失，新建文章可能失败。",
                severity: .error,
                category: "内容",
                fixAction: "手动创建 source/_posts 目录"
            ))
        } else {
            results.append(DiagnosticResult(
                title: "文章目录存在",
                message: "source/_posts 目录正常。",
                severity: .info,
                category: "内容"
            ))

            if postsCount == 0 {
                results.append(DiagnosticResult(
                    title: "暂无文章",
                    message: "站点还没有文章，建议创建第一篇。",
                    severity: .info,
                    category: "内容",
                    fixAction: "在文章页点击「新建」"
                ))
            } else {
                results.append(DiagnosticResult(
                    title: "文章数量",
                    message: "共 \(postsCount) 篇文章，\(pagesCount) 个页面。",
                    severity: .info,
                    category: "内容"
                ))

                // 检查草稿
                let drafts = model.posts.filter(\.isDraft).count
                if drafts > 0 {
                    results.append(DiagnosticResult(
                        title: "有草稿文章",
                        message: "共有 \(drafts) 篇草稿，这些文章不会出现在生成的站点中。",
                        severity: .info,
                        category: "内容"
                    ))
                }

                // 检查无标题文章
                let noTitle = model.posts.filter { $0.title.isEmpty }.count
                if noTitle > 0 {
                    results.append(DiagnosticResult(
                        title: "有无标题文章",
                        message: "共有 \(noTitle) 篇文章缺少标题，建议补全。",
                        severity: .warning,
                        category: "内容"
                    ))
                }

                // 检查无标签文章
                let noTags = model.posts.filter { $0.tags.isEmpty }.count
                if noTags > 0 && postsCount > 5 {
                    results.append(DiagnosticResult(
                        title: "部分文章缺少标签",
                        message: "\(noTags) 篇文章没有标签，添加标签有利于分类和 SEO。",
                        severity: .info,
                        category: "内容"
                    ))
                }
            }
        }

        return results
    }

    private func checkGit(site: HexoSite) -> [DiagnosticResult] {
        var results: [DiagnosticResult] = []

        let gitDir = site.path + "/.git"
        if !FileManager.default.fileExists(atPath: gitDir) {
            results.append(DiagnosticResult(
                title: "不是 Git 仓库",
                message: "站点目录未初始化 Git，建议初始化以便版本控制。",
                severity: .info,
                category: "Git",
                fixAction: "在终端执行 git init"
            ))
        } else {
            results.append(DiagnosticResult(
                title: "已初始化 Git 仓库",
                message: ".git 目录存在。",
                severity: .info,
                category: "Git"
            ))

            if model.remotes.isEmpty {
                results.append(DiagnosticResult(
                    title: "未配置远端",
                    message: "Git 仓库没有配置远端，无法 push/pull。",
                    severity: .warning,
                    category: "Git",
                    fixAction: "执行 git remote add origin <url>"
                ))
            } else {
                results.append(DiagnosticResult(
                    title: "已配置远端",
                    message: "Git 远端：\(model.remotes.joined(separator: ", "))",
                    severity: .info,
                    category: "Git"
                ))
            }

            if let status = model.gitStatus {
                let conflicted = status.conflicted
                if !conflicted.isEmpty {
                    results.append(DiagnosticResult(
                        title: "存在 Git 冲突",
                        message: "有 \(conflicted.count) 个文件存在冲突，需要手动解决。",
                        severity: .error,
                        category: "Git"
                    ))
                }
                let ahead = status.ahead
                if ahead > 0 {
                    results.append(DiagnosticResult(
                        title: "有未推送提交",
                        message: "领先远端 \(ahead) 个提交，建议及时推送。",
                        severity: .info,
                        category: "Git"
                    ))
                }
                let behind = status.behind
                if behind > 0 {
                    results.append(DiagnosticResult(
                        title: "落后远端",
                        message: "落后远端 \(behind) 个提交，建议先拉取。",
                        severity: .warning,
                        category: "Git"
                    ))
                }
            }
        }

        return results
    }

    private func checkBuildOutput(site: HexoSite) -> [DiagnosticResult] {
        var results: [DiagnosticResult] = []

        let publicDir = site.path + "/public"
        if !FileManager.default.fileExists(atPath: publicDir) {
            results.append(DiagnosticResult(
                title: "未生成站点",
                message: "public/ 目录不存在，需要先运行 hexo generate。",
                severity: .info,
                category: "构建",
                fixAction: "在构建与预览页点击「生成站点」"
            ))
        } else {
            results.append(DiagnosticResult(
                title: "构建产物存在",
                message: "public/ 目录存在，共 \(model.info?.buildFileCount ?? 0) 个文件。",
                severity: .info,
                category: "构建"
            ))

            // 检查关键文件
            let indexHtml = publicDir + "/index.html"
            if !FileManager.default.fileExists(atPath: indexHtml) {
                results.append(DiagnosticResult(
                    title: "缺少 index.html",
                    message: "public/ 目录下没有 index.html，可能生成不完整。",
                    severity: .warning,
                    category: "构建"
                ))
            }
        }

        return results
    }

    private func checkPerformance(site: HexoSite) -> [DiagnosticResult] {
        var results: [DiagnosticResult] = []

        let sourceDir = site.path + "/source"
        var totalSize: Int64 = 0
        var fileCount = 0

        if let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: sourceDir),
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += Int64(size)
                    fileCount += 1
                }
            }
        }

        if fileCount > 500 {
            results.append(DiagnosticResult(
                title: "源文件较多",
                message: "source/ 目录下有 \(fileCount) 个文件，生成速度可能较慢。",
                severity: .info,
                category: "性能"
            ))
        }

        if totalSize > 50 * 1024 * 1024 { // 50MB
            results.append(DiagnosticResult(
                title: "源文件较大",
                message: "source/ 目录占用 \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))，考虑清理无用文件。",
                severity: .info,
                category: "性能"
            ))
        }

        // 检查 public 目录大小
        let publicDir = site.path + "/public"
        var publicSize: Int64 = 0
        if let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: publicDir),
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    publicSize += Int64(size)
                }
            }
        }

        if publicSize > 100 * 1024 * 1024 { // 100MB
            results.append(DiagnosticResult(
                title: "构建产物较大",
                message: "public/ 目录占用 \(ByteCountFormatter.string(fromByteCount: publicSize, countStyle: .file))，部署可能较慢。",
                severity: .info,
                category: "性能"
            ))
        }

        return results
    }
}

// MARK: - 诊断结果

struct DiagnosticResult: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let severity: Severity
    let category: String
    var fixAction: String?

    enum Severity {
        case error, warning, info

        var color: Color {
            switch self {
            case .error: return .red
            case .warning: return .orange
            case .info: return .blue
            }
        }

        var icon: String {
            switch self {
            case .error: return "xmark.octagon.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .info: return "info.circle.fill"
            }
        }
    }
}

struct DiagnosticRow: View {
    let result: DiagnosticResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: result.severity.icon)
                    .foregroundStyle(result.severity.color)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(result.title)
                            .font(.callout.weight(.medium))
                        Text(result.category)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary.opacity(0.5), in: Capsule())
                    }

                    Text(result.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)
            }

            if let fix = result.fixAction {
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    Text(fix)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 30)
            }
        }
        .padding(12)
        .background(
            result.severity.color.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(result.severity.color.opacity(0.2), lineWidth: 1)
        )
    }
}