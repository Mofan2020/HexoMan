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
        if let match = AppLanguage(rawValue: raw), match.hasTranslations {
            return match
        }
        // 兼容旧版写入的 zh_CN 之类（早期调试里手填过）。
        if raw.hasPrefix("zh") { return .zhHans }
        return .system
    }

    /// 这个语言档**真的带了翻译**吗。
    ///
    /// 存在的意义是：万一某个语言档只有枚举项、catalog 里一条都没有，
    /// 选中它时 SwiftUI 找不到对应的 `.lproj`，每个 `Text` 都退回
    /// 开发语言（catalog 的 sourceLanguage 是 en）。结果不是「那个语言的界面」，
    /// 而是**中英混杂**——一半 key 走 fallback，一半是硬编码中文，
    /// 看起来就是「这个语言整个坏掉」。
    ///
    /// 所以让没有翻译的语言档不能被选中/恢复：退到 `.system` 至少
    /// 是一套自洽的语言，比掉进混杂状态好。
    ///
    /// `ja` 现在是 **true** —— 184 条日文已全部补入 `Localizable.xcstrings`，
    /// bundle 产出 `ja.lproj`。加新语言档时记得同步这里。
    var hasTranslations: Bool {
        switch self {
        case .system, .zhHans, .en, .ja:
            return true
        }
    }
}