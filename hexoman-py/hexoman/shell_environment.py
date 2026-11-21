"""把「用户真实的 shell 环境」抓出来。

对应 Swift 侧的 ``ShellEnvironment.swift``。

## 要解决的问题

从 Dock / 访达启动的图形程序，**不读** ``~/.zshrc``。后果非常具体：

- 用户终端里 ``node`` 是 ``/opt/homebrew/bin/node``（brew shellenv 加的）
- ``hexo`` 是 ``/usr/local/bin/hexo``（npm global 装的）
- 而 HexoMan 拿到的 PATH 只有 ``/usr/bin:/bin:/usr/sbin:/sbin``

于是「明明装了 hexo，HexoMan 却说找不到」。

## 做法

起一个登录 shell，按标准顺序把用户自己的启动文件 source 一遍，再把 resulting
environment 抓下来缓存起来。之后所有子进程直接继承这份环境。

## 为什么不每次都跑一次登录 shell

实测用户的 ``.zshrc`` 里有 starship init、orbstack、brew shellenv，一次 source
要 1~2 秒。``git status`` 之类的轮询命令每条都付这个代价不可接受。所以
只在首次（或用户手动「重新读取」）时 bootstrap 一次，之后走缓存。

## Windows 上怎么办

Windows 没有 rc 文件这套东西，图形程序拿到的 PATH 通常已经包含用户级和
系统级的 PATH（``%APPDATA%\\npm``、``%PROGRAMFILES%\\nodejs`` 都在里面）。
所以 Windows 上**不需要** bootstrap，直接继承进程环境即可。

**重要前提**：HexoMan **不自带** node / npm / git / hexo。一切都用用户自己
装的那份，这样版本天然一致，也不会和应用沙箱里的副本打架。
"""

from __future__ import annotations

import os
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

__all__ = [
    "ShellEnvironment",
    "ShellEnvironmentResolver",
    "fallback_path_entries",
]


def fallback_path_entries() -> list[str]:
    """无论用户怎么配，这几个路径都该在 PATH 里。

    Homebrew 在 Apple Silicon 上的默认前缀就是 ``/opt/homebrew``，但它是靠
    ``brew shellenv`` 往 PATH 里塞的——用户的 ``.zprofile`` 里可能压根没写
    那行。这里兜底加一次，保证「装了 brew node 就一定能用」。
    """
    if os.name == "nt":
        return []

    return [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]


@dataclass
class ShellEnvironment:
    """一次 shell bootstrap 的产物：用户真实的运行环境。"""

    #: 抓下来的完整环境变量。会作为所有子进程的基础环境。
    variables: dict[str, str] = field(default_factory=dict)
    #: 实际 source 到的启动文件顺序（只含真实存在的）。
    rc_files: list[str] = field(default_factory=list)
    #: 解析出的 PATH。
    path: str = ""

    def executable_path(self, name: str) -> str | None:
        """从 PATH 里找可执行文件。

        用于同步地判断「hexo 在不在」，省得为一次判断去起子进程。
        """
        if not name:
            return None

        # 绝对路径直接放行
        if os.path.isabs(name):
            return name if _is_executable(name) else None

        # 命令名里带路径分隔符（比如 node_modules/.bin/hexo）就没必要扫 PATH
        if os.sep in name or "/" in name:
            return name if _is_executable(name) else None

        for directory in self.path.split(os.pathsep):
            if not directory:
                continue
            candidate = os.path.join(directory, name)
            if _is_executable(candidate):
                return candidate
        return None

    @property
    def path_summary(self) -> str:
        """给界面看的 PATH 摘要。

        只挑 3 条最相关的。实测真实 PATH 有 40+ 项，全拼进一行会把详情挤成
        一条省略号，既不好看也看不出问题——用户真正要确认的只是
        「``/opt/homebrew/bin`` 在不在」这一件事。
        """
        entries = [item for item in self.path.split(os.pathsep) if item]
        if not entries:
            return "（空）"

        # homebrew 最优先，因为它承载着需求点名要保证的 node
        priority = ("homebrew", ".nvm", os.path.join(".local", ""), "node")
        picked: list[str] = []
        for keyword in priority:
            hit = next((item for item in entries if keyword in item), "")
            if hit and hit not in picked:
                picked.append(hit)
            if len(picked) >= 3:
                break

        if not picked:
            picked = entries[:3]

        # 只留尾部两段：完整路径太长，而尾部两段足够区分
        # ``/opt/homebrew/bin`` 和 ``/usr/local/bin`` 这类同名末级目录。
        shortened = []
        for entry in picked:
            parts = [part for part in entry.replace("\\", "/").split("/") if part]
            shortened.append("…/" + "/".join(parts[-2:]) if len(parts) > 2 else entry)

        return " : ".join(shortened) + f"（共 {len(entries)} 项）"

    @property
    def rc_summary(self) -> str:
        """rc 文件的可读描述。"""
        if not self.rc_files:
            return "未找到启动文件"
        return " → ".join(os.path.basename(item) for item in self.rc_files)

    def to_dict(self) -> dict[str, Any]:
        return {
            "path": self.path,
            "pathSummary": self.path_summary,
            "rcFiles": list(self.rc_files),
            "rcSummary": self.rc_summary,
        }


