//
//  BackupView.swift
//  HexoMan
//
//  站点备份与恢复界面。
//

import SwiftUI

struct BackupView: View {
    @EnvironmentObject private var model: HexoManModel

    @State private var backups: [BackupManager.BackupEntry] = []
    @State private var isLoading = false
    @State private var isCreating = false
    @State private var showError: String?

    /// 备份范围的预检结果。用户点按钮前就能看到「会打包多少、会跳过什么」，
    /// 而不是对着一个转圈等它慢慢把 node_modules 走一遍。
    @State private var plan: BackupManager.Plan?

    /// 是否包含 .git / public 这类体积大但可重建的内容。
    @State private var includeLarge = false

    /// 当前正在跑的 plan 任务句柄。
    /// 旧任务完成时如果已经被 cancel，直接丢回结果——避免
    /// 切站点 / 反复拨 includeLarge 时多个 Task 堆在一起乱序回写，
    /// 看着就是页面上一阵乱跳、按钮按了没反应。
    @State private var planTask: Task<Void, Never>?

    /// 本次统计针对的是哪个站点。用来识别「换了站点但旧统计的
    /// MainActor 回写才姗姗来迟」——那种情况会把新站点的统计覆盖成旧站点的。
    @State private var planSitePath: String?

    /// includeLarge 的**上一次参与统计的值**。
    ///
    /// 之前是用 `hasObservedIncludeLarge` 布尔量来吞掉 `.onChange(of:)` 的首调，
    /// 那个思路是错的：SwiftUI 在 macOS 14+/iOS 17+ 上会在**首次 body 评估期间**
    /// 就触发一次 `onChange` 回调，那时 `.onAppear` 还没跑，
    /// `hasObservedIncludeLarge` 仍是 false，于是唯一一次真实需要的首刷被丢掉了——
    /// 于是备份页一进来「将打包 N 个文件」永远是「正在统计…」，
    /// 看起来就是这个页面没法用。
    ///
    /// 改成记住「上次统计用的值」，首调时若值没真的变过就不重扫。
    /// 不依赖 onAppear / onChange 的相对时序，也就不会再被回调顺序坑到。
    @State private var lastPlannedIncludeLarge: Bool?

    private var activePolicy: BackupManager.Policy {
        includeLarge ? .full : .default
    }

