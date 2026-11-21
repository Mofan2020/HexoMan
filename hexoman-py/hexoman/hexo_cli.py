"""调用 hexo 命令。

对应 Swift 侧的 ``HexoService.swift``。核心问题是「到底该用哪个 hexo」：
优先级是刻意的——直接用 ``npx hexo`` 会在没装依赖的站点上触发一次联网安装，
那不是「管理」该有的行为。

## 与 Swift 版的两处差异

1. **Swift 版有「HexoMan 自装」这一档**（创建站点时自举出来的那份 hexo）。
   Python 版没有自举流程——用 ``npm install`` 现场装更简单，也不需要在
   应用支持目录里塞一份 node。所以优先级是：
   **用户显式指定 > 站点本地依赖 > 用户 PATH > 全局安装 > npx**。
2. **子进程继承用户真实 shell 环境**。从 Dock 启动的图形程序拿到的 PATH
   只有系统那几个目录，brew 装的 node 根本不在里面。这里通过
   :mod:`hexoman.shell_environment` 把用户 rc 文件 source 一遍，拿到的
   PATH 会传给每一个子进程。
"""

from __future__ import annotations

import os
import sys
from dataclasses import dataclass, field
from typing import Any, Mapping

from .model import Site
from .process import CommandRunner, ProcessResult
from .shell_environment import ShellEnvironment, ShellEnvironmentResolver

__all__ = ["HexoInvocation", "HexoService", "resolve_invocation", "HEXO_SOURCE_LABELS"]

#: hexo 来源的**稳定标识**。界面拿标识去 i18n 查文案，别把中文直接写进
#: 代码——切英文时那几行会变成中英混杂。
HEXO_SOURCE_LABELS = {
    "custom": "hexoSource.custom",
    "local": "hexoSource.local",
    "path": "hexoSource.path",
    "global": "hexoSource.global",
    "npx": "hexoSource.npx",
}


@dataclass
class HexoInvocation:
    """站点当前可用的 hexo 调用方式。"""

    executable: str
    prefix_arguments: list[str] = field(default_factory=list)
    source: str = "npx"

    def arguments(self, extra: list[str]) -> list[str]:
        return self.prefix_arguments + extra

    def to_dict(self) -> dict[str, Any]:
        return {
            "executable": self.executable,
            "prefixArguments": list(self.prefix_arguments),
            "source": self.source,
            "sourceKey": HEXO_SOURCE_LABELS.get(self.source, "hexoSource.npx"),
        }


def resolve_invocation(
    site: Site,
    custom_path: str = "",
    runner: CommandRunner | None = None,
    environment: ShellEnvironment | None = None,
) -> HexoInvocation:
    """找出这个站点该用哪个 hexo。

    优先级：**用户显式指定 > 站点本地依赖 > 用户 PATH > 全局安装 > npx**。
    """
    runner = runner or CommandRunner()

    if custom_path and runner.is_executable(custom_path):
        return HexoInvocation(executable=custom_path, source="custom")

    local = site.node_modules_bin
    if runner.is_executable(local):
        return HexoInvocation(executable=local, source="local")

    # 用户 PATH 里的 hexo。这是绝大多数装了 hexo-cli 的用户走的那条。
    if environment is not None:
        found = environment.executable_path("hexo")
        if found:
            return HexoInvocation(executable=found, source="path")

    found = runner.which("hexo")
    if found:
        return HexoInvocation(executable=found, source="path")

    global_path = _lookup_global_hexo(runner)
    if global_path:
        return HexoInvocation(executable=global_path, source="global")

    return HexoInvocation(executable="npx", prefix_arguments=["hexo"], source="npx")


def _lookup_global_hexo(runner: CommandRunner) -> str:
    """在常见位置找全局 hexo。

    不走 ``which``：Windows 上 ``which`` 依赖 ``PATHEXT``，
    而 npm 全局装出来的 ``hexo.cmd`` 只有在同一个 shell 里才认得。
    """
    candidates: list[str] = []

    if os.name == "nt":
        appdata = os.environ.get("APPDATA", "")
        if appdata:
            candidates.append(os.path.join(appdata, "npm", "hexo.cmd"))
            candidates.append(os.path.join(appdata, "npm", "hexo"))
        program_files = os.environ.get("PROGRAMFILES", r"C:\Program Files")
        candidates.append(os.path.join(program_files, "nodejs", "hexo.cmd"))
    else:
        home = os.path.expanduser("~")
        candidates.append("/usr/local/bin/hexo")
        candidates.append("/opt/homebrew/bin/hexo")
        candidates.append(os.path.join(home, ".nvm", "versions", "node", _latest_node_folder(home), "bin", "hexo"))

    return next((path for path in candidates if path and runner.is_executable(path)), "")


