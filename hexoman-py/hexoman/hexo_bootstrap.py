"""hexo-cli 的定位与自举。

对应 Swift 侧的 ``HexoCLIBootstrap.swift``。

## 为什么需要它

「创建 Hexo 项目」这一步需要 hexo-cli，但 HexoMan **不自带**任何
node / npm / hexo。所以策略是：借用用户自己装的那份工具链，按下面的
顺序找一个能用的 hexo，一个都没有才用用户的 npm 把 hexo-cli 装到
HexoMan 自己的目录里。

    1. 用户在设置里手填的路径          —— 最高优先级，用户说了算
    2. 用户 PATH 里的 hexo             —— npm i -g hexo-cli 装的那种
    3. HexoMan 自有目录里已装好的      —— 上次创建站点时自己装的那份
    4. 现场 npm install hexo-cli       —— 兜底，用用户的 npm

装在应用支持目录而不是全局，是为了不污染用户的全局 node_modules：
卸载 HexoMan 等于连它一起删干净。另外它不会写进任何 shell 配置文件，
用户下次开终端不会莫名其妙多出命令。

## 与 Swift 版的差异

Swift 版把自装的那份 hexo 排在「用户 PATH」**之后**、「npx」之前。
Python 版保持同样的优先级，只是实现上多了一条 Windows 分支——
Windows 上 ``node_modules/.bin/`` 里的是 ``hexo.cmd`` 而不是无扩展名的
脚本。
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .process import CommandRunner, ProcessResult
from .system_integration import app_data_directory

__all__ = [
    "HexoCLIBootstrap",
    "HexoSource",
    "HexoTemplate",
    "CLI_VERSION",
]

#: hexo-cli 版本。锁在 4.x 是因为 5.x 目前没有正式发布，
#: 4.3.2 是当前可用且稳定的线。
CLI_VERSION = "^4.3.2"


class HexoSource:
    """hexo 的来源说明。用于在界面上告诉用户「待会儿用的是哪一个」。"""

    CUSTOM = "custom"
    USER_PATH = "userPath"
    MANAGED = "managed"
    UNAVAILABLE = "unavailable"


@dataclass(frozen=True)
class HexoTemplate:
    """``hexo init`` 可用的模板。"""

    #: 落盘的标识
    key: str
    #: 传给 ``hexo init`` 的 ``--template`` 值。内置模板没有这个参数。
    template_argument: str | None = None
    #: 界面 key（文案在 i18n 里）
    title_key: str = ""
    subtitle_key: str = ""

    def init_arguments(self, name: str) -> list[str]:
        """拼出完整参数。抽出来是为了让向导预览的命令和真正执行的命令同源。"""
        arguments = ["init", name]
        if self.template_argument:
            arguments.extend(["--template", self.template_argument])
        return arguments


#: 可用模板。
#:
#: - ``starter``：hexo 官方示例模板（git 仓库），带一些示例文章，适合上手。
#: - ``standard``：hexo-cli 内置的空白模板。
TEMPLATES: tuple[HexoTemplate, ...] = (
    HexoTemplate(
        key="starter",
        template_argument="hexo-starter",
        title_key="siteWizard.template.starter",
        subtitle_key="siteWizard.template.starterHint",
    ),
    HexoTemplate(
        key="standard",
        template_argument=None,
        title_key="siteWizard.template.standard",
        subtitle_key="siteWizard.template.standardHint",
    ),
)


class HexoCLIBootstrap:
    """hexo-cli 的定位与自举。"""

    @staticmethod
    def install_directory() -> str:
        """HexoMan 自有的 hexo-cli 安装目录。"""
        return os.path.join(app_data_directory(), "cli")

    @staticmethod
    def managed_hexo_path() -> str:
        """自有安装目录里的 hexo 可执行文件。

        Windows 上 npm 装出来的是 ``hexo.cmd``。
        """
        binary = "hexo.cmd" if os.name == "nt" else "hexo"
        return os.path.join(
            HexoCLIBootstrap.install_directory(), "node_modules", ".bin", binary
        )

    @staticmethod
    def locate_hexo(
        custom_path: str,
        runner: CommandRunner | None = None,
        environment: Any = None,
    ) -> tuple[str, str] | None:
        """找一个现成能用的 hexo，不做任何安装。

        返回 ``(路径, 来源)``；一个都没有时返回 ``None``。
        """
        runner = runner or CommandRunner()

        trimmed = custom_path.strip()
        if trimmed and runner.is_executable(trimmed):
            return trimmed, HexoSource.CUSTOM

        # 用户 PATH 里的 —— npm i -g hexo-cli 装的就是这个
        if environment is not None:
            found = environment.executable_path("hexo")
            if found:
                return found, HexoSource.USER_PATH

        found = runner.which("hexo")
        if found:
            return found, HexoSource.USER_PATH

        # 之前创建站点时自己装过
        managed = HexoCLIBootstrap.managed_hexo_path()
        if runner.is_executable(managed):
            return managed, HexoSource.MANAGED

        return None

    @staticmethod
    def ensure_hexo(
        custom_path: str,
        runner: CommandRunner | None = None,
        environment: Any = None,
    ) -> str | None:
        """确保有一份可用的 hexo-cli，必要时用用户的 npm 现场装一份。

        返回 hexo 可执行文件路径；用户压根没有 node/npm 时返回 ``None``。
        整个过程只调用用户机器上已有的 npm，HexoMan 自己不携带任何运行时。
        """
        runner = runner or CommandRunner()

        existing = HexoCLIBootstrap.locate_hexo(custom_path, runner, environment)
        if existing is not None:
            return existing[0]

        # 没有现成的，先确认用户有 npm —— 没有的话就别白等一次 npm 报错了。
        npm = None
        if environment is not None:
            npm = environment.executable_path("npm")
        if not npm:
            npm = runner.which("npm")
        if not npm:
            return None

        directory = HexoCLIBootstrap.install_directory()
        try:
            Path(directory).mkdir(parents=True, exist_ok=True)
        except OSError:
            return None

        if not HexoCLIBootstrap.write_manifest(directory):
            return None

        # 用 --no-audit --no-fund 是为了把安装时间压下来，
        # 创建站点本来就要几分钟，网络请求能省则省。
        result = runner.run(
            [
                npm,
                "install",
                f"hexo-cli@{CLI_VERSION}",
                "--no-audit",
                "--no-fund",
                "--loglevel",
                "warn",
            ],
            cwd=directory,
        )

        managed = HexoCLIBootstrap.managed_hexo_path()
        if not result.success or not runner.is_executable(managed):
            return None
        return managed

    @staticmethod
    def write_manifest(directory: str) -> bool:
        """写一个最小的 package.json，让 npm 知道这个目录是个包。

        缺了它 npm 会照样装，但每次都会顺手生成一个名字叫 ``cli`` 的包，
        跟用户别的项目混淆。写清楚更省心。
        """
        manifest = {
            "name": "hexoman-managed-cli",
            "version": "1.0.0",
            "private": True,
            "description": "HexoMan 创建站点时自举的 hexo-cli。删除本目录即可完全卸载。",
            "dependencies": {"hexo-cli": CLI_VERSION},
        }

        target = Path(directory) / "package.json"
        try:
            target.write_text(
                json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True),
                encoding="utf-8",
            )
            return True
        except OSError:
            return False

    @staticmethod
    def managed_size_hint() -> str:
        """自装那份占了多少地方（界面上给用户一个直观印象）。"""
        modules = Path(HexoCLIBootstrap.install_directory()) / "node_modules"
        if not modules.is_dir():
            return "notInstalled"

        count = 0
        for root, _dirs, files in os.walk(modules):
            for name in files:
                if name.endswith(".js"):
                    count += 1
        return "installed" if count == 0 else f"installed:{count}"
