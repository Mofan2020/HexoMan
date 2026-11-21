"""YAML 文档树的读写操作。

对应 Swift 侧 ``YAMLDocument.swift`` 的测试——尤其是 Swift 版才有的
写操作：删键、删列表项、追加列表项。
"""

from __future__ import annotations

from hexoman.yaml_path import YamlDocument, YamlFormat


class TestRead:
    def test_get_scalar(self):
        document = YamlDocument("title: Hello\ntheme: yun\n")
        assert document.get("title") == "Hello"
        assert document.get("theme") == "yun"

    def test_get_nested_path(self):
        document = YamlDocument("avatar:\n  url: /a.png\n  rounded: true\n")
        assert document.get("avatar.url") == "/a.png"
        assert document.get("avatar.rounded") == "true"

    def test_missing_key_is_none(self):
        assert YamlDocument("title: x\n").get("nope") is None

    def test_trimmed_string(self):
        document = YamlDocument("title: '  padded  '\n")
        assert document.trimmed_string("title") == "padded"

    def test_bool(self):
        document = YamlDocument("a: true\nb: false\nc: yes\nd: maybe\n")
        assert document.bool("a") is True
        assert document.bool("b") is False
        assert document.bool("c") is True
        assert document.bool("d") is None

    def test_int(self):
        document = YamlDocument("a: 10\nb: notanumber\n")
        assert document.int("a") == 10
        assert document.int("b") is None

    def test_exists(self):
        document = YamlDocument("title: x\navatar:\n  url: /a.png\n")
        assert document.exists("title") is True
        assert document.exists("avatar.url") is True
        assert document.exists("avatar.nope") is False

    def test_has_block_children(self):
        document = YamlDocument(
            "avatar:\n  url: /a.png\ntheme: yun\nper_page: 10\nsocial:\n  - name: a\n"
        )
        assert document.has_block_children("avatar") is True
        assert document.has_block_children("social") is True
        assert document.has_block_children("theme") is False
        assert document.has_block_children("per_page") is False

    def test_count_at(self):
        document = YamlDocument("social:\n  - name: a\n  - name: b\n")
        assert document.count_at("social") == 2

    def test_keys_at(self):
        document = YamlDocument("avatar:\n  url: /a.png\n  rounded: true\n")
        assert document.keys_at("avatar") == ["url", "rounded"]

    def test_item_value(self):
        document = YamlDocument(
            "social:\n  - name: GitHub\n    link: https://github.com/x\n"
            "  - name: Weibo\n    link: https://weibo.com/x\n"
        )
        assert document.item_value(0, "name", "social") == "GitHub"
        assert document.item_value(1, "link", "social") == "https://weibo.com/x"
        assert document.item_value(9, "name", "social") is None

    def test_item_values(self):
        document = YamlDocument(
            "social:\n  - name: GitHub\n  - name: Weibo\n"
        )
        assert document.item_values("name", "social") == ["GitHub", "Weibo"]


class TestRemoveKey:
    def test_removes_top_level_key(self):
        document = YamlDocument("title: Hello\ntheme: yun\n")
        updated = document.remove_key("title")

        assert updated == "theme: yun\n"
        assert "title" not in (updated or "")

    def test_removes_nested_block_with_children(self):
        """删 ``avatar:`` 时它下面的 url / rounded 也得一起删掉。"""
        document = YamlDocument(
            "title: Hello\navatar:\n  url: /a.png\n  rounded: true\ntheme: yun\n"
        )
        updated = document.remove_key("avatar")

        assert updated == "title: Hello\ntheme: yun\n"

    def test_removes_nested_key_inside_parent(self):
        document = YamlDocument("avatar:\n  url: /a.png\n  rounded: true\n")
        updated = document.remove_key("avatar.url")

        assert updated == "avatar:\n  rounded: true\n"

    def test_missing_key_returns_none(self):
        assert YamlDocument("title: x\n").remove_key("nope") is None

    def test_parent_not_mapping_returns_none(self):
        document = YamlDocument("title: x\n")
        assert document.remove_key("title.sub") is None

    def test_keeps_surrounding_content(self):
        document = YamlDocument("a: 1\nb: 2\nc: 3\n")
        updated = document.remove_key("b")

        assert updated == "a: 1\nc: 3\n"


