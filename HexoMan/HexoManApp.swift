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
                Button(LocalizedStringKey("menu.newPost")) {
                    model.selection = .posts
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(model.currentSite == nil)

                Button(LocalizedStringKey("menu.addSite")) {
                    model.selection = .sites
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button(LocalizedStringKey("menu.refresh")) {
                    model.refreshAll()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.currentSite == nil)

                Divider()

                Button(LocalizedStringKey("menu.generate")) {
                    Task { await model.runGenerate() }
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(model.currentSite == nil)

                Button(model.isServerRunning
                       ? LocalizedStringKey("menu.stopServer")
                       : LocalizedStringKey("menu.startServer")) {
                    if model.isServerRunning {
                        model.stopServer()
                    } else {
                        Task { await model.startServer() }
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.currentSite == nil)

                Button(LocalizedStringKey("menu.openPreview")) {
                    NSWorkspaceBridge.open(model.previewURL)
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(!model.isServerRunning)
            }

            // 侧边栏之外再给一套键盘入口。⌘1…⌘9 直达各页面，
            // 这样即使侧边栏的点击链路出问题，也还有路可走。
            CommandMenu(LocalizedStringKey("menu.goto")) {
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

            // 语言切换菜单。
            //
            // macOS 顶栏菜单不会响应 SwiftUI 的 `.environment(\.locale)`，
            // 切语言后这一组菜单项会闪一下重建，是 Apple 框架的限制。
            // 菜单标题和选项本身是 LocalizedStringKey，所以新建时就已经是当前语言。
            CommandMenu(LocalizedStringKey("menu.language")) {
                ForEach(AppLanguage.allCases) { language in
                    Button {
                        model.language = language
                    } label: {
                        // Label 在 macOS 菜单里渲染为 leading 图标 + 文字，
                        // 选中态通过替换图标为 checkmark 表达。
                        if model.language == language {
                            Label(LocalizedStringKey(language.displayNameKey),
                                  systemImage: "checkmark")
                        } else {
                            Label(LocalizedStringKey(language.displayNameKey),
                                  systemImage: language.symbolName)
                        }
                    }
                    .keyboardShortcut(shortcutKey(for: language), modifiers: [.command])
                }
            }
        }
    }

    /// 各语言档对应的快捷键字符。
    ///
    /// 放在 `struct HexoManApp` 顶层，不放在 `.commands` 闭包里——
    /// Swift 不允许 `private` 在 `ViewBuilder` 闭包内出现，函数也得抬出来。
    private func shortcutKey(for language: AppLanguage) -> KeyEquivalent {
        switch language {
        case .system: return KeyEquivalent("1")
        case .zhHans: return KeyEquivalent("2")
        case .en: return KeyEquivalent("3")
        case .ja: return KeyEquivalent("4")
        }
    }
}

/// 纯占位。真正的落盘在 ContentView 里靠 scenePhase 触发，避免和 SwiftUI 生命周期打架。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}