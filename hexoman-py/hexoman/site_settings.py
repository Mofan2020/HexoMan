"""常用配置项的可视化编辑。

对应 Swift 侧的 ``SiteSettings.swift``。

## 为什么单独做这一层

Hexo 的 ``_config.yml`` 有上百个键，大部分是主题内部实现细节。
小白看到 ``theme: landscape`` 根本不知道该填什么，翻文档又慢。
这里挑出真正需要人改的那二十来个，其余原样留给「原始文件」页。

## 写入策略仍然是**保真优先**

只动目标那一行的值，保留行尾注释、保留键的原有顺序和缩进，绝不重排整个文件。

## 与 Swift 版的两处差异

1. **不用 YAML 解析器定位**。Swift 版按行扫文本，Python 版也按行扫——
   刻意**不用** :class:`~hexoman.yaml_path.YamlDocument`。站点配置被用户
   写坏过（``url: http://a: b`` 这类），YAML 解析器直接罢工，而「把
   ``title`` 那一行改掉」这件事跟整份文件是不是合法 YAML 无关。
   这里按行扫只认顶层键，缩进行、注释行、``---`` 一律跳过。

2. **标签走 i18n**。Swift 版把中文标签写死在结构体里，切英文就成了
   中英混杂。Python 版只存 key，文案从 :mod:`hexoman.i18n` 取，
   切语言立刻生效。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from .i18n import t as translate
from .yamlutil import format_scalar, parse_top_level_scalars

__all__ = [
    "SiteFieldKind",
    "SiteFieldGroup",
    "SiteField",
    "SiteSettings",
    "SiteSettingsError",
    "SITE_LANGUAGES",
]


class SiteFieldKind:
    """控件类型。"""

    TEXT = "text"
    INTEGER = "integer"
    BOOLEAN = "boolean"
    CHOICE = "choice"


class SiteFieldGroup:
    """分组。顺序就是界面上的显示顺序。"""

    BASIC = "basic"
    APPEARANCE = "appearance"
    CONTENT = "content"
    SOCIAL = "social"

    #: 全部分组，按界面顺序排。
    ORDER = (BASIC, APPEARANCE, CONTENT, SOCIAL)


#: 站点语言选项。
#:
#: 注意 ``zh-CN`` 必须在列表里：Hexo 官方的 ``_config.yml`` 默认值就是
#: ``zh-CN``，而 ``hexo new`` 生成的站点也都带这个值。少了它的话，
#: 新建的站点打开「站点语言」就是一个空白下拉，而且选了也存不进去。
#:
#: 这些标签是语言自己的名字（endonym），不翻译。
SITE_LANGUAGES: tuple[dict[str, str], ...] = (
    {"value": "zh-CN", "label": "简体中文"},
    {"value": "zh", "label": "简体中文（部分主题用这个）"},
    {"value": "zh-TW", "label": "繁體中文"},
    {"value": "en", "label": "English"},
    {"value": "ja", "label": "日本語"},
    {"value": "ko", "label": "한국어"},
    {"value": "ru", "label": "Русский"},
)


@dataclass(frozen=True)
class SiteField:
    """一个可可视化编辑的配置项。"""

    #: ``_config.yml`` 里的键名
    key: str
    #: 标签的文案 key（不是文案本身——文案在 i18n 里）
    label_key: str
    #: 说明文字的文案 key
    hint_key: str
    #: 分组
    group: str
    #: 控件类型
    kind: str = SiteFieldKind.TEXT
    #: ``choice`` 类型的候选项
    options: tuple[dict[str, str], ...] = field(default=())

    @property
    def id(self) -> str:
        return self.key

    def label(self, language: str = "zh") -> str:
        return translate(self.label_key, language)

    def hint(self, language: str = "zh") -> str:
        return translate(self.hint_key, language)

    def to_dict(self, language: str = "zh") -> dict[str, Any]:
        return {
            "id": self.id,
            "key": self.key,
            "label": self.label(language),
            "hint": self.hint(language),
            "group": self.group,
            "kind": self.kind,
            "options": [dict(option) for option in self.options],
        }


class SiteSettingsError(Exception):
    """常用配置写不进去。"""

    def __init__(self, code: str, key: str = "", message: str = "") -> None:
        super().__init__(message or code)
        self.code = code
        self.key = key
        self.message = message or code


#: 常用配置项清单。刻意保持精简——塞太多会让「常用」失去意义。
FIELDS: tuple[SiteField, ...] = (
    # -- 站点信息 --
    SiteField("title", "siteSettings.label.title", "siteSettings.hint.title", SiteFieldGroup.BASIC),
    SiteField("subtitle", "siteSettings.label.subtitle", "siteSettings.hint.subtitle", SiteFieldGroup.BASIC),
    SiteField("description", "siteSettings.label.description", "siteSettings.hint.description", SiteFieldGroup.BASIC),
    SiteField("author", "siteSettings.label.author", "siteSettings.hint.author", SiteFieldGroup.BASIC),
    SiteField("url", "siteSettings.label.url", "siteSettings.hint.url", SiteFieldGroup.BASIC),
    SiteField(
        "language",
        "siteSettings.label.language",
        "siteSettings.hint.language",
        SiteFieldGroup.BASIC,
        SiteFieldKind.CHOICE,
        SITE_LANGUAGES,
    ),
    SiteField("timezone", "siteSettings.label.timezone", "siteSettings.hint.timezone", SiteFieldGroup.BASIC),
    # -- 外观 --
    SiteField("theme", "siteSettings.label.theme", "siteSettings.hint.theme", SiteFieldGroup.APPEARANCE),
    SiteField("avatar", "siteSettings.label.avatar", "siteSettings.hint.avatar", SiteFieldGroup.APPEARANCE),
    SiteField("favicon", "siteSettings.label.favicon", "siteSettings.hint.favicon", SiteFieldGroup.APPEARANCE),
    SiteField("rss", "siteSettings.label.rss", "siteSettings.hint.rss", SiteFieldGroup.APPEARANCE, SiteFieldKind.BOOLEAN),
    # -- 内容与分页 --
    SiteField("per_page", "siteSettings.label.per_page", "siteSettings.hint.per_page", SiteFieldGroup.CONTENT, SiteFieldKind.INTEGER),
    SiteField("index_generator", "siteSettings.label.index_generator", "siteSettings.hint.index_generator", SiteFieldGroup.CONTENT, SiteFieldKind.INTEGER),
    SiteField("archive_generator", "siteSettings.label.archive_generator", "siteSettings.hint.archive_generator", SiteFieldGroup.CONTENT, SiteFieldKind.INTEGER),
    SiteField("tag_generator", "siteSettings.label.tag_generator", "siteSettings.hint.tag_generator", SiteFieldGroup.CONTENT, SiteFieldKind.INTEGER),
    SiteField("category_generator", "siteSettings.label.category_generator", "siteSettings.hint.category_generator", SiteFieldGroup.CONTENT, SiteFieldKind.INTEGER),
    SiteField("copy_code", "siteSettings.label.copy_code", "siteSettings.hint.copy_code", SiteFieldGroup.CONTENT, SiteFieldKind.BOOLEAN),
    # -- 社交链接 --
    SiteField("github", "siteSettings.label.github", "siteSettings.hint.github", SiteFieldGroup.SOCIAL),
    SiteField("twitter", "siteSettings.label.twitter", "siteSettings.hint.twitter", SiteFieldGroup.SOCIAL),
    SiteField("facebook", "siteSettings.label.facebook", "siteSettings.hint.facebook", SiteFieldGroup.SOCIAL),
    SiteField("weibo", "siteSettings.label.weibo", "siteSettings.hint.weibo", SiteFieldGroup.SOCIAL),
    SiteField("zhihu", "siteSettings.label.zhihu", "siteSettings.hint.zhihu", SiteFieldGroup.SOCIAL),
)


class SiteSettings:
    """常用配置项清单与读写。"""

    #: 收录的配置项。
    FIELDS: tuple[SiteField, ...] = FIELDS

    @classmethod
    def fields(cls, group: str = "") -> list[SiteField]:
        """按分组整理；``group`` 为空时返回全部（按分组顺序）。"""
        if group:
            return [item for item in cls.FIELDS if item.group == group]

        ordered: list[SiteField] = []
        for name in SiteFieldGroup.ORDER:
            ordered.extend(item for item in cls.FIELDS if item.group == name)
        return ordered

    @classmethod
    def groups(cls) -> list[str]:
        """分组顺序。"""
        return list(SiteFieldGroup.ORDER)

    @classmethod
    def values(cls, config: str) -> dict[str, str]:
        """读出所有收录项的当前值。

        只取顶层标量——``index_generator`` 这种展开成多行的块，
        这里读不到值（那是 :meth:`is_nested_block` 要管的事）。
        """
        return parse_top_level_scalars(config)

    @classmethod
    def is_nested_block(cls, key: str, config: str) -> bool:
        """这个键在当前配置里是不是一个「多行块」。

        为什么要单独判断：``index_generator`` 这类键，在不同站点里形态不一样——
        有人写 ``per_page: 10`` 一行搞定，有人展开成::

            index_generator:
              per_page: 10
              order_by: -date

        展开的情况下 HexoMan 绝不能去改它（会把整个块改坏），
        界面上也应该只读展示并引导去「原始文件」页，而不是给一个改了必然报错的输入框。
        """
        lines = config.split("\n")
        index = _find_top_level_key(lines, key)
        if index is None:
            return False

        # 往后找第一个非空行：中间隔了空行也还是这个键的块
        cursor = index + 1
        while cursor < len(lines):
            if not lines[cursor].strip():
                cursor += 1
                continue
            return _is_indented(lines[cursor])
        return False

    @classmethod
    def set_value(cls, raw_value: str, key: str, config: str) -> str:
        """把一个键的值写回 YAML 文本，返回**新的**全文。

        三种情况分别处理：

        1. 已有 ``key: value`` → 只换值，行尾注释保留
        2. 已有 ``key:`` 但下面跟缩进块 → **拒绝写入**并抛
           :class:`SiteSettingsError`。硬改会把整个嵌套结构搞坏，
           这是这里最重要的安全边界。
        3. 没有这个键 → 追加到文件末尾
        """
        value = raw_value.strip()
        lines = config.split("\n")

        index = _find_top_level_key(lines, key)
        if index is not None:
            # 下面隔几行空行也算挂着块，所以要跳过空行再判断
            cursor = index + 1
            while cursor < len(lines) and not lines[cursor].strip():
                cursor += 1
            if cursor < len(lines) and _is_indented(lines[cursor]):
                raise SiteSettingsError("keyHasNestedBlock", key)

            lines[index] = _rewrite_line(lines[index], value)
            return "\n".join(lines)

        # 文件末尾追加。刻意**不**在前面插空行：
        # 可视化页一次可能写回十几个键，每行都插一个空行会让文件凭空多出二十多行。
        # 先把末尾空行收干净，再直接追加，跟人在编辑器里手动加一行是一回事。
        while lines and not lines[-1].strip():
            lines.pop()

        if not lines:
            return f"{key}: {format_scalar(value)}"

        lines.append(f"{key}: {format_scalar(value)}")
        return "\n".join(lines)


# -- 行处理 ---------------------------------------------------------


def _find_top_level_key(lines: list[str], key: str) -> int | None:
    """找顶层键所在的行号。找不到返回 ``None``。"""
    for index, line in enumerate(lines):
        if _top_level_key(line) == key:
            return index
    return None


def _top_level_key(line: str) -> str | None:
    """取一行的顶层键名。缩进行、注释行、``---`` 都返回 ``None``。"""
    if not line or line[0] in " \t#-":
        return None
    if line.startswith("---") or line.startswith("..."):
        return None
    colon = line.find(":")
    if colon < 0:
        return None
    name = line[:colon].strip()
    return name or None


def _is_indented(line: str) -> bool:
    """这一行是不是缩进（属于某个键下面的块）。"""
    if not line:
        return False
    return line[0] in " \t"


def _rewrite_line(line: str, value: str) -> str:
    """替换一行的值，保留行尾注释和原有缩进习惯。"""
    colon = line.find(":")
    if colon < 0:
        return f"{line}: {format_scalar(value)}"

    before = line[:colon]
    tail = line[colon + 1 :]

    # 行尾注释只在 # 前是空白时才算注释，否则可能是 URL 里的锚点
    comment = _comment_start(tail)
    if comment is not None:
        return f"{before}: {format_scalar(value)} {tail[comment:]}"
    return f"{before}: {format_scalar(value)}"


def _comment_start(tail: str) -> int | None:
    """找出 `` #`` 注释的起始下标，没有则返回 ``None``。"""
    in_single = False
    in_double = False

    for index, character in enumerate(tail):
        if character == "'" and not in_double:
            in_single = not in_single
        elif character == '"' and not in_single:
            in_double = not in_double
        elif character == "#" and not in_single and not in_double:
            if index > 0 and tail[index - 1].isspace():
                return index
    return None
