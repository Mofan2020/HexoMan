"""前端用到的文案 key 必须都在文案表里。

界面上的文案 key 写错时，``t()`` 会回落成 key 原文——屏幕上直接出现
``posts.split`` 这种字符串。这个测试在 CI 里就把问题拦下来。
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from hexoman import i18n

UI_DIR = Path(__file__).resolve().parent.parent / "hexoman" / "ui"


def _extract_literal_keys() -> set[str]:
    """扫出 ``t("...")`` 形式的字面量 key。

    以 ``.`` 结尾的是**前缀**（``t("posts.filter." + key)``），不算完整 key，
    单独在 :func:`_extract_composed_keys` 里列。
    """
    source = (UI_DIR / "app.js").read_text(encoding="utf-8")
    return {
        key
        for key in re.findall(r'\bt\(\s*"([a-zA-Z][\w.]*)"', source)
        if not key.endswith(".")
    }


def _extract_composed_keys() -> set[str]:
    """扫出 ``t(prefix + suffix)`` 这种拼接出来的 key。

    这些没法静态算出来，只能人工列出——列在这里是为了有人补的时候
    看得见。
    """
    return {
        "posts.filter.all",
        "posts.filter.published",
        "posts.filter.draft",
        "posts.write",
        "posts.splitView",
        "posts.read",
        "pages.kind.indexed",
        "pages.kind.standalone",
        "pages.kind.asset",
    }


class TestFrontendKeys:
    def test_literal_keys_all_exist(self):
        missing = sorted(
            key
            for key in _extract_literal_keys()
            if key not in i18n.STRINGS["zh"] or key not in i18n.STRINGS["en"]
        )

        assert missing == [], f"前端用了不存在的文案 key：{missing}"

    def test_composed_keys_all_exist(self):
        missing = sorted(
            key
            for key in _extract_composed_keys()
            if key not in i18n.STRINGS["zh"] or key not in i18n.STRINGS["en"]
        )

        assert missing == [], f"前端用了不存在的文案 key：{missing}"

    def test_no_prefix_only_key_sneaks_in(self):
        """拼接前缀不该被当成完整 key 混进字面量集合。

        真出现了就说明有人把 ``t("posts.filter." + key)`` 写成了
        ``t("posts.filter.")``——界面上会显示 ``posts.filter.``。
        """
        source = (UI_DIR / "app.js").read_text(encoding="utf-8")
        assert 't("posts.filter.")' not in source

    def test_no_emoji_in_ui_source(self):
        """图标一律用内联 SVG，不许用 emoji。

        emoji 在不同系统上长相不一，也没法跟随主题着色。
        """
        source = (UI_DIR / "app.js").read_text(encoding="utf-8")
        html = (UI_DIR / "index.html").read_text(encoding="utf-8")

        # 常见的 emoji 码位区间
        emoji = re.compile(
            "[\U0001F300-\U0001FAFF\U00002600-\U000027BF\U0001F000-\U0001F2FF]"
        )

        assert not emoji.search(source), "app.js 里有 emoji"
        assert not emoji.search(html), "index.html 里有 emoji"

    def test_ui_files_exist(self):
        assert (UI_DIR / "index.html").is_file()
        assert (UI_DIR / "style.css").is_file()
        assert (UI_DIR / "app.js").is_file()

    def test_index_references_stylesheet_and_script(self):
        html = (UI_DIR / "index.html").read_text(encoding="utf-8")

        assert 'href="style.css"' in html
        assert 'src="app.js"' in html

    def test_style_defines_dark_mode(self):
        """深浅色跟随系统，CSS 里必须有 prefers-color-scheme 分支。"""
        css = (UI_DIR / "style.css").read_text(encoding="utf-8")

        assert "prefers-color-scheme: dark" in css

    def test_style_uses_system_font_stack(self):
        css = (UI_DIR / "style.css").read_text(encoding="utf-8")

        assert "-apple-system" in css
        assert "BlinkMacSystemFont" in css
