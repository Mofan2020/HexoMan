"""配置表单的自动生成（ConfigSchema / ConfigDocs）。"""

from __future__ import annotations

from hexoman.config_docs import ConfigDocs
from hexoman.config_schema import ConfigSchema, ConfigKnowledge, KIND_CHOICE
from hexoman.yaml_path import YamlDocument


SAMPLE = """title: 我的博客
url: https://example.com
per_page: 10
rss: true
color: "#0078E7"
favicon: /images/fav.png
theme: yun
avatar:
  url: /images/me.png
  rounded: true
social:
  - name: GitHub
    link: https://github.com/me
  - https://example.com/rss
"""


def _fields():
    document = YamlDocument(SAMPLE)
    return {field.id: field for field in ConfigSchema.fields(document)}


def test_fields_include_top_level_keys():
    fields = _fields()
    assert "title" in fields
    assert "url" in fields
    assert "per_page" in fields


def test_scalar_kinds_inferred_from_value_shape():
    fields = _fields()
    assert fields["per_page"].kind == "integer"
    assert fields["rss"].kind == "boolean"
    assert fields["color"].kind == "color"
    assert fields["favicon"].kind == "asset"
    assert fields["url"].kind == "url"


def test_known_keys_get_chinese_labels():
    fields = _fields()
    assert fields["title"].label == "站点标题"
    assert fields["per_page"].label == "每页文章数"
    assert fields["title"].is_known is True


def test_nested_mapping_becomes_group_with_children():
    fields = _fields()
    assert fields["avatar"].read_only_reason == "分组"
    assert fields["avatar"].child_count == 2
    assert fields["avatar.url"].value == "/images/me.png"
    assert fields["avatar.rounded"].kind == "boolean"


def test_sequence_becomes_readonly_list():
    fields = _fields()
    assert fields["social"].read_only_reason == "列表"
    assert fields["social"].child_count == 2


def test_choice_from_known_options():
    document = YamlDocument("language: zh-CN\n")
    fields = {field.id: field for field in ConfigSchema.fields(document)}

    assert fields["language"].kind == KIND_CHOICE
    values = [option["value"] for option in fields["language"].options]
    assert "zh-CN" in values


def test_doc_attached_for_known_key():
    fields = _fields()
    assert fields["url"].doc is not None
    assert "完整网址" in fields["url"].doc.summary


def test_generic_doc_for_unknown_color():
    document = YamlDocument("brand_color: '#ff0000'\n")
    field = ConfigSchema.fields(document)[0]

    assert field.kind == "color"
    assert field.doc is not None
    assert "十六进制" in field.doc.how_to_fill


def test_list_fields_scalar_items():
    document = YamlDocument(SAMPLE)
    items = ConfigSchema.list_fields(document, ["social"])

    assert len(items) == 2
    assert items[1].is_scalar is True
    assert items[1].scalar_value == "https://example.com/rss"


def test_list_fields_mapping_items():
    document = YamlDocument(SAMPLE)
    items = ConfigSchema.list_fields(document, ["social"])

    first = items[0]
    assert first.is_scalar is False
    assert first.title == "GitHub"
    keys = [field.key for field in first.fields]
    assert keys == ["name", "link"]


def test_list_fields_on_missing_path():
    document = YamlDocument(SAMPLE)
    assert ConfigSchema.list_fields(document, ["nope"]) == []


def test_humanize_falls_back_to_english():
    assert ConfigSchema.humanize("foobar_baz") == "Foobar Baz"
    assert ConfigSchema.humanize("avatar") == "头像"


def test_group_assignment():
    assert ConfigSchema.group_of("title") == "内容"
    assert ConfigSchema.group_of("theme") == "外观"
    assert ConfigSchema.group_of("source_dir") == "目录"
    assert ConfigSchema.group_of("deploy") == "部署"
    assert ConfigSchema.group_of("totally_unknown") == "其他"


def test_nested_key_hint_only_context_free_keys():
    # enable 在哪个父级下含义都一样
    assert ConfigSchema.nested_key_hint("enable") is not None
    # url 会随父级变义，不该套顶层说明
    assert ConfigSchema.nested_key_hint("url") is None


def test_fields_on_invalid_yaml_returns_empty():
    document = YamlDocument("bad: [unclosed\n")
    assert ConfigSchema.fields(document) == []


def test_config_docs_nested_lookup():
    doc = ConfigDocs.nested_doc("creative_commons", "license")
    assert doc is not None
    assert doc.options
    values = [option["value"] for option in doc.options]
    assert "by-nc-sa" in values


def test_config_docs_flat_lookup():
    doc = ConfigDocs.flat_doc("permalink")
    assert doc is not None
    assert "旧链接" in doc.tip


def test_config_docs_generic_by_kind():
    assert ConfigDocs.generic_doc("boolean") is not None
    assert ConfigDocs.generic_doc("readonly") is None
    assert ConfigDocs.generic_doc("text", "") is None
    assert ConfigDocs.generic_doc("text", "abc") is not None


def test_config_knowledge_covers_core_keys():
    for key in ("title", "url", "theme", "per_page", "timezone", "language"):
        assert ConfigKnowledge.lookup(key) is not None
