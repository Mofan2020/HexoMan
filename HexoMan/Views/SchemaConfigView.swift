//
//  SchemaConfigView.swift
//  HexoMan
//
//  完全基于 ConfigSchema 推断的可视化配置编辑器。
//  - 自动把 _config.yml / _config.*.yml 里的每个键变成对应控件
//  - 支持嵌套对象（avatar: { url: ..., gravatar: ... }）、列表（social: [{name, url}]）
//  - 用 YAMLPathEngine 回写，保真度与原始文件页一致
//

import SwiftUI




struct SchemaConfigView: View {
    @EnvironmentObject private var model: HexoManModel

    /// 选中的配置文件。按文件分组展示，避免主站配置和主题配置混在一起。
    @State private var selectedFileID: String?
    /// Schema 推断缓存。key = 文件路径。
    @State private var schemas: [String: [ConfigField]] = [:]

    var body: some View {
        VStack(spacing: 0) {
            if model.configFiles.isEmpty {
                EmptyHint(
                    systemImage: "gearshape",
                    title: "没有可编辑的配置文件",
                    message: "站点根目录下需要有 _config.yml。"
                )
            } else {
                HSplitView {
                    // 左侧：文件列表
                    fileList
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)

                    // 右侧：表单
                    formArea
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onChange(of: model.configFiles) { _, _ in
            if let selectedFileID,
               model.configFiles.contains(where: { $0.id == selectedFileID }) == false {
                self.selectedFileID = model.configFiles.first?.id
            }
        }
        .onAppear {
            if selectedFileID == nil {
                selectedFileID = model.configFiles.first?.id
            }
        }
    }

    // MARK: - 左侧文件列表

    private var fileList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedFileID) {
                ForEach(model.configFiles) { file in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name)
                                .font(.callout)
                                .lineLimit(1)
                            Text(file.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        if file.isModified {
                            Pill(text: "未保存", tint: .orange)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(file.id)
                }
            }
            .listStyle(.sidebar)

            Divider()

            Text("共 \(model.configFiles.count) 个配置文件")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
        }
    }

    // MARK: - 右侧表单区

    @ViewBuilder
    private var formArea: some View {
        if let selectedFileID,
           let file = model.configFiles.first(where: { $0.id == selectedFileID }) {
            let schema = schemaFor(file)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 文件头部信息
                    fileHeader(file)

                    // 按 Schema 推断的组逐个渲染
                    if schema.isEmpty {
                        Text("这个文件里没有推断出可编辑的配置项。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    } else {
                        ForEach(schema) { entry in
                            SchemaEntryView(
                                entry: entry,
                                filePath: file.path,
                                model: model,
                                onCommit: { path, value in
                                    model.updateConfigAt(path: file.path, yamlPath: path, value: value)
                                }
                            )
                        }
                    }
                }
                .padding(20)
            }
        } else {
            EmptyHint(
                systemImage: "doc.text",
                title: "选一个配置文件",
                message: "左边挑一个 _config*.yml 就能开始编辑。"
            )
        }
    }

    private func fileHeader(_ file: ConfigFile) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(file.name)
                    .font(.headline)

                if file.isModified {
                    Pill(text: "未保存", tint: .orange)
                } else {
                    Pill(text: "与磁盘一致", tint: .green)
                }

                Spacer(minLength: 8)

                Button {
                    model.saveConfig(file)
                } label: {
                    Label("保存", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!file.isModified)
                .keyboardShortcut("s", modifiers: .command)

                Button {
                    model.revertConfig(file)
                } label: {
                    Label("放弃改动", systemImage: "arrow.uturn.backward")
                }
                .disabled(!file.isModified)
            }

            Text(file.path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func schemaFor(_ file: ConfigFile) -> [ConfigField] {
        if let cached = schemas[file.path] { return cached }
        let doc = YAMLDocument(text: file.contents)
        let inferred = ConfigSchema.fields(in: doc)
        schemas[file.path] = inferred
        return inferred
    }
}

