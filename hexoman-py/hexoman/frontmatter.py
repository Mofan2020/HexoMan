"""文章 front matter 的解析与回写。

设计目标只有一个：**读到什么样，写回去就还什么样。**

为什么不用 ``yaml.dump`` 直接序列化回去：dump 会洗掉注释、引号风格和
键顺序，用户只是改了个标题，文件却面目全非。Hexo 生态里 front matter
常带 ``<!-- more -->`` 之外的自由内容，还有嵌套列表（角色表、导航项），
这些东西被 dump 一次就再也回不去了。

所以这里把 front matter 拆成两份：

1. **结构化数据**（:attr:`FrontMatter.data`）用 PyYAML 解析，供界面读取
   title / date / tags / categories / draft。
2. **原始行**（:attr:`FrontMatter.raw_lines`）原样保留，供回写时逐行替换。

回写时只动「我们改过的键」，其它行一个字节都不动。
"""

from __future__ import annotations

import datetime as _dt
import re
from dataclasses import dataclass, field
from typing import Any

from .yamlutil import load_yaml_mapping

__all__ = [
    "FrontMatter",
    "RawEntry",
    "split",
    "render",
    "parse_date",
    "format_date",
    "raw_entries",
    "split_inline_list",
]

_DELIMITER = "---"


@dataclass
class FrontMatter:
    """一篇文章的 front matter。

    ``present`` 表示原文里**本来就有** front matter 块。没有 front matter
    的文章保存后也不应该凭空多出一个空的 ``---`` 块——那等于无端改动了
    用户文件。
    """

    present: bool = False
    data: dict[str, Any] = field(default_factory=dict)
    raw_lines: list[str] = field(default_factory=list)
    # 改动过的键 -> 新值。``None`` 不表示删除，删除走 ``removals``。
    updates: dict[str, Any] = field(default_factory=dict)
    removals: set[str] = field(default_factory=set)

    # -- 读取 ---------------------------------------------------------

    def get(self, key: str, default: Any = None) -> Any:
        if key in self.updates:
            return self.updates[key]
        return self.data.get(key, default)

    def get_str(self, key: str, default: str = "") -> str:
        value = self.get(key, default)
        if value is None:
            return default
        if isinstance(value, bool):
            return "true" if value else "false"
        return str(value)

    def get_bool(self, key: str, default: bool = False) -> bool:
        value = self.get(key)
        if value is None:
            return default
        if isinstance(value, bool):
            return value
        return str(value).strip().lower() in {"true", "yes", "1"}

    def get_list(self, key: str) -> list[str]:
        """取列表型字段。

        YAML 里可能是列表、可能是逗号分隔的字符串、也可能只有一个标量，
        三种都要认 —— 真实博客三种写法都见过。
        """
        value = self.get(key)
        if value is None:
            return []
        if isinstance(value, list):
            return [str(item).strip() for item in value if str(item).strip()]
        if isinstance(value, str):
            text = value.strip()
            if text.startswith("[") and text.endswith("]"):
                text = text[1:-1]
            return [item.strip() for item in text.split(",") if item.strip()]
        return [str(value).strip()]

    def get_date(self, key: str = "date") -> _dt.datetime | None:
        value = self.get(key)
        if isinstance(value, _dt.datetime):
            return value
        if isinstance(value, _dt.date):
            return _dt.datetime(value.year, value.month, value.day)
        if isinstance(value, str):
            return parse_date(value)
        return None

    # -- 改写 ---------------------------------------------------------

    def set(self, key: str, value: Any) -> None:
        self.updates[key] = value
        self.removals.discard(key)

    def remove(self, key: str) -> None:
        self.updates.pop(key, None)
        self.removals.add(key)

    # -- 常用字段 ------------------------------------------------------

    @property
    def title(self) -> str:
        return self.get_str("title")

    @property
    def date(self) -> _dt.datetime | None:
        return self.get_date("date")

    @property
    def tags(self) -> list[str]:
        return self.get_list("tags")

    @property
    def categories(self) -> list[str]:
        return self.get_list("categories")

    @property
    def is_draft(self) -> bool:
        return self.get_bool("draft")


