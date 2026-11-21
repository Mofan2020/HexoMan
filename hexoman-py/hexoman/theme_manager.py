"""主题的扫描、切换与配置。

对应 Swift 侧的 ``ThemeManager.swift``。

## 为什么单独做

用户抱怨「能管理的东西太少」，而换主题是 Hexo 用户最高频的操作之一。
原来的做法是让人自己去改 ``_config.yml`` 里的 ``theme: yun``，改错了就是
白屏，而且装主题要自己去敲 npm 命令。

## 关键事实

主题装在 ``node_modules/hexo-theme-*``，**不在** ``themes/`` 目录里。
``themes/`` 只是空壳，Hexo 会优先找本地主题目录，找不到才用 node_modules。
所以扫主题要扫 node_modules，不是扫 ``themes/``。

## 与 Swift 版的差异

- **切换主题**：Swift 版用自研的 ``YAMLDocument`` 改 ``theme`` 键。这里用
  :mod:`hexoman.yaml_path`，它基于 PyYAML 的源码坐标，**只替换那一个值**，
  注释和键顺序全保留。
- **装主题**：Swift 版没有装主题的代码（那是 ``ThemeRegistry`` + npm 的事），
  这里同样不自己实现 npm 安装，只提供包名归一化，把安装交给 npm。
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .model import Site, read_text
from .yaml_path import YamlDocument

__all__ = [
    "InstalledTheme",
    "ThemeCatalog",
    "ThemeManager",
    "ThemeManagerError",
]


class ThemeManagerError(Exception):
    """主题操作出错。"""

    def __init__(self, code: str, message: str = "") -> None:
        super().__init__(message or code)
        self.code = code
        self.message = message or code


@dataclass
class InstalledTheme:
    """一个已安装的主题。"""

    #: 包名去掉 ``hexo-theme-`` 前缀，如 ``hexo-theme-yun`` → ``yun``
    name: str
    #: 完整包名
    package_name: str
    #: 版本号
    version: str = ""
    #: 一句话描述
    description: str = ""
    #: 主题自带的示例配置路径
    sample_config_path: str = ""
    #: 这个主题的配置文件在站点根目录叫什么
    config_file_name: str = ""
    #: 是否是当前使用的
    is_active: bool = False
    #: 站点里是否已有这个主题的配置文件
    has_site_config: bool = False

    @property
    def id(self) -> str:
        return self.package_name

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "packageName": self.package_name,
            "version": self.version,
            "description": self.description,
            "sampleConfigPath": self.sample_config_path,
            "configFileName": self.config_file_name,
            "isActive": self.is_active,
            "hasSiteConfig": self.has_site_config,
        }


@dataclass
class ThemeCatalogItem:
    """主题市场的精选列表里的一项。"""

    name: str
    package_name: str
    summary: str = ""
    author: str = ""
    homepage: str = ""

    @property
    def id(self) -> str:
        return self.package_name

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "packageName": self.package_name,
            "summary": self.summary,
            "author": self.author,
            "homepage": self.homepage,
        }


class ThemeCatalog:
    """主题市场的精选列表。

    只给几十个 widely used 的主题，而不是全量 npm 搜索——全量搜索要联网、
    结果几百个，小白根本选不出来。联网补全由
    :mod:`hexoman.theme_registry` 负责。
    """

    ITEMS: list[ThemeCatalogItem] = [
        ThemeCatalogItem(
            "yun", "hexo-theme-yun",
            "简洁大气的中文博客主题，配置项少、上手快。",
            "yunyoujun", "https://yun.yunyoujun.cn",
        ),
        ThemeCatalogItem(
            "landscape", "hexo-theme-landscape",
            "Hexo 官方主题，文档最全，适合当作入门参考。",
            "hexo", "https://hexo.io/themes/",
        ),
        ThemeCatalogItem(
            "next", "hexo-theme-next",
            "功能最全的主题之一，集成搜索、评论、多语言。",
            "theme-next", "https://theme-next.org",
        ),
        ThemeCatalogItem(
            "Fluid", "hexo-theme-fluid",
            "响应式三栏布局，配置项带注释，适合当作长期维护的站点主题。",
            "fluid-dev", "https://fluid-dev.github.io",
        ),
        ThemeCatalogItem(
            "Matery", "hexo-theme-matery",
            "Material 风格，自带多种配色方案和卡片式列表。",
            "Tuigug", "https://theme.matery.ink",
        ),
        ThemeCatalogItem(
            "whiskers", "hexo-theme-whiskers",
            "轻量的单栏主题，适合纯文字内容。",
            "porridge", "https://github.com/porridge/hexo-theme-whiskers",
        ),
        ThemeCatalogItem(
            "volantis", "hexo-theme-volantis",
            "功能丰富的主题，自带侧边栏、推荐位等大量组件。",
            "Etheme", "https://volantis.theme-best.com",
        ),
        ThemeCatalogItem(
            "reimu", "hexo-theme-reimu",
            "东方风格主题，自带大量装饰元素。",
            "TRSS", "https://github.com/TRSS-Yukari/reimu",
        ),
        ThemeCatalogItem(
            "solitude", "hexo-theme-solitude",
            "简洁的单栏主题，强调阅读体验。",
            "solitude", "https://github.com/valor-x",
        ),
        ThemeCatalogItem(
            "Anima", "hexo-theme-anima",
            "卡片式布局的主题，适合图片多的站点。",
            "anima", "https://github.com/anima-theme/anima",
        ),
    ]

    @staticmethod
    def find(name: str) -> ThemeCatalogItem | None:
        """按名字查精选项。"""
        for item in ThemeCatalog.ITEMS:
            if item.name == name:
                return item
        return None


class ThemeManager:
    """主题相关操作。"""

    # -- 包名归一化 ---------------------------------------------------

    @staticmethod
    def normalize_package_name(raw: str) -> str:
        """把用户输入归一到「主题短名」形式（去前缀去 scope）。

        - ``"yun"`` → ``"yun"``
        - ``"hexo-theme-yun"`` → ``"yun"``
        - ``"@scope/hexo-theme-yun"`` → ``"yun"``（scoped 包的 theme 部分）
        - ``"   yun   "`` → ``"yun"``
        """
        name = raw.strip()
        if name.startswith("@"):
            slash = name.find("/")
            if slash >= 0:
                name = name[slash + 1 :]
        if name.startswith("hexo-theme-"):
            name = name[len("hexo-theme-") :]
        return name.strip()

    @staticmethod
    def full_package_name(normalized_short_name: str) -> str:
        """主题短名 → npm 装包用全名（加 ``hexo-theme-`` 前缀）。

        接受 :meth:`normalize_package_name` 之后的输出，确保不会重复加前缀。
        """
        if normalized_short_name.startswith("@"):
            return normalized_short_name
        if normalized_short_name.startswith("hexo-theme-"):
            return normalized_short_name
        return f"hexo-theme-{normalized_short_name}"

    @staticmethod
    def short_name(full_name: str) -> str:
        """反向：从全名（装包用）抽出主题短名。

        - ``"hexo-theme-yun"`` → ``"yun"``
        - ``"@scope/hexo-theme-yun"`` → ``"yun"``（scoped 包）
        """
        name = full_name
        if name.startswith("@"):
            slash = name.find("/")
            if slash >= 0:
                name = name[slash + 1 :]
        if name.startswith("hexo-theme-"):
            name = name[len("hexo-theme-") :]
        return name

    # -- 扫描 ---------------------------------------------------------

    @staticmethod
    def installed(site: Site, active_name: str = "") -> list[InstalledTheme]:
        """扫描站点里已安装的所有主题。

        扫 ``node_modules/hexo-theme-*``，而不是 ``themes/``——后者通常是
        空的，扫了等于没扫。``themes/`` 目录里的本地主题也认。
        """
        root = Path(site.path)
        modules = root / "node_modules"
        themes_dir = root / "themes"

        themes: list[InstalledTheme] = []

        # node_modules 里的（npm 装的）
        try:
            entries = sorted(os.listdir(modules))
        except OSError:
            entries = []

        for package_name in entries:
            if not package_name.startswith("hexo-theme-"):
                continue
            name = package_name[len("hexo-theme-") :]
            version, description = ThemeManager._read_package_meta(
                modules / package_name / "package.json"
            )
            config_name = f"_config.{name}.yml"
            themes.append(
                InstalledTheme(
                    name=name,
                    package_name=package_name,
                    version=version,
                    description=description,
                    sample_config_path=ThemeManager._sample_config_path(
                        themes_dir, name
                    ),
                    config_file_name=config_name,
                    is_active=name == active_name,
                    has_site_config=(root / config_name).is_file(),
                )
            )

        # themes/ 目录里的（手动放的）也要认
        try:
            entries = sorted(os.listdir(themes_dir))
        except OSError:
            entries = []

        for name in entries:
            if name == ".gitkeep" or name.startswith("."):
                continue
            if any(theme.name == name for theme in themes):
                continue
            config_name = f"_config.{name}.yml"
            themes.append(
                InstalledTheme(
                    name=name,
                    package_name=f"hexo-theme-{name}",
                    version="本地",
                    description="themes 目录里的本地主题",
                    sample_config_path=str(themes_dir / name / "_config.yml"),
                    config_file_name=config_name,
                    is_active=name == active_name,
                    has_site_config=(root / config_name).is_file(),
                )
            )

        # 当前主题排最前
        themes.sort(key=lambda item: (not item.is_active, item.name))
        return themes

    @staticmethod
    def _sample_config_path(themes_dir: Path, name: str) -> str:
        """主题自带示例配置（npm 包里只有 ``_config.yml``，不带包名前缀）。"""
        path = themes_dir / name / "_config.yml"
        return str(path) if path.is_file() else ""

    @staticmethod
    def _read_package_meta(path: Path) -> tuple[str, str]:
        """读 package.json 的两个字段。版本缺失时用「未知」。"""
        text = read_text(path)
        if text is None:
            return "未知", ""
        try:
            data = json.loads(text)
        except (ValueError, UnicodeDecodeError):
            return "未知", ""
        if not isinstance(data, dict):
            return "未知", ""

        version = data.get("version")
        description = data.get("description")
        return (
            version if isinstance(version, str) and version else "未知",
            description if isinstance(description, str) else "",
        )

    # -- 切换 ---------------------------------------------------------

    @staticmethod
    def active_theme_name(site: Site) -> str:
        """站点当前用的主题名。"""
        config_path = Path(site.path) / "_config.yml"
        text = read_text(config_path)
        if text is None:
            return ""
        return YamlDocument(text).get("theme") or ""

    @staticmethod
    def switch_theme(site: Site, theme: InstalledTheme) -> None:
        """切换主题：改主配置里的 ``theme:`` 键。

        只改 ``theme`` 这一个键，别的一概不碰——换主题时如果顺手重排了整个
        ``_config.yml``，用户没法 review，出了问题也难回滚。

        实现上用 :mod:`hexoman.yaml_path` 做**外科手术式替换**：只替换
        ``theme`` 那一行的值，注释、键顺序、缩进全部原样保留。
        """
        config_path = Path(site.path) / "_config.yml"
        text = read_text(config_path)
        if text is None:
            raise ThemeManagerError("configMissing", "找不到站点的 _config.yml")

        document = YamlDocument(text)
        updated = document.set("theme", theme.name)
        if updated is None:
            # 站点配置里压根没有 theme 键，或者它不是标量。
            # 这两种情况都只能追加一行——不能覆盖用户写的内容。
            updated = _append_top_level(text, "theme", theme.name)
            if updated is None:
                raise ThemeManagerError(
                    "switchFailed", "改不动 _config.yml 里的 theme 键，请手动检查这个文件。"
                )

        try:
            temp = config_path.with_name(config_path.name + ".hexoman-tmp")
            temp.write_text(updated, encoding="utf-8")
            os.replace(temp, config_path)
        except OSError as error:
            raise ThemeManagerError("switchFailed", f"写入失败：{error}") from error

    @staticmethod
    def create_site_config(site: Site, theme: InstalledTheme) -> str:
        """把主题的示例配置复制成站点的 ``_config.<name>.yml``。

        没有这一步的话，用户切到新主题后打开配置页会发现「这个主题没有
        配置文件」，所有设置都没地方改——这是换主题最常见的后续困惑。
        """
        root = Path(site.path)
        target = root / theme.config_file_name

        sample = theme.sample_config_path
        contents = read_text(sample) if sample else None

        if contents is not None:
            header = (
                f"# {theme.package_name} 主题配置\n"
                "# 这份文件由 HexoMan 从主题自带示例复制而来，你可以按注释逐条修改。\n"
                "# 也可以到 https://hexo.io/themes/ 查该主题的完整配置说明。\n"
                "# 删除这个文件不会影响站点，只是不再加载主题设置。\n\n"
            )
            payload = header + contents
        else:
            # 主题包里没有示例配置，就造一个带注释的骨架
            payload = (
                f"# {theme.package_name} 主题配置\n"
                "# 这个主题没有提供示例配置，下面是通用骨架。\n"
                "# 具体支持哪些键，请参考该主题的官方文档。\n\n"
                "# 主题主色\n"
                'color: "#0078E7"\n\n'
                "# 站点图标\n"
                "favicon:\n\n"
                "# 头像\n"
                "avatar:\n"
                "  enable: true\n"
                "  url:\n"
                "  rounded: true\n\n"
                "# 社交链接\n"
                "social: []\n\n"
            )

        try:
            temp = target.with_name(target.name + ".hexoman-tmp")
            temp.write_text(payload, encoding="utf-8")
            os.replace(temp, target)
        except OSError as error:
            raise ThemeManagerError("createConfigFailed", f"写入失败：{error}") from error

        return str(target)

    @staticmethod
    def site_config_exists(site: Site, theme: InstalledTheme) -> bool:
        """某主题的配置是否已存在。"""
        return (Path(site.path) / theme.config_file_name).is_file()

    @staticmethod
    def recommended() -> list[ThemeCatalogItem]:
        """推荐的主题（没装任何主题时的引导）。"""
        return ThemeCatalog.ITEMS[:3]


def _append_top_level(text: str, key: str, value: str) -> str | None:
    """在文件末尾追加一行顶层 ``key: value``。

    只在 ``key`` **不存在**时用。已存在但不是标量时（用户写的是嵌套结构）
    绝不能追加——追加会在文件里留下第二个同名键，YAML 解析时后者覆盖前者，
    用户原来写的结构被悄悄废掉，而且看不出是哪一步坏的。
    """
    from .yamlutil import format_scalar

    # 顶层已经有这个键，无论它是什么类型，都不追加。
    if key in YamlDocument(text).top_level_keys():
        return None

    lines = text.split("\n")
    while lines and not lines[-1].strip():
        lines.pop()
    if not lines:
        return None

    lines.append(f"{key}: {format_scalar(value)}")
    return "\n".join(lines) + "\n"
