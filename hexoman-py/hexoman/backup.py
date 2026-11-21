"""站点备份与恢复。

对应 Swift 侧的 ``BackupManager.swift``。只备份「内容 + 配置」，不备份
node_modules / public 这种可重建的东西。

## 为什么不能直接 ``zip -r 站点目录 -x "*/node_modules/*"``

那是 Swift 版的原实现。看着能排除，实际**根本没排掉**——实测一个 152MB
的站点，压缩完 80MB、11581 个文件，里面 node_modules 有 11212 个。

两个原因叠加：

1. Info-ZIP 的 ``-x`` 模式在带斜杠时按整条路径匹配，``*/node_modules/*``
   匹配不上 zip 实际存储的 ``./node_modules/...``。
2. 更要命的是 ``-x`` 只在**已经遍历到**之后才丢弃，zip 依然会走进
   node_modules 和 .git 把几万个文件 stat 一遍——所以它还慢。

现在的做法是**自己先遍历、按目录名剪枝**，再把文件清单喂给压缩器。
剪枝发生在遍历阶段，node_modules 连 stat 都不会发生。同一站点实测：
4.6s / 80MB → 0.05s / 220KB（快 90 倍，小 360 倍）。

## 与 Swift 版的差异：用 ``zipfile`` 而不是外部 ``zip`` 命令

Windows 上默认没有 ``zip`` / ``unzip`` 命令。用标准库的 :mod:`zipfile`
两个平台都能跑，也不用管「子进程 stdout/stderr 谁先写满缓冲区」那类坑。
"""

from __future__ import annotations

import datetime as _dt
import os
import shutil
import uuid
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .model import Site
from .system_integration import app_data_directory

__all__ = ["BackupEntry", "BackupPlan", "BackupPolicy", "BackupManager", "BackupError"]


class BackupError(Exception):
    """备份 / 恢复出错。"""

    def __init__(self, code: str, message: str = "") -> None:
        super().__init__(message or code)
        self.code = code
        self.message = message or code


@dataclass
class BackupPolicy:
    """备份范围策略。"""

    #: 按目录名剪枝。目录**任意层级**命中即整棵子树跳过。
    excluded_directories: frozenset[str] = frozenset()
    #: 按文件名丢弃的文件。
    excluded_files: frozenset[str] = frozenset()
    #: 按后缀丢弃的文件。
    excluded_extensions: frozenset[str] = frozenset()


#: 默认策略：可重建 / 可重新拉取，且体积最大的那几项。
DEFAULT_POLICY = BackupPolicy(
    excluded_directories=frozenset(
        {
            "node_modules",  # 86MB / 11000+ 文件，npm i 就能回来
            ".git",  # 65MB，能重新 clone 或 git init
            "public",  # hexo generate 的产物
            ".wrangler",  # 本地调试缓存
            ".cache",
            "coverage",
            ".deploy",
            ".sass-cache",
        }
    ),
    excluded_files=frozenset({".DS_Store", "package-lock.json.bak"}),
    excluded_extensions=frozenset({"log", "zip", "swp"}),
)

#: 包含版本库和生成产物的大备份（用户明确要求时才用）。
FULL_POLICY = BackupPolicy(
    excluded_directories=frozenset({"node_modules"}),
    excluded_files=frozenset({".DS_Store"}),
    excluded_extensions=frozenset({"log", "swp"}),
)


@dataclass
class BackupPlan:
    """备份前先统计一遍，让界面上能立刻显示「将要打包多少个文件」。"""

    included_count: int = 0
    excluded_count: int = 0
    approximate_bytes: int = 0

    @property
    def included_description(self) -> str:
        return format_size(self.approximate_bytes)

    def to_dict(self) -> dict[str, Any]:
        return {
            "includedCount": self.included_count,
            "excludedCount": self.excluded_count,
            "approximateBytes": self.approximate_bytes,
            "includedDescription": self.included_description,
        }


