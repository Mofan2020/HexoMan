//
//  NewSiteWizard.swift
//  HexoMan
//
//  新建 Hexo 站点向导。分三步：基本信息 → 模板与主题 → 执行。
//

import SwiftUI

/// 新建站点向导。作为 sheet 从站点管理页打开。
struct NewSiteWizard: View {

    @EnvironmentObject private var model: HexoManModel
    @Environment(\.dismiss) private var dismiss

    /// 三个步骤。用 step 索引而不是三个独立页面，是因为校验要跨步骤共享同一份输入。
    private enum Step: Int, CaseIterable {
        case basic
        case options
        case execute

        var title: String {
            switch self {
            case .basic: return "基本信息"
            case .options: return "模板与主题"
            case .execute: return "执行"
            }
        }
    }

    @State private var step: Step = .basic
    @State private var name: String = "my-blog"
    @State private var parentDirectory: String = NewSiteWizard.defaultParentDirectory
    @State private var template: HexoTemplate = .standard
    @State private var themeName: String = ""
    @State private var installDependencies: Bool = true
    /// 正在执行创建流程。
    @State private var isRunning = false
    /// 创建成功并已加入列表，用于显示收尾提示。
    @State private var createdPath: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                stepIndicator
                Divider()
                Form {
                    switch step {
                    case .basic: basicSection
                    case .options: optionsSection
                    case .execute: executeSection
                    }
                }
                .formStyle(.grouped)
            }
            .frame(minWidth: 560, idealWidth: 620, minHeight: 520)
            .navigationTitle("新建 Hexo 站点")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .disabled(isRunning)
                }
                ToolbarItem(placement: .confirmationAction) {
                    footerButtons
                }
            }
        }
    }

    // MARK: - 步骤条

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(Array(Step.allCases.enumerated()), id: \.element) { index, item in
                HStack(spacing: 6) {
                    Text("\(index + 1)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(item == step ? Color.white : Color.secondary)
                        .frame(width: 18, height: 18)
                        .background(
                            item == step ? Color.accentColor : Color.secondary.opacity(0.2),
                            in: Circle()
                        )
                    Text(item.title)
                        .font(.caption)
                        .foregroundStyle(item == step ? Color.primary : Color.secondary)
                }
                if index < Step.allCases.count - 1 {
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: - 第一步：基本信息

    private var basicSection: some View {
        Section {
            TextField("项目名", text: $name)
                .font(.system(.body, design: .monospaced))

            HStack(spacing: 8) {
                TextField("父目录", text: $parentDirectory)
                    .font(.system(.body, design: .monospaced))

                Button {
                    if let url = NSWorkspaceBridge.chooseDirectory(
                        prompt: "选择父目录",
                        defaultPath: FileManager.default.fileExists(atPath: parentDirectory) ? parentDirectory : nil
                    ) {
                        parentDirectory = url.path
                    }
                } label: {
                    Label("选择…", systemImage: "folder")
                }
            }

            LabeledContent("最终路径") {
                Text(targetPath.isEmpty ? "—" : targetPath)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }

            if let message = validationMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        } header: {
            Text("站点位置")
        } footer: {
            // 说清 hexo init 的行为，否则用户会在项目名里手滑填一个完整路径。
            Text("项目名只能是目录名，不能带 /。hexo init 会在父目录下新建同名文件夹，所以目标目录不得已存在。")
        }
    }

    // MARK: - 第二步：模板与主题

    private var optionsSection: some View {
        Section {
            Picker("模板", selection: $template) {
                ForEach(HexoTemplate.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.radioGroup)

            Text(template.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("主题名（可留空）", text: $themeName)
                .font(.system(.body, design: .monospaced))

            Text("留空则用 hexo 默认主题 landscape。填了名字会在创建后执行 npm install hexo-theme-<名字> 并改写 _config.yml 的 theme 字段。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("创建后自动安装依赖（npm install）", isOn: $installDependencies)
        } header: {
            Text("模板与主题")
        } footer: {
            Text("不装依赖也能建站，但 hexo 命令要等装完才能用。")
        }
    }

    // MARK: - 第三步：执行

    private var executeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("将在 \(parentDirectory) 下执行：")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ForEach(Array(plannedCommands.enumerated()), id: \.offset) { _, command in
                    Text(command)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)

            if isRunning || createdPath != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if isRunning {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(runningHint)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let createdPath {
                        Label("已创建并加入列表：\(createdPath)", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                            .textSelection(.enabled)
                    }

                    LogConsole(runner: model.shell)
                        .frame(minHeight: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("将要执行的命令")
        } footer: {
            Text("hexo init 需要联网下载 hexo-cli，第一次会慢一些。执行过程中可以随时关闭本窗口，站点仍会继续创建。")
        }
    }

    // MARK: - 底部按钮

    @ViewBuilder
    private var footerButtons: some View {
        switch step {
        case .basic:
            Button("下一步") {
                withAnimation { step = .options }
            }
            .buttonStyle(.borderedProminent)
            .disabled(validationMessage != nil)

        case .options:
            HStack(spacing: 8) {
                Button("上一步") {
                    withAnimation { step = .basic }
                }
                Button("下一步") {
                    withAnimation { step = .execute }
                }
                .buttonStyle(.borderedProminent)
            }

        case .execute:
            if isRunning {
                ProgressView()
                    .controlSize(.small)
            } else if createdPath != nil {
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
            } else {
                HStack(spacing: 8) {
                    Button("上一步") {
                        withAnimation { step = .options }
                    }
                    Button("开始创建") {
                        Task { await run() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                }
            }
        }
    }

    // MARK: - 执行

    private func run() async {
        guard isRunning == false else { return }
        isRunning = true
        model.shell.clear()
        defer { isRunning = false }

        guard let path = await model.createSite(
            name: name,
            parentDirectory: parentDirectory,
            template: template,
            installDependencies: installDependencies
        ) else {
            // createSite 已经弹过失败原因，这里只把用户按回执行步骤。
            withAnimation { step = .options }
            return
        }

        // 主题是可选的，只有填了才装；不填就用 hexo 默认主题，不做多余动作。
        let trimmedTheme = themeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTheme.isEmpty == false {
            _ = await model.applyTheme(named: trimmedTheme)
        }

        createdPath = path
    }

    // MARK: - 校验与预览

    /// 目标绝对路径。
    private var targetPath: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else { return "" }
        let parent = parentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard parent.isEmpty == false else { return trimmedName }
        return (parent as NSString).appendingPathComponent(trimmedName)
    }

    /// 第一步的错误提示。返回 nil 表示通过。
    private var validationMessage: String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedName.isEmpty {
            return "项目名不能为空"
        }
        if trimmedName.contains("/") {
            return "项目名不能包含 /，它只能是目录名"
        }
        if trimmedName == "." || trimmedName == ".." {
            return "项目名不能是 . 或 .."
        }
        if parentDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请选择父目录"
        }
        if FileManager.default.fileExists(atPath: targetPath) {
            return "目标目录已存在，换个名字或者先把它移走"
        }
        return nil
    }

    /// 预览用命令。跟 model 里真正执行的命令同源，避免「预览和实际不一致」。
    private var plannedCommands: [String] {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTheme = themeName.trimmingCharacters(in: .whitespacesAndNewlines)

        var commands = [
            ShellRunner.displayCommand("npx", ["--yes", "hexo-cli"] + template.initArguments(name: trimmedName))
        ]
        if installDependencies {
            commands.append(ShellRunner.displayCommand("npm", ["install"]))
        }
        if trimmedTheme.isEmpty == false {
            commands.append(ShellRunner.displayCommand("npm", ["install", "hexo-theme-\(trimmedTheme)"]))
        }
        return commands
    }

    private var runningHint: String {
        installDependencies
            ? "正在创建站点并安装依赖，可能要一两分钟…"
            : "正在创建站点…"
    }

    /// 默认父目录。优先 ~/Documents，不存在就用家目录。
    static var defaultParentDirectory: String {
        let documents = (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
        return FileManager.default.fileExists(atPath: documents) ? documents : NSHomeDirectory()
    }
}
