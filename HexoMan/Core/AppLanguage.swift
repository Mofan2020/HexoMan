//
//  AppLanguage.swift
//  HexoMan
//
//  UI 语言选项。落盘的是 `AppSettings.language`（"system" / 语言 ID）。
//  SwiftUI 那边拿到的是 Locale，渲染时按 Locale 自动选 `.lproj` 资源。
//
//  选 JP / EN / CN 之外的"系统跟随"作为默认值，理由见
//  `AppSettings.language` 上的注释。
//

import Foundation

/// UI 语言档。
///
/// - rawValue: 落盘的字符串。`"system"` 表示跟随系统（默认），
///   其余是 BCP-47 语言标识。
/// - locale: SwiftUI 拿来注入 `.environment(\.locale, ...)` 的 Locale。
///   跟随系统时返回 `Locale.current`，让 Apple 框架决定真用哪份资源。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case en
    case ja

    var id: String { rawValue }

    /// 当前语言对应的 Locale。`.system` 时直接返回系统 Locale。
    var locale: Locale {
        switch self {
        case .system:
            return Locale.current
        case .zhHans:
            return Locale(identifier: "zh-Hans")
        case .en:
            return Locale(identifier: "en")
        case .ja:
            return Locale(identifier: "ja")
        }
    }

    /// 菜单里显示的名字。本地化走 `xcstrings`（key 形如 `language.menu.system`）。
    var displayNameKey: String {
        switch self {
        case .system: return "language.menu.system"
        case .zhHans: return "language.menu.zhHans"
        case .en: return "language.menu.en"
        case .ja: return "language.menu.ja"
        }
    }

    /// 菜单里显示的图标。`.system` 给个 Globe 圆点的特殊表达。
    var symbolName: String {
        switch self {
        case .system: return "globe"
        case .zhHans: return "character.bubble"
        case .en: return "a.circle"
        case .ja: return "j.circle"
        }
    }

    /// 解析任意字符串。失败回落到 `.system`（最不坏的选择）。
    static func resolve(_ raw: String) -> AppLanguage {
        if let match = AppLanguage(rawValue: raw) { return match }
        // 兼容旧版写入的 zh_CN 之类（早期调试里手填过）。
        if raw.hasPrefix("zh") { return .zhHans }
        return .system
    }
}