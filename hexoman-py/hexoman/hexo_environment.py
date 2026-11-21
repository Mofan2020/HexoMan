"""工具链体检：node / npm / npx / hexo / git。

对应 Swift 侧的 ``HexoEnvironment.swift``。

## 存在的理由

终端里 ``hexo -v`` 好好的，HexoMan 里却找不到 hexo，用户完全不知道问题
在哪。诊断要把「为什么找不到」翻译成人话。

## 设计前提

HexoMan **不自带** node / npm / git / hexo。缺什么就如实告诉用户怎么
自己装，不在应用里藏一份。
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .process import CommandRunner, ProcessResult
from .shell_environment import ShellEnvironment, ShellEnvironmentResolver

__all__ = ["ToolProbe", "ToolchainInfo", "HexoEnvironment"]


@dataclass
class ToolProbe:
    """单个可执行文件的探测结果。"""

    name: str
    #: 解析到的绝对路径。
    path: str = ""
    #: 版本号输出（已去掉命令名前缀）。
    version: str = ""

    @property
    def id(self) -> str:
        return self.name

    @property
    def is_available(self) -> bool:
        return bool(self.path)

    @property
    def short_path(self) -> str:
        """只显示路径尾部三段，完整路径在详情里再看。"""
        if not self.path:
            return ""
        parts = [part for part in self.path.replace("\\", "/").split("/") if part]
        return "/".join(parts[-3:])

    @property
    def display_version(self) -> str:
        """界面上显示的一行摘要。"""
        if not self.is_available:
            return "未找到"
        if self.version:
            return f"{self.version} · {self.short_path}"
        return self.short_path

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "path": self.path,
            "version": self.version,
            "isAvailable": self.is_available,
            "shortPath": self.short_path,
            "displayVersion": self.display_version,
        }


@dataclass
class ToolchainInfo:
    """工具链整体体检结果。"""

    node: ToolProbe = field(default_factory=lambda: ToolProbe("node"))
    npm: ToolProbe = field(default_factory=lambda: ToolProbe("npm"))
    npx: ToolProbe = field(default_factory=lambda: ToolProbe("npx"))
    #: 全局 hexo 的位置。
    global_hexo: ToolProbe = field(default_factory=lambda: ToolProbe("hexo"))
    #: git。Hexo 本身不用，但 HexoMan 的版本管理功能全靠它。
    git: ToolProbe = field(default_factory=lambda: ToolProbe("git"))
    #: 诊断出来的注意事项，直接展示给用户。
    warnings: list[str] = field(default_factory=list)
    #: 读到的 shell 环境摘要。
    environment: dict[str, Any] = field(default_factory=dict)

    @property
    def is_usable(self) -> bool:
        """整体是否具备跑 hexo 的条件。"""
        return self.node.is_available or self.global_hexo.is_available

    def to_dict(self) -> dict[str, Any]:
        return {
            "node": self.node.to_dict(),
            "npm": self.npm.to_dict(),
            "npx": self.npx.to_dict(),
            "globalHexo": self.global_hexo.to_dict(),
            "git": self.git.to_dict(),
            "warnings": list(self.warnings),
            "environment": dict(self.environment),
            "isUsable": self.is_usable,
        }


class HexoEnvironment:
    """工具链探测。只做只读检查，不改任何环境变量。"""

    @staticmethod
    def inspect(
        runner: CommandRunner | None = None,
        environment: ShellEnvironment | None = None,
        uses_shell_environment: bool = True,
        custom_rc_path: str = "",
    ) -> ToolchainInfo:
        """逐个跑 ``--version`` 拿版本。任何一个失败都只影响自己那一项。"""
        runner = runner or CommandRunner()
        home = os.path.expanduser("~")

        if environment is None and uses_shell_environment:
            environment = ShellEnvironmentResolver.resolve(custom_rc_path=custom_rc_path)

        command_env = environment.variables if environment else None

        def probe(name: str, args: list[str]) -> ToolProbe:
            result = runner.run([name] + args, cwd=home, env=command_env)
            return HexoEnvironment._make_probe(name, result, environment)

        info = ToolchainInfo()
        info.node = probe("node", ["-v"])
        info.npm = probe("npm", ["-v"])
        info.npx = probe("npx", ["-v"])
        info.global_hexo = probe("hexo", ["version"])
        info.git = probe("git", ["--version"])

        if environment is not None:
            info.environment = environment.to_dict()

        info.warnings = HexoEnvironment.diagnose(
            info,
            environment=environment,
            uses_shell_environment=uses_shell_environment,
        )
        return info

    @staticmethod
    def _make_probe(
        name: str, result: ProcessResult, environment: ShellEnvironment | None
    ) -> ToolProbe:
        """把一次命令执行结果变成探测结论。

        可用性只看「命令能不能跑通」，不自己扫一遍 PATH 目录——那种搜索
        :mod:`hexoman.hexo_cli` 里已经有了，重复一份只会两边结论不一致。
        路径从缓存的真实环境里取，这样版本和路径说的是同一个东西。
        """
        if not result.success:
            return ToolProbe(name=name)

        path = ""
        if environment is not None:
            path = environment.executable_path(name) or ""
        if not path:
            path = name

        return ToolProbe(name=name, path=path, version=HexoEnvironment.clean_version(result.output))

    @staticmethod
    def clean_version(output: str) -> str:
        """取输出里第一行，剥掉 v 前缀和多余空白。"""
        for line in output.splitlines():
            trimmed = line.strip()
            if not trimmed:
                continue
            return trimmed.strip("vV ")
        return ""

    @staticmethod
    def diagnose(
        info: ToolchainInfo,
        environment: ShellEnvironment | None = None,
        uses_shell_environment: bool = True,
    ) -> list[str]:
        """根据探测结果给出人话诊断。"""
        warnings: list[str] = []

        # 先说环境本身对不对，这决定了后面所有结论是否可信。
        if environment is not None:
            if not environment.rc_files and os.name != "nt":
                warnings.append(
                    "没有找到任何 zsh 配置文件，HexoMan 只能看到系统自带的几个命令目录。\n"
                    "如果你用 Homebrew 装的 node，这里会显示「未找到」。"
                    "可以在下面手动指定启动文件路径。"
                )
        elif uses_shell_environment and os.name != "nt":
            warnings.append("读取 shell 环境失败，命令可能找不到。检查一下启动文件路径是否填对。")

        if not info.node.is_available:
            # 重点怀疑 GUI 环境丢了 PATH，这几乎总能对上 brew / nvm 的使用方式
            node_path = HexoEnvironment.brew_or_nvm_node_path()
            if node_path:
                warnings.append(
                    f"系统里能找到 node（{node_path}），但它不在 HexoMan 当前的 PATH 里。\n"
                    "常见原因是 brew 的环境变量写在 .zprofile 或 .zshrc 里，没被读到。\n"
                    "请在下面确认「读取 zsh 配置」是打开的、rc 路径填对。"
                )
            else:
                warnings.append(
                    "没找到 node。HexoMan 不自带 Node.js，请自己先装一个（建议 18 以上）：\n"
                    "Homebrew 用 `brew install node`，或去 nodejs.org 装官方安装包。\n"
                    "装完点「重新检测」即可。"
                )
        elif not info.global_hexo.is_available:
            warnings.append(
                "找到 node，但没找到全局 hexo。这不影响管理已有站点——站点本地装了依赖就能用。\n"
                "需要「创建新站点」时，HexoMan 会用你的 npm 现场装一份 hexo-cli，不用你手动操作。"
            )

        if not info.git.is_available:
            warnings.append(
                "没找到 git，「Git」页面的提交 / 推送 / 拉取会不可用。\n"
                "Windows 上可以装 Git for Windows，macOS 上用 Xcode 自带的一份"
                "（`xcode-select --install`），或者 `brew install git`。"
            )

        if info.node.version and not HexoEnvironment.is_recent_enough(info.node.version):
            warnings.append(
                f"Node 版本是 {info.node.version}，Hexo 8 建议 18 以上，可能会有兼容问题。"
            )

        return warnings

    @staticmethod
    def brew_or_nvm_node_path() -> str:
        """在几个常见安装位置里找 node。

        用来判断「装了但 PATH 里没有」还是「压根没装」。
        """
        home = os.path.expanduser("~")
        candidates = [
            os.path.join(home, "AppData", "Roaming", "nvm", "node.exe"),
            os.path.join(home, "AppData", "Roaming", "npm", "node.exe"),
        ]

        if os.name != "nt":
            candidates = [
                "/opt/homebrew/bin/node",
                "/usr/local/bin/node",
            ]
            versions_root = Path(home) / ".nvm" / "versions" / "node"
            try:
                entries = sorted(os.listdir(versions_root))
            except OSError:
                entries = []
            if entries:
                candidates.append(str(versions_root / entries[-1] / "bin" / "node"))

        for candidate in candidates:
            if candidate and os.path.isfile(candidate):
                return candidate
        return ""

    @staticmethod
    def is_recent_enough(version: str) -> bool:
        """从 ``v26.8.1`` / ``26.8.1`` 里取出主版本号，判断是否 >= 18。"""
        cleaned = version.strip().strip("vV ")
        head = cleaned.split(".")[0] if cleaned else ""
        try:
            major = int(head)
        except ValueError:
            # 解析不出版本号就当它没问题——不该因为读不懂版本号就报警。
            return True
        return major >= 18
