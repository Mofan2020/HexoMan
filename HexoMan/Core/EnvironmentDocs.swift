//
//  EnvironmentDocs.swift
//  HexoMan
//
//  「HexoMan 工具链 + 环境安装」文档的数据源。
//
//  纯数据，所有渲染走 SwiftUI Text + 本地化字符串。
//  这是个轻量级的内嵌文档——HexoMan 的 README 已经写过类似内容，
//  这里把「按工具分章节 + 一键复制命令」做成可交互形式。
//

import Foundation
import SwiftUI

/// 单条命令。「显示给用户的描述」走本地化，「实际命令字符串」是原文。
struct DocCommand: Identifiable {
    var id: String { command }
    var description: LocalizedStringKey
    var command: String
}

/// 文档小节。一节里有几个命令 + 一段解释。
struct DocSection: Identifiable {
    var id: String
    var icon: String
    var title: LocalizedStringKey
    var summary: LocalizedStringKey
    var bullets: [LocalizedStringKey] = []
    var commands: [DocCommand] = []
    /// 关联的「下一步」章节 ID。在视图里点章节标题可跳转。
    var seeAlso: [String] = []
}

enum EnvironmentDocs {

    /// 章节列表（按用户典型阅读顺序）。
    static let sections: [DocSection] = [
        // MARK: - 总览
        DocSection(
            id: "overview",
            icon: "info.circle",
            title: "envDocs.overview.title",
            summary: "envDocs.overview.summary",
            bullets: [
                "envDocs.overview.bullet1",
                "envDocs.overview.bullet2",
                "envDocs.overview.bullet3"
            ],
            seeAlso: ["node", "git", "hexo", "shell", "troubleshoot"]
        ),
        // MARK: - Node.js
        DocSection(
            id: "node",
            icon: "shippingbox",
            title: "envDocs.node.title",
            summary: "envDocs.node.summary",
            bullets: [
                "envDocs.node.bullet1",
                "envDocs.node.bullet2",
                "envDocs.node.bullet3",
                "envDocs.node.bullet4"
            ],
            commands: [
                DocCommand(description: "envDocs.node.brew", command: "brew install node"),
                DocCommand(description: "envDocs.node.official", command: "https://nodejs.org/zh-cn/download"),
                DocCommand(description: "envDocs.node.checkVersion", command: "node -v")
            ],
            seeAlso: ["nvm", "shell"]
        ),
        // MARK: - nvm/fnm
        DocSection(
            id: "nvm",
            icon: "rectangle.stack",
            title: "envDocs.nvm.title",
            summary: "envDocs.nvm.summary",
            bullets: [
                "envDocs.nvm.bullet1",
                "envDocs.nvm.bullet2",
                "envDocs.nvm.bullet3"
            ],
            commands: [
                DocCommand(description: "envDocs.nvm.install", command: "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash"),
                DocCommand(description: "envDocs.nvm.use", command: "nvm install --lts"),
                DocCommand(description: "envDocs.nvm.aliasDefault", command: "nvm alias default node")
            ],
            seeAlso: ["node", "shell"]
        ),
        // MARK: - Git
        DocSection(
            id: "git",
            icon: "arrow.triangle.branch",
            title: "envDocs.git.title",
            summary: "envDocs.git.summary",
            bullets: [
                "envDocs.git.bullet1",
                "envDocs.git.bullet2"
            ],
            commands: [
                DocCommand(description: "envDocs.git.brew", command: "brew install git"),
                DocCommand(description: "envDocs.git.xcode", command: "xcode-select --install"),
                DocCommand(description: "envDocs.git.checkVersion", command: "git --version")
            ],
            seeAlso: ["shell"]
        ),
        // MARK: - Hexo
        DocSection(
            id: "hexo",
            icon: "puzzlepiece",
            title: "envDocs.hexo.title",
            summary: "envDocs.hexo.summary",
            bullets: [
                "envDocs.hexo.bullet1",
                "envDocs.hexo.bullet2",
                "envDocs.hexo.bullet3"
            ],
            commands: [
                DocCommand(description: "envDocs.hexo.installLocal", command: "npm install --save hexo"),
                DocCommand(description: "envDocs.hexo.checkVersion", command: "npx hexo -v")
            ],
            seeAlso: ["node", "troubleshoot"]
        ),
        // MARK: - Shell 环境
        DocSection(
            id: "shell",
            icon: "terminal",
            title: "envDocs.shell.title",
            summary: "envDocs.shell.summary",
            bullets: [
                "envDocs.shell.bullet1",
                "envDocs.shell.bullet2",
                "envDocs.shell.bullet3",
                "envDocs.shell.bullet4"
            ],
            seeAlso: ["troubleshoot", "node"]
        ),
        // MARK: - 疑难排查
        DocSection(
            id: "troubleshoot",
            icon: "stethoscope",
            title: "envDocs.troubleshoot.title",
            summary: "envDocs.troubleshoot.summary",
            bullets: [
                "envDocs.troubleshoot.bullet1",
                "envDocs.troubleshoot.bullet2",
                "envDocs.troubleshoot.bullet3",
                "envDocs.troubleshoot.bullet4",
                "envDocs.troubleshoot.bullet5"
            ],
            commands: [
                DocCommand(description: "envDocs.troubleshoot.whichNode", command: "which node && node -v"),
                DocCommand(description: "envDocs.troubleshoot.pathCheck", command: "echo $PATH"),
                DocCommand(description: "envDocs.troubleshoot.zshrc", command: "cat ~/.zshrc | tail -20")
            ]
        ),
        // MARK: - 隐私与网络
        DocSection(
            id: "privacy",
            icon: "lock.shield",
            title: "envDocs.privacy.title",
            summary: "envDocs.privacy.summary",
            bullets: [
                "envDocs.privacy.bullet1",
                "envDocs.privacy.bullet2",
                "envDocs.privacy.bullet3",
                "envDocs.privacy.bullet4"
            ]
        )
    ]

    /// 章节按 id 查。
    static func find(_ id: String) -> DocSection? {
        sections.first { $0.id == id }
    }
}