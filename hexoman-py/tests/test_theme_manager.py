"""主题扫描 / 切换 / 配置生成。"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from hexoman.model import Site
from hexoman.theme_manager import (
    InstalledTheme,
    ThemeCatalog,
    ThemeManager,
    ThemeManagerError,
)


@pytest.fixture
def site(tmp_path: Path) -> Site:
    root = tmp_path / "blog"
    (root / "node_modules" / "hexo-theme-yun").mkdir(parents=True)
    (root / "node_modules" / "hexo-theme-landscape").mkdir(parents=True)
    (root / "node_modules" / "left-pad").mkdir(parents=True)
    (root / "themes" / "local").mkdir(parents=True)

    (root / "node_modules" / "hexo-theme-yun" / "package.json").write_text(
        json.dumps({"name": "hexo-theme-yun", "version": "1.2.3", "description": "yun 主题"}),
        encoding="utf-8",
    )
    (root / "node_modules" / "hexo-theme-landscape" / "package.json").write_text(
        json.dumps({"name": "hexo-theme-landscape", "version": "7.0.0"}),
        encoding="utf-8",
    )
    (root / "themes" / "local" / "_config.yml").write_text("a: 1\n", encoding="utf-8")

    (root / "_config.yml").write_text(
        "# 站点配置\ntitle: 我的博客\ntheme: yun\nauthor: me\n", encoding="utf-8"
    )
    (root / "_config.yun.yml").write_text("avatar:\n  rounded: true\n", encoding="utf-8")
    (root / "package.json").write_text('{"dependencies": {"hexo": "^7"}}', encoding="utf-8")

    return Site(path=str(root), last_opened=1.0)


# -- 包名归一化 --------------------------------------------------------


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("yun", "yun"),
        ("hexo-theme-yun", "yun"),
        ("@scope/hexo-theme-yun", "yun"),
        ("   yun   ", "yun"),
    ],
)
def test_normalize_package_name(raw, expected):
    assert ThemeManager.normalize_package_name(raw) == expected


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("yun", "hexo-theme-yun"),
        ("hexo-theme-yun", "hexo-theme-yun"),
        ("@scope/x", "@scope/x"),
    ],
)
def test_full_package_name(raw, expected):
    assert ThemeManager.full_package_name(raw) == expected


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("hexo-theme-yun", "yun"),
        ("@scope/hexo-theme-yun", "yun"),
        ("yun", "yun"),
    ],
)
def test_short_name(raw, expected):
    assert ThemeManager.short_name(raw) == expected


# -- 扫描 -------------------------------------------------------------


def test_installed_scans_node_modules(site: Site):
    themes = ThemeManager.installed(site, active_name="yun")
    names = {theme.name for theme in themes}

    assert "yun" in names
    assert "landscape" in names
    # 非 hexo-theme-* 的包不该被当成主题
    assert "left-pad" not in names


def test_installed_reads_metadata(site: Site):
    themes = {theme.name: theme for theme in ThemeManager.installed(site, "yun")}
    assert themes["yun"].version == "1.2.3"
    assert themes["yun"].description == "yun 主题"
    assert themes["yun"].config_file_name == "_config.yun.yml"
    assert themes["yun"].has_site_config is True


def test_installed_marks_active(site: Site):
    themes = ThemeManager.installed(site, active_name="yun")
    assert themes[0].name == "yun"
    assert themes[0].is_active is True
    assert all(not theme.is_active for theme in themes[1:])


def test_installed_includes_local_themes(site: Site):
    themes = {theme.name: theme for theme in ThemeManager.installed(site, "")}
    assert "local" in themes
    assert themes["local"].version == "本地"
    assert themes["local"].sample_config_path.endswith("_config.yml")


def test_installed_missing_node_modules_returns_local_only(tmp_path: Path):
    root = tmp_path / "bare"
    (root / "themes").mkdir(parents=True)
    site = Site(path=str(root), last_opened=0.0)

    assert ThemeManager.installed(site, "") == []


def test_active_theme_name(site: Site):
    assert ThemeManager.active_theme_name(site) == "yun"


# -- 切换 -------------------------------------------------------------


def test_switch_theme_only_changes_theme_line(site: Site):
    themes = {theme.name: theme for theme in ThemeManager.installed(site, "yun")}
    ThemeManager.switch_theme(site, themes["landscape"])

    text = (Path(site.path) / "_config.yml").read_text(encoding="utf-8")
    assert "theme: landscape" in text
    # 注释和别的键原样保留
    assert "# 站点配置" in text
    assert "title: 我的博客" in text
    assert "author: me" in text


def test_switch_theme_appends_when_missing(tmp_path: Path):
    root = tmp_path / "s"
    root.mkdir()
    (root / "_config.yml").write_text("title: x\n", encoding="utf-8")
    site = Site(path=str(root), last_opened=0.0)

    theme = InstalledTheme(name="yun", package_name="hexo-theme-yun", version="1")
    ThemeManager.switch_theme(site, theme)

    text = (root / "_config.yml").read_text(encoding="utf-8")
    assert "theme: yun" in text
    assert "title: x" in text


def test_switch_theme_missing_config_raises(tmp_path: Path):
    site = Site(path=str(tmp_path / "nope"), last_opened=0.0)
    theme = InstalledTheme(name="yun", package_name="hexo-theme-yun")

    with pytest.raises(ThemeManagerError):
        ThemeManager.switch_theme(site, theme)


# -- 主题配置 ---------------------------------------------------------


def test_create_site_config_from_sample(site: Site):
    themes = {theme.name: theme for theme in ThemeManager.installed(site, "yun")}

    # 给 yun 造一份示例配置
    sample = Path(site.path) / "themes" / "yun" / "_config.yml"
    sample.parent.mkdir(parents=True)
    sample.write_text("color: blue\n", encoding="utf-8")
    themes["yun"].sample_config_path = str(sample)

    target = ThemeManager.create_site_config(site, themes["yun"])

    content = Path(target).read_text(encoding="utf-8")
    assert "hexo-theme-yun" in content
    assert "color: blue" in content


def test_create_site_config_skeleton_when_no_sample(site: Site):
    themes = {theme.name: theme for theme in ThemeManager.installed(site, "yun")}
    themes["yun"].sample_config_path = ""

    target = ThemeManager.create_site_config(site, themes["yun"])
    content = Path(target).read_text(encoding="utf-8")

    assert "没有提供示例配置" in content
    assert "avatar:" in content


def test_site_config_exists(site: Site):
    themes = {theme.name: theme for theme in ThemeManager.installed(site, "yun")}
    assert ThemeManager.site_config_exists(site, themes["yun"]) is True
    assert ThemeManager.site_config_exists(site, themes["landscape"]) is False


# -- 精选目录 ---------------------------------------------------------


def test_catalog_has_ten_entries():
    assert len(ThemeCatalog.ITEMS) == 10


def test_catalog_find():
    assert ThemeCatalog.find("yun") is not None
    assert ThemeCatalog.find("nope") is None


def test_recommended_returns_three():
    assert len(ThemeManager.recommended()) == 3
