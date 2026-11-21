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
    "YamlFormat",
]


class YamlFormat:
    """回写时的引号策略。

    对应 Swift 侧的 ``YAMLFormat``。区别在于：Swift 版是自己写的一整套
    YAML 解析器，这里的标量编码直接复用 :func:`hexoman.yamlutil.format_scalar`
    ——两边的「危险字符」清单本来就对齐过。
    """

    #: 尽量裸写，保持文件清爽
    AUTO = "auto"
    #: 一定是字符串（``true`` / ``123`` 这类要强制加引号）
    TEXT = "text"
    #: 一定是布尔
    BOOLEAN = "boolean"
    #: 一定是整数
    INTEGER = "integer"
    #: 原样写入，不加工
    RAW = "raw"

    @staticmethod
    def encode(value: str, hint: str = AUTO, keep_quote: str | None = None) -> str:
        """把用户输入的值编码成 YAML 文本。"""
        if hint == YamlFormat.RAW:
            return value

        if keep_quote is not None:
            return YamlFormat._quote(value, keep_quote)

        if hint == YamlFormat.TEXT:
            if value == "" or YamlFormat.looks_like_non_string(value):
                return YamlFormat._quote(value, '"')
            return format_scalar(value)

        return format_scalar(value)

    @staticmethod
    def _quote(value: str, quote: str) -> str:
        if quote == "'":
            return "'" + value.replace("'", "''") + "'"
        escaped = (
            value.replace("\\", "\\\\")
            .replace('"', '\\"')
            .replace("\n", "\\n")
        )
        return '"' + escaped + '"'

    @staticmethod
    def looks_like_non_string(value: str) -> bool:
        """这个值裸写出来会不会被 YAML 读成别的类型。"""
        lowered = value.lower()
        if lowered in ("true", "false", "yes", "no", "on", "off", "null", "~", "y", "n"):
            return True
        try:
            int(value)
            return True
        except ValueError:
            pass
        try:
            float(value)
            return True
        except ValueError:
            return False


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
        #: 原文按行切分的缓存。写操作会把它置空。
        self._line_cache: list[str] | None = None

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

    def trimmed_string(self, path: str) -> str | None:
        """取标量值并去掉两端空白。"""
        value = self.get(path)
        return value.strip() if value is not None else None

    def bool(self, path: str) -> bool | None:
        """取布尔值。认 ``true/false/yes/no/on/off``（大小写不敏感）。"""
        value = self.get(path)
        if value is None:
            return None
        lowered = value.strip().lower()
        if lowered in ("true", "yes", "on", "1"):
            return True
        if lowered in ("false", "no", "off", "0"):
            return False
        return None

    def int(self, path: str) -> int | None:
        """取整数。取不到或不是整数时返回 ``None``。"""
        value = self.get(path)
        if value is None:
            return None
        try:
            return int(value.strip())
        except (TypeError, ValueError):
            return None

    def exists(self, path: str) -> bool:
        """这个路径下有没有东西（不一定是标量）。"""
        parts = [part for part in path.split(".") if part]
        if not parts:
            return False
        return self.node_at(parts) is not None

    def has_block_children(self, path: str) -> bool:
        """这个路径下是不是挂着一整块（映射或序列）。

        对应 Swift 的 ``hasBlockChildren``。改这种键的时候必须**拒绝**——
        把它压成一行会毁掉用户写的结构。
        """
        parts = [part for part in path.split(".") if part]
        if not parts:
            return False
        node = self.node_at(parts)
        if node is None:
            return False
        if node.is_mapping:
            return bool(node.entries)
        if node.is_sequence:
            return bool(node.items)
        return False

    def count_at(self, path: str) -> int:
        """这个路径下有几项（序列的项数或映射的键数）。"""
        parts = [part for part in path.split(".") if part]
        if not parts:
            return 0
        node = self.node_at(parts)
        if node is None:
            return 0
        if node.is_sequence:
            return len(node.items)
        if node.is_mapping:
            return len(node.entries)
        return 0

    def keys_at(self, path: str) -> list[str]:
        """这个路径下的键名（映射才有）。"""
        parts = [part for part in path.split(".") if part]
        if not parts:
            return []
        node = self.node_at(parts)
        if node is None or not node.is_mapping:
            return []
        return [entry.key for entry in node.entries]

    def item_value(self, index: int, field: str, path: str) -> str | None:
        """序列里第 ``index`` 项的某个字段的值。

        ``item_value(0, "name", "social")`` → ``social`` 第一项的 ``name``。
        """
        parts = [part for part in path.split(".") if part]
        if not parts:
            return None
        node = self.node_at(parts)
        if node is None or not node.is_sequence:
            return None
        if not 0 <= index < len(node.items):
            return None

        item = node.items[index]
        if item.is_mapping:
            for entry in item.entries:
                if entry.key == field and entry.node.is_scalar:
                    return entry.node.value
            return None

        if item.is_scalar and field == "":
            return item.value
        return None

    def item_values(self, field: str, path: str) -> list[str]:
        """序列里每一项的某个字段的值（没有这项的跳过）。"""
        parts = [part for part in path.split(".") if part]
        if not parts:
            return []
        node = self.node_at(parts)
        if node is None or not node.is_sequence:
            return []

        values: list[str] = []
        for item in node.items:
            if not item.is_mapping:
                continue
            for entry in item.entries:
                if entry.key == field and entry.node.is_scalar:
                    values.append(entry.node.value)
                    break
        return values

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
        #
        # 这里只查 child 是不是 None，不查它是不是映射：child() 对标量或序列
        # 都返回一个节点，但那种节点的 entries 是空的，后面的 parent.child(leaf)
        # 会拿到 None，_insert_key 也会因为 entries 为空返回 None ——
        # 结果和不检查一样。多一个判断只是让人以为这里处理了两种情况。
        parent = self.root
        for key in parts[:-1]:
            child = parent.child(key)
            if child is None:
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

    def remove_key(self, path: str) -> str | None:
        """删除映射里的某个键（含它下面的整块），返回**新的**全文。

        删不掉时返回 ``None``（路径不存在、父级不是映射）。
        """
        parts = [part for part in path.split(".") if part]
        if not parts:
            return None

        parent = self.root if len(parts) == 1 else self.node_at(parts[:-1])
        if parent is None or not parent.is_mapping:
            return None

        leaf = parts[-1]
        entry = next((item for item in parent.entries if item.key == leaf), None)
        if entry is None:
            return None

        # 键所在的那一行 + 它下面缩进更深的子行，整块删掉。
        key_line = self._line_of(entry.key_start)
        end_line = self._block_end(key_line, self._indent_of(key_line))
        return self._delete_lines(key_line, end_line)

    def remove_item(self, index: int, path: str) -> str | None:
        """删除序列里的第 ``index`` 项（含它的所有字段行）。"""
        parts = [part for part in path.split(".") if part]
        if not parts:
            return None

        node = self.node_at(parts)
        if node is None or not node.is_sequence:
            return None
        if not 0 <= index < len(node.items):
            return None

        item = node.items[index]
        dash_line = self._line_of(item.start)
        dash_indent = self._indent_of(dash_line)
        end_line = self._block_end(dash_line, dash_indent)
        return self._delete_lines(dash_line, end_line)

    def append_item(self, pairs: list[tuple[str, str]], path: str) -> str | None:
        """往序列末尾追加一项（形如 ``- name: …``）。

        ``pairs`` 是 ``(键, 值)`` 列表，第一个键会写在短横线后面。
        """
        if not pairs:
            return None

        parts = [part for part in path.split(".") if part]
        if not parts:
            return None

        node = self.node_at(parts)
        dash_indent = 0
        insert_line = -1

        if node is not None and node.is_sequence and node.items:
            # 用序列自己的缩进（短横线所在列），不是首项字段的列——
            # 后者比短横线右移两格，拿来当缩进会把新项顶到列表外面去。
            first_line = self._line_of(node.items[0].start)
            dash_indent = self._indent_of(first_line)
            last_line = self._line_of(node.items[-1].start)
            insert_line = self._block_end(last_line, dash_indent)
        else:
            # 键存在但下面是空的 → 在这一行下面铺开。
            key_node = node
            if key_node is None or not key_node.is_null:
                return None

            entry = self._entry_for(parts)
            if entry is None:
                return None

            key_line = self._line_of(entry.key_start)
            dash_indent = self._indent_of(key_line) + 2
            insert_line = key_line

        field_indent = dash_indent + 2
        rendered: list[str] = []
        head = " " * dash_indent + f"- {pairs[0][0]}: {format_scalar(pairs[0][1])}"
        rendered.append(head)
        for key, value in pairs[1:]:
            rendered.append(" " * field_indent + f"{key}: {format_scalar(value)}")

        return self._insert_lines(insert_line, rendered)

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

    def _delete_span(self, start: int, end: int) -> str | None:
        """删掉 ``[start, end)`` 这一段，连同它所在的整行。

        PyYAML 给的坐标是**值**的区间，不含行尾注释。所以按坐标切完之后
        还要把那一行剩下的部分（注释）一起清掉，否则会留下半行注释。
        """
        if start < 0 or end > len(self.text) or start >= end:
            return None

        line_start = self.text.rfind("\n", 0, start) + 1
        line_end = self.text.find("\n", end)
        if line_end < 0:
            line_end = len(self.text)
        else:
            line_end += 1

        return self.text[:line_start] + self.text[line_end:]

    def _lines(self) -> list[str]:
        """按行切分原文（缓存，避免反复切）。"""
        if self._line_cache is None:
            self._line_cache = self.text.split("\n")
        return self._line_cache

    def _line_of(self, index: int) -> int:
        """字符下标 → 行号（0 起）。"""
        if index <= 0:
            return 0
        return self.text.count("\n", 0, index)

    def _indent_of(self, line_index: int) -> int:
        """某一行的缩进宽度（制表符按 4 算）。"""
        lines = self._lines()
        if not 0 <= line_index < len(lines):
            return 0

        line = lines[line_index]
        indent = 0
        for character in line:
            if character == " ":
                indent += 1
            elif character == "\t":
                indent += 4
            else:
                break
        return indent

    def _block_end(self, line_index: int, indent: int) -> int:
        """一个键（或列表项）所在块的**最后一行**（含）。

        块的定义：**比 ``indent`` 缩进更深**的行都算块的内容。
        空行算不算取决于它后面还有没有块内容——文件末尾的空行不算。
        """
        lines = self._lines()
        last = line_index

        for index in range(line_index + 1, len(lines)):
            line = lines[index]
            if not line.strip():
                # 空行先记着，遇到缩进更深的行就并进块；遇到同级行就丢掉。
                continue

            if self._indent_of(index) > indent:
                last = index
                continue

            break

        return last

    def _delete_lines(self, first: int, last: int) -> str:
        """删掉 ``[first, last]`` 这一段行（含两端）。"""
        lines = list(self._lines())
        del lines[first : last + 1]
        self._line_cache = None
        return "\n".join(lines)

    def _entry_for(self, parts: list[str]) -> YamlEntry | None:
        """按路径找到最后一段的映射项（用来拿它的键起始位置）。"""
        parent = self.root if len(parts) == 1 else self.node_at(parts[:-1])
        if parent is None or not parent.is_mapping:
            return None

        leaf = parts[-1]
        return next((item for item in parent.entries if item.key == leaf), None)

    def _insert_lines(self, insert_line: int, rendered: list[str]) -> str:
        """在第 ``insert_line`` 行之后插入几行。"""
        lines = list(self._lines())
        if insert_line >= len(lines):
            insert_line = len(lines) - 1
        lines[insert_line + 1 : insert_line + 1] = rendered
        self._line_cache = None
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
