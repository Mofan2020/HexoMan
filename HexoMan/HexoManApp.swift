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
                // ⌘N 留给系统自带的「新建窗口」，这里用 ⌘⌥N 避免两个动作抢同一个键。
                Button("新建文章") {
                    model.selection = .posts
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
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

            // 侧边栏之外再给一套键盘入口。⌘1…⌘9 直达各页面，
            // 这样即使侧边栏的点击链路出问题，也还有路可走。
            CommandMenu("转到") {
                ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element) { index, item in
                    // 只给能映射到单个数字键的项编号，也就是 ⌘1…⌘9。
                    //
                    // 这里不能图省事直接对每项都拼字符串：SidebarItem 一共 10 项，
                    // 第 10 项算出来是 "10"，而 Character("10") 会直接 fatal error
                    // （一个 Character 只允许一个字形簇），整个进程 SIGTRAP。
                    // 表现是界面上所有按钮突然全没了，看起来像布局崩了，其实是 app 挂了。
                    // 站点管理正好排在第 10 项，所以它不参与编号。
                    if index < 9 {
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
}

/// 纯占位。真正的落盘在 ContentView 里靠 scenePhase 触发，避免和 SwiftUI 生命周期打架。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
