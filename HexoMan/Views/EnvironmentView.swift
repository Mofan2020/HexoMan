//
//  EnvironmentView.swift
//  HexoMan
//
//  工具链与运行环境文档。
//
//  数据来自 EnvironmentDocs，渲染走 SwiftUI Text + 本地化。
//  没有第三方 markdown 库——文档结构不复杂（每节：标题 + 摘要 + 几个 bullets +
//  几条命令），自己渲染更可控。
//

import SwiftUI

struct EnvironmentView: View {
    @EnvironmentObject private var model: HexoManModel
    @State private var selectedSectionID: String = EnvironmentDocs.sections.first?.id ?? "overview"

    var body: some View {
        HSplitView {
            tocColumn
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 300)
            detailColumn
                .frame(minWidth: 480)
        }
    }

    // MARK: - 左：目录

    private var tocColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(EnvironmentDocs.sections) { section in
                        TOCRow(
                            section: section,
                            isSelected: section.id == selectedSectionID,
                            onTap: { selectedSectionID = section.id }
                        )
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
            }
        }
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("envDocs.pageTitle")
                .font(.headline)
            Text("envDocs.pageSubtitle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - 右：详情

    @ViewBuilder
    private var detailColumn: some View {
        if let section = EnvironmentDocs.find(selectedSectionID) {
            SectionDetailView(section: section)
        } else {
            EmptyHint(
                systemImage: "questionmark.folder",
                title: "envDocs.overview.title",
                message: "envDocs.overview.summary"
            )
        }
    }
}

// MARK: - 目录行

private struct TOCRow: View {
    let section: DocSection
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                Text(section.title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                isSelected ? Color.accentColor.opacity(0.1) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 章节详情

private struct SectionDetailView: View {
    let section: DocSection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                Text(section.summary)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if section.bullets.isEmpty == false {
                    bulletList
                }

                if section.commands.isEmpty == false {
                    commandList
                }

                if section.seeAlso.isEmpty == false {
                    seeAlso
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: section.icon)
                .font(.title)
                .foregroundStyle(Color.accentColor)
            Text(section.title)
                .font(.title.weight(.semibold))
            Spacer()
        }
    }

    private var bulletList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(section.bullets.enumerated()), id: \.offset) { _, bullet in
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                        .foregroundStyle(.tertiary)
                        .frame(width: 12, alignment: .leading)
                    Text(bullet)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
        }
    }

    private var commandList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(section.commands) { cmd in
                CommandCard(cmd: cmd)
            }
        }
    }

    private var seeAlso: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("envDocs.seeAlso")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(section.seeAlso, id: \.self) { refID in
                    if let ref = EnvironmentDocs.find(refID) {
                        SeeAlsoPill(section: ref)
                    }
                }
            }
        }
    }
}

// 单条命令卡片：「描述 + 命令 + 复制按钮」。
private struct CommandCard: View {
    let cmd: DocCommand
    @State private var copyHint: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text(cmd.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(cmd.command, forType: .string)
                    copyHint = "envDocs.copy.ok"
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("复制命令")
            }
            Text(cmd.command)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.2))
                )
            if let hint = copyHint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copyHint = nil
                        }
                    }
            }
        }
    }
}

/// 「关联章节」小标签。点击跳到对应章节。
private struct SeeAlsoPill: View {
    let section: DocSection
    @EnvironmentObject private var model: HexoManModel

    var body: some View {
        Button {
            // 通过设置 selection 切换到 Environment 页面 + 选这个 section。
            // 这里用一个简单的 hack：直接发一个 notification 给 EnvironmentView
            // 通过 NotificationCenter + userInfo。
            NotificationCenter.default.post(
                name: .envDocsSelectSection,
                object: nil,
                userInfo: ["section": section.id]
            )
        } label: {
            Label(section.title, systemImage: section.icon)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.1),
                            in: Capsule())
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }
}

extension Notification.Name {
    static let envDocsSelectSection = Notification.Name("HexoMan.envDocs.selectSection")
}