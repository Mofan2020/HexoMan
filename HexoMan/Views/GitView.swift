//
//  GitView.swift
//  HexoMan
//
//  Git 集成：看状态、管改动、提交推送，外加提交历史和 git 命令的真实输出。
//

import AppKit
import SwiftUI

struct GitView: View {

    @EnvironmentObject private var model: HexoManModel

    @State private var commitMessage = ""
    /// 「git init」提示里要不要顺手把操作复制到剪贴板。
    @State private var didCopyInitCommand = false

    var body: some View {
        if model.info?.isGitRepository != true {
            notARepository
        } else {
            VSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        branchCard
                        conflictsNotice
                        changesSection
                        remotesSection
                        actionsSection
                    }
                    .padding(20)
                }
                .frame(minHeight: 260, idealHeight: 340)

                // 下半部：上面是提交历史，下面是 git 命令的真实输出。
                VStack(spacing: 0) {
                    commitList
                    Divider()
                    LogConsole(runner: model.shell)
                        .frame(minHeight: 160, maxHeight: .infinity)
                }
                .frame(minHeight: 200, maxHeight: .infinity)
            }
        }
    }

    // MARK: - 非仓库

    private var notARepository: some View {
        VStack(spacing: 16) {
            EmptyHint(
                systemImage: "arrow.triangle.branch",
                title: "这个站点不是 git 仓库",
                message: "站点目录下没有 .git。想用版本管理的话，在终端里进入站点目录执行 git init，再添加一个远端就能在这里提交和推送了。"
            )

            VStack(spacing: 10) {
                Text(ShellRunner.displayCommand("git", ["init"]))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                HStack(spacing: 10) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("git init", forType: .string)
                        didCopyInitCommand = true
                    } label: {
                        Label(
                            didCopyInitCommand ? "已复制" : "复制命令",
                            systemImage: didCopyInitCommand ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .help("复制到剪贴板，自己去终端里跑")

                    if let site = model.currentSite {
                        Button {
                            NSWorkspaceBridge.openFolder(site.path)
                        } label: {
                            Label("在访达中显示", systemImage: "folder")
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
            }
        }
    }

    // MARK: - 分支状态

    private var branchCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("仓库状态", systemImage: "arrow.triangle.branch")
                    .font(.headline)

                Spacer(minLength: 8)

                Button {
                    Task { await model.refreshGit() }
                } label: {
                    HStack(spacing: 6) {
                        if model.isBusy {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("刷新")
                    }
                }
                .disabled(model.isBusy)
            }

            HStack(spacing: 8) {
                if let branch = model.gitStatus?.branch, branch.isEmpty == false {
                    Pill(text: branch, tint: .accentColor)
                }

                if let ahead = model.gitStatus?.ahead, ahead > 0 {
                    Pill(text: "领先 \(ahead)", tint: .green)
                }

                if let behind = model.gitStatus?.behind, behind > 0 {
                    Pill(text: "落后 \(behind)", tint: .orange)
                }

                if let upstream = model.gitStatus?.upstream, upstream.isEmpty == false {
                    Text(upstream)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Pill(text: "未设置上游", tint: .secondary)
                }

                Spacer(minLength: 0)
            }

            Text(model.gitStatus?.summary ?? "还没读到状态，点「刷新」")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("最近提交 \(model.commits.count) 条")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// 冲突必须显式摆在最前面，不然很容易被漏掉然后提交出一堆坏内容。
    @ViewBuilder
    private var conflictsNotice: some View {
        if let conflicted = model.gitStatus?.conflicted, conflicted.isEmpty == false {
            VStack(alignment: .leading, spacing: 8) {
                Label("有 \(conflicted.count) 个文件存在冲突", systemImage: "exclamationmark.octagon.fill")
                    .font(.headline)
                    .foregroundStyle(.red)

                Text("需要手动解决冲突后再提交，否则 git 会拒绝这次提交。")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ForEach(conflicted, id: \.self) { path in
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.octagon")
                            .font(.caption2)
                            .foregroundStyle(.red)
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: - 变更文件

    private var changesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("变更文件", systemImage: "list.bullet.rectangle")
                    .font(.headline)

                if let count = model.gitStatus?.changeCount, count > 0 {
                    Pill(text: "\(count) 个", tint: .accentColor)
                }

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 10) {
                changeGroup(title: "已暂存", symbol: "checkmark.circle", tint: .green, paths: model.gitStatus?.staged ?? [])
                Divider()
                changeGroup(title: "已修改", symbol: "pencil.circle", tint: .orange, paths: model.gitStatus?.modified ?? [])
                Divider()
                changeGroup(title: "未跟踪", symbol: "questionmark.circle", tint: .blue, paths: model.gitStatus?.untracked ?? [])
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func changeGroup(title: String, symbol: String, tint: Color, paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline)
                Text("\(paths.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }

            if paths.isEmpty {
                Text("（空）")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(paths, id: \.self) { path in
                    // 点击定位到站点目录，用户自己去 Finder 里找具体文件。
                    Button {
                        if let site = model.currentSite {
                            NSWorkspaceBridge.openFolder(site.path)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(path)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 6)
                            Image(systemName: "folder")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .help("在访达中打开站点目录")
                }
            }
        }
    }

    // MARK: - 远端

    private var remotesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("远端", systemImage: "network")
                .font(.headline)

            if model.remotes.isEmpty {
                Text("未配置远端。git push / pull 会失败，需要先 git remote add origin <地址>。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 8) {
                    ForEach(model.remotes, id: \.self) { remote in
                        DetailRow(label: remoteLabel(remote), value: remoteURL(remote), monospaced: true)
                        if remote != model.remotes.last {
                            Divider()
                        }
                    }
                }
                .padding(14)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    // MARK: - 操作

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("操作", systemImage: "bolt")
                .font(.headline)

            HStack(spacing: 8) {
                TextField("提交信息", text: $commitMessage)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .onSubmit(performCommit)

                Button {
                    performCommit()
                } label: {
                    busyLabel("提交全部改动", symbol: "checkmark.seal")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || trimmedMessage.isEmpty)
                .help("git add -A 后提交全部改动，包括未跟踪文件")
            }

            HStack(spacing: 10) {
                Button {
                    Task { await model.pull() }
                } label: {
                    busyLabel("拉取", symbol: "arrow.down.circle")
                }
                .disabled(model.isBusy)
                .help("git pull --rebase")

                Button {
                    Task { await model.push() }
                } label: {
                    busyLabel("推送", symbol: "arrow.up.circle")
                }
                .disabled(model.isBusy || (model.gitStatus?.ahead ?? 0) == 0)
                .help((model.gitStatus?.ahead ?? 0) == 0 ? "没有待推送的提交" : "git push")

                Button {
                    Task { await model.refreshGit() }
                } label: {
                    busyLabel("刷新", symbol: "arrow.clockwise")
                }
                .disabled(model.isBusy)

                Spacer(minLength: 0)

                if let site = model.currentSite {
                    Button {
                        NSWorkspaceBridge.openFolder(site.path)
                    } label: {
                        Label("在访达中显示", systemImage: "folder")
                    }
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 提交记录

    /// 提交记录和日志并排放：上半部看历史，下半部看 git 命令的真实输出。
    private var commitList: some View {
        Group {
            if model.commits.isEmpty {
                Text("还没有提交记录")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.commits) { commit in
                            HStack(spacing: 10) {
                                Text(commit.shortHash)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(width: 72, alignment: .leading)

                                Text(commit.subject)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                Spacer(minLength: 10)

                                Text(commit.author)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)

                                if let date = commit.date {
                                    Text(date.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .monospacedDigit()
                                }
                            }
                            .padding(.vertical, 5)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - 辅助

    private func performCommit() {
        let message = trimmedMessage
        guard message.isEmpty == false else { return }

        Task {
            await model.commit(message: message)
            // 只有提交真的走完了才清输入框，失败时用户还能看到原信息再改。
            let committed = model.toast?.text == "已提交" && model.toast?.kind == .success
            if committed || model.gitStatus?.changeCount == 0 {
                commitMessage = ""
            }
        }
    }

    private var trimmedMessage: String {
        commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func busyLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: symbol)
            }
            Text(title)
        }
    }

    /// remotes 形如 `origin → https://...`，拆成名字和地址两栏显示。
    private func remoteLabel(_ remote: String) -> String {
        remote.components(separatedBy: " → ").first ?? remote
    }

    private func remoteURL(_ remote: String) -> String {
        remote.components(separatedBy: " → ").dropFirst().joined(separator: " → ")
    }
}
