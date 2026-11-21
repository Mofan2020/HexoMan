"""YAML 文档树与路径读写。

对应 Swift 侧的 ``YAMLDocument.swift``（1200 多行）与 ``YAMLPathEngine``。

## 为什么要自己一层

``_config.yml`` 是用户手写的文件，里面有注释、有手抄的引号风格、有按
语义排的键顺序。用 ``yaml.safe_dump`` 序列化回去会把这些全洗掉——用户
只是改了个 ``theme``，整个文件却面目全非。

所以这里用 PyYAML 的 ``compose()`` 拿**带源码坐标**的节点树：每个节点都
知道自己占了原文哪一段。于是「改一个键」可以只替换那一段文本，其余字节
一个不动。

## 与 Swift 版的能力差异

Swift 版自己写了一套 YAML 解析器（``YAMLDocument.swift`` 有 1200 多行），
对畸形 YAML 更宽容。Python 版直接用 PyYAML：

- 合法 YAML：能力**超过** Swift 版（因为有源码坐标，能做外科手术式改写）。
- 非法 YAML：解析失败时 ``get`` 退回逐行扫顶层标量，``set`` **拒绝写入**
  （宁可不动，也不把用户文件改坏）。

这个取舍是有意的：配置改坏了很难恢复，而「读不到某个键」只是界面上少
显示一项。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Sequence

import yaml

from .yamlutil import format_scalar, parse_top_level_scalars

__all__ = [
    "YamlNode",
    "YamlEntry",
    "YamlDocument",
]


@dataclass
class YamlEntry:
    """映射里的一项：键 + 值节点。"""

    key: str
    node: "YamlNode"
    key_start: int = 0
    key_end: int = 0


@dataclass
class YamlNode:
    """YAML 树里的一个节点，带源码坐标。

    ``start`` / ``end`` 是该节点在原文里的字符区间（左闭右开）。
    ``start_line`` / ``end_line`` 是行号（0 起）。
    """

    kind: str  # "scalar" | "sequence" | "mapping"
    value: str = ""
    style: str | None = None
    tag: str = ""
    start: int = 0
    end: int = 0
    start_line: int = 0
    end_line: int = 0
    column: int = 0
    entries: list[YamlEntry] = field(default_factory=list)
    items: list["YamlNode"] = field(default_factory=list)

    # -- 判定 ---------------------------------------------------------

    @property
    def is_scalar(self) -> bool:
        return self.kind == "scalar"

    @property
    def is_sequence(self) -> bool:
        return self.kind == "sequence"

    @property
    def is_mapping(self) -> bool:
        return self.kind == "mapping"

    @property
    def is_block_scalar(self) -> bool:
        """是不是 ``|`` / ``>`` 写法的多行文本。"""
        return self.is_scalar and self.style in ("|", ">")

    @property
    def is_flow(self) -> bool:
        """是不是 ``[ ]`` / ``{ }`` 写法的流式结构。"""
        return self.style in ("[", "{")

    @property
    def is_null(self) -> bool:
        """空值（``avatar:`` 后面什么都不写）。"""
        return self.is_scalar and self.value == "" and self.style is None

    # -- 取子项 -------------------------------------------------------

    def child(self, key: str) -> "YamlNode | None":
        """按键取值。"""
        if not self.is_mapping:
            return None
        for entry in self.entries:
            if entry.key == key:
                return entry.node
        return None

    def to_python(self) -> Any:
        """转成普通 Python 对象（列表 / 字典 / 标量）。"""
        if self.is_mapping:
            return {entry.key: entry.node.to_python() for entry in self.entries}
        if self.is_sequence:
            return [item.to_python() for item in self.items]
        return self.value


class YamlDocument:
    """一份 YAML 文本的树 + 按路径读写的能力。"""

    def __init__(self, text: str) -> None:
        self.text = text or ""
        self.root: YamlNode | None = None
        self.error: str = ""
        self._scalars: dict[str, str] = {}

        try:
            composed = yaml.compose(self.text)
        except yaml.YAMLError as error:
            self.error = str(error)
            composed = None

        if composed is not None:
            self.root = _convert(composed)
        else:
            # 解析失败：留一个逐行扫出来的顶层标量表，至少还能读到几个键。
            self._scalars = parse_top_level_scalars(self.text)

    # -- 读 -----------------------------------------------------------

    def node_at(self, path: Sequence[str]) -> YamlNode | None:
        """按路径取节点。``path`` 是键名序列。"""
        node = self.root
        for key in path:
            if node is None:
                return None
            node = node.child(key)
        return node

    def get(self, path: str) -> str | None:
        """按点号路径取标量值。

        ``"avatar.url"`` → 头像地址。取不到或不是标量时返回 ``None``。
        """
        parts = [part for part in path.split(".") if part]
        if not parts:
            return None

        node = self.node_at(parts)
        if node is None:
            # 解析失败时的兜底：只认顶层标量。
            if len(parts) == 1:
                return self._scalars.get(parts[0])
            return None

        if not node.is_scalar:
            return None
        return node.value

    def top_level_entries(self) -> list[YamlEntry]:
        """顶层键值对。"""
        if self.root is None or not self.root.is_mapping:
            return []
        return list(self.root.entries)

    def top_level_keys(self) -> list[str]:
        return [entry.key for entry in self.top_level_entries()]

    # -- 写 -----------------------------------------------------------

    def set(self, path: str, value: str) -> str | None:
        """设置某个路径的值，返回**新的**全文。

        只有两种情况会成功：

        1. 叶子已存在且是标量 → 只替换它那一段文本。
        2. 父级映射已存在、叶子不存在 → 在父块末尾插入一行。

        父级不存在、或者叶子是个映射/序列时返回 ``None``（不改）。
        那种情况需要新建整块结构，交给 :mod:`hexoman.config_sync` 处理。
        """
        parts = [part for part in path.split(".") if part]
        if not parts:
            return None

        if self.root is None or not self.root.is_mapping:
            return None

        # 一路下探到父级映射
        parent = self.root
        for key in parts[:-1]:
            child = parent.child(key)
            if child is None or not child.is_mapping:
                return None
            parent = child

        leaf = parts[-1]
        rendered = format_scalar(value)
        existing = parent.child(leaf)

        if existing is not None:
            if not existing.is_scalar:
                # 叶子是映射或序列：整体替换会毁掉用户写的结构，不做。
                return None
            return self._replace_span(existing.start, existing.end, rendered)

        return self._insert_key(parent, leaf, rendered)

    # -- 内部 ---------------------------------------------------------

    def _replace_span(self, start: int, end: int, rendered: str) -> str:
        return self.text[:start] + rendered + self.text[end:]

    def _insert_key(self, parent: YamlNode, key: str, rendered: str) -> str | None:
        """在父映射块末尾插入一行 ``key: value``。"""
        if not parent.entries:
            return None

        last = parent.entries[-1]
        insert_line = last.node.end_line + 1
        indent = " " * parent.column

        lines = self.text.split("\n")
        if insert_line > len(lines):
            insert_line = len(lines)

        lines.insert(insert_line, f"{indent}{key}: {rendered}")
        return "\n".join(lines)


def _convert(node: Any) -> YamlNode:
    """把 PyYAML 的节点树转成自己的节点类型。"""
    if isinstance(node, yaml.MappingNode):
        entries: list[YamlEntry] = []
        for key_node, value_node in node.value:
            key = str(key_node.value)
            entries.append(
                YamlEntry(
                    key=key,
                    node=_convert(value_node),
                    key_start=key_node.start_mark.index,
                    key_end=key_node.end_mark.index,
                )
            )
        return YamlNode(
            kind="mapping",
            style="{" if node.flow_style else None,
            tag=str(node.tag),
            start=node.start_mark.index,
            end=node.end_mark.index,
            start_line=node.start_mark.line,
            end_line=node.end_mark.line,
            column=node.start_mark.column,
            entries=entries,
        )

    if isinstance(node, yaml.SequenceNode):
        return YamlNode(
            kind="sequence",
            style="[" if node.flow_style else None,
            tag=str(node.tag),
            start=node.start_mark.index,
            end=node.end_mark.index,
            start_line=node.start_mark.line,
            end_line=node.end_mark.line,
            column=node.start_mark.column,
            items=[_convert(item) for item in node.value],
        )

    return YamlNode(
        kind="scalar",
        value=str(node.value),
        style=node.style,
        tag=str(node.tag),
        start=node.start_mark.index,
        end=node.end_mark.index,
        start_line=node.start_mark.line,
        end_line=node.end_mark.line,
        column=node.start_mark.column,
    )
