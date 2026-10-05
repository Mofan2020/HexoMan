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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection

            if backups.isEmpty && !isLoading {
                EmptyHint(
                    systemImage: "externaldrive.badge.plus",
                    title: "还没有备份",
                    message: "点击右上角「新建备份」创建第一个备份。备份包含 source/、配置文件、package.json 等核心文件，不包含 node_modules/ 和 public/ 等可重建目录。"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                backupList
            }
        }
        .padding(20)
        .onAppear(perform: loadBackups)
        .alert("操作失败", isPresented: Binding(
            get: { showError != nil },
            set: { if !$0 { showError = nil } }
        )) {
            Button("确定", role: .cancel) { showError = nil }
        } message: {
            Text(showError ?? "")
        }
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
                if isLoading {
                    ProgressView("加载备份列表…")
                        .frame(maxWidth: .infinity)
                        .padding(40)
                } else {
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
    }

    private func loadBackups() {
        guard let site = model.currentSite else { return }
        isLoading = true
        backups = BackupManager.listBackups(for: site.path)
        isLoading = false
    }

    private func createBackup() async {
        guard let site = model.currentSite else { return }
        isCreating = true
        do {
            let entry = try await BackupManager.createBackup(for: site)
            backups.insert(entry, at: 0)
            model.toast = Toast(text: "备份已创建", kind: .success)
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