@dataclass
class BackupEntry:
    """一个备份文件。"""

    #: 稳定 id 用文件路径（Swift 用随机 UUID，重启后列表项会全部失效）
    path: str
    site_path: str = ""
    date: float = 0.0
    size: int = 0
    file_count: int = 0

    @property
    def id(self) -> str:
        return self.path

    @property
    def display_name(self) -> str:
        if not self.date:
            return os.path.basename(self.path)
        return _dt.datetime.fromtimestamp(self.date).strftime("%Y-%m-%d %H:%M")

    @property
    def formatted_size(self) -> str:
        return format_size(self.size)

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "path": self.path,
            "sitePath": self.site_path,
            "date": self.date,
            "displayName": self.display_name,
            "size": self.size,
            "formattedSize": self.formatted_size,
            "fileCount": self.file_count,
        }


def format_size(size: int) -> str:
    if size < 1024:
        return f"{size} B"
    if size < 1024 * 1024:
        return f"{size / 1024:.1f} KB"
    return f"{size / 1024 / 1024:.1f} MB"


class BackupManager:
    """站点备份。"""

    # -- 目录 ---------------------------------------------------------

    @staticmethod
    def backup_directory(directory: str = "") -> Path:
        """备份目录。

        默认跟配置文件放在一起，不污染用户 home。``directory`` 可以显式指定——
        单元测试必须用临时目录，绝不写进用户真实的备份夹。
        """
        target = Path(directory) if directory else Path(app_data_directory()) / "Backups"
        target.mkdir(parents=True, exist_ok=True)
        return target

    # -- 遍历 ---------------------------------------------------------

    @staticmethod
    def collect_files(root: str, policy: BackupPolicy = DEFAULT_POLICY) -> tuple[list[str], BackupPlan]:
        """按策略收集要打包的相对路径。

        剪枝在**遍历时**完成：命中排除目录直接跳过整棵子树，不再 stat 里面的
        任何东西。这是速度提升的全部来源。

        排除目录按**路径任意一段 component** 判断——不只是当层目录名。旧版本
        只看当层名字，于是 ``themes/landscape/node_modules`` 这种嵌套的排除
        目录照样会被 stat 进去；一旦用户装了带 node_modules 的主题，第一次
        进备份页时 plan 计算就会卡几十秒到几分钟。
        """
        root_path = Path(root)
        files: list[str] = []
        excluded = 0
        total_bytes = 0

        if not root_path.is_dir():
            return files, BackupPlan()

        for directory, subdirectories, filenames in os.walk(root_path):
            # 按目录名剪枝：命中就整棵子树都不进去
            kept: list[str] = []
            for name in subdirectories:
                if name in policy.excluded_directories:
                    excluded += 1
                    continue
                kept.append(name)
            subdirectories[:] = kept

            for filename in filenames:
                if filename in policy.excluded_files:
                    excluded += 1
                    continue

                extension = os.path.splitext(filename)[1].lstrip(".").lower()
                if extension in policy.excluded_extensions:
                    excluded += 1
                    continue

                full = Path(directory) / filename
                try:
                    size = full.stat().st_size
                except OSError:
                    # 读不到就跳过，不让整个备份失败
                    continue

                relative = full.relative_to(root_path).as_posix()
                if not relative:
                    continue

                files.append(relative)
                total_bytes += size

        files.sort()
        return files, BackupPlan(
            included_count=len(files),
            excluded_count=excluded,
            approximate_bytes=total_bytes,
        )

    @staticmethod
    def plan(site: Site, policy: BackupPolicy = DEFAULT_POLICY) -> BackupPlan:
        """预览将要打包的内容（不写文件），供界面在点按钮前先告知范围。"""
        return BackupManager.collect_files(site.path, policy)[1]

    # -- 创建 ---------------------------------------------------------

    @staticmethod
    def create_backup(
        site: Site,
        policy: BackupPolicy = DEFAULT_POLICY,
        directory: str = "",
    ) -> BackupEntry:
        """创建备份。"""
        files, plan = BackupManager.collect_files(site.path, policy)
        if not files:
            raise BackupError(
                "nothingToBackup",
                "这个站点里没有找到可备份的内容。确认选对了站点目录。",
            )

        timestamp = _dt.datetime.now()
        backup_name = f"{site.folder_name}-{timestamp.strftime('%Y%m%d-%H%M%S')}.zip"
        destination = BackupManager.backup_directory(directory) / backup_name

        # 同一秒内连点两次会撞名，加个后缀
        if destination.exists():
            destination = destination.with_name(
                f"{destination.stem}-{uuid.uuid4().hex[:6]}.zip"
            )

        root_path = Path(site.path)
        try:
            with zipfile.ZipFile(
                destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6
            ) as archive:
                for relative in files:
                    archive.write(root_path / relative, arcname=relative)
        except (OSError, zipfile.BadZipFile) as error:
            # 压到一半失败会留下半个损坏的 zip，必须删掉，
            # 否则它会被当成一个正常备份列在列表里，恢复时才炸。
            destination.unlink(missing_ok=True)
            raise BackupError("zipFailed", f"备份压缩失败：{error}") from error

        try:
            size = destination.stat().st_size
        except OSError:
            size = 0

        return BackupEntry(
            path=str(destination),
            site_path=site.path,
            date=timestamp.timestamp(),
            size=size,
            # 清单是我们自己收集的，比重新数一遍 zip 里的条目准，也省一次解包
            file_count=plan.included_count,
        )

    # -- 列出 ---------------------------------------------------------

    @staticmethod
    def list_backups(site_path: str, directory: str = "") -> list[BackupEntry]:
        """列出某站点的所有备份。"""
        site_name = os.path.basename(site_path.rstrip("/\\"))
        backup_root = BackupManager.backup_directory(directory)

        try:
            entries = sorted(backup_root.iterdir())
        except OSError:
            return []

        results: list[BackupEntry] = []
        for path in entries:
            if not path.is_file() or path.suffix.lower() != ".zip":
                continue
            if not path.name.startswith(site_name + "-"):
                continue
            try:
                stat = path.stat()
            except OSError:
                continue
            results.append(
                BackupEntry(
                    path=str(path),
                    site_path=site_path,
                    date=stat.st_mtime,
                    size=stat.st_size,
                )
            )

        results.sort(key=lambda item: item.date, reverse=True)
        return results

    # -- 恢复 ---------------------------------------------------------

    @staticmethod
    def restore_backup(entry: BackupEntry, site_path: str, directory: str = "") -> None:
        """恢复备份。

        归档里的条目是相对站点根目录的（``source/…``、``_config.yml`` …），
        解压后**直接落在临时目录下**，并没有多包一层站点名目录。

        恢复只覆盖归档里有的文件，**不删**站点上多出来的文件——删掉用户
        后来新建、但没进这个备份的东西，比恢复失败更糟。
        """
        import tempfile

        site_root = Path(site_path)
        if not site_root.is_dir():
            raise BackupError("siteMissing", "站点目录不存在，无法恢复。")

        temp_dir = Path(tempfile.mkdtemp(prefix="hexoman-restore-"))
        try:
            with zipfile.ZipFile(entry.path) as archive:
                names = archive.namelist()
                if not names:
                    raise BackupError("invalidBackup", "这个备份文件是空的或已损坏，无法恢复。")
                archive.extractall(temp_dir)
        except zipfile.BadZipFile as error:
            shutil.rmtree(temp_dir, ignore_errors=True)
            raise BackupError("unzipFailed", f"备份解压失败：{error}") from error
        except OSError as error:
            shutil.rmtree(temp_dir, ignore_errors=True)
            raise BackupError("unzipFailed", f"备份解压失败：{error}") from error

        try:
            for item in sorted(temp_dir.iterdir()):
                target = site_root / item.name
                if item.is_dir():
                    shutil.copytree(item, target, dirs_exist_ok=True)
                else:
                    if target.exists():
                        target.unlink()
                    shutil.move(str(item), str(target))
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)

    # -- 删除 ---------------------------------------------------------

    @staticmethod
    def delete_backup(entry: BackupEntry) -> None:
        """删除备份文件。"""
        try:
            Path(entry.path).unlink(missing_ok=True)
        except OSError as error:
            raise BackupError("deleteFailed", f"删除失败：{error}") from error
