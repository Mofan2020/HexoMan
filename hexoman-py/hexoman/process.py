"""子进程执行。

对应 Swift 侧的 ``ShellRunner.swift``，但拆得更细：这里只管「怎么把一个
命令跑起来并拿到输出」，日志聚合、状态面板那些留给上层。

**平台差异全部集中在本文件**，其它模块不许自己拼 ``subprocess``。
"""

from __future__ import annotations

import os
import shutil
import subprocess
from dataclasses import dataclass
from typing import Any, Mapping, Sequence

__all__ = ["ProcessResult", "CommandRunner", "NullCommandRunner"]


@dataclass
class ProcessResult:
    """一次执行的结果。"""

    exit_code: int
    output: str

    @property
    def success(self) -> bool:
        return self.exit_code == 0

    @property
    def error_summary(self) -> str | None:
        """失败时给出最后几行有效输出，给界面弹错误用。"""
        if self.success:
            return None
        lines = [line.strip() for line in self.output.splitlines() if line.strip()]
        if not lines:
            return None
        return "\n".join(lines[-5:])


class CommandRunner:
    """跑外部命令。

    用 ``shell=False`` + 参数数组：站点路径里可能有空格，用 ``shell=True``
    拼字符串会被 shell 解释成两条命令。
    """

    def __init__(self, cwd: str | None = None, env: Mapping[str, str] | None = None) -> None:
        self.cwd = cwd
        self.env = dict(env) if env else None

    def run(
        self,
        args: Sequence[str],
        cwd: str | None = None,
        timeout: float | None = 600.0,
        env: Mapping[str, str] | None = None,
    ) -> ProcessResult:
        """执行命令并等它结束。

        ``env`` 给了就用它作为**完整**环境（不与当前环境合并）——传的是
        「用户真实 shell 环境」时就是这个语义。
        """
        if not args:
            return ProcessResult(exit_code=-1, output="空命令")

        try:
            completed = subprocess.run(  # noqa: S603
                list(args),
                cwd=cwd or self.cwd,
                env=dict(env) if env is not None else self.env,
                capture_output=True,
                text=True,
                timeout=timeout,
                shell=False,
            )
        except FileNotFoundError:
            return ProcessResult(exit_code=127, output=f"找不到命令：{args[0]}")
        except subprocess.TimeoutExpired:
            return ProcessResult(exit_code=124, output=f"命令超时：{' '.join(args)}")
        except OSError as error:
            return ProcessResult(exit_code=1, output=str(error))

        # stdout 与 stderr 合并：用户看到的是「命令干了什么」，分开看反而费解
        output = (completed.stdout or "") + (completed.stderr or "")
        return ProcessResult(exit_code=completed.returncode, output=output)

    def spawn(
        self,
        args: Sequence[str],
        cwd: str | None = None,
        env: Mapping[str, str] | None = None,
    ) -> subprocess.Popen[str] | None:
        """启动长驻进程（如 ``hexo server``），不等待结束。

        失败返回 ``None`` 而不是抛异常：预览服务起不来是一个可恢复的状态，
        不是程序崩溃。
        """
        if not args:
            return None

        try:
            return subprocess.Popen(  # noqa: S603
                list(args),
                cwd=cwd or self.cwd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                shell=False,
                env=dict(env) if env is not None else self.env,
            )
        except (FileNotFoundError, OSError):
            return None

    def which(self, name: str) -> str | None:
        """在 PATH 里找可执行文件。"""
        return shutil.which(name)

    def is_executable(self, path: str) -> bool:
        """路径是不是可执行文件。

        Windows 上 ``node_modules/.bin/hexo`` 是个 ``.cmd`` 脚本而不是
        ELF 可执行文件，用 ``os.access(X_OK)`` 判断在 Windows 上不成立，
        所以额外看扩展名。
        """
        if not path or not os.path.isfile(path):
            return False
        if os.access(path, os.X_OK):
            return True
        return os.name == "nt" and path.lower().endswith((".cmd", ".bat", ".exe"))


class NullCommandRunner(CommandRunner):
    """什么都不做的 runner。

    单元测试用它替代真命令：测试里绝不允许真的跑 ``hexo`` 或 ``git``——
    一来慢，二来会改用户仓库的状态。
    """

    def __init__(self, result: ProcessResult | None = None) -> None:
        super().__init__()
        self.result = result or ProcessResult(exit_code=0, output="")
        self.calls: list[dict[str, Any]] = []

    def run(
        self,
        args: Sequence[str],
        cwd: str | None = None,
        timeout: float | None = 600.0,
        env: Mapping[str, str] | None = None,
    ) -> ProcessResult:
        self.calls.append({"args": list(args), "cwd": cwd})
        return self.result

    def spawn(
        self,
        args: Sequence[str],
        cwd: str | None = None,
        env: Mapping[str, str] | None = None,
    ) -> subprocess.Popen[str] | None:
        self.calls.append({"args": list(args), "cwd": cwd, "spawn": True})
        return None

    def which(self, name: str) -> str | None:
        self.calls.append({"which": name})
        return None

    def is_executable(self, path: str) -> bool:
        return False