class TestRemoveItem:
    def test_removes_first_item(self):
        document = YamlDocument(
            "social:\n  - name: GitHub\n    link: https://g\n  - name: Weibo\n    link: https://w\n"
        )
        updated = document.remove_item(0, "social")

        assert "GitHub" not in (updated or "")
        assert "Weibo" in (updated or "")

    def test_removes_last_item(self):
        document = YamlDocument(
            "social:\n  - name: GitHub\n    link: https://g\n  - name: Weibo\n    link: https://w\n"
        )
        updated = document.remove_item(1, "social")

        assert "GitHub" in (updated or "")
        assert "Weibo" not in (updated or "")

    def test_out_of_range_returns_none(self):
        document = YamlDocument("social:\n  - name: a\n")
        assert document.remove_item(5, "social") is None

    def test_not_a_sequence_returns_none(self):
        document = YamlDocument("social: notalist\n")
        assert document.remove_item(0, "social") is None


class TestAppendItem:
    def test_appends_to_existing_sequence(self):
        document = YamlDocument(
            "social:\n  - name: GitHub\n    link: https://g\n"
        )
        updated = document.append_item(
            [("name", "Weibo"), ("link", "https://w")], "social"
        )

        assert updated is not None
        assert "- name: GitHub" in updated
        assert "- name: Weibo" in updated
        assert "link: https://w" in updated

    def test_appended_item_keeps_sequence_indentation(self):
        """新项必须跟已有项同一个缩进——顶到外面去 Hexo 就读不到了。"""
        document = YamlDocument(
            "social:\n  - name: GitHub\n    link: https://g\n"
        )
        updated = document.append_item([("name", "Weibo")], "social")

        assert updated is not None
        assert "\n  - name: Weibo" in updated

    def test_appends_to_empty_key(self):
        """``social:`` 底下什么都没有时，在这一行下面铺开。"""
        document = YamlDocument("social:\n")
        updated = document.append_item([("name", "GitHub")], "social")

        assert updated is not None
        assert "social:\n  - name: GitHub" in updated

    def test_appends_to_missing_key_returns_none(self):
        document = YamlDocument("theme: yun\n")
        assert document.append_item([("name", "x")], "social") is None

    def test_appends_to_scalar_key_returns_none(self):
        document = YamlDocument("social: notalist\n")
        assert document.append_item([("name", "x")], "social") is None

    def test_empty_pairs_returns_none(self):
        document = YamlDocument("social:\n  - name: a\n")
        assert document.append_item([], "social") is None

    def test_result_is_valid_yaml(self):
        document = YamlDocument(
            "social:\n  - name: GitHub\n    link: https://g\n"
        )
        updated = document.append_item(
            [("name", "Weibo"), ("link", "https://w")], "social"
        )

        reparsed = YamlDocument(updated or "")
        assert reparsed.error == ""
        assert reparsed.item_values("name", "social") == ["GitHub", "Weibo"]


class TestYamlFormat:
    def test_auto_keeps_bare_scalars(self):
        assert YamlFormat.encode("yun") == "yun"
        assert YamlFormat.encode("10") == "10"
        assert YamlFormat.encode("true") == "true"

    def test_auto_quotes_dangerous_values(self):
        assert YamlFormat.encode("a: b") == '"a: b"'

    def test_text_hint_forces_quotes_on_booleans(self):
        """文本类型的 ``true`` 要加引号，否则 Hexo 那边读成了布尔。"""
        assert YamlFormat.encode("true", YamlFormat.TEXT) == '"true"'
        assert YamlFormat.encode("123", YamlFormat.TEXT) == '"123"'

    def test_text_hint_leaves_plain_words_alone(self):
        assert YamlFormat.encode("yun", YamlFormat.TEXT) == "yun"

    def test_raw_hint_writes_verbatim(self):
        assert YamlFormat.encode("a: b", YamlFormat.RAW) == "a: b"

    def test_keep_quote_preserves_single_quotes(self):
        assert YamlFormat.encode("it's", keep_quote="'") == "'it''s'"

    def test_looks_like_non_string(self):
        assert YamlFormat.looks_like_non_string("true") is True
        assert YamlFormat.looks_like_non_string("null") is True
        assert YamlFormat.looks_like_non_string("10") is True
        assert YamlFormat.looks_like_non_string("yun") is False