def _is_executable(path: str) -> bool:
    """路径是不是可执行文件。

    Windows 上 ``node_modules/.bin/hexo`` 是个 ``.cmd`` 脚本而不是 ELF
    可执行文件，用 ``os.access(X_OK)`` 判断在 Windows 上不成立，所以额外
    看扩展名。
    """
    if not path or not os.path.isfile(path):
        return False
    if os.access(path, os.X_OK):
        return True
    return os.name == "nt" and path.lower().endswith((".cmd", ".bat", ".exe"))


class ShellEnvironmentResolver:
    """负责把「用户真实的 shell 环境」抓出来。"""

    #: zsh 启动文件，按 zsh 官方的加载顺序。
    RC_FILE_NAMES = (".zshenv", ".zprofile", ".zshrc")

    #: 这些变量是 shell 运行时自己的状态，带进子进程只会让行为变怪，全部丢掉。
    #:
    #: 特别是 ``SHLVL`` / ``ZSH_VERSION`` / ``RPROMPT`` 之类，会让某些 npm
    #: 脚本以为自己跑在交互 shell 里，从而跳过非交互处理直接调 ``less`` 或
    #: ``vim``，把 HexoMan 卡死。
    DROPPED_KEYS = frozenset(
        {
            "PWD",
            "OLDPWD",
            "SHLVL",
            "_",
            "ZSH_VERSION",
            "ZSH_NAME",
            "ZSH_PATCHLEVEL",
            "ZSH_ARGZERO",
            "RPROMPT",
            "RPS1",
            "PROMPT",
            "PS1",
            "COLUMNS",
            "LINES",
        }
    )

    @classmethod
    def resolve(
        cls, custom_rc_path: str = "", working_directory: str | None = None
    ) -> ShellEnvironment | None:
        """跑一次 bootstrap，把用户真实环境抓下来。

        ``custom_rc_path`` 为空则自动找 ``$ZDOTDIR`` 下的标准三件套。
        """
        if os.name == "nt":
            # Windows 上不需要 bootstrap：图形进程拿到的 PATH 已经包含
            # 用户级与系统级的路径（npm global、nodejs 都在里面）。
            return cls._inherit_environment()

        directory = working_directory or os.path.expanduser("~")
        script = cls.bootstrap_script(custom_rc_path)

        try:
            completed = subprocess.run(  # noqa: S603
                ["/bin/zsh", "-c", script],
                cwd=directory,
                capture_output=True,
                text=True,
                timeout=15,
                shell=False,
                env={
                    "HOME": os.path.expanduser("~"),
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "USER": os.environ.get("USER", ""),
                    "LANG": "en_US.UTF-8",
                    "LC_ALL": "en_US.UTF-8",
                },
            )
        except (OSError, subprocess.SubprocessError):
            return None

        if completed.returncode != 0:
            return None

        return cls.parse(completed.stdout, custom_rc_path)

    @classmethod
    def _inherit_environment(cls) -> ShellEnvironment | None:
        """Windows：直接继承当前进程的环境。"""
        variables = {
            key: value
            for key, value in os.environ.items()
            if key not in cls.DROPPED_KEYS
        }
        path = variables.get("PATH", "")
        if not path:
            return None
        return ShellEnvironment(
            variables=variables,
            rc_files=[],
            path=path,
        )

    @classmethod
    def bootstrap_script(cls, custom_rc_path: str) -> str:
        """拼出 bootstrap 脚本。

        关键点：

        1. rc 的输出和报错都丢掉——用户 rc 里的 ``echo``、警告不该出现在
           HexoMan 日志里。
        2. source 失败不能中断（``|| true``），用户 rc 里一个语法错误不该让
           整个环境探测失败。
        3. 最后 ``env -0`` 输出 NUL 分隔的键值对，比 ``printenv`` 稳
           （不受 locale 和换行影响）。
        """
        lines: list[str] = []

        if custom_rc_path:
            # 用户显式指定了 rc 文件，就只用它，不掺自动探测的结果
            quoted = cls.shell_quote(custom_rc_path)
            lines.append(f"[ -f {quoted} ] && . {quoted} >/dev/null 2>&1 || true")
        else:
            # ZDOTDIR 是 zsh 自己找 rc 的依据，优先用它，找不到才退回 $HOME。
            lines.append('ZD="${ZDOTDIR:-$HOME}"')
            for name in cls.RC_FILE_NAMES:
                lines.append(f'[ -f "$ZD/{name}" ] && . "$ZD/{name}" >/dev/null 2>&1 || true')

        # 兜底 PATH。放在 source 之后**前置**到 PATH 前面——用户显式指定的
        # 版本优先，同时 brew 没配进 rc 时的常见前缀也不会漏掉。
        lines.append('case ":$PATH:" in')
        for entry in fallback_path_entries():
            lines.append(f'  *":{entry}:"*) ;;')
            lines.append(f'  *) PATH="{entry}:$PATH" ;;')
        lines.append("esac")
        lines.append("export PATH")
        lines.append("exec /usr/bin/env -0")
        return "\n".join(lines)

    @classmethod
    def parse(cls, output: str, custom_rc_path: str = "") -> ShellEnvironment | None:
        """解析 ``env -0`` 的输出。"""
        variables: dict[str, str] = {}

        for entry in output.split("\0"):
            if not entry:
                continue
            key, separator, value = entry.partition("=")
            if not separator or not key:
                continue
            if key in cls.DROPPED_KEYS:
                continue
            variables[key] = value

        path = variables.get("PATH", "")
        if not path:
            return None

        # HOME 必须保留：很多 npm 脚本靠它找 ~/.npmrc 和缓存
        variables.setdefault("HOME", os.path.expanduser("~"))

        return ShellEnvironment(
            variables=variables,
            rc_files=cls.existing_rc_files(custom_rc_path),
            path=path,
        )

    @classmethod
    def existing_rc_files(cls, custom_rc_path: str = "") -> list[str]:
        """列出真正被 source 的 rc 文件。

        用于在界面上如实告诉用户「我读的是哪几个文件」。
        """
        if custom_rc_path:
            return [custom_rc_path] if os.path.isfile(custom_rc_path) else []

        zdot = os.environ.get("ZDOTDIR") or os.path.expanduser("~")
        return [
            str(Path(zdot) / name)
            for name in cls.RC_FILE_NAMES
            if os.path.isfile(Path(zdot) / name)
        ]

    @staticmethod
    def shell_quote(value: str) -> str:
        """单引号包裹，内部的单引号按 POSIX 惯例转义。

        rc 路径来自用户输入，拼进脚本前必须过这一层，否则路径里的引号和
        ``$`` 会被 shell 展开，等于给了自己一个命令注入面。
        """
        return "'" + value.replace("'", "'\\''") + "'"