// MARK: - 单个 Schema 条目的视图

struct SchemaEntryView: View {

    let entry: ConfigField
    let filePath: String
    @ObservedObject var model: HexoManModel
    let onCommit: (String, String) -> Void

    @State private var pendingValue: String = ""
    /// 用户是否动过这个字段。用来区分「暂存值为空」和「用户主动清空」。
    @State private var hasPending = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 标签行
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.label)
                    .font(.callout)
                Text(entry.path.yamlDisplay)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.quaternary)
                Spacer(minLength: 8)
            }

            // 控件
            controlView

            // 说明：有详细文档就用可展开的文档，没有就退回原来那行 hint
            if let doc = entry.doc, doc.isEmpty == false {
                ConfigHelpView(doc: doc)
            } else if !entry.hint.isEmpty {
                Text(entry.hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .sheet(isPresented: $showListEditor) {
            ListEditorSheet(
                path: self.entry.path.yamlDisplay,
                items: $listItems,
                onSave: saveListItems,
                model: model,
                filePath: filePath
            )
        }
    }

    @ViewBuilder
    private var controlView: some View {
        if !entry.isWritable {
            // 只读：列表、分组、块文本等
            VStack(alignment: .leading, spacing: 8) {
                Text(readOnlyLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                
                // 对于列表类型，提供编辑入口
                if entry.childCount > 0 && readOnlyLabel.contains("列表") {
                    Button("编辑列表项…") {
                        editList()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        } else {
            switch entry.kind {
            case .text, .url, .asset:
                TextField("留空表示不设置", text: textBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($isFocused)
                    .onSubmit { commit() }

            case .color:
                TextField("#RRGGBB", text: textBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($isFocused)
                    .onSubmit { commit() }

            case .boolean:
                Toggle("", isOn: boolBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)

            case .integer:
                TextField("数字", text: intBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($isFocused)
                    .onSubmit { commit() }

            case .multiline:
                TextEditor(text: textBinding)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 80)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)

            case .choice(let options):
                Picker("", selection: textBinding) {
                    // 补当前值：候选表里没有的值（如自定义时区、
                    // 换主题留下的自定义枚举）否则显示成空白且存不进去
                    ForEach(ConfigField.mergedOptions(options, current: entry.value)) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
                .onChange(of: textBinding.wrappedValue) { _, new in
                    if new != pendingValue {
                        pendingValue = new
                        commit()
                    }
                }

            case .readOnly:
                Text(readOnlyLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var readOnlyLabel: String {
        switch entry.kind {
        case .readOnly(let reason): 
            if reason == "列表" && entry.childCount > 0 {
                return "列表（\(entry.childCount) 项）——点击「编辑列表项」修改"
            }
            return reason
        default: return "只读"
        }
    }

    // MARK: - 绑定

    private var textBinding: Binding<String> {
        Binding(
            get: { hasPending ? pendingValue : (model.configValue(at: filePath, path: entry.path.yamlDisplay) ?? entry.value ?? "") },
            set: {
                pendingValue = $0
                // 靠 pendingValue.isEmpty 判断「用户没动过」是错的：
                // 用户把某个值**清空**时，get 会立刻回退到磁盘上的旧值，
                // 于是这个字段永远清不掉，下拉框也点不回空。
                // 必须单独记一个「动过」的标记。
                hasPending = true
            }
        )
    }

    private var boolBinding: Binding<Bool> {
        Binding(
            get: { (model.configValue(at: filePath, path: entry.path.yamlDisplay) ?? entry.value ?? "").lowercased() == "true" },
            set: { commit($0 ? "true" : "false") }
        )
    }

    private var intBinding: Binding<String> {
        Binding(
            get: { hasPending ? pendingValue : (model.configValue(at: filePath, path: entry.path.yamlDisplay) ?? entry.value ?? "") },
            set: {
                pendingValue = String($0.filter { $0.isNumber || $0 == "-" })
                hasPending = true
            }
        )
    }

    // MARK: - 提交

    private func commit(_ value: String? = nil) {
        let valueToCommit = value ?? pendingValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = model.configValue(at: filePath, path: entry.path.yamlDisplay) ?? entry.value ?? ""
        guard current != valueToCommit else {
            hasPending = false
            return
        }
        onCommit(entry.path.yamlDisplay, valueToCommit)
        hasPending = false
        pendingValue = ""
    }
    
    // MARK: - 列表编辑
    
    @State private var showListEditor = false
    @State private var listItems: [ListItem] = []
    
    private var isListField: Bool {
        entry.childCount > 0 && readOnlyLabel.contains("列表")
    }
    
    private func editList() {
        loadListItems()
        showListEditor = true
    }
    
    private func loadListItems() {
        let path = entry.path.yamlDisplay
        let text = model.configFiles.first(where: { $0.path == filePath })?.contents ?? ""
        let count = YAMLPathEngine.shared.listCount(path, in: text)
        
        var items: [ListItem] = []
        for i in 0..<count {
            // Try to get name/title/name field for display
            let name = YAMLPathEngine.shared.listItemValue(entry.path.yamlDisplay, index: i, field: "name", in: model.configFiles.first(where: { $0.path == filePath })?.contents ?? "") 
                ?? YAMLPathEngine.shared.listItemValue(entry.path.yamlDisplay, index: i, field: "title", in: model.configFiles.first(where: { $0.path == filePath })?.contents ?? "")
                ?? YAMLPathEngine.shared.listItemValue(entry.path.yamlDisplay, index: i, field: "text", in: model.configFiles.first(where: { $0.path == filePath })?.contents ?? "")
                ?? "第 \(i + 1) 项"
            
            // Get all fields for this item
            var fields: [ListItemField] = []
            let text = model.configFiles.first(where: { $0.path == filePath })?.contents ?? ""
            let doc = YAMLDocument(text: text)
            if let sequence = doc.node(at: YAMLPath(dottedPath: entry.path.yamlDisplay)),
               let items = sequence.items,
               i < items.count,
               let fields_dict = items[i].value.entries {
                for field in fields_dict {
                    if let scalar = field.node.scalar {
                        fields.append(ListItemField(key: field.key, value: scalar.value))
                    }
                }
            }
            
            items.append(ListItem(index: i, displayName: name, fields: fields))
        }
        
        listItems = items
        showListEditor = true
    }
    
    private func saveListItems() {
        // 将编辑后的列表项写回 YAML
        let path = entry.path.yamlDisplay
        let text = model.configFiles.first(where: { $0.path == filePath })?.contents ?? ""
        
        // 删除旧列表项
        var currentText = text
        for i in (0..<listItems.count).reversed() {
            let itemPath = path + "[\(i)]"
            let result = YAMLPathEngine.shared.set(itemPath, to: "", in: currentText)
            if case .success(let newText) = result {
                currentText = newText
            }
        }
        
        // 重新添加编辑后的项
        for item in listItems {
            // 构建列表项的 YAML
            var itemYAML = "- "
            for (idx, field) in item.fields.enumerated() {
                if idx > 0 {
                    itemYAML += "\n  "
                }
                itemYAML += "\(field.key): \(field.value)"
            }
            
            let result = YAMLPathEngine.shared.set(entry.path.yamlDisplay, to: itemYAML, in: currentText)
            if case .success(let newText) = result {
                currentText = newText
            }
        }
        
        // 写回文件
        if let file = model.configFiles.first(where: { $0.path == filePath }) {
            var fileCopy = file
            fileCopy.contents = currentText
            model.saveConfig(ConfigStore.markSaved(fileCopy))
        }
}











// MARK: - 列表编辑 Sheet






// MARK: - 列表编辑 Sheet






// MARK: - 列表编辑 Sheet










// MARK: - 列表编辑 Sheet



}