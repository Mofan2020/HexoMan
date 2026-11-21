"""YAML 文档的按路径读写。"""

from __future__ import annotations

import pytest

from hexoman.yaml_path import YamlDocument


SAMPLE = """# 站点配置
# 这些注释必须原样保留
title: 我的博客
url: https://example.com   # 行尾注释
theme: yun
avatar:
  url: /images/avatar.png
  rounded: true
social:
  - name: GitHub
    link: https://github.com/me
footer:
  since: 2020
"""


def test_get_top_level_and_nested():
    document = YamlDocument(SAMPLE)
    assert document.get("title") == "我的博客"
    assert document.get("theme") == "yun"
    assert document.get("avatar.url") == "/images/avatar.png"
    assert document.get("footer.since") == "2020"


def test_get_missing_returns_none():
    document = YamlDocument(SAMPLE)
    assert document.get("nope") is None
    assert document.get("avatar.missing") is None
    # 映射节点不是标量，get 返回 None
    assert document.get("avatar") is None


def test_set_replaces_only_the_value():
    document = YamlDocument(SAMPLE)
    updated = document.set("theme", "landscape")

    assert updated is not None
    assert "theme: landscape" in updated
    # 注释、其它键、嵌套结构一个字节都没动
    assert "# 这些注释必须原样保留" in updated
    assert "url: https://example.com   # 行尾注释" in updated
    assert "  url: /images/avatar.png" in updated
    assert "social:" in updated
    assert YamlDocument(updated).get("avatar.url") == "/images/avatar.png"


def test_set_nested_leaf():
    document = YamlDocument(SAMPLE)
    updated = document.set("avatar.url", "/images/new.png")

    assert updated is not None
    assert "url: /images/new.png" in updated
    assert "/images/avatar.png" not in updated
    # 兄弟键不受影响
    assert "rounded: true" in updated


def test_set_quotes_when_needed():
    document = YamlDocument("title: plain\n")
    updated = document.set("title", "带: 冒号")
    assert updated is not None
    # 不加引号会被 YAML 截断成两个键
    assert '"带: 冒号"' in updated
    assert YamlDocument(updated).get("title") == "带: 冒号"


def test_set_missing_key_appends_to_block():
    document = YamlDocument("title: x\navatar:\n  url: /a.png\n")
    updated = document.set("avatar.rounded", "true")

    assert updated is not None
    parsed = YamlDocument(updated)
    assert parsed.get("avatar.rounded") == "true"
    assert parsed.get("avatar.url") == "/a.png"


def test_set_refuses_to_replace_mapping():
    document = YamlDocument(SAMPLE)
    # 目标是映射，整体替换会毁掉结构
    assert document.set("avatar", "oops") is None


def test_set_refuses_when_parent_missing():
    document = YamlDocument(SAMPLE)
    # 父级不存在时不该硬写，交给 config_sync 处理
    assert document.set("missing.child", "x") is None


def test_invalid_yaml_falls_back_to_scalars():
    broken = "title: x\nbad: [unclosed\n"
    document = YamlDocument(broken)
    assert document.root is None
    # 兜底仍能读到顶层标量
    assert document.get("title") == "x"
    # 解析不了就拒绝写入，不把文件改坏
    assert document.set("title", "y") is None


def test_top_level_keys():
    document = YamlDocument(SAMPLE)
    assert document.top_level_keys() == [
        "title",
        "url",
        "theme",
        "avatar",
        "social",
        "footer",
    ]


def test_block_scalar_detected():
    document = YamlDocument("skip_render: |\n  node_modules\n  public\n")
    node = document.node_at(["skip_render"])
    assert node is not None
    assert node.is_block_scalar
    assert "node_modules" in node.value


def test_flow_style_detected():
    document = YamlDocument("tags: [a, b]\n")
    node = document.node_at(["tags"])
    assert node is not None
    assert node.is_flow


@pytest.mark.parametrize(
    "text,path,expected",
    [
        ("a: 1\n", ["a"], "1"),
        ("a:\n  b:\n    c: deep\n", ["a", "b", "c"], "deep"),
        ('q: "quoted"\n', ["q"], "quoted"),
    ],
)
def test_various_shapes(text, path, expected):
    assert YamlDocument(text).node_at(path).value == expected
