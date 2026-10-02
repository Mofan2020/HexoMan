//
//  HexoManApp.swift
//  HexoMan
//

import SwiftUI

@main
struct HexoManApp: App {

    @StateObject private var model = HexoManModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("HexoMan") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 680)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("新建文章") {
                    model.selection = .posts
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.currentSite == nil)

                Button("添加站点…") {
                    model.selection = .sites
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("刷新") {
                    model.refreshAll()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.currentSite == nil)

                Divider()

                Button("生成站点") {
                    Task { await model.runGenerate() }
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(model.currentSite == nil)

                Button(model.isServerRunning ? "停止预览" : "启动预览") {
                    if model.isServerRunning {
                        model.stopServer()
                    } else {
                        Task { await model.startServer() }
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.currentSite == nil)

                Button("打开预览页") {
                    NSWorkspaceBridge.open(model.previewURL)
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(!model.isServerRunning)
            }

            // 侧边栏之外再给一套键盘入口。⌘1…⌘6 直达各页面，
            // 这样即使侧边栏的点击链路出问题，也还有路可走。
            CommandMenu("转到") {
                ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element) { index, item in
                    Button(item.title) {
                        model.selection = item
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(index + 1)")),
                        modifiers: .command
                    )
                }
            }
        }
    }
}

/// 纯占位。真正的落盘在 ContentView 里靠 scenePhase 触发，避免和 SwiftUI 生命周期打架。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
