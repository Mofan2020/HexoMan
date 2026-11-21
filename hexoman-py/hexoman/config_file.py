"""站点配置文件（``_config.yml`` 及主题配置）的读写。

对应 Swift 侧的 ``ConfigFile.swift``。

## 为什么要单独一层

Hexo 的站点有**两份**配置：

- ``_config.yml``——站点配置，Hexo 自己读的键在这里
- ``_config.<主题>.yml``——主题配置，主题**优先读自己这份**

用户几乎只改第一份（它就叫「站点配置」，最显眼），但改完头像发现站点没反应，
是因为主题那份盖住了。这个错位由 :mod:`hexoman.config_sync` 处理，
这里只管「把文件读出来 / 写回去」。

## 与 Swift 版的差异

Swift 版写完会**重新读一遍**核对内容是否一致，不一致就报错。
这里保留这个行为（``save`` 返回布尔），因为「显示已保存但文件没落盘」
是最难排查的一类问题。
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .model import Site, read_text
from .yaml_path import YamlDocument

__all__ = ["ConfigFile", "ConfigStore", "ConfigStoreError"]


class ConfigStoreError(Exception):
    """配置文件操作出错。"""

    def __init__(self, code: str, message: str = "") -> None:
        super().__init__(message or code)
        self.code = code
        self.message = message or code


@dataclass
class ConfigFile:
    """一个可编辑的配置文件。"""

    #: 绝对路径
    path: str
    #: 展示名
    name: str = ""
    #: 一句话说明它管什么
    subtitle: str = ""
    #: 当前编辑器里的内容
    contents: str = ""
    #: 磁盘上的原始内容，用来判断有没有改过
    original_contents: str = field(default="", repr=False)

    @property
    def id(self) -> str:
        return self.path

    @property
    def is_modified(self) -> bool:
        return self.contents != self.original_contents

    @property
    def top_level_keys(self) -> list[str]:
        """顶层配置键，编辑器侧栏用来快速跳转。"""
        document = YamlDocument(self.contents)
        keys = document.top_level_keys()
        if keys:
            return sorted(keys)
        # 解析失败时退回逐行扫，至少能列出键名
        from .yamlutil import parse_top_level_scalars

        return sorted(parse_top_level_scalars(self.contents).keys())

    def to_dict(self) -> dict[str, Any]:
        return {
            "path": self.path,
            "name": self.name,
            "subtitle": self.subtitle,
            "contents": self.contents,
            "isModified": self.is_modified,
            "topLevelKeys": self.top_level_keys,
        }


class ConfigStore:
    """站点根目录下所有 ``_config*.yml``。"""

    @staticmethod
    def list(site: Site) -> list[ConfigFile]:
        """列出站点配置。主配置排第一，主题配置按名字排。"""
        root = Path(site.path)
        try:
            entries = sorted(os.listdir(root))
        except OSError:
            return []

        candidates = [
            name
            for name in entries
            if name.startswith("_config") and name.endswith(".yml")
        ]
        # `_config.yml` 永远第一
        candidates.sort(key=lambda name: (name != "_config.yml", name))

        files: list[ConfigFile] = []
        for filename in candidates:
            path = root / filename
            contents = read_text(path)
            if contents is None:
                continue
            files.append(
                ConfigFile(
                    path=str(path),
                    name=filename,
                    contents=contents,
                    original_contents=contents,
                    subtitle=ConfigStore.describe(filename),
                )
            )
        return files

    @staticmethod
    def describe(filename: str) -> str:
        """文件名 → 人话解释。"""
        if filename == "_config.yml":
            return "站点主配置"

        theme = filename.replace("_config.", "").replace(".yml", "")
        return f"主题配置（{theme}）"

    @staticmethod
    def load(path: str) -> ConfigFile:
        """读一个文件。"""
        contents = read_text(path) or ""
        return ConfigFile(
            path=path,
            name=os.path.basename(path),
            contents=contents,
            original_contents=contents,
            subtitle=ConfigStore.describe(os.path.basename(path)),
        )

    @staticmethod
    def save(config: ConfigFile) -> None:
        """写回磁盘。写成功后同步 baseline，避免「已保存」却还显示未保存。

        写完**重新读一遍核对**：内容与预期不符就报错。宁可让用户看到
        「保存失败」，也不要让界面显示已保存而磁盘上是旧内容。
        """
        directory = os.path.dirname(config.path)
        if directory:
            Path(directory).mkdir(parents=True, exist_ok=True)

        target = Path(config.path)
        temp = target.with_name(target.name + ".hexoman-tmp")
        try:
            temp.write_text(config.contents, encoding="utf-8")
            os.replace(temp, target)
        except OSError as error:
            temp.unlink(missing_ok=True)
            raise ConfigStoreError("writeFailed", f"写入失败：{error}") from error

        saved = read_text(target)
        if saved != config.contents:
            raise ConfigStoreError(
                "writeVerificationFailed",
                f"文件写入验证失败：{config.path} 内容与预期不符",
            )

    @staticmethod
    def mark_saved(config: ConfigFile) -> ConfigFile:
        """存盘后把新内容设为基准，使 ``is_modified`` 归零。"""
        updated = ConfigFile(
            path=config.path,
            name=config.name,
            subtitle=config.subtitle,
            contents=config.contents,
            original_contents=config.contents,
        )
        return updated
