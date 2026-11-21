"""新建 Hexo 站点与安装依赖。

对应 Swift 侧 ``HexoManModel.swift`` 里的 ``createSite(...)`` 与
``installDependencies()``，以及 ``HexoSite.swift`` 里的 ``HexoTemplate``。

## 为什么不直接跑 ``npx hexo-cli``

Swift 版早先用过 ``npx --yes hexo-cli``，那会在创建站点时偷偷从网上
下一份到 npm 缓存，慢且不可控。这里改成：先在用户机器上找现成的
hexo-cli，找不到才用用户自己的 npm 装一份到 HexoMan 的目录里
（见 :mod:`hexoman.hexo_bootstrap`）。
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .hexo_bootstrap import HexoCLIBootstrap, HexoTemplate, TEMPLATES
from .model import Site
from .process import CommandRunner, ProcessResult

__all__ = [
    "SiteCreator",
    "SiteCreateResult",
    "HexoTemplate",
    "TEMPLATES",
]


@dataclass
class SiteCreateResult:
    """新建站点的结果。"""

    ok: bool
    path: str = ""
    error: str = ""
    message: str = ""
    #: 站点建好了但依赖没装上。这不算创建失败——站点已经在了，
    #: 只是暂时跑不了 hexo。用户可以在站点管理里重试。
    dependency_failed: bool = False

    def to_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "path": self.path,
            "error": self.error,
            "message": self.message,
            "dependencyFailed": self.dependency_failed,
        }


class SiteCreator:
    """创建站点 / 装依赖。"""

    @staticmethod
    def templates() -> tuple[HexoTemplate, ...]:
        """可用模板。"""
        return TEMPLATES

    @staticmethod
    def is_valid_site_name(name: str) -> bool:
        """项目名合法性：非空、无路径分隔符、不以点开头。

        避免 ``.`` / ``..`` 这类怪路径。
        """
        trimmed = name.strip()
        if not trimmed or trimmed in (".", ".."):
            return False
        return "/" not in trimmed and "\\" not in trimmed

    @staticmethod
    def create(
        name: str,
        parent_directory: str,
        template: str = "standard",
        install_dependencies: bool = True,
        runner: CommandRunner | None = None,
        environment: Any = None,
        custom_hexo_path: str = "",
    ) -> SiteCreateResult:
        """在 ``parent_directory`` 下建一个新站点。

        步骤：校验名字 → 确认目录存在且目标不存在 → 找/装 hexo-cli →
        ``hexo init`` → 落盘检查 → （可选）``npm install`` → 返回路径。
        """
        runner = runner or CommandRunner()

        trimmed_name = name.strip()
        trimmed_parent = parent_directory.strip()

        if not SiteCreator.is_valid_site_name(trimmed_name):
            return SiteCreateResult(
                ok=False, error="invalidName", message="项目名不能为空，也不能包含 /"
            )
        if not trimmed_parent:
            return SiteCreateResult(
                ok=False, error="parentEmpty", message="请先选择父目录"
            )
        if not os.path.isdir(trimmed_parent):
            return SiteCreateResult(
                ok=False, error="parentMissing", message=f"父目录不存在：{trimmed_parent}"
            )

        target = os.path.join(trimmed_parent, trimmed_name)
        # 已存在就不要再 init 一次：hexo init 往已有目录里塞文件会污染用户手写的内容。
        if os.path.exists(target):
            return SiteCreateResult(
                ok=False, error="alreadyExists", message=f"{target} 已存在，换个名字或先删掉它"
            )

        # 先确保有一份 hexo-cli。用户压根没有 node/npm 时这里直接失败，
        # 早点报错比让 npm 吐一屏看不懂的输出强。
        hexo = HexoCLIBootstrap.ensure_hexo(
            custom_hexo_path, runner=runner, environment=environment
        )
        if not hexo:
            return SiteCreateResult(
                ok=False,
                error="hexoUnavailable",
                message=(
                    "找不到 hexo-cli，而且没有 npm 可以安装它。"
                    "请先装 Node.js，再重试。"
                ),
            )

        chosen = SiteCreator._template(template)

        # hexo init 必须在父目录里跑，它自己会生成以项目名命名的子目录。
        result = runner.run(
            [hexo] + chosen.init_arguments(trimmed_name),
            cwd=trimmed_parent,
        )
        if not result.success:
            return SiteCreateResult(
                ok=False, error="initFailed", message=result.error_summary or "未知错误"
            )

        # 退出码 0 不代表目录真建出来了（有些环境只吐警告），落一次盘检查再继续。
        if not os.path.exists(target):
            return SiteCreateResult(
                ok=False, error="notCreated", message=f"创建失败：没有生成目录 {target}"
            )

        # 依赖装不上不算创建失败：站点已经在了，只是暂时跑不了 hexo。
        dependency_failed = False
        if install_dependencies:
            dependency_failed = not SiteCreator.install_dependencies(
                Site(path=target), runner=runner
            )

        return SiteCreateResult(
            ok=True, path=target, dependency_failed=dependency_failed
        )

    @staticmethod
    def install_dependencies(
        site: Site, runner: CommandRunner | None = None
    ) -> bool:
        """在站点目录跑 ``npm install``。返回是否成功。

        clone 下来的 Hexo 站经常没有 node_modules，hexo 命令直接不可用；
        给一个一键修复入口比让用户自己开终端猜命令靠谱。
        """
        runner = runner or CommandRunner()

        npm = runner.which("npm")
        if not npm:
            return False

        result = runner.run(
            [
                npm,
                "install",
                "--no-audit",
                "--no-fund",
                "--loglevel",
                "warn",
            ],
            cwd=site.path,
        )
        return result.success

    @staticmethod
    def _template(key: str) -> HexoTemplate:
        for item in TEMPLATES:
            if item.key == key:
                return item
        return TEMPLATES[-1]
