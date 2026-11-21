"""文案与设置存储。"""

from __future__ import annotations

import json
from pathlib import Path

from hexoman import i18n
from hexoman.settings import AppSettings, SettingsStore


class TestStrings:
    def test_both_languages_have_the_same_keys(self):
        """两个语言的 key 必须一一对应。

        少一个 key，界面上那个位置就会显示 key 原文（比如 ``posts.saveSuccess``），
        看起来像坏了。
        """
        zh_keys = set(i18n.STRINGS["zh"].keys())
        en_keys = set(i18n.STRINGS["en"].keys())

        assert zh_keys == en_keys

    def test_no_empty_values(self):
        for language, table in i18n.STRINGS.items():
            for key, value in table.items():
                assert value.strip(), f"{language}.{key} 是空的"

    def test_placeholder_names_match_between_languages(self):
        """占位符名字必须一致，否则 ``format`` 会炸。"""
        import re

        for key in i18n.STRINGS["zh"]:
            zh_names = set(re.findall(r"\{(\w+)\}", i18n.STRINGS["zh"][key]))
            en_names = set(re.findall(r"\{(\w+)\}", i18n.STRINGS["en"][key]))
            assert zh_names == en_names, f"{key} 的占位符不一致"

    def test_get_strings_returns_copy(self):
        first = i18n.get_strings("zh")
        first["nav.posts"] = "改了"

        assert i18n.get_strings("zh")["nav.posts"] != "改了"

    def test_unknown_language_falls_back(self):
        """未知语言不能返回空字典——界面会变成一屏 key 原文。"""
        strings = i18n.get_strings("fr")

        assert strings["nav.posts"] != ""

    def test_t_replaces_placeholders(self):
        result = i18n.t("sites.count", "zh", count=3)

        assert "3" in result

    def test_t_falls_back_to_key(self):
        assert i18n.t("完全.不存在的.key") == "完全.不存在的.key"

    def test_available_languages(self):
        codes = [item["code"] for item in i18n.available_languages()]

        assert "zh" in codes
        assert "en" in codes


class TestSettings:
    def test_missing_file_returns_defaults(self, tmp_path: Path):
        store = SettingsStore(path=str(tmp_path / "nope.json"))

        settings = store.load()

        assert settings.server_port == 4000
        assert settings.sites == []

    def test_broken_file_returns_defaults(self, tmp_path: Path):
        path = tmp_path / "settings.json"
        path.write_text("{ 这不是 JSON")

        settings = SettingsStore(path=str(path)).load()

        assert settings.server_port == 4000

    def test_round_trip(self, tmp_path: Path):
        path = tmp_path / "settings.json"
        store = SettingsStore(path=str(path))

        settings = AppSettings()
        settings.server_port = 5000
        settings.language = "en"
        store.save(settings)

        loaded = store.load()

        assert loaded.server_port == 5000
        assert loaded.language == "en"

    def test_missing_field_does_not_wipe_other_data(self):
        """加一个字段不能把老用户的数据清空。

        Swift 版踩过这个坑：合成解码遇到缺字段直接抛，一抛就退回出厂设置，
        用户的站点列表、语言选择全没了，还没有提示。
        """
        data = {
            "sites": [{"path": "/tmp/site", "lastOpened": 123.0}],
            "lastSitePath": "/tmp/site",
            "serverPort": 4200,
        }

        settings = AppSettings.from_dict(data)

        assert len(settings.sites) == 1
        assert settings.sites[0].path == "/tmp/site"
        assert settings.last_site_path == "/tmp/site"
        assert settings.server_port == 4200
        # 缺字段的用默认值，不抛异常
        assert settings.language == i18n.DEFAULT_LANGUAGE

    def test_site_entries_without_path_are_skipped(self):
        data = {"sites": [{"lastOpened": 1.0}, {"path": "/tmp/x"}]}

        settings = AppSettings.from_dict(data)

        assert len(settings.sites) == 1

    def test_wrong_types_fall_back(self):
        data = {"serverPort": "不是数字", "autoScrollLog": "不是布尔"}

        settings = AppSettings.from_dict(data)

        assert settings.server_port == 4000
        assert settings.auto_scroll_log is True

    def test_save_creates_directory(self, tmp_path: Path):
        path = tmp_path / "nested" / "dir" / "settings.json"
        store = SettingsStore(path=str(path))

        store.save(AppSettings())

        assert path.exists()

    def test_saved_file_is_readable_json(self, tmp_path: Path):
        path = tmp_path / "settings.json"
        store = SettingsStore(path=str(path))

        store.save(AppSettings())

        data = json.loads(path.read_text(encoding="utf-8"))
        assert "sites" in data
        assert "language" in data
