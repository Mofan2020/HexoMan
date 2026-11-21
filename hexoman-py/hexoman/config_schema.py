"""把 YAML 的任意路径自动变成带中文说明的交互控件。

对应 Swift 侧的 ``ConfigSchema.swift``。

## 设计取向：**不维护一份手工清单**

早先的手写字段清单有两个后果：一是漏——``social:`` 是列表、``avatar:`` 是
嵌套块，压根不在清单里，页面上永远是空白；二是费劲——换个主题（yun /
landscape / next）键名完全不同，清单立刻过期。

现在改成：**读 YAML 树的形状来定控件**。

- 标量给文本框；``true``/``false`` 给开关；纯数字给数字框
- 已知语义的键（theme / timezone 之类）额外给出中文说明和候选项
- 序列给可增删的列表编辑器
- 嵌套映射自动展开成分组

换任何主题都不用改代码。

## 只展开一层是刻意的

Hexo 配置最深也就两三层，全展平会让页面变成一堵看不到头的墙。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from .config_docs import ConfigDoc, ConfigDocs
from .yaml_path import YamlDocument, YamlEntry, YamlNode

__all__ = ["ConfigField", "ListField", "ConfigKnowledge", "ConfigSchema"]

#: 控件类型。
KIND_TEXT = "text"
KIND_INTEGER = "integer"
KIND_BOOLEAN = "boolean"
KIND_CHOICE = "choice"
KIND_COLOR = "color"
KIND_ASSET = "asset"
KIND_URL = "url"
KIND_MULTILINE = "multiline"
KIND_READONLY = "readonly"


def _opt(value: str, label: str) -> dict[str, str]:
    return {"value": value, "label": label}


@dataclass
class ConfigField:
    """一个自动推断出来的配置项。"""

    #: YAML 路径（键名序列）
    path: list[str]
    label: str = ""
    hint: str = ""
    kind: str = KIND_TEXT
    #: 分组
    group: str = ""
    #: 当前值（标量才有）
    value: str = ""
    #: 这个路径下挂着的子项数量，用于折叠区标题
    child_count: int = 0
    #: 是否在 schema 里有已知说明
    is_known: bool = False
    #: ``choice`` 类型的候选项
    options: list[dict[str, str]] = field(default_factory=list)
    #: 详细填写文档
    doc: ConfigDoc | None = None
    #: 只读提示文案（``kind == readonly`` 时用）
    read_only_reason: str = ""

    @property
    def id(self) -> str:
        return ".".join(self.path)

    @property
    def key(self) -> str:
        """路径最后一段（列表编辑器里当成字段名用）。"""
        return self.path[-1] if self.path else ""

    @property
    def is_writable(self) -> bool:
        return self.kind != KIND_READONLY

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "path": list(self.path),
            "label": self.label,
            "hint": self.hint,
            "kind": self.kind,
            "group": self.group,
            "value": self.value,
            "childCount": self.child_count,
            "isKnown": self.is_known,
            "options": [dict(option) for option in self.options],
            "doc": self.doc.to_dict() if self.doc else None,
            "readOnlyReason": self.read_only_reason,
            "isWritable": self.is_writable,
        }


@dataclass
class ListField:
    """列表里的一项（社媒链接、菜单项这类）。"""

    path: list[str]
    index: int = 0
    title: str = ""
    #: 这一项下面每个字段的描述
    fields: list[ConfigField] = field(default_factory=list)
    #: 是不是标量项（``- https://...``）
    is_scalar: bool = False
    scalar_value: str = ""

    @property
    def id(self) -> str:
        return f"{'.'.join(self.path)}#{self.index}"

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "path": list(self.path),
            "index": self.index,
            "title": self.title,
            "fields": [item.to_dict() for item in self.fields],
            "isScalar": self.is_scalar,
            "scalarValue": self.scalar_value,
        }


class ConfigKnowledge:
    """认识的键名。**不认识的键照样能编辑**，只是没有说明文字。

    这里只收「含义稳定、跨主题基本一致」的键。主题自己的键（sidebar /
    banner / menu 这些）由各自的注释行提供上下文，加上自动推断的控件类型，
    已经足够用了。
    """

    LANGUAGES = [
        _opt("zh", "简体中文"),
        _opt("zh-CN", "简体中文"),
        _opt("zh-TW", "繁體中文"),
        _opt("en", "English"),
        _opt("ja", "日本語"),
        _opt("ko", "한국어"),
    ]

    TIMEZONES = [
        _opt("Asia/Shanghai", "中国标准时间 (Asia/Shanghai)"),
        _opt("Asia/Hong_Kong", "香港 (Asia/Hong_Kong)"),
        _opt("Asia/Taipei", "台北 (Asia/Taipei)"),
        _opt("Asia/Tokyo", "东京 (Asia/Tokyo)"),
        _opt("Asia/Singapore", "新加坡 (Asia/Singapore)"),
        _opt("Europe/London", "伦敦 (Europe/London)"),
        _opt("America/New_York", "纽约 (America/New_York)"),
        _opt("America/Los_Angeles", "洛杉矶 (America/Los_Angeles)"),
        _opt("UTC", "协调世界时 (UTC)"),
    ]

    #: 键名 → {label, hint, control, options}。
    #: ``control`` 为 ``None`` 表示「控件类型由值自动推断」。
    ENTRIES: dict[str, dict[str, Any]] = {
        # 站点
        "title": {"label": "站点标题", "hint": "浏览器标签页和网站顶部显示的名字。", "control": KIND_TEXT},
        "subtitle": {"label": "站点副标题", "hint": "标题下面那行小字，留空不显示。", "control": KIND_TEXT},
        "description": {"label": "站点描述", "hint": "一句话介绍，搜索引擎会拿它当摘要。", "control": KIND_TEXT},
        "keywords": {"label": "站点关键词", "hint": "多个关键词用英文逗号分隔，留空表示不设。", "control": KIND_TEXT},
        "author": {"label": "作者名", "hint": "文章署名和「关于」页显示的名字。", "control": KIND_TEXT},
        "language": {
            "label": "站点语言",
            "hint": "决定站点界面语言。",
            "control": KIND_CHOICE,
            "options": LANGUAGES,
        },
        "timezone": {
            "label": "时区",
            "hint": "影响文章日期显示。",
            "control": KIND_CHOICE,
            "options": TIMEZONES,
        },
        "url": {
            "label": "站点网址",
            "hint": "最终对外的完整地址，结尾斜杠可省。社交链接和 RSS 都靠它拼。",
            "control": KIND_URL,
        },
        "root": {"label": "站点根路径", "hint": "部署在子目录时用，比如 /blog。", "control": KIND_TEXT},
        "permalink": {
            "label": "永久链接格式",
            "hint": "文章 URL 的结构。改这个会让所有旧链接失效，谨慎。",
            "control": KIND_TEXT,
        },
        # 外观
        "theme": {"label": "主题", "hint": "当前使用的主题包名。换主题建议去「主题」页操作。", "control": KIND_TEXT},
        "favicon": {"label": "网站图标", "hint": "浏览器标签页那个小图标。", "control": KIND_ASSET},
        "avatar": {"label": "头像", "hint": "站点头像设置。", "control": None},
        "logo": {"label": "Logo", "hint": "站点 Logo 图片。", "control": KIND_ASSET},
        "rss": {"label": "生成 RSS", "hint": "开启后在根目录生成 feed.xml。", "control": KIND_BOOLEAN},
        "mode": {
            "label": "亮暗模式",
            "hint": "界面的明暗主题。",
            "control": KIND_CHOICE,
            "options": [
                _opt("auto", "跟随系统"),
                _opt("light", "始终亮色"),
                _opt("dark", "始终暗色"),
                _opt("time", "按时间自动切换"),
            ],
        },
        "color": {"label": "主题色", "hint": "站点的强调色。", "control": KIND_COLOR},
        "colors": {"label": "配色", "hint": "站点配色方案。", "control": None},
        "background": {"label": "背景图", "hint": "站点背景图片。", "control": KIND_ASSET},
        "sidebar": {"label": "侧边栏", "hint": "侧边栏外观设置。", "control": None},
        "banner": {"label": "首页横幅", "hint": "首页顶部大图区域。", "control": None},
        "menu": {"label": "导航菜单", "hint": "站点导航项。", "control": None},
        "social": {"label": "社交链接", "hint": "侧边栏的社交图标，点击跳到对应主页。", "control": None},
        "footer": {"label": "页脚", "hint": "页脚内容。", "control": None},
        "plugins": {"label": "插件", "hint": "主题启用的插件。", "control": None},
        "behance": {"label": "Behance", "hint": "Behance 主页地址。", "control": KIND_URL},
        "twitter": {"label": "Twitter / X", "hint": "Twitter 或 X 主页地址。", "control": KIND_URL},
        "github": {"label": "GitHub", "hint": "GitHub 主页地址。", "control": KIND_URL},
        "facebook": {"label": "Facebook", "hint": "Facebook 主页地址。", "control": KIND_URL},
        "instagram": {"label": "Instagram", "hint": "Instagram 主页地址。", "control": KIND_URL},
        "linkedin": {"label": "LinkedIn", "hint": "LinkedIn 主页地址。", "control": KIND_URL},
        "bilibili": {"label": "哔哩哔哩", "hint": "B 站主页地址。", "control": KIND_URL},
        "zhihu": {"label": "知乎", "hint": "知乎主页地址。", "control": KIND_URL},
        "weibo": {"label": "微博", "hint": "微博主页地址。", "control": KIND_URL},
        "qq": {"label": "QQ", "hint": "QQ 群链接或号码。", "control": KIND_TEXT},
        "email": {"label": "邮箱", "hint": "联系邮箱。", "control": KIND_TEXT},
        "icp": {"label": "备案号", "hint": "页脚显示的备案号。", "control": KIND_TEXT},
        # 内容
        "per_page": {
            "label": "每页文章数",
            "hint": "首页和归档页一页显示几篇，0 表示不分页。",
            "control": KIND_INTEGER,
        },
        "pagination_dir": {"label": "分页目录", "hint": "分页文件存放的目录名。", "control": KIND_TEXT},
        "index_generator": {"label": "首页生成设置", "hint": "首页显示哪些文章。", "control": None},
        "archive_generator": {"label": "归档页设置", "hint": "归档页显示哪些文章。", "control": None},
        "tag_generator": {"label": "标签页设置", "hint": "标签页显示哪些文章。", "control": None},
        "category_generator": {"label": "分类页设置", "hint": "分类页显示哪些文章。", "control": None},
        "default_layout": {
            "label": "默认布局",
            "hint": "hexo new 新建内容时的默认布局。",
            "control": KIND_CHOICE,
            "options": [
                _opt("post", "文章 (post)"),
                _opt("page", "页面 (page)"),
                _opt("draft", "草稿 (draft)"),
            ],
        },
        "new_post_name": {
            "label": "新文章文件名规则",
            "hint": "决定 hexo new 生成的文件名。:title 用标题，:year 用年份。",
            "control": KIND_TEXT,
        },
        "filename_case": {
            "label": "文件名大小写",
            "hint": "0 不转换，1 转小写，2 转大写。",
            "control": KIND_INTEGER,
        },
        "titlecase": {"label": "标题转 Title Case", "hint": "自动把英文标题首字母大写。", "control": KIND_BOOLEAN},
        "render_drafts": {"label": "渲染草稿", "hint": "开启后草稿也会出现在站点里。", "control": KIND_BOOLEAN},
        "post_asset_folder": {
            "label": "文章独立资源目录",
            "hint": "每篇文章的图片放在同名子目录里。",
            "control": KIND_BOOLEAN,
        },
        "relative_link": {"label": "使用相对链接", "hint": "链接不带域名，方便本地预览。", "control": KIND_BOOLEAN},
        "future": {"label": "显示未来文章", "hint": "日期未到的文章也显示出来。", "control": KIND_BOOLEAN},
        "date_format": {"label": "日期格式", "hint": "Moment.js 格式，例：YYYY-MM-DD。", "control": KIND_TEXT},
        "time_format": {"label": "时间格式", "hint": "Moment.js 格式，例：HH:mm:ss。", "control": KIND_TEXT},
        "updated_option": {
            "label": "更新时间取值",
            "hint": "mtime 用文件修改时间，date 用 front-matter 里的 date。",
            "control": KIND_CHOICE,
            "options": [
                _opt("mtime", "文件修改时间"),
                _opt("date", "文章日期"),
                _opt("empty", "不显示"),
            ],
        },
        "default_category": {"label": "默认分类", "hint": "文章没写分类时归到这里。", "control": KIND_TEXT},
        "skip_render": {
            "label": "跳过渲染的路径",
            "hint": "这些文件原样拷贝，不经模板处理。",
            "control": KIND_MULTILINE,
        },
        "include": {"label": "包含的文件", "hint": "source 下要被处理的文件，留空表示全部。", "control": KIND_MULTILINE},
        "exclude": {"label": "排除的文件", "hint": "source 下要跳过的文件。", "control": KIND_MULTILINE},
        "ignore": {"label": "完全忽略的路径", "hint": "既不处理也不拷贝。", "control": KIND_MULTILINE},
        "external_link": {"label": "外链处理", "hint": "站外链接是否在新标签页打开。", "control": None},
        "highlight": {"label": "代码高亮", "hint": "文章里代码块的显示方式。", "control": None},
        "prismjs": {"label": "Prism 语法高亮", "hint": "代码高亮的具体设置。", "control": None},
        "syntax_highlighter": {
            "label": "高亮引擎",
            "hint": "prismjs 或 highlighter。",
            "control": KIND_CHOICE,
            "options": [
                _opt("prismjs", "Prism.js（推荐）"),
                _opt("highlighter", "highlight.js"),
            ],
        },
        "copy_code": {"label": "代码复制按钮", "hint": "代码块右上角显示「复制」。", "control": KIND_BOOLEAN},
        "meta_generator": {"label": "生成 meta 标签", "hint": "自动生成 SEO 相关的 meta 标签。", "control": KIND_BOOLEAN},
        "search": {"label": "搜索", "hint": "站内搜索功能设置。", "control": None},
        "deploy": {"label": "部署", "hint": "hexo deploy 的目标配置。", "control": None},
        # 目录
        "source_dir": {"label": "源目录", "hint": "存放文章和页面的目录，一般不动。", "control": KIND_TEXT},
        "public_dir": {"label": "输出目录", "hint": "生成站点放哪，一般不动。", "control": KIND_TEXT},
        "tag_dir": {"label": "标签目录", "hint": "标签页输出目录。", "control": KIND_TEXT},
        "archive_dir": {"label": "归档目录", "hint": "归档页输出目录。", "control": KIND_TEXT},
        "category_dir": {"label": "分类目录", "hint": "分类页输出目录。", "control": KIND_TEXT},
        "code_dir": {"label": "代码目录", "hint": "文章里的下载文件放哪。", "control": KIND_TEXT},
        "i18n_dir": {"label": "多语言目录", "hint": ":lang 表示按语言分目录。", "control": KIND_TEXT},
        # 列表项里常见的字段
        "name": {"label": "名称", "hint": "显示出来的名字。", "control": KIND_TEXT},
        "link": {"label": "链接", "hint": "点击跳转到的地址。", "control": KIND_URL},
        "icon": {"label": "图标", "hint": "图标类名，形如 ri:github-line。", "control": KIND_TEXT},
        "path": {"label": "路径", "hint": "目标路径。", "control": KIND_TEXT},
        "type": {"label": "类型", "hint": "这一项的种类。", "control": KIND_TEXT},
        "enable": {"label": "启用", "hint": "关掉后这一段不生效。", "control": KIND_BOOLEAN},
        "value": {"label": "值", "hint": "这一项的值。", "control": KIND_TEXT},
        "label": {"label": "标签", "hint": "这一项显示的名字。", "control": KIND_TEXT},
    }

    #: 常见英文键的中文对照。覆盖不到的直接显示英文。
    CHINESE_NAMES: dict[str, str] = {
        "enable": "启用", "enabled": "启用", "disable": "禁用",
        "true": "开", "false": "关",
        "link": "链接", "path": "路径", "dir": "目录",
        "name": "名称", "title": "标题", "desc": "描述", "description": "描述",
        "icon": "图标", "color": "颜色", "bg": "背景", "background": "背景",
        "image": "图片", "img": "图片", "avatar": "头像", "logo": "标志",
        "opacity": "不透明度", "rounded": "圆角", "position": "位置",
        "size": "尺寸", "width": "宽度", "height": "高度", "radius": "圆角",
        "margin": "外边距", "padding": "内边距", "font": "字体", "weight": "字重",
        "text": "文字", "border": "边框", "shadow": "阴影",
        "animation": "动画", "duration": "时长", "delay": "延迟",
        "type": "类型", "value": "值", "label": "标签", "target": "目标",
        "count": "数量", "limit": "上限", "offset": "偏移", "depth": "深度",
        "index": "序号", "order": "排序", "orderby": "排序字段",
        "per": "每页", "page": "页", "list": "列表", "item": "条目",
        "content": "内容", "html": "HTML", "code": "代码",
        "locale": "语言", "format": "格式",
        "theme": "主题", "layout": "布局", "template": "模板", "widget": "挂件",
        "search": "搜索", "tag": "标签", "category": "分类", "archive": "归档",
        "post": "文章", "draft": "草稿", "published": "已发布",
        "password": "访问密码", "toc": "目录", "mathjax": "数学公式",
        "chart": "图表", "mermaid": "流程图", "emoji": "表情",
        "truncate": "截断", "excerpt": "摘要", "summary": "摘要",
        "sticky": "置顶", "top": "置顶", "hot": "热门", "reward": "打赏",
        "comment": "评论", "share": "分享",
    }

    @classmethod
    def lookup(cls, key: str) -> dict[str, Any] | None:
        """找键的说明。没登记就返回 ``None``，调用方据此降级。"""
        return cls.ENTRIES.get(key)


class ConfigSchema:
    """从 YAML 文档生成可交互的配置结构。"""

    # -- 字段列表 -----------------------------------------------------

    @classmethod
    def fields(cls, document: YamlDocument) -> list[ConfigField]:
        """生成整个文件的字段列表（顶层 + 一层嵌套展开）。"""
        root = document.root
        if root is None or not root.is_mapping:
            return []

        result: list[ConfigField] = []
        for entry in root.entries:
            cls._append_field(entry, [entry.key], result)
        return result

    @classmethod
    def _append_field(
        cls, entry: YamlEntry, path: list[str], result: list[ConfigField]
    ) -> None:
        key = entry.key
        node = entry.node
        known = ConfigKnowledge.lookup(key)
        doc = ConfigDocs.flat_doc(key)

        # 标量：直接给控件
        if node.is_scalar:
            kind = cls.infer_kind(key, node, known, doc)
            result.append(
                ConfigField(
                    path=path,
                    label=known["label"] if known else cls.humanize(key),
                    hint=known["hint"] if known else "",
                    kind=kind,
                    group=cls.group_of(key),
                    value=node.value,
                    is_known=known is not None,
                    options=list(known.get("options", [])) if known and kind == KIND_CHOICE else [],
                    doc=doc or ConfigDocs.generic_doc(kind, node.value),
                )
            )
            return

        # 列表：给列表编辑器
        if node.is_sequence:
            result.append(
                ConfigField(
                    path=path,
                    label=known["label"] if known else cls.humanize(key),
                    hint=known["hint"] if known else f"共 {len(node.items)} 项",
                    kind=KIND_READONLY,
                    read_only_reason="列表",
                    group=cls.group_of(key),
                    child_count=len(node.items),
                    is_known=known is not None,
                    doc=doc,
                )
            )
            return

        # 嵌套映射：建一个分组，子项单独成字段
        children = node.entries
        result.append(
            ConfigField(
                path=path,
                label=known["label"] if known else cls.humanize(key),
                hint=known["hint"] if known else f"{len(children)} 项设置",
                kind=KIND_READONLY,
                read_only_reason="分组",
                group=cls.group_of(key),
                child_count=len(children),
                is_known=known is not None,
                doc=doc,
            )
        )

        # 子项**不看**顶层已知键表。
        #
        # 为什么要区分：``url`` 在顶层是「站点网址」，在 avatar 下面是「头像文件」；
        # ``language`` 在顶层是站点语言，在 creative_commons 下面是「许可证语言」。
        # 拿同一份说明套所有层级，就会出现「头像的地址项写着站点网址」这种明显
        # 不对的标签——用户看到会以为填错了地方。
        for child in children:
            if not child.node.is_scalar:
                continue  # 再深一层就不收了
            child_doc = ConfigDocs.nested_doc(parent=key, child=child.key)
            child_known = cls.nested_key_hint(child.key)
            child_kind = cls.infer_kind(child.key, child.node, child_known, child_doc)
            result.append(
                ConfigField(
                    path=path + [child.key],
                    # 标签保持短，长解释交给 doc 渲染。
                    label=child_known["label"] if child_known else cls.humanize(child.key),
                    hint=child_known["hint"] if child_known else "",
                    kind=child_kind,
                    group=known["label"] if known else cls.humanize(key),
                    value=child.node.value,
                    is_known=child_known is not None or child_doc is not None,
                    options=list(child_known.get("options", []))
                    if child_known and child_kind == KIND_CHOICE
                    else [],
                    doc=child_doc or ConfigDocs.generic_doc(child_kind, child.node.value),
                )
            )

    # -- 列表编辑器 ---------------------------------------------------

    @classmethod
    def list_fields(cls, document: YamlDocument, path: list[str]) -> list[ListField]:
        """生成列表编辑器需要的结构。

        标量项（``- https://...``）和映射项（``- name: GitHub``）都能处理，
        映射项的字段名从**这一项实际有的键**里读，不写死——不同主题的列表项
        字段差别很大（yun 是 name/link/icon/color，landscape 只有 link/label）。
        """
        node = document.node_at(path)
        if node is None or not node.is_sequence:
            return []

        result: list[ListField] = []
        for index, item in enumerate(node.items):
            if item.is_scalar:
                title = item.value if item.value else f"第 {index + 1} 项"
                result.append(
                    ListField(
                        path=path,
                        index=index,
                        title=title,
                        is_scalar=True,
                        scalar_value=item.value,
                    )
                )
                continue

            if not item.is_mapping:
                result.append(ListField(path=path, index=index, title=f"第 {index + 1} 项"))
                continue

            fields: list[ConfigField] = []
            for child in item.entries:
                known = ConfigKnowledge.lookup(child.key)
                kind = cls.infer_kind(child.key, child.node, known)
                fields.append(
                    ConfigField(
                        path=path + [str(index), child.key],
                        label=known["label"] if known else cls.humanize(child.key),
                        hint=known["hint"] if known else "",
                        kind=kind,
                        value=child.node.value,
                        is_known=known is not None,
                        options=list(known.get("options", []))
                        if known and kind == KIND_CHOICE
                        else [],
                    )
                )

            # 标题取第一个文本类字段的值；取不到就退回序号
            candidate = next(
                (item.value for item in fields if cls.is_textual(item.kind) and item.value),
                "",
            )
            if not candidate:
                candidate = next((item.value for item in fields if item.value), "")

            result.append(
                ListField(
                    path=path,
                    index=index,
                    title=candidate or f"第 {index + 1} 项",
                    fields=fields,
                )
            )

        return result

    # -- 推断 ---------------------------------------------------------

    @classmethod
    def infer_kind(
        cls,
        key: str,
        node: YamlNode,
        known: dict[str, Any] | None,
        doc: ConfigDoc | None = None,
    ) -> str:
        """从键名、已知说明和值的实际形状推断控件类型。

        ``doc`` 里的候选值**优先**于自动推断：``creative_commons.license``
        的值 ``by-nc-sa`` 看起来就是普通文本，但文档知道它是枚举，所以必须
        给下拉，而不是让新手去背这串东西。
        """
        if doc is not None and doc.options:
            return KIND_CHOICE
        if known is not None:
            if known.get("control") == KIND_CHOICE and known.get("options"):
                return KIND_CHOICE
            if known.get("control"):
                return str(known["control"])

        if node.is_block_scalar:
            return KIND_READONLY
        if node.is_flow:
            return KIND_READONLY

        value = node.value.strip()
        lowered = value.lower()

        if lowered in ("true", "false"):
            return KIND_BOOLEAN
        if value:
            try:
                int(value)
                return KIND_INTEGER
            except ValueError:
                pass
        if lowered.startswith("http://") or lowered.startswith("https://"):
            return KIND_URL
        if _looks_like_hex_color(value):
            return KIND_COLOR
        if _is_image_path(value):
            return KIND_ASSET
        if "\n" in value:
            return KIND_MULTILINE
        return KIND_TEXT

    # -- 命名 ---------------------------------------------------------

    @classmethod
    def group_of(cls, key: str) -> str:
        """分组。跟 ConfigKnowledge 的语义分组对齐，让表单读起来有结构。"""
        content = {
            "title", "subtitle", "description", "keywords", "author", "language",
            "timezone", "url", "root", "permalink", "index_generator", "per_page",
            "pagination_dir", "default_category", "tag_generator", "category_generator",
            "archive_generator", "new_post_name", "default_layout", "filename_case",
            "titlecase", "render_drafts", "post_asset_folder", "relative_link", "future",
            "date_format", "time_format", "updated_option", "skip_render", "include",
            "exclude", "ignore", "meta_generator", "search",
        }
        appearance = {
            "theme", "favicon", "avatar", "logo", "rss", "mode", "color", "colors",
            "background", "sidebar", "banner", "menu", "footer", "plugins",
            "external_link", "highlight", "prismjs", "syntax_highlighter", "copy_code",
        }
        directories = {
            "source_dir", "public_dir", "tag_dir", "archive_dir", "category_dir",
            "code_dir", "i18n_dir",
        }

        if key in content:
            return "内容"
        if key in appearance:
            return "外观"
        if key in directories:
            return "目录"
        if key == "deploy":
            return "部署"
        return "其他"

    @classmethod
    def nested_key_hint(cls, key: str) -> dict[str, Any] | None:
        """嵌套层级里**语义与上下文无关**的键，才配固定说明。

        收录标准很简单：不管它出现在 avatar 下面还是 banner 下面，含义都一样。
        凡是「url」「title」这种会随父级变义的键，一律不进这里。
        """
        if key in ("enable", "icon", "name", "type", "value", "label", "link"):
            return ConfigKnowledge.ENTRIES.get(key)
        return None

    @classmethod
    def humanize(cls, key: str) -> str:
        """把 ``trailing_index`` 变成「Trailing Index」这种可读标签。

        翻译不出中文的键就退回英文原样——**宁可给英文也不要瞎翻译**，
        猜错含义比不给说明更糟。
        """
        spaced = key.replace("_", " ").replace("-", " ")
        words = []
        for word in spaced.split():
            chinese = ConfigKnowledge.CHINESE_NAMES.get(word.lower())
            if chinese:
                words.append(chinese)
            else:
                words.append(word[:1].upper() + word[1:])
        return " ".join(words)

    @classmethod
    def is_textual(cls, kind: str) -> bool:
        return kind in (KIND_TEXT, KIND_URL, KIND_COLOR, KIND_ASSET)


def _looks_like_hex_color(value: str) -> bool:
    if not value.startswith("#"):
        return False
    body = value[1:]
    if len(body) not in (3, 4, 6, 8):
        return False
    return all(char in "0123456789abcdefABCDEF" for char in body)


def _is_image_path(value: str) -> bool:
    lowered = value.lower()
    return any(
        lowered.endswith(suffix)
        for suffix in (".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".avif", ".ico")
    )
