"""站点配置与主题配置之间的公共项同步。

对应 Swift 侧的 ``ConfigSync.swift``。

## 要解决的问题

Hexo 的站点有两份配置：

    _config.yml            站点配置。Hexo 自己读的键在这里。
    _config.yun.yml        主题配置。主题**优先读自己这份**，同名键会盖掉站点配置。

于是头像、favicon、标题、副标题这类「两边都想写」的值就要写两遍。而用户
几乎只会去改 ``_config.yml``——因为它就叫「站点配置」，最显眼。

结果就是：改完头像，站点没反应。用户会反复检查自己有没有保存成功、有没有
重新生成，最后怀疑是工具坏了。**这是本功能要消灭的体验。**

## 原则

- **站点配置是唯一权威源**。改站点配置 → 自动把同样的值写到主题配置。
- 只同步「两边含义一致」的键。``sidebar`` / ``banner`` / ``menu`` 这类主题
  私有结构绝不同步——同步过去大概率把主题配置改坏。
- 用户可以手动关掉（``AppSettings.syncs_theme_config``）。

## 一个容易踩死的细节

「只在主题配置里配了」的情况**不能**当成差异自动抹平：很多人是把头像直接
写在主题配置里的，站点配置压根没这个键。按「站点是权威源」去清掉主题的值，
等于用户配好的头像当场消失。所以这类单独列出、只告知，由用户决定要不要
搬回站点配置。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from .yaml_path import YamlDocument
from .yamlutil import format_scalar

__all__ = ["SharedKey", "Difference", "ThemeOnlyEntry", "ConfigSync"]


@dataclass(frozen=True)
class SharedKey:
    """一个需要双份保持一致的键。"""

    key: str
    label: str
    note: str = ""


@dataclass
class Difference:
    """一处「两边不一样」。"""

    key: str
    label: str
    note: str = ""
    #: 站点配置（权威源）里的值
    site_value: str = ""
    #: 主题配置里的值
    theme_value: str = ""

    @property
    def id(self) -> str:
        return self.key

    @property
    def site_display(self) -> str:
        return self.site_value if self.site_value else "（未设置）"

    @property
    def theme_display(self) -> str:
        return self.theme_value if self.theme_value else "（未设置）"

    def to_dict(self) -> dict[str, Any]:
        return {
            "key": self.key,
            "label": self.label,
            "note": self.note,
            "siteValue": self.site_value,
            "themeValue": self.theme_value,
            "siteDisplay": self.site_display,
            "themeDisplay": self.theme_display,
        }


@dataclass
class ThemeOnlyEntry:
    """只在**主题配置**里设了、站点配置里没有的键。"""

    key: str
    label: str
    value: str
    #: 站点配置里这个键的状态：``missing``（没有）/ ``empty``（有但空）
    site_state: str = "missing"

    @property
    def id(self) -> str:
        return self.key

    @property
    def site_state_description(self) -> str:
        return "站点配置里没有这一项" if self.site_state == "missing" else "站点配置里是空的"

    def to_dict(self) -> dict[str, Any]:
        return {
            "key": self.key,
            "label": self.label,
            "value": self.value,
            "siteState": self.site_state,
            "siteStateDescription": self.site_state_description,
        }


class ConfigSync:
    """同步引擎。"""

    #: 会自动同步的键。
    #:
    #: 收录标准：两边含义一致、值是标量、且用户确实会去站点配置里改它。
    #:
    #: ``key`` 可以写成 ``父键.子键``：``avatar`` 在两份配置里都是**嵌套块**
    #: （底下有 url / gravatar / rounded / rotated），整体搬会破坏缩进结构，
    #: 所以只按叶子键逐个同步。
    SHARED_KEYS: tuple[SharedKey, ...] = (
        SharedKey("title", "站点标题", "主题优先读自己配置里的标题，不同步的话浏览器标签和站名会不一致"),
        SharedKey("subtitle", "站点副标题", "同上"),
        SharedKey("description", "站点描述", "主题和 SEO 都会用"),
        SharedKey("keywords", "站点关键词", "SEO 用，同步后主题侧也能拿到"),
        SharedKey("author", "作者名", "文章署名和「关于」页都用它"),
        SharedKey("url", "站点网址", "社交链接、RSS、文章末尾的版权链接全靠它拼"),
        SharedKey("root", "站点根路径", "部署在子目录时两处都要一致，否则内页全 404"),
        SharedKey("language", "站点语言", "界面语言，主题覆盖后用户会以为没生效"),
        SharedKey("timezone", "时区", "日期显示"),
        SharedKey("favicon", "网站图标", "主题侧有自己的 logo 配置，不同步就只改了一半"),
        SharedKey("logo", "Logo", "同上"),
        SharedKey("rss", "生成 RSS", "开关状态"),
        SharedKey("per_page", "每页文章数", "分页数量"),
        SharedKey("mode", "亮暗模式", "主题侧常自己定义了一套"),
        # 嵌套块：只同步叶子键
        SharedKey("avatar.url", "头像地址", "主题侧 avatar 优先级高于站点配置，不同步就会「改了没反应」"),
        SharedKey("avatar.gravatar", "头像 Gravatar 邮箱", "同上"),
        SharedKey("avatar.rounded", "头像圆形", "同上"),
        SharedKey("avatar.rotated", "头像跟随鼠标转动", "同上"),
        SharedKey("codeblock.copy_btn", "代码复制按钮", "主题侧几乎总会有一份自己的"),
    )

    # -- 键表 ---------------------------------------------------------

    @classmethod
    def is_syncable(cls, key: str) -> bool:
        """这个键参不参与同步。"""
        return any(shared.key == key for shared in cls.SHARED_KEYS)

    @classmethod
    def label_for(cls, key: str) -> str | None:
        for shared in cls.SHARED_KEYS:
            if shared.key == key:
                return shared.label
        return None

    # -- 差异检测 -----------------------------------------------------

    @classmethod
    def theme_only_entries(
        cls, site_config: str, theme_config: str
    ) -> list[ThemeOnlyEntry]:
        """找出「只在主题配置里配了」的公共项。"""
        site_document = YamlDocument(site_config)
        theme_document = YamlDocument(theme_config)

        result: list[ThemeOnlyEntry] = []
        for shared in cls.SHARED_KEYS:
            theme_value = (theme_document.get(shared.key) or "").strip()
            if not theme_value:
                continue

            # 区分「键不存在」和「键存在但是空的」——前者写回时要新建，后者只要填值
            raw_site = site_document.get(shared.key)
            site_value = (raw_site or "").strip()
            if site_value:
                continue

            result.append(
                ThemeOnlyEntry(
                    key=shared.key,
                    label=shared.label,
                    value=theme_value,
                    site_state="missing" if raw_site is None else "empty",
                )
            )

        return result

    @classmethod
    def differences(cls, site_config: str, theme_config: str) -> list[Difference]:
        """比较两份配置，找出需要同步的差异。

        只比较**两边都有值**的键：

        - 主题配置里没这个键 = 主题不关心它，不是冲突（很多主题压根不读 ``keywords``）
        - 站点配置里没这个键 = 用户没设置，不要去覆盖主题侧已有的值
        """
        site_document = YamlDocument(site_config)
        theme_document = YamlDocument(theme_config)

        result: list[Difference] = []
        for shared in cls.SHARED_KEYS:
            theme_raw = theme_document.get(shared.key)
            if theme_raw is None:
                continue
            theme_value = theme_raw.strip()

            site_value = (site_document.get(shared.key) or "").strip()
            if not site_value or site_value == theme_value:
                continue

            result.append(
                Difference(
                    key=shared.key,
                    label=shared.label,
                    note=shared.note,
                    site_value=site_value,
                    theme_value=theme_value,
                )
            )

        return result

    # -- 写入 ---------------------------------------------------------

    @classmethod
    def apply_to_theme(cls, key: str, value: str, theme_config: str) -> str | None:
        """把某个键的值从站点配置复制到主题配置。

        返回 ``None`` 表示**不需要写**（值本来就一样，或者主题配置里没这个键）。
        调用方据此决定要不要真的落盘、要不要弹「已同步」提示。
        """
        if not cls.is_syncable(key):
            return None

        document = YamlDocument(theme_config)
        current = (document.get(key) or "").strip()
        if current == value:
            return None
        # 主题配置里压根没这个路径：不擅自新增结构
        if document.get(key) is None:
            return None

        return document.set(key, value)

    @classmethod
    def apply_to_site(cls, key: str, value: str, site_config: str) -> str | None:
        """把一个键的值从**主题配置搬回站点配置**。

        用于「我只在主题配置里配了，帮我搬到站点配置，以后换主题不丢」这种诉求。
        """
        if not cls.is_syncable(key):
            return None
        return _write_nested(site_config, key, value)

    @classmethod
    def sync_all(
        cls, site_config: str, theme_config: str
    ) -> tuple[str, list[str]]:
        """把一份主题配置整体对齐到站点配置，返回所有发生变化的键。"""
        result = theme_config
        changed: list[str] = []

        for difference in cls.differences(site_config, theme_config):
            updated = cls.apply_to_theme(difference.key, difference.site_value, result)
            if updated is not None:
                result = updated
                changed.append(difference.label)

        return result, changed


def _write_nested(text: str, key: str, value: str) -> str | None:
    """写入一个可能带点号的路径，**必要时先把缺失的父级块建出来**。

    不能直接丢给 ``YamlDocument.set``：站点配置里压根没有 ``avatar:`` 这一段时，
    ``set("avatar.url", …)`` 会返回 ``None``——而这恰恰是最常见的情况：用户只在
    ``_config.yun.yml`` 里配了头像，``_config.yml`` 里连 ``avatar:`` 这行都没有。
    不处理的话，「搬到站点配置」按钮点了跟没点一样。
    """
    parts = [part for part in key.split(".") if part]
    if not parts:
        return None

    document = YamlDocument(text)

    # 1. 引擎自己能处理（父级映射在，或者键是顶层的）
    direct = document.set(key, value)
    if direct is not None:
        return direct

    if len(parts) == 1:
        # 顶层键不存在：追加到文件末尾
        return _append_top_level(text, parts[0], value)

    parent_node = document.node_at(parts[:-1])
    leaf = parts[-1]

    # 2. 父键存在但后面空着（``avatar:`` 裸一行）→ 在它下面插一行子键
    if parent_node is not None and parent_node.is_null:
        return _insert_child_line(text, parent_node.start_line, leaf, value)

    # 3. 父路径整个不存在 → 在文件末尾追加整块
    return _append_block(text, parts, value)


def _append_top_level(text: str, key: str, value: str) -> str | None:
    # 顶层已经有这个键，无论它是什么类型，都不追加：追加会留下第二个同名键，
    # YAML 里后者覆盖前者，用户原来写的结构被悄悄废掉。
    if key in YamlDocument(text).top_level_keys():
        return None

    lines = text.split("\n")
    while lines and not lines[-1].strip():
        lines.pop()
    if not lines:
        return None
    lines.append(f"{key}: {format_scalar(value)}")
    return "\n".join(lines) + "\n"


def _insert_child_line(text: str, parent_line: int, key: str, value: str) -> str | None:
    """在 ``parent_line`` 这一行下面插一行子键。"""
    lines = text.split("\n")
    if parent_line < 0 or parent_line >= len(lines):
        return None

    parent = lines[parent_line]
    indent = len(parent) - len(parent.lstrip())
    child_indent = " " * (indent + 2)

    lines.insert(parent_line + 1, f"{child_indent}{key}: {format_scalar(value)}")
    return "\n".join(lines)


def _append_block(text: str, parts: list[str], value: str) -> str | None:
    """在文件末尾追加一整块嵌套结构。"""
    if len(parts) < 2:
        return None

    lines = text.split("\n")
    while lines and not lines[-1].strip():
        lines.pop()
    if not lines:
        return None

    step = _detect_indent_width(lines) or 2

    depth = 0
    for part in parts[:-1]:
        lines.append(" " * (depth * step) + f"{part}:")
        depth += 1
    lines.append(" " * (depth * step) + f"{parts[-1]}: {format_scalar(value)}")

    return "\n".join(lines) + "\n"


def _detect_indent_width(lines: list[str]) -> int | None:
    """从已有的缩进里猜一个缩进宽度，猜不到就用 2。"""
    smallest: int | None = None
    for line in lines:
        if not line.startswith(" "):
            continue
        count = len(line) - len(line.lstrip(" "))
        if count <= 0:
            continue
        if smallest is None or count < smallest:
            smallest = count

    if smallest is None or smallest <= 0 or smallest > 8:
        return None
    return smallest