def split(text: str) -> tuple[FrontMatter, str]:
    """把整篇文章切成 ``(front_matter, body)``。

    没有 front matter 时返回 ``(FrontMatter(present=False), 全文)``，
    正文就是原文——不做任何裁剪。

    ``---`` 没有闭合时同样按「没有 front matter」处理：宁可原样保留，
    也不要给用户文件补一个莫名其妙的 ``---`` 块。
    """
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    lines = normalized.split("\n")

    if not lines or lines[0].strip() != _DELIMITER:
        return FrontMatter(present=False), normalized

    closing = -1
    for index in range(1, len(lines)):
        if lines[index].strip() == _DELIMITER:
            closing = index
            break

    if closing < 0:
        return FrontMatter(present=False), normalized

    raw_lines = lines[1:closing]
    body = "\n".join(lines[closing + 1 :])

    front = FrontMatter(
        present=True,
        data=load_yaml_mapping("\n".join(raw_lines)),
        raw_lines=raw_lines,
    )
    return front, body


def render(front: FrontMatter, body: str) -> str:
    """把 front matter 与正文拼回完整文件。"""
    if not front.present and not front.updates and not front.removals:
        return body

    lines = list(front.raw_lines)

    for key in front.removals:
        lines = _remove_key(lines, key)

    for key, value in front.updates.items():
        lines = _set_key(lines, key, value)

    block = "\n".join(lines).strip("\n")
    if not block:
        return f"{_DELIMITER}\n{_DELIMITER}\n{body}"

    return f"{_DELIMITER}\n{block}\n{_DELIMITER}\n{body}"


# -- 内部：逐行改写 ----------------------------------------------------


def _key_pattern(key: str) -> re.Pattern[str]:
    """匹配顶层的 ``key:``。

    必须要求 ``key`` 出现在第一列，否则 ``tags:`` 会命中缩进块里的
    ``  - tags: xxx``。
    """
    return re.compile(r"^" + re.escape(key) + r"\s*:")


def _block_end(lines: list[str], start: int) -> int:
    """返回 ``key`` 所属块的结束下标（不含）。

    块的定义是：键所在行 + 其后所有缩进行。空行归块，碰到下一个顶格键结束。
    """
    index = start + 1
    while index < len(lines):
        line = lines[index]
        if not line.strip():
            index += 1
            continue
        if line[0] in " \t":
            index += 1
            continue
        break
    return index


def _set_key(lines: list[str], key: str, value: Any) -> list[str]:
    """设置顶层键，保留其它行原样。

    键不存在就追加到块末尾；键存在就替换它和它下面的缩进块。
    """
    pattern = _key_pattern(key)
    rendered = _render_value(key, value)

    for index, line in enumerate(lines):
        if not pattern.match(line):
            continue
        end = _block_end(lines, index)
        return lines[:index] + rendered + lines[end:]

    return lines + rendered


def _remove_key(lines: list[str], key: str) -> list[str]:
    pattern = _key_pattern(key)
    for index, line in enumerate(lines):
        if not pattern.match(line):
            continue
        end = _block_end(lines, index)
        return lines[:index] + lines[end:]
    return lines


def _render_value(key: str, value: Any) -> list[str]:
    """把一个键值渲染成 YAML 行。"""
    if value is None:
        return [f"{key}:"]

    if isinstance(value, bool):
        return [f"{key}: {'true' if value else 'false'}"]

    if isinstance(value, _dt.datetime):
        return [f"{key}: {format_date(value)}"]

    if isinstance(value, _dt.date):
        return [f"{key}: {value.strftime('%Y-%m-%d')}"]

    if isinstance(value, (int, float)):
        return [f"{key}: {value}"]

    if isinstance(value, list):
        if not value:
            return [f"{key}:"]
        # 块状列表是 `hexo new` 的默认产物，也是绝大多数真实博客的写法
        return [f"{key}:"] + [f"  - {_scalar(item)}" for item in value]

    if isinstance(value, dict):
        import yaml

        dumped = yaml.safe_dump(
            value, allow_unicode=True, default_flow_style=False, sort_keys=False
        )
        indented = ["  " + line for line in dumped.rstrip("\n").split("\n")]
        return [f"{key}:"] + indented

    return [f"{key}: {_scalar(value)}"]


def _scalar(value: Any) -> str:
    """渲染标量，必要时加引号。

    加引号的判据是「不加会被 YAML 误读」：值里带 ``:`` / ``#``、
    以特殊字符开头、或者长得像数字/布尔。
    """
    text = str(value)
    if text == "":
        return '""'

    needs_quotes = (
        text.strip() != text
        or ": " in text
        or text.endswith(":")
        or "#" in text
        or text[0] in "-?:,[]{}#&*!|>'\"%@`"
        or text.lower() in {"true", "false", "yes", "no", "null", "none", "on", "off"}
        or _looks_numeric(text)
    )
    if not needs_quotes:
        return text

    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def _looks_numeric(text: str) -> bool:
    try:
        float(text)
    except ValueError:
        return False
    return True


