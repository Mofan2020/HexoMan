//
//  DashboardView.swift
//  HexoMan
//
//  站点总览：把「这个站点现在什么状态、接下来该点什么」压缩到一屏里。
//

import SwiftUI

struct DashboardView: View {

    @EnvironmentObject private var model: HexoManModel

    var body: some View {
        // 没有站点就没必要渲染指标，先把人引到站点管理页。
        if model.currentSite == nil {
            VStack(spacing: 14) {
                EmptyHint(
                    systemImage: "gauge.with.dots.needle.33percent",
                    title: "还没有站点",
                    message: "添加一个 Hexo 站点之后，这里会显示它的构建状态、依赖情况和常用操作。"
                )

                Button {
                    model.selection = .sites
                } label: {
                    Label("去添加站点", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    statCards
                    dependenciesNotice
                    details
                    actions
                    recentCommits
                }
                .padding(20)
            }
        }
    }

    // MARK: - 标题区

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.info?.displayName ?? model.currentSite?.folderName ?? "未命名站点")
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Text(model.info?.url ?? "尚未配置站点地址")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 16)

            Button {
                model.refreshAll()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(model.isBusy)
        }
    }

    // MARK: - 指标卡片

    private var statCards: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 140, maximum: 260), spacing: 12)],
            spacing: 12
        ) {
            StatCard(
                title: "文章",
                value: "\(model.posts.count)",
                systemImage: "doc.text",
                caption: model.info?.statusSummary
            )

            StatCard(
                title: "Hexo 版本",
                value: nonEmpty(model.info?.hexoVersion, fallback: "未声明"),
                systemImage: "cube.box",
                caption: model.hexoSource
            )

            StatCard(
                title: "主题",
                value: nonEmpty(model.info?.theme, fallback: "未设置"),
                systemImage: "paintpalette",
                caption: nonEmpty(model.info?.themeVersion, fallback: "无主题版本信息")
            )

            StatCard(
                title: "构建产物",
                value: "\(model.info?.buildFileCount ?? 0) 个文件",
                systemImage: "shippingbox",
                caption: (model.info?.hasBuildOutput ?? false) ? "已有 public 目录" : "还没有 public 目录"
            )

            StatCard(
                title: "依赖",
                value: (model.info?.dependenciesInstalled ?? false) ? "已安装" : "未安装",
                systemImage: (model.info?.dependenciesInstalled ?? false) ? "checkmark.seal" : "exclamationmark.triangle",
                tint: (model.info?.dependenciesInstalled ?? false) ? .green : .orange,
                caption: (model.info?.dependenciesInstalled ?? false) ? "node_modules 就绪" : "需要先 npm install"
            )
        }
    }

    /// 依赖没装是最高频的阻塞点，单独给一条可操作提示，而不是只丢一个橙色数字。
    @ViewBuilder
    private var dependenciesNotice: some View {
        if model.info?.dependenciesInstalled == false {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 6) {
                    Text("站点依赖还没安装")
                        .font(.headline)

                    // 我们不代跑 npm install：一来耗时不可控，二来安装失败需要用户自己能看输出。
                    Text("在站点目录执行 `npm install` 之后，生成和预览才能正常工作。装好后回到这里点「刷新」。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if let site = model.currentSite {
                    Button {
                        NSWorkspaceBridge.openFolder(site.path)
                    } label: {
                        Label("打开站点目录", systemImage: "folder")
                    }
                    .help("打开站点目录，自己去终端跑 npm install")
                }
            }
            .padding(14)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: - 站点详情

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("站点详情", symbol: "info.circle")

            VStack(spacing: 8) {
                DetailRow(label: "站点路径", value: model.currentSite?.path ?? "", monospaced: true)
                Divider()
                DetailRow(label: "Hexo 来源", value: model.hexoSource)
                Divider()
                DetailRow(label: "命令预览", value: model.hexoCommandPreview, monospaced: true)
                Divider()
                DetailRow(
                    label: "Git 仓库",
                    value: (model.info?.isGitRepository ?? false) ? "是" : "否"
                )
                Divider()
                DetailRow(
                    label: "远端",
                    value: nonEmpty(model.info?.gitRemote, fallback: "未配置")
                )
                Divider()
                DetailRow(label: "预览端口", value: "\(model.serverPort)")
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: - 快捷操作

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("快捷操作", symbol: "bolt")

            // 构建类命令会写磁盘、跑几十秒，期间全部禁用，避免连点。
            HStack(spacing: 10) {
                Button {
                    Task { await model.runGenerate() }
                } label: {
                    HStack(spacing: 6) {
                        if model.isBusy {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "hammer")
                        }
                        Text("生成站点")
                    }
                }
                .disabled(model.isBusy)

                Button {
                    Task { await model.runClean() }
                } label: {
                    Label("清理", systemImage: "sparkles")
                }
                .disabled(model.isBusy)

                Button {
                    if model.isServerRunning {
                        model.stopServer()
                    } else {
                        Task { await model.startServer() }
                    }
                } label: {
                    Label(
                        model.isServerRunning ? "停止预览" : "启动预览",
                        systemImage: model.isServerRunning ? "stop.circle" : "play.circle"
                    )
                }

                Button {
                    NSWorkspaceBridge.open(model.previewURL)
                } label: {
                    Label("打开预览页", systemImage: "safari")
                }
                .disabled(!model.isServerRunning)
                .help(model.isServerRunning ? "在浏览器打开预览" : "预览未启动")

                Button {
                    if let site = model.currentSite {
                        NSWorkspaceBridge.openFolder(site.path)
                    }
                } label: {
                    Label("在访达中显示", systemImage: "folder")
                }

                Button {
                    Task { await model.refreshGit() }
                } label: {
                    Label("刷新 Git 状态", systemImage: "arrow.triangle.branch")
                }
                .disabled(model.info?.isGitRepository != true)

                Spacer(minLength: 0)
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: - 最近提交

    /// 精简版，完整提交列表在 Git 页。这里只回答「这个站点最近动过什么」。
    @ViewBuilder
    private var recentCommits: some View {
        if model.commits.isEmpty == false {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    sectionTitle("最近提交", symbol: "clock.arrow.circlepath")

                    if let branch = model.gitStatus?.branch, branch.isEmpty == false {
                        Pill(text: branch, tint: .accentColor)
                    }
                }

                VStack(spacing: 0) {
                    // 用下标判断是否最后一行，省掉一次 prefix 重复计算
                    ForEach(Array(model.commits.prefix(5).enumerated()), id: \.element.id) { index, commit in
                        HStack(spacing: 10) {
                            Text(commit.shortHash)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 68, alignment: .leading)

                            Text(commit.subject)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            Spacer(minLength: 10)

                            if let date = commit.date {
                                Text(date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 7)

                        if index < min(5, model.commits.count) - 1 {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Button {
                    model.selection = .git
                } label: {
                    Label("查看全部 Git 状态", systemImage: "arrow.right")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 辅助

    private func sectionTitle(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.headline)
    }

    /// 空字符串统一显示兜底文案，避免卡片上出现一大片空白。
    private func nonEmpty(_ value: String?, fallback: String) -> String {
        guard let value, value.isEmpty == false else { return fallback }
        return value
    }
}
