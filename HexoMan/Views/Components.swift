//
//  Components.swift
//  HexoMan
//
//  跨页面复用的 UI 零件：提示条、状态卡片、标签、日志控制台。
//

import SwiftUI

// MARK: - 侧边栏按钮

/// 侧边栏的一个导航项。
///
/// 自己画而不用 `Label` + `.listStyle(.sidebar)`，是因为要精确控制选中态高亮，
/// 并且保证「点击 → 赋值」这条路径不经过任何隐式选中机制。
struct SidebarButton: View {
    var title: String
    var systemImage: String
    var badge: Int = 0
    var isActive: Bool = false
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .frame(width: 16)

                Text(title)
                    .font(.callout)

                Spacer(minLength: 4)

                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption2)
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.tertiary.opacity(0.5), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(background)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(title)
    }

    private var background: Color {
        if isActive { return Color.accentColor.opacity(0.16) }
        if isHovering { return Color.primary.opacity(0.06) }
        return .clear
    }
}

// MARK: - 提示条

/// 右上角浮出的操作反馈。3 秒后自动消失。
struct ToastView: View {
    let toast: Toast
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .foregroundStyle(tint)

            Text(toast.text)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(3)

            Spacer(minLength: 8)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        .frame(maxWidth: 460)
        .task(id: toast.id) {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            onDismiss()
        }
    }

    private var symbolName: String {
        switch toast.kind {
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var tint: Color {
        switch toast.kind {
        case .success: return .green
        case .failure: return .red
        case .info: return .accentColor
        }
    }
}

// MARK: - 状态卡片

/// 总览页用的一个指标块。
struct StatCard: View {
    var title: String
    var value: String
    var systemImage: String
    var tint: Color = .accentColor
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// 一行「标题 + 值」，用于详情列表。
struct DetailRow: View {
    var label: String
    var value: String
    var monospaced: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value.isEmpty ? "—" : value)
                .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                .foregroundStyle(value.isEmpty ? .tertiary : .primary)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .font(.callout)
    }
}

// MARK: - 小标签

struct Pill: View {
    var text: String
    var tint: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }
}

// MARK: - 空状态

struct EmptyHint: View {
    var systemImage: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

// MARK: - 日志控制台

/// 展示 `ShellRunner` 收集到的输出。构建页和 Git 页共用。
struct LogConsole: View {
    @ObservedObject var runner: ShellRunner
    var autoScroll: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            scroll
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("命令输出")
                .font(.caption)
                .foregroundStyle(.secondary)

            if runner.jobs.isEmpty == false {
                Text("· \(runner.jobs.count) 个任务运行中")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Spacer()

            Button {
                runner.clear()
            } label: {
                Label("清空", systemImage: "trash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)

            Button {
                runner.stopAll()
            } label: {
                Label("全部停止", systemImage: "stop.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(runner.jobs.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var scroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(runner.lines) { line in
                        Text(line.displayText)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(color(for: line.stream))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .onChange(of: runner.lines.count) {
                guard autoScroll, let last = runner.lines.last else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func color(for stream: LogStream) -> Color {
        switch stream {
        case .standardOutput: return .primary
        case .standardError: return .red
        case .meta: return .accentColor
        }
    }
}
