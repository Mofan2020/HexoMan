"""git 常用动作。

对应 Swift 侧的 ``GitService.swift``。命令都带 ``-C <site>``，
不切用户当前目录。
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Any

from .model import Site
from .process import CommandRunner, ProcessResult

__all__ = ["GitCommit", "GitStatus", "GitService", "parse_porcelain_v2"]


@dataclass
class GitCommit:
    """一条提交记录。"""

    short_hash: str
    subject: str
    author: str = ""
    date: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "shortHash": self.short_hash,
            "subject": self.subject,
            "author": self.author,
            "date": self.date,
        }


@dataclass
class GitStatus:
    """仓库当前状态。"""

    branch: str = ""
    upstream: str = ""
    ahead: int = 0
    behind: int = 0
    staged: list[str] = field(default_factory=list)
    modified: list[str] = field(default_factory=list)
    untracked: list[str] = field(default_factory=list)
    conflicted: list[str] = field(default_factory=list)

    @property
    def is_clean(self) -> bool:
        return not (
            self.staged or self.modified or self.untracked or self.conflicted
        )

    @property
    def change_count(self) -> int:
        return (
            len(self.staged)
            + len(self.modified)
            + len(self.untracked)
            + len(self.conflicted)
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "branch": self.branch,
            "upstream": self.upstream,
            "ahead": self.ahead,
            "behind": self.behind,
            "staged": list(self.staged),
            "modified": list(self.modified),
            "untracked": list(self.untracked),
            "conflicted": list(self.conflicted),
            "isClean": self.is_clean,
            "changeCount": self.change_count,
        }


def parse_porcelain_v2(output: str) -> GitStatus:
    """解析 ``git status --porcelain=v2 --branch`` 的输出。

    用 v2 格式是因为字段位置固定，比 v1 的 ``XY path`` 更好解析。
    """
    status = GitStatus()

    for line in output.splitlines():
        # 头部三行形如 ``# branch.head main``。
        # 必须先按已知前缀切掉再取值——按第一个空格切会把「branch.head」
        # 当成分支名。
        if line.startswith("# branch.head"):
            value = _value_after("# branch.head", line)
            status.branch = "detached" if value == "(detached)" else value
            continue
        if line.startswith("# branch.upstream"):
            status.upstream = _value_after("# branch.upstream", line)
            continue
        if line.startswith("# branch.ab"):
            # 形如 ``# branch.ab +1 -2``，分别是 ahead / behind
            for token in _value_after("# branch.ab", line).split():
                if token.startswith("+"):
                    status.ahead = _to_int(token[1:])
                elif token.startswith("-"):
                    status.behind = _to_int(token[1:])
            continue

        if not line or line.startswith("#"):
            continue

        # 条目按类型有固定的字段数，路径总是在最后一格。
        #
        #   1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
        #   2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path><TAB><orig>
        #   u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
        #   ? <path>
        #
        # 路径里可以带空格，所以只能按「前 N 格是固定字段」切，不能 split 全部。
        marker = line[0]

        if marker == "?":
            status.untracked.append(line[2:].strip())
            continue

        if marker == "!":
            # 忽略的文件，不进状态列表
            continue

        if marker == "u":
            fields = line.split(" ", 10)
            if len(fields) < 11:
                continue
            status.conflicted.append(fields[10].strip())
            continue

        if marker in ("1", "2"):
            # 重命名条目多一格 ``<X><score>``，并且有两个路径（用 TAB 分隔）
            limit = 9 if marker == "2" else 8
            fields = line.split(" ", limit)
            if len(fields) <= limit:
                continue

            xy = fields[1]
            if len(xy) < 2:
                continue

            path = fields[limit].strip()
            # 重命名：``new.txt\told.txt``，只取新路径
            if "\t" in path:
                path = path.split("\t", 1)[0]

            # X 是暂存区状态，Y 是工作区状态
            if xy[0] != ".":
                status.staged.append(path)
            if xy[1] != ".":
                status.modified.append(path)

    return status


def _value_after(prefix: str, line: str) -> str:
    if not line.startswith(prefix):
        return ""
    return line[len(prefix) :].strip()


def _to_int(text: str) -> int:
    try:
        return int(text)
    except ValueError:
        return 0


class GitService:
    """git 命令封装。"""

    def __init__(self, site: Site, runner: CommandRunner | None = None) -> None:
        self.site = site
        self.runner = runner or CommandRunner()

    def _run(self, args: list[str]) -> ProcessResult:
        return self.runner.run(["git", "-C", self.site.path] + args, cwd=self.site.path)

    def status(self) -> GitStatus | None:
        """读一次状态。站点不是 git 仓库时返回 ``None``。"""
        result = self._run(["status", "--porcelain=v2", "--branch"])
        if not result.success:
            return None
        return parse_porcelain_v2(result.output)

    def log(self, limit: int = 20) -> list[GitCommit]:
        """读最近提交。"""
        result = self._run(
            [
                "log",
                f"-{limit}",
                "--pretty=format:%h%x09%an%x09%ad%x09%s",
                "--date=short",
            ]
        )
        if not result.success:
            return []

        commits: list[GitCommit] = []
        for line in result.output.splitlines():
            fields = line.split("\t")
            if len(fields) < 4:
                continue
            commits.append(
                GitCommit(
                    short_hash=fields[0],
                    author=fields[1],
                    date=fields[2],
                    subject=fields[3],
                )
            )
        return commits

    def commit(self, message: str) -> ProcessResult:
        """暂存全部改动后提交。"""
        trimmed = message.strip()
        if not trimmed:
            return ProcessResult(exit_code=1, output="提交信息为空")

        add = self._run(["add", "-A"])
        if not add.success:
            return add

        return self._run(["commit", "-m", trimmed])

    def push(self) -> ProcessResult:
        return self._run(["push"])

    def pull(self) -> ProcessResult:
        return self._run(["pull", "--rebase"])

    def remotes(self) -> list[str]:
        """列出远端。

        纯文本解析 ``.git/config``，不跑子进程——总览页要立刻显示。
        """
        config_file = os.path.join(self.site.path, ".git", "config")
        try:
            with open(config_file, encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError:
            return []

        remotes: list[str] = []
        current = ""

        for raw_line in text.splitlines():
            line = raw_line.strip()
            if line.startswith("[remote"):
                name = line.replace("[remote", "").replace("]", "").strip().strip('"')
                current = name.split(" ")[0] if name else ""
                continue
            if current and line.startswith("url"):
                _, _, value = line.partition("=")
                remotes.append(f"{current} → {value.strip()}")
                current = ""

        return remotes
