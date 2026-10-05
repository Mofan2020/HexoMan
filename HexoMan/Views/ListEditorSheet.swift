//
//  ListEditorSheet.swift
//  HexoMan
//
//  列表编辑器 Sheet
//

import SwiftUI

// MARK: - 列表项模型

struct ListItem: Identifiable {
    let index: Int
    var displayName: String
    var fields: [ListItemField]
    
    var id: String { "\(index)" }
}

struct ListItemField: Identifiable {
    var key: String
    var value: String
    var id: String { key }
}

// MARK: - 列表编辑 Sheet

struct ListEditorSheet: View {
    let path: String
    @Binding var items: [ListItem]
    let onSave: () -> Void
    @ObservedObject var model: HexoManModel
    let filePath: String
    
    @Environment(\.dismiss) private var dismiss
    @State private var editingIndex: Int?
    @State private var editingFields: [ListItemField] = []
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("编辑列表：" + path)
                    .font(.headline)
                Spacer()
                Button("完成") {
                    onSave()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            
            if items.isEmpty {
                Text("暂无列表项")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(items.indices, id: \.self) { index in
                        let item = items[index]
                        HStack {
                            Text(item.displayName)
                                .font(.callout)
                            Spacer()
                            Button("编辑") {
                                editingIndex = index
                                editingFields = item.fields
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            
                            Button(role: .destructive) {
                                items.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    }
                    .onMove { from, to in
                        items.move(fromOffsets: from, toOffset: to)
                    }
                }
                .frame(minHeight: 200, maxHeight: 400)
            }
            
            HStack {
                Button("添加项目") {
                    let newIndex = items.count
                    let newItem = ListItem(index: newIndex, displayName: "新项目 \(newIndex + 1)", fields: [])
                    items.append(newItem)
                    editingIndex = newIndex
                    editingFields = []
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                if let editingIndex = editingIndex {
                    Button("取消编辑") {
                        self.editingIndex = nil
                    }
                    .buttonStyle(.bordered)
                }
            }
            
            if editingIndex != nil {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("编辑项目 \(editingIndex! + 1)")
                        .font(.subheadline.weight(.medium))
                    
                    ForEach(editingFields.indices, id: \.self) { idx in
                        HStack {
                            TextField("键", text: $editingFields[idx].key)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            TextField("值", text: $editingFields[idx].value)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    
                    HStack {
                        Button("添加字段") {
                            editingFields.append(ListItemField(key: "", value: ""))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        Button("保存") {
                            if let idx = editingIndex {
                                items[idx].fields = editingFields
                                // Update display name from name/title field
                                if let nameField = editingFields.first(where: { $0.key == "name" || $0.key == "title" }),
                                   !nameField.value.isEmpty {
                                    items[idx].displayName = nameField.value
                                }
                                editingIndex = nil
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 600, height: 500)
    }
}