    var body: some View {
        // 上半部放头部 + 备份范围说明，下半部放「列表或空状态」。
        // 早先把它们平铺到同一个 VStack，让 EmptyHint 的 `.frame(maxHeight: .infinity)`
        // 把整个高度抢走，导致首次进入时「站点备份」标题与「新建备份」按钮被挤出可见区。
        // 这里拆成两块：标题+按钮永远在顶部，下面这块独立决定要不要显示空状态。
        VStack(alignment: .leading, spacing: 16) {
            headerSection
            planSection

            Group {
                if isLoading {
                    ProgressView("加载备份列表…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if backups.isEmpty {
                    EmptyHint(
                        systemImage: "externaldrive.badge.plus",
                        title: "还没有备份",
                        message: "点击右上角「新建备份」创建第一个备份。备份包含 source/、配置文件、package.json 等核心文件；node_modules/、public/、.git/ 这些能重新生成的内容默认不打包。"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    backupList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .onAppear {
            loadBackups()
            refreshPlan()
        }
        .onChange(of: model.currentSite?.path) { _, _ in
            loadBackups()
            refreshPlan()
        }
        .onChange(of: includeLarge) { _, _ in
            refreshPlan()
        }
        // 离场时把进行中的统计任务 cancel，避免完成时回写到已经被切走的页面。
        .onDisappear {
            planTask?.cancel()
        }
        .alert("操作失败", isPresented: Binding(
            get: { showError != nil },
            set: { if !$0 { showError = nil } }
        )) {
            Button("确定", role: .cancel) { showError = nil }
        } message: {
            Text(showError ?? "")
        }
    }

    /// 备份范围说明 + 范围切换。
    private var planSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label("备份范围", systemImage: "checklist")
                    .font(.callout.weight(.medium))

                if let plan {
                    Text("将打包 \(plan.includedCount) 个文件 · 约 \(plan.includedDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if plan.excludedCount > 0 {
                        Text("跳过 \(plan.excludedCount) 项")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                } else {
                    Text("正在统计…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)

                Toggle(isOn: $includeLarge) {
                    Text("包含 .git / public 等大目录")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
                .help("默认不打包。这些目录通常几十上百 MB，而且能通过 git clone 和 hexo generate 重新得到。勾上后备份会明显变慢、变大。")
            }

            Text("""
            默认包含：source/ 文章与页面、_config*.yml 配置、package.json、主题与模板、脚本。
            默认排除：node_modules/（依赖，npm i 可重建）、public/（生成产物）、.git/（版本历史）、\
            .wrangler/、*.log、.DS_Store。
            """)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var headerSection: some View {
        HStack {
            Label("站点备份", systemImage: "externaldrive")
                .font(.title2.weight(.semibold))

            Spacer()

            if let site = model.currentSite {
                Text(site.folderName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.3), in: Capsule())
            }

            // 把按钮 label 内的 `if isCreating` 提到外面来——否则 Button 在两种状态下
            // 会是 ProgressView vs Label 两种 view 类型。SwiftUI macOS 14+ / iOS 17+
            // 对 Button label 的 view 类型稳定性比旧版本严格，类型一变会让整棵子树
            // 渲染失败，外观表现就是「站点备份」标题和按钮一起消失，下面只剩
            // Group 里的 EmptyHint。
            //
            // 旧版本（Xcode 15 / macOS 13）SwiftUI 偷懒不强检，这种写法看着没事；
            // 升 Xcode 26/27 之后就裸奔了。整个 BackupView「菜单栏 UI 消失 /
            // 开始备份按钮没有出现 / 操作无反应」症状的真实根因就是这里。
            //
            // 改法：在外部根据 isCreating 选 ProgressView vs Button 本身，
            // Button label 内部永远只有一个 Label 类型——稳定。
            if isCreating {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    Task { await createBackup() }
                } label: {
                    Label("新建备份", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                // 备份进行中禁用：这一分支已经换成 ProgressView 了，
                // 但留一道保险——万一 isCreating 在同一帧内被两次点击穿过，
                // 第二个 createBackup 会并发写同一个 zip 文件。
                .disabled(model.currentSite == nil || isCreating)
            }
        }
    }

    private var backupList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(backups) { backup in
                    BackupRow(
                        backup: backup,
                        onRestore: { restoreBackup(backup) },
                        onDelete: { deleteBackup(backup) }
                    )
                }
            }
        }
    }

    /// 列出当前站点的备份。同步读 `~/Library/Application Support/HexoMan/Backups/`，
    /// 数据量通常是几个到几十个 zip，自身不慢；但 BackupView.onAppear 在主线程上调用，
    /// 把这一次磁盘列举也挪到后台更稳，避免站点路径含 symlink 时 stat 一卡整个
    /// view 树渲染被拖住。
    private func loadBackups() {
        guard let site = model.currentSite else { return }
        let sitePath = site.path
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let entries = BackupManager.listBackups(for: sitePath)
            await MainActor.run {
                // 站点切走后结果直接丢，避免 UI 闪一下旧站点的备份。
                guard self.model.currentSite?.path == sitePath else {
                    self.isLoading = false
                    return
                }
                self.backups = entries
                self.isLoading = false
            }
        }
    }

    /// 重新统计将要打包的范围。站点或开关变化时都跑一次。
    ///
    /// 旧任务会被 cancel——避免切站点时多个统计任务堆在一起完成后乱序
    /// 回写 `plan`，那会让 UI 短暂显示一个过时的统计数字，
    /// 甚至在「包含大目录」开关快速来回拨时被卡住。
    ///
    /// 「同样的站点 + 同样的开关」重复调用是**空操作**。这一条很关键：
    /// onAppear 和 onChange(of: includeLarge) 的首调都可能要求刷新，
    /// 不做幂等就会 cancel 掉刚起步的任务、再起一个，
    /// 于是 `plan` 迟迟不落地，界面停在「正在统计…」。
    private func refreshPlan() {
        guard let site = model.currentSite else {
            planTask?.cancel()
            plan = nil
            planSitePath = nil
            lastPlannedIncludeLarge = nil
            return
        }

        // 幂等：同一站点 + 同一策略，且统计任务还活着，就什么都不做。
        // （任务已结束且有结果时也不必重扫；`plan != nil` 覆盖了这种情况。）
        if planSitePath == site.path,
           lastPlannedIncludeLarge == includeLarge,
           plan != nil || (planTask?.isCancelled == false)
        {
            return
        }

        planTask?.cancel()
        planSitePath = site.path
        lastPlannedIncludeLarge = includeLarge
        // 新统计开始前先清掉旧结果，界面立刻回到「正在统计…」，
        // 不会拿上一个站点的数字冒充当前站点的。
        plan = nil

        let policy = activePolicy
        let sitePath = site.path
        planTask = Task {
            let result = await BackupManager.plan(for: site, policy: policy)
            if Task.isCancelled { return }
            await MainActor.run {
                // 双重保险：既看 cancel，也看当前站点 / 当前策略是不是还是这一份。
                // 光看 cancel 挡不住「旧任务刚好在 cancel 生效前完成」的窄缝。
                guard self.model.currentSite?.path == sitePath,
                      self.lastPlannedIncludeLarge == self.includeLarge
                else { return }
                self.plan = result
            }
        }
    }

    private func createBackup() async {
        guard let site = model.currentSite else { return }
        isCreating = true
        do {
            let entry = try await BackupManager.createBackup(for: site, policy: activePolicy)
            backups.insert(entry, at: 0)
            model.toast = Toast(
                text: "备份已创建：\(entry.fileCount) 个文件 · \(entry.formattedSize)",
                kind: .success
            )
            refreshPlan()
        } catch {
            showError = error.localizedDescription
        }
        isCreating = false
    }

    private func restoreBackup(_ backup: BackupManager.BackupEntry) {
        guard let site = model.currentSite else { return }
        Task {
            do {
                try await BackupManager.restoreBackup(backup, to: site.path)
                await model.refreshAll()
                model.toast = Toast(text: "已从 \(backup.displayName) 恢复", kind: .success)
            } catch {
                showError = error.localizedDescription
            }
        }
    }

    private func deleteBackup(_ backup: BackupManager.BackupEntry) {
        do {
            try BackupManager.deleteBackup(backup)
            backups.removeAll { $0.id == backup.id }
            model.toast = Toast(text: "已删除备份", kind: .success)
        } catch {
            showError = error.localizedDescription
        }
    }
}

// MARK: - 备份行

struct BackupRow: View {
    let backup: BackupManager.BackupEntry
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(backup.displayName)
                    .font(.callout.weight(.medium))

                Text("\(backup.formattedSize) · \(backup.fileCount) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Button("恢复", action: onRestore)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("删除这个备份")
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }
}