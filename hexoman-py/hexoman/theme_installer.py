"""主题安装与跨主题迁移。

对应 Swift 侧 ``HexoManModel.swift`` 里的 ``applyTheme(named:)`` 与
``computeThemeMigration(site:newThemeShortName:)``。

## 为什么单独一个模块

Swift 版把这段逻辑写在 model 里（视图直接调 model）。Python 版的
``api.py`` 只做「桥接」，不写业务逻辑，所以算法落到这里——纯函数，
单元测试能直接覆盖。

## 迁移计划是什么

装主题时顺便算一份「老主题 → 新主题」的公共项搬运清单：

- 老主题的 ``_config.<A>.yml`` 里有些键是**公共项**——hexo 通用配置
  （站点标题、头像、社交链接等），新主题 B 可能也支持。
- 也可能 B 自带的 sample 里也有这些键，那应该把 A 里的当前值搬过去。

这里只**计算**要搬什么，不真正写入。新主题可能完全没那些选项，
让用户在界面上逐项决定。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .config_sync import ConfigSync
from .model import Site, read_text
from .yaml_path import YamlDocument

__all__ = [
    "ThemeMigrationEntry",
    "ThemeMigrationPlan",
    "ThemeInstallResult",
    "ThemeInstaller",
]


@dataclass
class ThemeMigrationEntry:
    """单条迁移项。``current_value`` 是从旧主题配置抽出来的当前值。"""

    key: str
    label: str
    current_value: str = ""

    @property
    def id(self) -> str:
        return self.key

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "key": self.key,
            "label": self.label,
            "currentValue": self.current_value,
        }


@dataclass
class ThemeMigrationPlan:
    """一份「老主题→新主题」的公共项搬运清单。"""

    from_theme: str
    to_theme: str
    entries: list[ThemeMigrationEntry] = field(default_factory=list)

    @property
    def has_items(self) -> bool:
        return bool(self.entries)

    def to_dict(self) -> dict[str, Any]:
        return {
            "fromTheme": self.from_theme,
            "toTheme": self.to_theme,
            "entries": [entry.to_dict() for entry in self.entries],
            "hasItems": self.has_items,
        }


@dataclass
class ThemeInstallResult:
    """装主题的结果。

    ``migration`` 非空表示有可以搬过去的公共项，界面用它来展示
    「要不要把这些值搬到新主题」的清单。
    """

    installed: bool
    package_name: str
    migration: ThemeMigrationPlan | None = None
    error: str = ""
    message: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "installed": self.installed,
            "packageName": self.package_name,
            "migration": self.migration.to_dict() if self.migration else None,
            "error": self.error,
            "message": self.message,
        }


class ThemeInstaller:
    """装主题 + 算迁移计划。

    只**计算**迁移计划，不写盘——写不写由用户逐项决定。
    """

    @staticmethod
    def compute_migration(site: Site, new_theme_short_name: str) -> ThemeMigrationPlan | None:
        """算跨主题迁移评估。

        找不到旧主题配置或新主题示例配置时返回 ``None``（没有可比的东西）。
        """
        root = Path(site.path)
        config_path = root / "_config.yml"
        site_config = read_text(config_path)
        if site_config is None:
            return None

        old_theme_name = (YamlDocument(site_config).get("theme") or "").strip()
        if not old_theme_name or old_theme_name == new_theme_short_name:
            return None

        old_config_name = f"_config.{old_theme_name}.yml"
        old_text = read_text(root / old_config_name)
        if old_text is None:
            return None

        new_sample = (
            root
            / "node_modules"
            / f"hexo-theme-{new_theme_short_name}"
            / "_config.yml"
        )
        new_text = read_text(new_sample)
        if new_text is None:
            return None

        # 只搬 ConfigSync 认得的同步项（avatar / favicon / title 等）：
        # 同 key 且两边都有值才算「差异」。
        differences = ConfigSync.differences(old_text, new_text)
        if not differences:
            return None

        old_document = YamlDocument(old_text)
        entries = [
            ThemeMigrationEntry(
                key=difference.key,
                label=difference.label,
                current_value=old_document.get(difference.key) or "",
            )
            for difference in differences
        ]

        return ThemeMigrationPlan(
            from_theme=old_theme_name,
            to_theme=new_theme_short_name,
            entries=entries,
        )

    @staticmethod
    def write_theme(site: Site, name: str) -> None:
        """只改 ``_config.yml`` 里的顶层 ``theme:`` 一行。

        读不到文件就原样建一个。
        """
        config_path = Path(site.path) / "_config.yml"
        line = f"theme: {name}"

        text = read_text(config_path)
        if text is None:
            # 配置文件读不到（不存在或编码异常）时，补一个最小配置而不是放弃。
            config_path.parent.mkdir(parents=True, exist_ok=True)
            config_path.write_text(line + "\n", encoding="utf-8")
            return

        lines = text.split("\n")
        replaced = False

        for index, candidate in enumerate(lines):
            if not candidate.startswith("theme:"):
                continue
            lines[index] = line
            replaced = True
            break

        if not replaced:
            lines.append(line)

        config_path.write_text("\n".join(lines), encoding="utf-8")
