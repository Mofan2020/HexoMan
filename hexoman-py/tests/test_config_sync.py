"""站点配置与主题配置的同步。"""

from __future__ import annotations

from hexoman.config_sync import ConfigSync
from hexoman.yaml_path import YamlDocument


SITE = """title: 我的博客
subtitle: 副标题
url: https://example.com
avatar:
  url: /images/me.png
  rounded: true
footer:
  since: 2020
"""

THEME = """# 主题配置，注释必须保留
title: 旧标题
avatar:
  url: /images/old.png
  rounded: false
  rotated: true
menu:
  - name: 首页
    link: /
"""


def test_shared_keys_include_nested_paths():
    assert ConfigSync.is_syncable("title")
    assert ConfigSync.is_syncable("avatar.url")
    assert not ConfigSync.is_syncable("menu")


def test_label_for():
    assert ConfigSync.label_for("avatar.url") == "头像地址"
    assert ConfigSync.label_for("nope") is None


def test_differences_finds_mismatches():
    differences = {item.key: item for item in ConfigSync.differences(SITE, THEME)}

    assert differences["title"].site_value == "我的博客"
    assert differences["title"].theme_value == "旧标题"
    assert differences["avatar.url"].site_value == "/images/me.png"
    assert differences["avatar.url"].theme_value == "/images/old.png"
    # 主题配置里没有的键不算差异
    assert "url" not in differences
    assert "footer.since" not in differences


def test_differences_skip_equal_values():
    same = "title: x\navatar:\n  url: /a.png\n"
    assert ConfigSync.differences(same, same) == []


def test_apply_to_theme_replaces_value():
    updated = ConfigSync.apply_to_theme("title", "新标题", THEME)

    assert updated is not None
    assert "title: 新标题" in updated
    # 注释和别的键都留着
    assert "# 主题配置，注释必须保留" in updated
    assert "menu:" in updated


def test_apply_to_theme_nested():
    updated = ConfigSync.apply_to_theme("avatar.url", "/images/new.png", THEME)

    assert updated is not None
    parsed = YamlDocument(updated)
    assert parsed.get("avatar.url") == "/images/new.png"
    # 兄弟键不受影响
    assert parsed.get("avatar.rotated") == "true"


def test_apply_to_theme_returns_none_when_same():
    assert ConfigSync.apply_to_theme("title", "旧标题", THEME) is None


def test_apply_to_theme_refuses_unknown_key_in_theme():
    """主题配置里压根没有这个键时，不擅自新增结构。"""
    assert ConfigSync.apply_to_theme("per_page", "10", THEME) is None


def test_apply_to_theme_refuses_unsyncable():
    assert ConfigSync.apply_to_theme("menu", "x", THEME) is None


def test_sync_all_reports_changed_labels():
    updated, changed = ConfigSync.sync_all(SITE, THEME)

    assert "站点标题" in changed
    assert "头像地址" in changed
    parsed = YamlDocument(updated)
    assert parsed.get("title") == "我的博客"
    assert parsed.get("avatar.url") == "/images/me.png"


def test_theme_only_entries():
    site_config = "title: x\n"
    theme_config = "avatar:\n  url: /only-theme.png\ntitle: x\n"

    entries = {item.key: item for item in ConfigSync.theme_only_entries(site_config, theme_config)}

    assert "avatar.url" in entries
    assert entries["avatar.url"].value == "/only-theme.png"
    assert entries["avatar.url"].site_state == "missing"
    # 站点侧有值的键不属于这一类
    assert "title" not in entries


def test_theme_only_detects_empty_site_key():
    site_config = "avatar:\n  url:\n"
    theme_config = "avatar:\n  url: /x.png\n"

    entries = ConfigSync.theme_only_entries(site_config, theme_config)
    assert entries[0].site_state == "empty"


def test_apply_to_site_appends_missing_top_level_key():
    updated = ConfigSync.apply_to_site("favicon", "/images/fav.png", SITE)

    assert updated is not None
    assert YamlDocument(updated).get("favicon") == "/images/fav.png"


def test_apply_to_site_refuses_when_top_level_key_is_not_a_scalar():
    """顶层键已存在且是嵌套结构时，不能追加第二个同名键。

    追加会让文件里出现两个 ``avatar:``，YAML 解析时后者覆盖前者，
    用户原本配的结构就被悄悄废掉了。
    """
    site_config = "title: x\navatar:\n  url: /old.png\n"

    assert ConfigSync.apply_to_site("avatar", "/new.png", site_config) is None


def test_apply_to_site_creates_missing_parent_block():
    """站点配置里连 avatar: 那行都没有时也要能写进去。

    这是最常见的场景：用户只在 _config.yun.yml 里配了头像。
    """
    site_config = "title: x\n"
    updated = ConfigSync.apply_to_site("avatar.url", "/images/me.png", site_config)

    assert updated is not None
    parsed = YamlDocument(updated)
    assert parsed.get("avatar.url") == "/images/me.png"
    # 原来的键还在
    assert parsed.get("title") == "x"


def test_apply_to_site_seeds_empty_parent():
    site_config = "title: x\navatar:\n"
    updated = ConfigSync.apply_to_site("avatar.rounded", "true", site_config)

    assert updated is not None
    parsed = YamlDocument(updated)
    assert parsed.get("avatar.rounded") == "true"


def test_apply_to_site_existing_parent():
    updated = ConfigSync.apply_to_site("avatar.url", "/images/new.png", SITE)

    assert updated is not None
    parsed = YamlDocument(updated)
    assert parsed.get("avatar.url") == "/images/new.png"
    # 兄弟键保留
    assert parsed.get("avatar.rounded") == "true"