def _latest_node_folder(home: str) -> str:
    """取 ``~/.nvm/versions/node`` 下最后一个版本目录。

    够用且不用跑 node 去问版本号。
    """
    root = os.path.join(home, ".nvm", "versions", "node")
    try:
        entries = sorted(os.listdir(root))
    except OSError:
        return ""
    return entries[-1] if entries else ""


class HexoService:
    """hexo 动作集合。每个方法只负责组装命令，具体执行交给 runner。"""

    def __init__(
        self,
        site: Site,
        custom_path: str = "",
        runner: CommandRunner | None = None,
        environment: ShellEnvironment | None = None,
    ) -> None:
        self.site = site
        self.custom_path = custom_path
        self.runner = runner or CommandRunner()
        self.environment = environment

    def invocation(self) -> HexoInvocation:
        return resolve_invocation(
            self.site, self.custom_path, self.runner, self.environment
        )

    def _env(self) -> Mapping[str, str] | None:
        """子进程要用的环境。

        基于用户真实 shell 环境，再叠上几条**强制**设置：

        - ``NO_COLOR`` / ``TERM=dumb``：ANSI 颜色码在界面里就是乱码
        - ``LANG`` / ``LC_ALL``：不强制 UTF-8 的话中文文件名会乱码
        - ``CI=1`` / ``npm_config_yes``：npm 在非交互下会等 TTY 输入，
          stdin 已经接到 null，这里再标上非交互让它直接走
        """
        base: dict[str, str] = {}
        if self.environment is not None:
            base = dict(self.environment.variables)
        else:
            base = dict(os.environ)

        base["FORCE_COLOR"] = "0"
        base["NO_COLOR"] = "1"
        base["TERM"] = "dumb"
        base["LANG"] = "en_US.UTF-8"
        base["LC_ALL"] = "en_US.UTF-8"
        base["CI"] = "1"
        base["npm_config_yes"] = "true"
        return base

    def clean(self) -> tuple[str, list[str]]:
        """``hexo clean`` —— 清掉 db.json 和 public。"""
        invocation = self.invocation()
        return invocation.executable, invocation.arguments(["clean"])

    def generate(self) -> tuple[str, list[str]]:
        """``hexo generate``"""
        invocation = self.invocation()
        return invocation.executable, invocation.arguments(["generate"])

    def server(self, port: int, drafts: bool = False) -> tuple[str, list[str]]:
        """``hexo server``

        ``hexo server`` 默认只渲染已发布的文章，草稿（front-matter 里
        ``draft: true``）在预览里根本不存在——写草稿的人会以为预览坏了。
        所以 ``drafts=True`` 时加 ``--draft``。
        """
        invocation = self.invocation()
        args = invocation.arguments(["server", "-p", str(port)])
        if drafts:
            args.append("--draft")
        return invocation.executable, args

    def preview_url(self, port: int) -> str:
        return f"http://localhost:{port}"

    def command_preview(self, action: str = "generate") -> str:
        """拼出给人看的命令行，方便对着终端复现。"""
        if action == "clean":
            executable, args = self.clean()
        elif action == "server":
            executable, args = self.server(4000)
        else:
            executable, args = self.generate()

        return display_command(executable, args)

    # -- 执行 ---------------------------------------------------------

    def run_clean(self) -> ProcessResult:
        executable, args = self.clean()
        return self.runner.run([executable] + args, cwd=self.site.path, env=self._env())

    def run_generate(self) -> ProcessResult:
        executable, args = self.generate()
        return self.runner.run([executable] + args, cwd=self.site.path, env=self._env())

    def start_server(self, port: int, drafts: bool = False):
        """启动预览服务，返回 ``(Popen, 命令预览)``。

        失败返回 ``(None, 命令预览)``：预览起不来是可恢复的状态，
        界面要能提示用户而不是崩掉。
        """
        executable, args = self.server(port, drafts)
        process = self.runner.spawn([executable] + args, cwd=self.site.path, env=self._env())
        return process, display_command(executable, args)

    def stop_server(self, process) -> None:
        """停止预览服务。

        先 terminate 再给 1.5 秒体面退出，不行就强杀。``hexo server``
        会派生子进程，只 terminate 父进程经常留一堆孤儿。
        """
        if process is None:
            return

        try:
            process.terminate()
        except OSError:
            return

        try:
            process.wait(timeout=1.5)
        except Exception:
            try:
                process.kill()
            except OSError:
                pass


def display_command(executable: str, arguments: list[str]) -> str:
    """拼出给人看的命令行，方便对着终端复现。"""
    parts = [executable] + list(arguments)
    return "$ " + " ".join(f'"{part}"' if " " in part else part for part in parts)
