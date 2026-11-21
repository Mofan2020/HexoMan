"""站点管理：判定、探测、增删切换。

对应 Swift 侧的 ``HexoSite.swift``（``SiteProbe``）与
``HexoManModel.swift`` 里的站点管理部分。
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

from . import yamlutil
from .model import Site, SiteInfo, normalize_path, now_timestamp
from .posts import load_posts

__all__ = [
    "is_hexo_site",
    "inspect_site",
    "resolve_paths",
    "add_site",
    "remove_site",
    "select_site",
    "sort_sites",
    "SiteList",
]


def is_hexo_site(path: str) -> bool:
    """判断目录是不是一个 Hexo 站点。

    判定标准：有 ``package.json``（且声明了 hexo 依赖）+ 有 ``_config.yml``。

    hexo 的声明既可能在 ``dependencies`` 也可能在 ``devDependencies``，
    两处都认；解析不了 JSON 时退回文本匹配，避免因为一个逗号漏判。
    """
    if not path:
        return False

    package_file = Path(path) / "package.json"
    config_file = Path(path) / "_config.yml"

    if not package_file.is_file() or not config_file.is_file():
        return False

    try:
        package = json.loads(package_file.read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeDecodeError):
        try:
            text = package_file.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return False
        return '"hexo"' in text

    if not isinstance(package, dict):
        return False

    for key in ("dependencies", "devDependencies"):
        deps = package.get(key)
        if isinstance(deps, dict) and "hexo" in deps:
            return True

    return False


def resolve_paths(site: Site) -> tuple[str, str]:
    """解析站点实际用的源码目录和文章目录。

    读 ``_config.yml`` 的 ``source_dir`` / ``new_dir``。读不到就退回
    ``source`` / ``source/_posts``，**绝不让探测失败** —— Hexo 允许把
    目录改成任意值，硬编码路径会让定制过的站点显示成零篇文章。
    """
    source = os.path.join(site.path, "source")
    new_dir = "_posts"

    text = _read_config(site.path)
    if text:
        scalars = yamlutil.load_yaml_mapping(text)
        raw_source = str(scalars.get("source_dir") or "").strip()
        raw_new = str(scalars.get("new_dir") or "").strip()
        if raw_source:
            source = _absolute(raw_source, site.path)
        if raw_new:
            new_dir = raw_new

    posts = _absolute(new_dir, source)
    return source, posts


def _absolute(value: str, base: str) -> str:
    """把相对路径挂到 base 下；``~`` / 绝对路径自己展开。"""
    if value.startswith("~"):
        return os.path.expanduser(value)
    if os.path.isabs(value):
        return os.path.normpath(value)
    return os.path.normpath(os.path.join(base, value))


def _read_config(site_path: str) -> str:
    config_file = Path(site_path) / "_config.yml"
    try:
        return config_file.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def inspect_site(site: Site) -> SiteInfo:
    """采集站点信息。任何单项失败都不影响其他项，缺失字段留空。"""
    info = SiteInfo()

    config_text = _read_config(site.path)
    if config_text:
        scalars = yamlutil.load_yaml_mapping(config_text)
        info.title = str(scalars.get("title") or "")
        info.url = str(scalars.get("url") or "")
        info.theme = str(scalars.get("theme") or "")

    package = _read_package(site.path)
    if package:
        info.hexo_version = _version_of(package, "hexo")
        if info.theme:
            info.theme_version = _version_of(package, f"hexo-theme-{info.theme}")

    info.dependencies_installed = os.path.exists(site.node_modules_bin)

    git_dir = os.path.join(site.path, ".git")
    info.is_git_repository = os.path.exists(git_dir)
    if info.is_git_repository:
        info.git_remote = _parse_remote(os.path.join(git_dir, "config"))

    source, posts = resolve_paths(site)
    info.source_directory = source
    info.posts_directory = posts
    info.post_count = len(load_posts(site))

    info.has_build_output = os.path.isdir(site.public_directory)
    if info.has_build_output:
        try:
            info.build_file_count = len(os.listdir(site.public_directory))
        except OSError:
            info.build_file_count = 0

    return info


def _read_package(site_path: str) -> dict[str, Any]:
    package_file = Path(site_path) / "package.json"
    try:
        data = json.loads(package_file.read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def _version_of(package: dict[str, Any], name: str) -> str:
    for key in ("dependencies", "devDependencies"):
        deps = package.get(key)
        if isinstance(deps, dict):
            version = deps.get(name)
            if isinstance(version, str):
                return version
    return ""


def _parse_remote(git_config_path: str) -> str:
    """从 ``.git/config`` 里提取第一个 remote url，纯文本解析。

    不调 git 命令：总览页要「立刻」显示远端，等一次子进程太慢。
    """
    try:
        text = Path(git_config_path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""

    in_origin = False
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if line.startswith("["):
            in_origin = 'remote "origin"' in line
            continue
        if in_origin and line.startswith("url"):
            _, _, value = line.partition("=")
            return value.strip()
    return ""


# -- 站点列表 ----------------------------------------------------------


def sort_sites(sites: list[Site]) -> list[Site]:
    """按上次打开时间倒序。

    返回新列表而不是就地排序：调用方经常要拿排序前的结果做对比。
    """
    return sorted(sites, key=lambda item: item.last_opened, reverse=True)


def add_site(sites: list[Site], path: str) -> tuple[list[Site], bool]:
    """加入站点，返回 ``(新列表, 是否成功)``。

    已经在列表里的站点只刷新「上次打开时间」，不重复添加。
    """
    normalized = normalize_path(path)
    if not is_hexo_site(normalized):
        return sites, False

    for index, site in enumerate(sites):
        if site.path == normalized:
            updated = list(sites)
            updated[index] = Site(path=normalized, last_opened=now_timestamp())
            return sort_sites(updated), True

    return sort_sites(list(sites) + [Site.create(normalized)]), True


def remove_site(sites: list[Site], path: str) -> list[Site]:
    """从列表移除。

    **只动列表，不删磁盘文件。** 用户从 HexoMan 里移除一个站点，
    期望的是「我不想在这儿看到它」，不是「把我的博客删了」。
    """
    return [site for site in sites if site.path != normalize_path(path)]


def select_site(sites: list[Site], path: str) -> list[Site]:
    """切换当前站点：刷新目标站点的 ``last_opened`` 并重新排序。"""
    normalized = normalize_path(path)
    updated = list(sites)
    for index, site in enumerate(updated):
        if site.path == normalized:
            updated[index] = Site(path=site.path, last_opened=now_timestamp())
            break
    return sort_sites(updated)


class SiteList:
    """站点列表的状态容器。

    之所以单独一个类：站点列表要落盘（``settings.json``），而排序、增删
    的规则散在各处容易走样。集中在一处，行为才一致。
    """

    def __init__(self, sites: list[Site] | None = None, current_path: str = "") -> None:
        self._sites = sort_sites(list(sites or []))
        self.current_path = normalize_path(current_path) if current_path else ""

    @property
    def sites(self) -> list[Site]:
        return list(self._sites)

    @property
    def current(self) -> Site | None:
        for site in self._sites:
            if site.path == self.current_path:
                return site
        return None

    def add(self, path: str) -> bool:
        updated, ok = add_site(self._sites, path)
        self._sites = updated
        if ok:
            self.current_path = normalize_path(path)
        return ok

    def remove(self, path: str) -> None:
        normalized = normalize_path(path)
        self._sites = remove_site(self._sites, normalized)
        if self.current_path == normalized:
            self.current_path = ""

    def select(self, path: str) -> None:
        normalized = normalize_path(path)
        self._sites = select_site(self._sites, normalized)
        self.current_path = normalized

    def to_dict(self) -> dict[str, Any]:
        return {
            "sites": [site.to_dict() for site in self._sites],
            "currentSitePath": self.current_path,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "SiteList":
        raw_sites = data.get("sites") or []
        sites = [
            Site.from_dict(item)
            for item in raw_sites
            if isinstance(item, dict) and item.get("path")
        ]
        return cls(sites, str(data.get("currentSitePath") or ""))
