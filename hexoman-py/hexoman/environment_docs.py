"""「HexoMan 工具链 + 环境安装」文档的数据源。

对应 Swift 侧的 ``EnvironmentDocs.swift``。

纯数据，渲染交给界面。这是个轻量级的内嵌文档——README 已经写过类似内容，
这里把「按工具分章节 + 一键复制命令」做成可交互形式。

## 为什么全部内置

HexoMan 的承诺之一是「不联网也能用」。环境文档如果放在外部 wiki / 文档站，
用户在没网或者域名挂掉的时候就看不了了——而那恰好是他们最需要排查环境
问题的时候。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

__all__ = ["DocCommand", "DocSection", "EnvironmentDocs"]


@dataclass
class DocCommand:
    """单条命令。"""

    #: 显示给用户的描述
    description: str
    #: 实际命令字符串（用户要复制进终端的东西，保持原文）
    command: str

    def to_dict(self) -> dict[str, Any]:
        return {"description": self.description, "command": self.command}


@dataclass
class DocSection:
    """文档小节。一节里有几个命令 + 一段解释。"""

    id: str
    icon: str
    title: str
    summary: str
    bullets: list[str] = field(default_factory=list)
    commands: list[DocCommand] = field(default_factory=list)
    #: 关联的「下一步」章节 ID
    see_also: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "icon": self.icon,
            "title": self.title,
            "summary": self.summary,
            "bullets": list(self.bullets),
            "commands": [item.to_dict() for item in self.commands],
            "seeAlso": list(self.see_also),
        }


class EnvironmentDocs:
    """章节列表（按用户典型阅读顺序）。"""

    SECTIONS: list[DocSection] = [
        DocSection(
            id="overview",
            icon="info",
            title="总览",
            summary="HexoMan 管理的是「你已经有的」Hexo 站点。它不自带 Node.js、npm、git 或 hexo。",
            bullets=[
                "站点管理、文章编辑、Markdown 预览不依赖任何外部工具，装好 HexoMan 就能用。",
                "生成、预览、Git 提交需要 node / npm / hexo / git，用你自己装的那份。",
                "环境不对时，「环境」页会告诉你缺什么、怎么装，而不是只说一句「出错了」。",
            ],
            see_also=["node", "git", "hexo", "shell", "troubleshoot"],
        ),
        DocSection(
            id="node",
            icon="package",
            title="Node.js",
            summary="Hexo 跑在 Node.js 上。建议装 18 以上的 LTS 版本。",
            bullets=[
                "macOS 用 Homebrew 装最省事：`brew install node`。",
                "Windows 去 nodejs.org 下 LTS 安装包，装的时候勾上「加入 PATH」。",
                "装完在终端里 `node -v` 应该能打印版本号。",
                "如果终端里能跑、HexoMan 里说找不到，多半是 PATH 没被读到——看下面「Shell 环境」一节。",
            ],
            commands=[
                DocCommand("macOS：用 Homebrew 安装", "brew install node"),
                DocCommand("官方下载页（Windows 用安装包）", "https://nodejs.org/zh-cn/download"),
                DocCommand("检查版本", "node -v"),
            ],
            see_also=["nvm", "shell"],
        ),
        DocSection(
            id="nvm",
            icon="layers",
            title="nvm / fnm（可选）",
            summary="需要同时维护多个 Node 版本时装一个版本管理器。只用最新版就不必装。",
            bullets=[
                "nvm 装在 ~/.nvm 下，每个版本各有自己的 bin 目录。",
                "用 nvm 的站点，HexoMan 需要能读到 nvm 写进 .zshrc 的那段初始化。",
                "Windows 上对应的是 nvm-windows，装法和命令都不一样。",
            ],
            commands=[
                DocCommand("安装 nvm（macOS / Linux shell）", "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash"),
                DocCommand("安装并使用最新 LTS", "nvm install --lts"),
                DocCommand("设为默认版本", "nvm alias default node"),
            ],
            see_also=["node", "shell"],
        ),
        DocSection(
            id="git",
            icon="branch",
            title="Git",
            summary="Hexo 本身不用 git，但 HexoMan 的提交 / 推送 / 拉取全靠它。",
            bullets=[
                "macOS 装 Xcode 命令行工具就自带 git。",
                "Windows 装 Git for Windows，安装时会问要不要加入 PATH，选「是」。",
                "站点目录里要有 .git 才算 Git 仓库。",
            ],
            commands=[
                DocCommand("安装 Xcode 命令行工具（自带 git）", "xcode-select --install"),
                DocCommand("macOS：用 Homebrew 安装", "brew install git"),
                DocCommand("检查版本", "git --version"),
                DocCommand("Windows 下载页", "https://git-scm.com/download/win"),
            ],
            see_also=["shell"],
        ),
        DocSection(
            id="hexo",
            icon="puzzle",
            title="Hexo CLI",
            summary="管理已有站点不要求全局装 hexo——站点自己的 node_modules 里有就能用。",
            bullets=[
                "站点目录下执行过 npm install，node_modules/.bin 里就会有 hexo。",
                "全局装一份（npm install -g hexo-cli）的好处是能在任意目录 hexo new 建站。",
                "HexoMan 优先用站点本地的 hexo，版本和站点依赖天然一致。",
            ],
            commands=[
                DocCommand("装到站点本地（推荐）", "npm install --save hexo"),
                DocCommand("全局安装 CLI（可选）", "npm install -g hexo-cli"),
                DocCommand("用站点本地的 hexo 检查版本", "npx hexo -v"),
            ],
            see_also=["node", "troubleshoot"],
        ),
        DocSection(
            id="shell",
            icon="terminal",
            title="Shell 环境",
            summary="从 Dock / 访达 / 开始菜单启动的程序，拿到的是「系统最小环境」，不读你的 shell 配置文件。",
            bullets=[
                "这就是「终端里 hexo 好好的，HexoMan 说找不到」的根本原因。",
                "HexoMan 会起一个 zsh、把你的 .zshenv / .zprofile / .zshrc source 一遍，把真实的 PATH 抓下来。",
                "抓一次就缓存，不需要每次命令都等 1~2 秒。",
                "刚在终端里装完 node / hexo，回 HexoMan 点「重新读取环境」即可。",
            ],
            see_also=["troubleshoot", "node"],
        ),
        DocSection(
            id="troubleshoot",
            icon="wrench",
            title="疑难排查",
            summary="按这个顺序查，绝大多数「找不到命令」的问题都能定位。",
            bullets=[
                "先在终端里确认命令本身能跑：`which node && node -v`。",
                "看 PATH 里有没有 brew / nvm 的目录：`echo $PATH`。",
                "确认 .zshrc 里确实写了那段初始化（brew shellenv / nvm 的 source 行）。",
                "回到「环境」页点「重新检测」，看诊断结论有没有变。",
                "还不行就在「环境」页手动指定启动文件路径，绕开自动探测。",
            ],
            commands=[
                DocCommand("确认命令本身能跑", "which node && node -v"),
                DocCommand("看当前 PATH", "echo $PATH"),
                DocCommand("看 .zshrc 末尾几行", "cat ~/.zshrc | tail -20"),
            ],
        ),
        DocSection(
            id="privacy",
            icon="lock",
            title="隐私与网络",
            summary="HexoMan 默认完全离线。只有你主动打开「允许联网搜索主题」之后才会访问 npm。",
            bullets=[
                "联网只发生在主题市场搜索时，只 GET npm registry 的包元数据。",
                "不发送你的站点内容、文章、配置或路径。",
                "不写 cookie、不做后台轮询、不做使用统计。",
                "随时可以在设置里关掉，关掉后主题市场退回内置精选列表。",
            ],
        ),
    ]

    @classmethod
    def find(cls, section_id: str) -> DocSection | None:
        """按 id 查章节。"""
        for section in cls.SECTIONS:
            if section.id == section_id:
                return section
        return None

    @classmethod
    def to_list(cls) -> list[dict[str, Any]]:
        return [section.to_dict() for section in cls.SECTIONS]
