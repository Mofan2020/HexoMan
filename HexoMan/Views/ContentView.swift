//
//  ContentView.swift
//  HexoMan
//
//  主框架：左侧功能栏 + 右侧内容区，外加站点切换器和提示条。
//

import SwiftUI

struct ContentView: View {

    @EnvironmentObject private var model: HexoManModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        } detail: {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .topTrailing) {
            if let toast = model.toast {
                ToastView(toast: toast) { model.dismissToast() }
                    .padding(.trailing, 20)
                    .padding(.top, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.28), value: model.toast)
        .onChange(of: scenePhase) { _, phase in
            // 退到后台或关窗口时把设置落盘
            if phase != .active { model.persist() }
        }
    }

    // MARK: - 侧边栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            siteSwitcher

            Divider()

            navigationList

            Divider()
            statusFooter
        }
    }

    /// 导航项。
    ///
    /// 这里刻意用**显式按钮**而不是 `List(selection:)`。
    /// macOS 上单选 List 传非 Optional 绑定时行点击经常不生效，
    /// 而按钮的动作是显式的——点了就一定赋值，不依赖任何隐式选中机制。
    private var navigationList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(SidebarItem.allCases) { item in
                    SidebarButton(
                        title: item.title,
                        systemImage: item.symbolName,
                        badge: badge(for: item),
                        isActive: model.selection == item
                    ) {
                        model.selection = item
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 站点切换下拉。没站点时给一个「添加」按钮。
    private var siteSwitcher: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("当前站点")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            if model.sites.isEmpty {
                Button {
                    model.selection = .sites
                } label: {
                    Label("添加站点…", systemImage: "plus.circle")
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .controlSize(.large)
            } else {
                Picker("当前站点", selection: siteBinding) {
                    ForEach(model.sites) { site in
                        Text(displayName(for: site)).tag(site.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// 侧边栏底部的状态条：当前页面 + 预览是否在跑 + hexo 来源。
    ///
    /// 把当前页面名放出来是刻意的：侧边栏点击如果又出问题，
    /// 这一行会立刻暴露「点击到底有没有生效」，不用再靠猜。
    private var statusFooter: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.isServerRunning ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)

                Text(model.selection.title)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                Spacer(minLength: 4)

                if model.isServerRunning {
                    Text("预览中")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }

            Text("hexo：\(model.hexoSource)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - 内容区

    /// 内容区永远按 `model.selection` 分发。
    ///
    /// 早先的写法是「没有站点就直接返回 SiteManagerView」，把 switch 整个短路掉了——
    /// 结果全新安装（一个站点都没有）时，点侧边栏任何一项都没有反应。
    /// 现在改成：先按选中项分发，再由 `siteRequired` 在缺站点时给出可操作的引导。
    @ViewBuilder
    private var content: some View {
        switch model.selection {
        case .sites:
            SiteManagerView()
        case .overview:
            siteRequired { DashboardView() }
        case .posts:
            siteRequired { PostsView() }
        case .build:
            siteRequired { BuildView() }
        case .config:
            siteRequired { ConfigView() }
        case .git:
            siteRequired { GitView() }
        }
    }

    /// 包裹需要站点的页面。没有站点或站点目录已丢失时，给一个能直接去添加站点的提示。
    @ViewBuilder
    private func siteRequired<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if model.currentSite == nil {
            EmptyHint(
                systemImage: "folder.badge.plus",
                title: "先添加一个站点",
                message: "HexoMan 需要一个 Hexo 站点才能工作。到「站点管理」里选一个站点目录，或者直接新建一个。"
            )
            .overlay(alignment: .bottom) {
                Button("去添加站点") {
                    model.selection = .sites
                }
                .controlSize(.large)
                .padding(.bottom, 60)
            }
        } else if model.currentSiteMissing {
            missingSite
        } else {
            content()
        }
    }

    private var missingSite: some View {
        EmptyHint(
            systemImage: "questionmark.folder",
            title: "站点目录找不到了",
            message: "目录 \(model.currentSite?.path ?? "") 已不存在，可能被移动或删除。可以到站点管理里移除它，或者重新添加。"
        )
        .overlay(alignment: .bottom) {
            HStack(spacing: 12) {
                Button("去站点管理") {
                    model.selection = .sites
                }
                .controlSize(.large)

                if let site = model.currentSite {
                    Button("从列表移除") {
                        model.removeSite(site)
                    }
                    .controlSize(.large)
                }
            }
            .padding(.bottom, 60)
        }
    }

    // MARK: - 辅助

    /// 只有当前站点才显示自己的名字，其余显示目录名。
    private func displayName(for site: HexoSite) -> String {
        if model.currentSite?.path == site.path, let info = model.info {
            return info.displayName
        }
        return site.folderName
    }

    /// 侧边栏条目右侧的小角标。
    private func badge(for item: SidebarItem) -> Int {
        switch item {
        case .posts: return model.filteredPosts.count
        case .sites: return model.sites.count
        default: return 0
        }
    }

    /// Picker 要绑到 site.id（Hashable 且唯一），不能直接绑整个 HexoSite。
    private var siteBinding: Binding<String> {
        Binding(
            get: { model.currentSite?.id ?? "" },
            set: { newValue in
                if let site = model.sites.first(where: { $0.id == newValue }) {
                    model.selectSite(site)
                }
            }
        )
    }
}
