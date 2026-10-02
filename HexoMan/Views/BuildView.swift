//
//  BuildView.swift
//  HexoMan
//
//  构建与预览：跑 hexo clean / generate、开关本地预览服务器、看真实命令输出。
//

import SwiftUI

struct BuildView: View {

    @EnvironmentObject private var model: HexoManModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    environmentBar
                    toolchainPanel
                    dependencyNotice
                    actions
                    portSection
                }
                .padding(20)
            }
            // 上面这一坨内容高度不固定（诊断信息会随环境变长变短），
            // 所以必须给它一个下限；不给的话日志区的 maxHeight: .infinity
            // 会把所有剩余空间吃掉，这一屏就被压成一条缝。
            .frame(minHeight: 280, maxHeight: .infinity)

            Divider()

            // 日志占一块固定比例的下方区域。给上下界而不是纯 .infinity，
            // 这样窗口拉高时日志不会无限膨胀、拉矮时也不会把上面挤没。
            VStack(spacing: 0) {
                if model.shell.lines.isEmpty {
                    Text("还没有命令输出")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 6)
                }

                LogConsole(runner: model.shell)
            }
            .frame(minHeight: 180, idealHeight: 260, maxHeight: 340)
        }
    }

    /// 工具链体检 + 自定义 hexo 路径。
    ///
    /// 单独一屏是因为「终端里 hexo 好好的，HexoMan 里找不到」这类问题
    /// 光报错没用，得让用户看到 node 到底是什么版本、hexo 到底在哪。
    private var toolchainPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("运行环境体检", systemImage: "stethoscope")
                    .font(.headline)

                Spacer()

                if model.isInspectingToolchain {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        // 重新检测时强制重读 rc 文件：用户很可能刚在终端里装完 node
                        Task { await model.refreshToolchain(reloadShellEnvironment: true) }
                    } label: {
                        Label("重新检测", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }

            if let chain = model.toolchain {
                VStack(spacing: 8) {
                    DetailRow(label: "node", value: chain.node.displayVersion, monospaced: true)
                    Divider()
                    DetailRow(label: "npm", value: chain.npm.displayVersion, monospaced: true)
                    Divider()
                    DetailRow(label: "全局 hexo", value: chain.globalHexo.displayVersion, monospaced: true)
                    Divider()
                    DetailRow(label: "git", value: chain.git.displayVersion, monospaced: true)
                }
                .padding(14)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                if !chain.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(chain.warnings, id: \.self) { warning in
                            Label {
                                Text(warning)
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding(12)
                    .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            shellEnvironmentRow
            customPathRow
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task {
            // 首次进入构建页时体检一次，之后靠用户手动刷新
            if model.toolchain == nil {
                await model.refreshToolchain()
            }
        }
    }

    /// zsh 配置读取开关 + 读到了哪些 rc 文件。
    ///
    /// 默认只显示一行状态，详细说明和路径输入收进折叠区。
    /// 原因很实际：这些诊断信息对绝大多数用户是噪音，全部铺开会把这一屏撑得很长，
    /// 而构建页真正要放的是「构建环境 + 操作按钮 + 日志」。
    @State private var showShellDetail = false

    private var shellEnvironmentRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("读取 zsh 配置", isOn: $model.usesShellEnvironment)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                Spacer(minLength: 8)

                Text(model.usesShellEnvironment ? model.resolvedRCSummary : "已关闭")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showShellDetail.toggle()
                    }
                } label: {
                    Image(systemName: showShellDetail ? "chevron.down" : "chevron.right")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help(showShellDetail ? "收起" : "展开 zsh 配置详情")
            }

            if showShellDetail {
                if model.usesShellEnvironment {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("""
                        从 Dock 启动的图形程序不读 ~/.zshrc，Homebrew 的环境变量因此完全不可见。
                        打开这个开关，HexoMan 会用 zsh 加载你的 .zshenv / .zprofile / .zshrc，
                        拿到和你终端里一样的 PATH。
                        """)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            TextField("rc 文件路径（留空自动找）", text: $model.customRCPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11.5, design: .monospaced))

                            Button("选择…") {
                                if let url = NSWorkspaceBridge.chooseFile(prompt: "选择 zsh 配置文件") {
                                    model.customRCPath = url.path
                                }
                            }
                        }

                        if let problem = model.customRCPathProblem {
                            Label(problem, systemImage: "exclamationmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }

                        DetailRow(label: "已读取", value: model.resolvedRCSummary, monospaced: true)
                        DetailRow(label: "PATH 关键项", value: model.resolvedPathSummary, monospaced: true)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Text("关闭后 HexoMan 只用 app 启动时继承到的环境，通常只有系统四个目录，brew 装的 node 会不可见。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 自定义 hexo 路径。自动探测失灵时的最后一道手动兜底。
    private var customPathRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("自定义 hexo 路径（可选）")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("留空则自动探测", text: $model.customHexoPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))

                Button("选择…") {
                    if let url = NSWorkspaceBridge.chooseFile(prompt: "选择") {
                        model.customHexoPath = url.path
                    }
                }

                if model.customHexoPath.isEmpty == false {
                    Button("清除") {
                        model.customHexoPath = ""
                    }
                }
            }

            if let problem = model.customHexoPathProblem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                Text("一般不用填。终端里 `which hexo` 的结果填进来即可；nvm 装的通常在 ~/.nvm/versions/node/<版本>/bin/hexo。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 环境信息

    private var environmentBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("构建环境", systemImage: "info.circle")
                .font(.headline)

            VStack(spacing: 8) {
                DetailRow(label: "站点", value: siteName)
                Divider()
                DetailRow(label: "站点路径", value: model.currentSite?.path ?? "", monospaced: true)
                Divider()
                DetailRow(label: "Hexo 来源", value: model.hexoSource)
                Divider()
                DetailRow(label: "命令预览", value: model.hexoCommandPreview, monospaced: true)
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    /// 依赖没装时构建必然失败，直接在这里说清楚，并给一条能自己解决的出路。
    @ViewBuilder
    private var dependencyNotice: some View {
        if model.info?.dependenciesInstalled == false {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 6) {
                    Text("站点依赖未安装")
                        .font(.headline)

                    Text("HexoMan 不自带 Node.js，用的是你系统里的那一份。装好之后回到「站点管理」点「安装依赖」，或者在这里点「重新检测」。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                // 先解包再用，绝不碰 model.currentSite!
                if let site = model.currentSite {
                    Button {
                        NSWorkspaceBridge.openFolder(site.path)
                    } label: {
                        Label("在访达中显示站点", systemImage: "folder")
                    }
                    .help("打开站点目录，自己去终端跑 npm install")
                }
            }
            .padding(14)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: - 动作

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("构建动作", systemImage: "hammer")
                .font(.headline)

            HStack(spacing: 10) {
                Button {
                    Task { await model.runClean() }
                } label: {
                    busyLabel("清理", symbol: "sparkles")
                }
                .disabled(model.isBusy)
                .help("清空缓存和已生成的 public 目录")

                Button {
                    Task { await model.runGenerate() }
                } label: {
                    busyLabel("生成站点", symbol: "hammer")
                }
                .disabled(model.isBusy)
                .help("执行 hexo generate，产物写入 public 目录")

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
                .buttonStyle(.borderedProminent)
                .tint(model.isServerRunning ? Color.orange : Color.accentColor)
                .disabled(model.isBusy)
                .help(model.isServerRunning ? "停掉本地预览服务器" : "启动 hexo server")

                Button {
                    NSWorkspaceBridge.open(model.previewURL)
                } label: {
                    Label("打开预览页", systemImage: "safari")
                }
                .disabled(!model.isServerRunning)
                .help(model.isServerRunning ? "在浏览器打开预览" : "预览未启动")

                Spacer(minLength: 0)
            }

            buildOutputRow
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// 构建产物情况。generate 成功后这个数字会变，是用户最直接的反馈。
    private var buildOutputRow: some View {
        HStack(spacing: 10) {
            Pill(
                text: hasBuildOutput ? "已有构建产物" : "尚无构建产物",
                tint: hasBuildOutput ? Color.green : Color.secondary
            )
            Pill(text: "\(buildFileCount) 个文件", tint: .accentColor)

            if hasBuildOutput, let site = model.currentSite {
                Button {
                    NSWorkspaceBridge.openFolder(site.publicDirectory)
                } label: {
                    Label("打开 public 目录", systemImage: "shippingbox")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("在访达中打开构建产物目录")
            }

            Spacer(minLength: 0)
        }
    }

    private var hasBuildOutput: Bool { model.info?.hasBuildOutput ?? false }
    private var buildFileCount: Int { model.info?.buildFileCount ?? 0 }

    // MARK: - 端口

    private var portSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("预览端口", systemImage: "network")
                .font(.headline)

            HStack(spacing: 12) {
                Stepper(
                    value: portBinding,
                    in: 1024...65535,
                    step: 1
                ) {
                    Text("端口")
                        .font(.callout)
                        .monospacedDigit()
                }
                .frame(width: 190)

                Pill(text: "http://localhost:\(model.serverPort)", tint: model.isServerRunning ? .green : .accentColor)

                if model.isServerRunning {
                    Pill(text: "预览运行中", tint: .green)
                }

                Spacer(minLength: 0)

                Button {
                    model.refreshAll()
                } label: {
                    Label("刷新环境", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("重新探测站点状态（比如刚跑完 npm install）")
            }

            if model.isServerRunning {
                Label("端口改动要重启预览才生效：先「停止预览」，改完再「启动预览」。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 辅助

    /// 运行中就把图标换成进度条，按钮本身已经 disabled，这里只负责视觉。
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

    /// Stepper 要 Int 绑定，顺便把越界值夹回合法区间。
    private var portBinding: Binding<Int> {
        Binding(
            get: { model.serverPort },
            set: { newValue in
                model.serverPort = min(65535, max(1024, newValue))
            }
        )
    }

    private var siteName: String {
        if let info = model.info { return info.displayName }
        return model.currentSite?.folderName ?? "—"
    }
}
