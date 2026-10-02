//
//  SystemIntegration.swift
//  HexoMan
//
//  与系统打交道的薄封装：访达、浏览器、文件选择框。
//

import AppKit
import SwiftUI

enum NSWorkspaceBridge {

    /// 在访达里选中文件。
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// 打开站点目录。
    static func openFolder(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// 用默认程序打开 URL。
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// 弹文件选择框。
    ///
    /// 用可执行权限做过滤而不是按扩展名：hexo、node、git 都可能没有扩展名，
    /// 按名字挑会漏掉一大半实际可用的文件。
    static func chooseFile(prompt: String, defaultPath: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.prompt = prompt
        if let defaultPath {
            panel.directoryURL = URL(fileURLWithPath: defaultPath)
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// 弹目录选择框。`prompt` 是「选择」按钮上的字。
    static func chooseDirectory(prompt: String, defaultPath: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = prompt
        if let defaultPath {
            panel.directoryURL = URL(fileURLWithPath: defaultPath)
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// 在主线程跑一段 UI 更新。
@MainActor
enum OnMain {
    static func run(_ action: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async { action() }
        }
    }
}
