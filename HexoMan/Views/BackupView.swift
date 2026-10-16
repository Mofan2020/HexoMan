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

    /// `onChange(of: includeLarge)` 在 SwiftUI macOS 14+ / iOS 17+ 上
    /// **初次 body 评估时会立刻触发一次回调**——即使值没真变。
    /// 配合 `.onAppear` 里也调 `refreshPlan`，刚进 backup 页这一拍
    /// 会有两个 plan Task 互相 cancel。视觉上无大碍，但浪费一次
    /// 全站点遍历，且容易在 cancel 时序上踩到 race。
    /// 用这个标记把首次回调吞掉，仅在「值真的变过」时才刷新。
    @State private var hasObservedIncludeLarge = false

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
            // 标记 includeLarge 已经「观察过」初始值——后续 onChange 才真正刷新。
            // SwiftUI macOS 14+ / iOS 17+ 的 .onChange(of:) 在 view 首次出现时
            // 会立刻回调一次（即使值未变），所以吞掉那次避免与 onAppear 重复扫全站。
            hasObservedIncludeLarge = true
        }
        .onChange(of: model.currentSite?.path) { _, _ in
            loadBackups()
            refreshPlan()
        }
        .onChange(of: includeLarge) { _, _ in
            guard hasObservedIncludeLarge else { return }
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

            Button {
                Task { await createBackup() }
            } label: {
                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("新建备份", systemImage: "plus.circle")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.currentSite == nil || isCreating)
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
    private func refreshPlan() {
        guard let site = model.currentSite else {
            planTask?.cancel()
            plan = nil
            return
        }
        planTask?.cancel()
        planTask = Task { [activePolicy] in
            let result = await BackupManager.plan(for: site, policy: activePolicy)
            if Task.isCancelled { return }
            await MainActor.run {
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