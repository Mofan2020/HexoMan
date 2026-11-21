"""常用配置（SiteSettings）。

对应 Swift 侧 ``SiteSettings.swift`` 的测试。
"""

from __future__ import annotations

import pytest

from hexoman import i18n
from hexoman.site_settings import (
    SITE_LANGUAGES,
    SiteField,
    SiteFieldGroup,
    SiteFieldKind,
    SiteSettings,
    SiteSettingsError,
)


class TestFields:
    def test_every_field_has_a_label_and_a_hint(self):
        for field in SiteSettings.fields():
            assert field.key
            assert field.label_key.startswith("siteSettings.label.")
            assert field.hint_key.startswith("siteSettings.hint.")

    def test_labels_exist_in_both_languages(self):
        """标签必须中英都有——缺一个切语言就变成中英混杂。"""
        for field in SiteSettings.fields():
            for language in ("zh", "en"):
                assert field.label_key in i18n.STRINGS[language], field.label_key
                assert field.hint_key in i18n.STRINGS[language], field.hint_key

    def test_group_labels_exist_in_both_languages(self):
        for group in SiteSettings.groups():
            key = f"siteSettings.group.{group}"
            assert key in i18n.STRINGS["zh"], key
            assert key in i18n.STRINGS["en"], key

    def test_fields_are_grouped_in_display_order(self):
        fields = SiteSettings.fields()
        groups = [field.group for field in fields]

        # 每个分组内部连续，且分组顺序与 groups() 一致
        seen: list[str] = []
        for group in groups:
            if not seen or seen[-1] != group:
                seen.append(group)
        assert seen == SiteSettings.groups()

    def test_fields_in_group_filters(self):
        basic = SiteSettings.fields(SiteFieldGroup.BASIC)
        assert basic
        assert all(item.group == SiteFieldGroup.BASIC for item in basic)

    def test_language_choices_include_zh_cn(self):
        """zh-CN 必须在列表里——Hexo 官方 _config.yml 的默认值就是它。"""
        values = [option["value"] for option in SITE_LANGUAGES]
        assert "zh-CN" in values

    def test_language_field_is_a_choice(self):
        language = next(item for item in SiteSettings.fields() if item.key == "language")
        assert language.kind == SiteFieldKind.CHOICE
        assert language.options == SITE_LANGUAGES

    def test_boolean_and_integer_kinds(self):
        by_key = {item.key: item for item in SiteSettings.fields()}
        assert by_key["rss"].kind == SiteFieldKind.BOOLEAN
        assert by_key["copy_code"].kind == SiteFieldKind.BOOLEAN
        assert by_key["per_page"].kind == SiteFieldKind.INTEGER
        assert by_key["title"].kind == SiteFieldKind.TEXT

    def test_label_follows_language(self):
        title = next(item for item in SiteSettings.fields() if item.key == "title")
        assert title.label("zh") == "站点标题"
        assert title.label("en") == "Site title"


class TestValues:
    def test_reads_top_level_scalars(self):
        config = "title: 我的博客\ntheme: yun\nurl: https://example.com\n"
        values = SiteSettings.values(config)

        assert values["title"] == "我的博客"
        assert values["theme"] == "yun"
        assert values["url"] == "https://example.com"

    def test_missing_key_is_empty_string(self):
        values = SiteSettings.values("theme: yun\n")
        assert values.get("title", "") == ""


class TestNestedBlock:
    def test_block_form_is_detected(self):
        config = "index_generator:\n  per_page: 10\n  order_by: -date\n"
        assert SiteSettings.is_nested_block("index_generator", config) is True

    def test_scalar_form_is_not_a_block(self):
        config = "index_generator: 10\n"
        assert SiteSettings.is_nested_block("index_generator", config) is False

    def test_blank_lines_do_not_break_block_detection(self):
        config = "index_generator:\n\n  per_page: 10\n"
        assert SiteSettings.is_nested_block("index_generator", config) is True

    def test_unknown_key_is_not_a_block(self):
        assert SiteSettings.is_nested_block("nope", "title: x\n") is False

    def test_indented_key_below_another_key_is_not_top_level(self):
        config = "avatar:\n  url: /a.png\n"
        # url 是 avatar 的子键，不是顶层键
        assert SiteSettings.is_nested_block("url", config) is False


