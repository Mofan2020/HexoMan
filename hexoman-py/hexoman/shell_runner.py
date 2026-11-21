"""统一的子进程执行器 + 日志面板。

对应 Swift 侧的 ``ShellRunner.swift``。:mod:`hexoman.process` 负责「怎么把
一个命令跑起来」，这里负责 **Swift 版 ShellRunner 的另一半**：

- 把 stdout / stderr 拆成一行行，剥掉 ANSI 颜色码
- 维护一份有上限的日志（长时间跑 ``hexo server`` 不该把内存撑爆）
- 管理长驻任务（启动 / 停止 / 全部停止）

## 为什么日志要有上限

``hexo server`` 开了就不关，日志能刷到几万行。没有上限的话跑一天就吃掉
几百 MB。4000 行足够覆盖用户会往上翻的范围。
"""

from __future__ import annotations

import re
import threading
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Mapping, Sequence

from .process import CommandRunner, ProcessResult

__all__ = ["LogLine", "RunningJob", "ShellRunner", "strip_ansi", "display_command"]

#: 日志保留上限。
MAX_LINES = 4000

#: ANSI 转义序列。比 Swift 版的「遇到字母就结束」更准——后者会把
#: ``\x1b[31m红\x1b[0m`` 里的中文一起吃进状态机。
_ANSI_PATTERN = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")


def strip_ansi(text: str) -> str:
    """去掉 ANSI 转义序列。

    stdout / stderr 里的颜色码在界面里就是乱码，入库前先剥掉。
    """
    if "\x1b" not in text:
        return text
    return _ANSI_PATTERN.sub("", text)


def display_command(executable: str, arguments: Sequence[str]) -> str:
    """拼出给人看的命令行，方便对着终端复现。"""
    parts = [executable] + list(arguments)
    return "$ " + " ".join(f'"{part}"' if " " in part else part for part in parts)


@dataclass
class LogLine:
    """界面里的一行日志。"""

    text: str
    #: stdout / stderr / meta
    stream: str = "stdout"
    timestamp: float = field(default_factory=time.time)

    @property
    def display_text(self) -> str:
        return strip_ansi(self.text)

    def to_dict(self) -> dict[str, Any]:
        return {
            "text": self.display_text,
            "stream": self.stream,
            "timestamp": self.timestamp,
        }


@dataclass
class RunningJob:
    """长驻任务的句柄。``hexo server`` 这类不会自己退出的命令靠它停止。"""

    id: str
    label: str
    process: Any
    started_at: float = field(default_factory=time.time)

    @property
    def is_running(self) -> bool:
        return self.process is not None and self.process.poll() is None


class ShellRunner:
    """所有外部命令的统一入口。"""

    def __init__(
        self,
        runner: CommandRunner | None = None,
        environment: Mapping[str, str] | None = None,
        max_lines: int = MAX_LINES,
    ) -> None:
        self.runner = runner or CommandRunner()
        self.environment = dict(environment) if environment else None
        self.max_lines = max_lines

        self._lock = threading.Lock()
        self._lines: list[LogLine] = []
        self._jobs: dict[str, RunningJob] = {}

    # -- 日志 ---------------------------------------------------------

    @property
    def lines(self) -> list[LogLine]:
        with self._lock:
            return list(self._lines)

    def emit(self, text: str, stream: str = "meta") -> None:
        """加一行日志。"""
        with self._lock:
            self._lines.append(LogLine(text=str(text), stream=stream))
            if len(self._lines) > self.max_lines:
                del self._lines[: len(self._lines) - self.max_lines]

    def clear(self) -> None:
        with self._lock:
            self._lines.clear()

    def log_dicts(self) -> list[dict[str, Any]]:
        return [line.to_dict() for line in self.lines]

    # -- 一次性命令 ---------------------------------------------------

    def run(
        self,
        label: str,
        executable: str,
        arguments: Sequence[str],
        working_directory: str = "",
    ) -> ProcessResult:
        """执行一次性命令，跑完即返回。"""
        self.emit(display_command(executable, arguments), "meta")

        result = self.runner.run(
            [executable] + list(arguments),
            cwd=working_directory or None,
            env=self.environment,
        )

        for line in (result.output or "").splitlines():
            if line.strip():
                self.emit(strip_ansi(line), "stdout" if result.success else "stderr")

        self.emit(f"退出码 {result.exit_code}", "meta")
        return result

    # -- 长驻任务 -----------------------------------------------------

    def start_service(
        self,
        label: str,
        executable: str,
        arguments: Sequence[str],
        working_directory: str = "",
    ) -> str:
        """启动长驻任务（如 ``hexo server``），返回句柄 id。

        失败返回空字符串——预览起不来是可恢复的状态，不该抛异常。
        """
        self.emit(display_command(executable, arguments), "meta")

        process = self.runner.spawn(
            [executable] + list(arguments),
            cwd=working_directory or None,
            env=self.environment,
        )
        if process is None:
            self.emit("启动失败：无法创建进程", "stderr")
            return ""

        job_id = f"{label}-{uuid.uuid4().hex[:8]}"
        job = RunningJob(id=job_id, label=label, process=process)

        with self._lock:
            self._jobs[job_id] = job

        self.emit(f"▶ {label} 已启动（pid {getattr(process, 'pid', '?')}）", "meta")
        return job_id

    @property
    def jobs(self) -> dict[str, RunningJob]:
        with self._lock:
            return dict(self._jobs)

    def stop(self, job_id: str) -> None:
        """停止某个长驻任务。"""
        with self._lock:
            job = self._jobs.pop(job_id, None)
        if job is not None:
            self._terminate(job)

    def stop_all(self) -> None:
        with self._lock:
            jobs = list(self._jobs.values())
            self._jobs.clear()
        for job in jobs:
            self._terminate(job)

    def _terminate(self, job: RunningJob) -> None:
        """先 terminate 再给 1.5 秒体面退出，不行就强杀。

        ``hexo server`` 会派生子进程，只 terminate 父进程经常留一堆孤儿。
        """
        process = job.process
        if process is None or process.poll() is not None:
            self.emit(f"■ {job.label} 已停止", "meta")
            return

        try:
            process.terminate()
            process.wait(timeout=1.5)
        except Exception:
            try:
                process.kill()
            except OSError:
                pass

        self.emit(f"■ {job.label} 已停止", "meta")

    # -- 文本工具 -----------------------------------------------------

    @staticmethod
    def split_lines(chunk: str) -> list[str]:
        """把一段输出切成完整行。空行丢掉。"""
        return [
            line[:-1] if line.endswith("\r") else line
            for line in chunk.split("\n")
            if line.strip()
        ]