# -- 日期 --------------------------------------------------------------

_DATE_FORMATS = (
    "%Y-%m-%d %H:%M:%S",
    "%Y-%m-%dT%H:%M:%S",
    "%Y-%m-%d %H:%M",
    "%Y-%m-%d",
    "%Y/%m/%d %H:%M:%S",
    "%Y/%m/%d",
)


def parse_date(text: str) -> _dt.datetime | None:
    """解析 front matter 里的日期。

    PyYAML 已经会把 ISO 日期解析成 ``datetime``，这个函数处理的是
    YAML 认不出的格式（``2026/11/20 10:00:00``、带时区后缀等）。
    """
    cleaned = text.strip().strip("'\"")
    if not cleaned:
        return None

    # 去掉末尾时区：本地时间语义下时区对文章日期没有意义
    if cleaned.endswith("Z"):
        cleaned = cleaned[:-1]
    elif "+" in cleaned[10:]:
        cleaned = cleaned[:10] + cleaned[10:].split("+", 1)[0]

    for fmt in _DATE_FORMATS:
        try:
            return _dt.datetime.strptime(cleaned, fmt)
        except ValueError:
            continue
    return None


def format_date(value: _dt.datetime) -> str:
    """渲染成 Hexo 生态最常见的 ``YYYY-MM-DD HH:mm:ss``。"""
    return value.strftime("%Y-%m-%d %H:%M:%S")


# -- 原始条目 ----------------------------------------------------------


@dataclass
class RawEntry:
    """front matter 里的一个原始条目。

    界面要显示的是「文件里实际写了什么」，而不是 PyYAML 解析出来的结果：
    块状列表 ``tags:`` 下面挂着几行 ``- xxx``，解析后只剩一个 list，
    但用户看到的是缩进的结构。``value`` 保留原文，``items`` 是块状列表
    拆出来的行，``verbatim_block`` 是多行文本块。
    """

    key: str
    value: str = ""
    is_block_list: bool = False
    verbatim_block: str = ""


def raw_entries(front: "FrontMatter") -> list[RawEntry]:
    """按文件里的顺序列出 front matter 的每一个键。

    键的**原始文本**（``rawValue``）保留引号和行尾写法，块状列表会被
    识别出来。界面据此决定给什么控件。
    """
    entries: list[RawEntry] = []
    lines = front.raw_lines
    index = 0

    while index < len(lines):
        line = lines[index]
        index += 1

        # 只认顶格键
        if not line or line[0] in " \t#-" or line.startswith("---"):
            continue

        colon = line.find(":")
        if colon < 0:
            continue

        key = line[:colon].strip()
        if not key:
            continue

        inline = line[colon + 1 :].strip()

        # 收集这个键下面的缩进块
        block: list[str] = []
        while index < len(lines):
            candidate = lines[index]
            if candidate.strip() and candidate[0] not in " \t":
                break
            block.append(candidate)
            index += 1

        is_block_list = any(
            stripped.startswith("- ") or stripped == "-"
            for stripped in (item.strip() for item in block)
            if stripped
        )

        verbatim = ""
        if block:
            # 去掉公共缩进，只留内容
            indents = [
                len(item) - len(item.lstrip())
                for item in block
                if item.strip()
            ]
            common = min(indents) if indents else 0
            verbatim = "\n".join(item[common:] if item.strip() else "" for item in block).strip("\n")

        entries.append(
            RawEntry(
                key=key,
                value=inline,
                is_block_list=is_block_list,
                verbatim_block=verbatim,
            )
        )

    return entries


def split_inline_list(inner: str) -> list[str]:
    """切分内联列表，**引号内的逗号不算分隔符**。

    ``["带,逗号", "普通"]`` 必须切出两项而不是三项。
    """
    items: list[str] = []
    current = ""
    quote: str | None = None

    for character in inner:
        if quote is not None:
            if character == quote:
                quote = None
            current += character
            continue

        if character in "\"'":
            quote = character
            current += character
            continue

        if character == ",":
            items.append(current)
            current = ""
            continue

        current += character

    tail = current.strip()
    if tail:
        items.append(tail)

    return [
        item.strip().strip("\"'").strip() for item in items if item.strip()
    ]
