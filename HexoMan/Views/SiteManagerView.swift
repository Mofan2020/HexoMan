//
//  SiteManagerView.swift
//  HexoMan
//
//  添加、切换、移除站点。既是空状态下的引导页，也是侧边栏里的管理页。
//

import SwiftUI

struct SiteManagerView: View {

    @EnvironmentObject private var model: HexoManModel

    /// 手动敲路径用的输入框。
    @State private var pathInput: String = ""
    /// 正在等待确认移除的站点。非空即表示确认框应该弹。
    @State private var pendingRemoval: HexoSite?
    /// 新建站点向导是否打开。
    @State private var showingWizard = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                addSection
                listSection
                footer
            }
            .padding(20)
        }
        .confirmationDialog(
            "移除站点",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if $0 == false { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("移除", role: .destructive) {
                if let site = pendingRemoval {
                    model.removeSite(site)
                }
                pendingRemoval = nil
            }
            Button("取消", role: .cancel) {
                pendingRemoval = nil
            }
        } message: {
            // 明确说清不会删磁盘文件，否则没人敢点。
            Text("只从列表移除，不删除磁盘上的文件。站点目录和 Git 仓库都保持原样。")
        }
        .sheet(isPresented: $showingWizard) {
            NewSiteWizard()
                .environmentObject(model)
        }
    }

    // MARK: - 添加站点

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("添加站点", systemImage: "plus.circle")
                .font(.headline)

            HStack(spacing: 8) {
                Button {
                    showingWizard = true
                } label: {
                    Label("创建新站点…", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("用 hexo init 在本地生成一个新项目")

                Button {
                    guard let url = NSWorkspaceBridge.chooseDirectory(prompt: "选择") else { return }
                    Task { await model.addSite(at: url.path) }
                } label: {
                    Label("选择站点目录…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .help("把已有的 Hexo 项目加进来")
            }

            HStack(spacing: 8) {
                TextField("或直接粘贴站点绝对路径", text: $pathInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .onSubmit(addByPath)

                Button("添加", action: addByPath)
                    .disabled(pathInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // 当前站点缺依赖时给一条直达的修复入口，
            // 免得用户去构建页看到「请在终端执行 npm install」却不知道去哪儿执行。
            if let info = model.info, info.dependenciesInstalled == false {
                HStack(spacing: 8) {
                    Button {
                        Task { _ = await model.installDependencies() }
                    } label: {
                        Label("为当前站点安装依赖", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isBusy)

                    Text("站点目录里还没有 node_modules，装完 hexo 命令才能用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 判定标准必须写清楚，否则用户会反复选错目录。
            Text("判定标准：包含 _config.yml 且 package.json 声明了 hexo 依赖的目录")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func addByPath() {
        let trimmed = pathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        // 成功与否由 addSite 自己弹 toast，这里只负责清输入框。
        Task { await model.addSite(at: trimmed) }
        pathInput = ""
    }

    // MARK: - 站点列表

    @ViewBuilder
    private var listSection: some View {
        if model.sites.isEmpty {
            VStack(spacing: 10) {
                Text("已添加的站点")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                EmptyHint(
                    systemImage: "folder.badge.plus",
                    title: "还没有站点",
                    message: "用上面的「选择站点目录…」挑一个 Hexo 项目目录，添加后就能在这里管理多个站点。"
                )
                .frame(minHeight: 180)
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("已添加的站点")
                    .font(.headline)

                VStack(spacing: 8) {
                    ForEach(model.sites) { site in
                        siteRow(site)
                    }
                }
            }
        }
    }

    private func siteRow(_ site: HexoSite) -> some View {
        let isCurrent = model.currentSite?.path == site.path
        let exists = FileManager.default.fileExists(atPath: site.configFile)
        // 依赖状态直接查盘：只有当前站点才有 model.info，其他站点也要能提示。
        let dependenciesInstalled = isCurrent
            ? (model.info?.dependenciesInstalled ?? FileManager.default.fileExists(atPath: site.nodeModulesBin))
            : FileManager.default.fileExists(atPath: site.nodeModulesBin)

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(displayName(for: site, isCurrent: isCurrent))
                        .font(.callout)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .lineLimit(1)

                    if isCurrent {
                        Pill(text: "当前", tint: .accentColor)
                    }

                    if exists == false {
                        Pill(text: "目录不存在", tint: .orange)
                    } else if dependenciesInstalled == false {
                        Pill(text: "依赖未安装", tint: .orange)
                    }
                }

                Text(site.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)

                Text("上次打开：" + relativeDate(site.lastOpened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                // 光给个「未安装」标签等于让人干看着，所以直接给能修的按钮。
                if exists, dependenciesInstalled == false {
                    Button {
                        // installDependencies 只作用于当前站点，先切过去再装。
                        if isCurrent == false {
                            model.selectSite(site)
                        }
                        Task { _ = await model.installDependencies() }
                    } label: {
                        Label("安装依赖", systemImage: "arrow.down.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.isBusy)
                    .help("在站点目录执行 npm install")
                }

                Button {
                    NSWorkspaceBridge.openFolder(site.path)
                } label: {
                    Image(systemName: "folder")
                }
                .help("在访达中显示")
                .disabled(exists == false)

                Button {
                    pendingRemoval = site
                } label: {
                    Image(systemName: "trash")
                }
                .help(isCurrent ? "当前站点不能直接移除，先切换到别的站点" : "从列表移除")
                .disabled(isCurrent)
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(
            isCurrent ? Color.accentColor.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isCurrent ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.18),
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        // 只有不是当前站点时才需要切换，避免无谓的重复刷新
        .onTapGesture {
            if isCurrent == false {
                model.selectSite(site)
            }
        }
    }

    private var footer: some View {
        Text("站点列表保存在 ~/Library/Application Support/HexoMan/settings.json")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - 辅助

    /// 当前站点用配置里的标题，其他站点还没探测过，只能显示目录名。
    private func displayName(for site: HexoSite, isCurrent: Bool) -> String {
        if isCurrent, let info = model.info {
            return info.displayName
        }
        return site.folderName
    }

    /// 「3 天前」比绝对时间更符合「我多久没打开它」的判断。
    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
