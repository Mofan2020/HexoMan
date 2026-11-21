"""本地配置持久化：站点列表、语言、预览端口。

对应 Swift 侧的 ``SettingsStore.swift``。落在应用支持目录，
不污染用户 home。
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from typing import Any

from .i18n import DEFAULT_LANGUAGE, STRINGS
from .model import Site
from .system_integration import app_data_directory

__all__ = ["AppSettings", "SettingsStore"]


@dataclass
class AppSettings:
    """落盘的设置。

    **逐字段容错解码**：Python 的 ``dataclass`` 默认不会因为缺字段炸掉，
    但这里仍然手动逐字段读，理由和 Swift 版一样——加一个字段不能清空
    老用户的数据。
    """

    sites: list[Site] = field(default_factory=list)
    last_site_path: str = ""
    server_port: int = 4000
    auto_scroll_log: bool = True
    custom_hexo_path: str = ""
    uses_shell_environment: bool = True
    custom_rc_path: str = ""
    syncs_theme_config: bool = True
    language: str = DEFAULT_LANGUAGE
    online_theme_search: bool = False
    dont_ask_online_consent: bool = False
    preview_drafts: bool = False

    def to_dict(self) -> dict[str, Any]:
        return {
            "sites": [site.to_dict() for site in self.sites],
            "lastSitePath": self.last_site_path,
            "serverPort": self.server_port,
            "autoScrollLog": self.auto_scroll_log,
            "customHexoPath": self.custom_hexo_path,
            "usesShellEnvironment": self.uses_shell_environment,
            "customRCPath": self.custom_rc_path,
            "syncsThemeConfig": self.syncs_theme_config,
            "language": self.language,
            "onlineThemeSearch": self.online_theme_search,
            "dontAskOnlineConsent": self.dont_ask_online_consent,
            "previewDrafts": self.preview_drafts,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "AppSettings":
        raw_sites = data.get("sites") or []
        sites = [
            Site.from_dict(item)
            for item in raw_sites
            if isinstance(item, dict) and item.get("path")
        ]

        defaults = cls()
        language = str(data.get("language") or defaults.language)
        # Swift 版存的是 ``"system"``（跟随系统），Python 版没有这个档位，
        # 落到默认语言即可——认不出来的值不该让整个设置文件读不出来。
        if language not in STRINGS:
            language = defaults.language

        return cls(
            sites=sites,
            last_site_path=str(data.get("lastSitePath") or ""),
            server_port=_as_int(data.get("serverPort"), defaults.server_port),
            auto_scroll_log=_as_bool(data.get("autoScrollLog"), defaults.auto_scroll_log),
            custom_hexo_path=str(data.get("customHexoPath") or ""),
            uses_shell_environment=_as_bool(
                data.get("usesShellEnvironment"), defaults.uses_shell_environment
            ),
            custom_rc_path=str(data.get("customRCPath") or ""),
            syncs_theme_config=_as_bool(
                data.get("syncsThemeConfig"), defaults.syncs_theme_config
            ),
            language=language,
            online_theme_search=_as_bool(
                data.get("onlineThemeSearch"), defaults.online_theme_search
            ),
            dont_ask_online_consent=_as_bool(
                data.get("dontAskOnlineConsent"), defaults.dont_ask_online_consent
            ),
            preview_drafts=_as_bool(data.get("previewDrafts"), defaults.preview_drafts),
        )


def _as_int(value: Any, fallback: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return fallback


def _as_bool(value: Any, fallback: bool) -> bool:
    """宽松地读布尔。

    只认 ``true``/``false``/``yes``/``no``/``1``/``0`` 这几个字面量；
    其它值（比如用户手写错成了 ``"是"``）用默认值，不猜。
    """
    if isinstance(value, bool):
        return value
    if value is None:
        return fallback
    text = str(value).strip().lower()
    if text in {"true", "yes", "1"}:
        return True
    if text in {"false", "no", "0"}:
        return False
    return fallback


class SettingsStore:
    """读写 ``settings.json``。"""

    def __init__(self, path: str | None = None) -> None:
        self.path = path or os.path.join(app_data_directory(), "settings.json")

    def load(self) -> AppSettings:
        """读设置。文件不存在或坏了就返回出厂设置。

        解析失败**不抛错**——设置文件坏了不该让应用起不来。
        """
        try:
            with open(self.path, encoding="utf-8") as handle:
                data = json.load(handle)
        except (OSError, ValueError):
            return AppSettings()

        if not isinstance(data, dict):
            return AppSettings()

        return AppSettings.from_dict(data)

    def save(self, settings: AppSettings) -> None:
        """写设置。失败静默忽略——设置存不下不该打断用户正在做的事。"""
        directory = os.path.dirname(self.path)
        try:
            if directory:
                os.makedirs(directory, exist_ok=True)
            with open(self.path, "w", encoding="utf-8") as handle:
                json.dump(settings.to_dict(), handle, ensure_ascii=False, indent=2)
        except OSError:
            return
