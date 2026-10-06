//
//  ConfigHelpView.swift
//  HexoMan
//
//  配置项的「填写帮助」。被可视化配置页、结构化页、主题配置页共用。
//
//  为什么要单独抽出来：这三个页面都渲染 ConfigField，
//  帮助内容也必须长得一样——否则用户在主题配置页看到的是一排没有说明的输入框，
//  转到站点配置页同一个键又有说明，会以为是自己记错了。
//
//  默认只显示一行摘要，保持表单紧凑；
//  真正耗地方的「怎么填 / 每个候选值什么意思」收在展开区里。
//

import SwiftUI

// MARK: - 入口

struct ConfigHelpView: View {

    let doc: ConfigDoc

    /// 一行摘要是否展开。
    @State private var isExpanded = false

    /// 候选值的逐条解释，默认收起——通常有 4~7 条，全展开会把表单撑得很长。
    @State private var showOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            summaryRow
            if isExpanded {
                Divider().padding(.vertical, 1)
                expandedBody
            }
        }
        .padding(.vertical, 4)
    }

    private var summaryRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(doc.summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if hasMore {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    Text(isExpanded ? "收起" : "怎么填？")
                        .font(.caption2.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            Spacer(minLength: 0)
        }
    }

    /// 有没有值得展开的内容。全空的文档不值得给一个点不开的按钮。
    private var hasMore: Bool {
        !doc.detail.isEmpty
            || doc.howToFill != nil
            || !doc.examples.isEmpty
            || !doc.options.isEmpty
            || doc.tip != nil
            || !doc.links.isEmpty
    }

    @ViewBuilder
    private var expandedBody: some View {
        if !doc.detail.isEmpty {
            Text(doc.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let howToFill = doc.howToFill {
            labeledBlock("怎么填", text: howToFill)
        }

        if !doc.options.isEmpty {
            optionsBlock
        }

        if !doc.examples.isEmpty {
            examplesBlock
        }

        if let tip = doc.tip {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
                Text(tip)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if !doc.links.isEmpty {
            FlowLayout(spacing: 10) {
                ForEach(doc.links.indices, id: \.self) { index in
                    Link(doc.links[index].label, destination: URL(string: doc.links[index].url) ?? URL(string: "about:blank")!)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: 候选值逐条解释

    private var optionsBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showOptions.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(doc.options.count > 1 ? "\(doc.options.count) 个选项分别是什么意思" : "这个选项什么意思")
                        .font(.caption.weight(.medium))
                    Image(systemName: showOptions ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)

            if showOptions {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(doc.options) { option in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(option.value)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                            Text(option.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 2)
            }
        }
    }

    private var examplesBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("示例")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ForEach(doc.examples, id: \.self) { example in
                Text(example)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
    }

    private func labeledBlock(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 内嵌说明

/// 直接显示摘要那一行，不带展开按钮。
/// 给已经有自己标题层级的场景用（比如表单卡片里）。
struct ConfigHelpSummary: View {
    let doc: ConfigDoc?

    var body: some View {
        if let doc {
            Text(doc.summary)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}