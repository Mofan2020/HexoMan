"""YAML 读取的公共工具。

Hexo 的 ``_config.yml`` 和文章 front matter 都是 YAML，但两者对本项目的
要求不同：

- ``_config.yml`` 只需要读顶层标量（title / url / theme / new_dir …），
  嵌套块整体忽略。
- front matter 需要「读到什么就写回什么」，所以解析和回写是分开的，
  见 :mod:`hexoman.frontmatter`。

统一走 PyYAML，但**必须**有手写解析兜底：Hexo 生态里大量配置文件是
「YAML-like」而不是合法 YAML（值里带冒号没加引号、Tab 缩进、自定义标签），
PyYAML 直接抛 ``YAMLError``，而这些字段恰恰是总览页要显示的。
"""

from __future__ import annotations

from typing import Any

import yaml

__all__ = ["load_yaml_mapping", "parse_top_level_scalars", "format_scalar"]


def load_yaml_mapping(text: str) -> dict[str, Any]:
    """把 YAML 文本读成字典。

    解析失败**不抛错**，退回手写的顶层标量解析。理由：front matter 是用户
    手写的内容，一个手滑的冒号不该让整篇文章在列表里打不开。
    """
    try:
        loaded = yaml.safe_load(text)
    except yaml.YAMLError:
        return parse_top_level_scalars(text)

    if isinstance(loaded, dict):
        return loaded
    if loaded is None:
        return {}
    # 顶层不是映射（例如写成了列表）时也走兜底，至少还能读到几个键。
    return parse_top_level_scalars(text)


def parse_top_level_scalars(text: str) -> dict[str, str]:
    """只取第一列的 ``key: value``，值一律当字符串。

    缩进行属于嵌套块，直接跳过 —— 本函数不负责理解嵌套结构。
    """
    result: dict[str, str] = {}

    for raw_line in text.splitlines():
        if not raw_line or raw_line[0] in " \t#-":
            continue
        if raw_line.startswith("---") or raw_line.startswith("..."):
            continue

        colon = raw_line.find(":")
        if colon < 0:
            continue

        key = raw_line[:colon].strip()
        if not key:
            continue

        result[key] = _strip_comment(raw_line[colon + 1 :].strip())

    return result


def _strip_comment(value: str) -> str:
    """剥掉行尾注释，引号内的 ``#`` 不算注释。

    ``url: https://example.com/#anchor`` 这种写法很常见，把 ``#anchor``
    当注释砍掉会得到一个坏链接。
    """
    in_single = False
    in_double = False

    for index, char in enumerate(value):
        if char == "'" and not in_double:
            in_single = not in_single
        elif char == '"' and not in_single:
            in_double = not in_double
        elif char == "#" and not in_single and not in_double:
            previous = value[index - 1] if index > 0 else " "
            if previous.isspace():
                return value[:index].strip()
            continue

    return value


def format_scalar(value: str) -> str:
    """把一个字符串渲染成 YAML 标量，必要时加引号。

    「必要时」的判据是「不加会被 YAML 误读」：值本身是布尔/数字字面量、
    以特殊字符开头、或者含 ``: `` / `` #`` 这类会截断值的符号。

    规则和 Swift 版 ``ConfigSync.formatScalar`` 保持一致：``true`` /
    ``false`` 和纯数字保持裸写（它们本来就是 YAML 的布尔与数字类型，
    加引号反而改变了语义），其余危险值加双引号并转义。
    """
    if value == "":
        return '""'
    if value in ("true", "false"):
        return value

    try:
        int(value)
        return value
    except ValueError:
        pass

    dangerous = (
        ": ",
        " #",
        "'",
        '"',
        "\n",
        "[",
        "]",
        "{",
        "}",
        ",",
        "&",
        "*",
        "!",
        "|",
        ">",
        "%",
        "@",
        "`",
    )
    if any(token in value for token in dangerous):
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'

    return value