class TestSetValue:
    def test_replaces_value_and_keeps_comment(self):
        """改值保留行尾注释。

        Swift 侧 ``rewrite`` 拼的是 ``"{before}: {value} {comment}"``——
        注释前是**一个**空格，原来注释前的两个空格会被收成一个。
        """
        config = "title: Old  # 这是标题\ntheme: yun\n"
        updated = SiteSettings.set_value("New", "title", config)

        assert updated == "title: New # 这是标题\ntheme: yun\n"

    def test_indented_key_is_not_a_top_level_key(self):
        """缩进的键不是顶层键。

        Swift 的 ``topLevelKey`` 对以空格/制表符开头的行返回 ``nil``，
        所以 ``  title: Old`` 不会被当成顶层的 ``title``——它是别的键的子项。
        结果是新键被追加到文件末尾，而不是改到那一行。
        """
        config = "  title: Old\n"
        updated = SiteSettings.set_value("New", "title", config)

        assert updated == "  title: Old\ntitle: New"

    def test_appends_missing_key_at_end(self):
        config = "theme: yun\n"
        updated = SiteSettings.set_value("Hello", "title", config)

        assert updated == "theme: yun\ntitle: Hello"

    def test_append_does_not_insert_blank_lines(self):
        """一次写回十几个键时，每行都插空行会让文件凭空多出二十多行。"""
        config = "theme: yun\n\n\n"
        updated = SiteSettings.set_value("Hello", "title", config)

        assert updated == "theme: yun\ntitle: Hello"

    def test_append_to_empty_config(self):
        assert SiteSettings.set_value("Hello", "title", "") == "title: Hello"

    def test_nested_block_is_refused(self):
        config = "index_generator:\n  per_page: 10\n"
        with pytest.raises(SiteSettingsError) as error:
            SiteSettings.set_value("20", "index_generator", config)

        assert error.value.code == "keyHasNestedBlock"
        assert error.value.key == "index_generator"

    def test_refusal_leaves_the_file_untouched(self):
        config = "index_generator:\n  per_page: 10\n"
        with pytest.raises(SiteSettingsError):
            SiteSettings.set_value("20", "index_generator", config)

        # set_value 是纯函数，抛异常时不会改到调用方的字符串
        assert config == "index_generator:\n  per_page: 10\n"

    def test_boolean_writes_bare(self):
        updated = SiteSettings.set_value("true", "rss", "theme: yun\n")
        assert updated == "theme: yun\nrss: true"

    def test_dangerous_value_gets_quoted(self):
        updated = SiteSettings.set_value("a: b", "title", "theme: yun\n")
        assert '"a: b"' in updated

    def test_value_with_hash_gets_quoted(self):
        updated = SiteSettings.set_value("x # y", "title", "theme: yun\n")
        assert '"x # y"' in updated

    def test_url_anchor_is_not_treated_as_comment(self):
        """``https://a.com/#top`` 里的 # 前面没有空白，不是注释。"""
        config = "url: https://a.com/#top\n"
        updated = SiteSettings.set_value("https://b.com/#end", "url", config)

        assert updated == "url: https://b.com/#end\n"

    def test_comment_inside_quotes_is_not_a_comment(self):
        """引号里的 # 不是注释。

        Swift 的 ``commentStart`` 会跟踪单双引号状态，引号内的 ``#`` 不算注释，
        所以整行按普通值处理。
        """
        config = 'title: "old # keep"\n'
        updated = SiteSettings.set_value("new", "title", config)

        assert updated == "title: new\n"

    def test_empty_value_is_written_as_empty_string(self):
        """空值写成 ``""`` 而不是留空。

        Swift 的 ``format("")`` 返回空串，写出来是 ``title: ``——YAML 读回来
        是 **null**，不是空字符串。这里显式写 ``""``，语义才是「这个键有值，
        值是空的」。
        """
        updated = SiteSettings.set_value("", "subtitle", "title: x\n")

        assert updated == 'title: x\nsubtitle: ""'
