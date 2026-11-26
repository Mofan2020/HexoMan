"""Markdown 渲染：预览用的那一套。

引擎是 Python-Markdown（``markdown`` 包，本来就写在 ``requirements.txt``
里）。之前那版是手写解析器，有两处硬伤：

1. **嵌套列表被拍平。** 二级列表项被并进上一项的正文，用户看到的是一行
   带换行的文字。
2. **原始 HTML 全被转义。** Hexo 文章里写 ``<img align="right">`` 是常事，
   转义之后预览跟真实站点长得完全不一样。

换引擎带来两个新的责任，这版一并处理：

- **原始 HTML 会原样透传。** 预览页带着能改文件的桥接（``deletePost``
  之类），一篇从网上抄来的文章里藏一段 ``<script>`` 就能直接调后端。
  所以渲染完要过一遍白名单消毒：``script`` / ``style`` / ``iframe`` 连内容
  一起丢掉，其余标签按白名单保留，``on*`` 事件属性和 ``javascript:`` 一律
  剥掉。
- **Hexo 标签不认识。** ``{% asset_img %}``、``{% codeblock %}`` 这些是
  Hexo 自己解析的，Markdown 引擎看到只会当普通文字。渲染前先翻译成等价
  的 Markdown。

另外做了：代码高亮（pygments 负责分类，CSS 负责颜色）、标题大纲、
阅读时长。
"""

from __future__ import annotations

import html
import re
import threading
import unicodedata
from dataclasses import dataclass, field
from html.parser import HTMLParser
from typing import Any, Callable

import markdown

from . import frontmatter
from .model import word_count

__all__ = [
    "render_markdown",
    "render_markdown_document",
    "sanitize_html",
    "RenderResult",
]


# ---------------------------------------------------------------- 引擎

_EXTENSIONS = [
    "fenced_code",
    "tables",
    "footnotes",
    "attr_list",
    "def_list",
    "abbr",
    "sane_lists",
    "toc",
]

_ENGINE_LOCK = threading.Lock()
_RENDER_LOCK = threading.Lock()
_ENGINE: markdown.Markdown | None = None


def _slugify(value: str, separator: str) -> str:
    """标题转锚点 id。

    Python-Markdown 默认的 slugify 会把非 ASCII 全丢掉，中文标题一律变成
    ``_1``、``_2``，大纲里点不开。这里保留中文，只去掉标点。
    """
    text = unicodedata.normalize("NFKC", value).strip().lower()
    text = re.sub(r"[^\w\s-]", "", text, flags=re.UNICODE)
    text = re.sub(r"[\s%s]+" % re.escape(separator), separator, text)
    return text.strip(separator)


def _engine() -> markdown.Markdown:
    global _ENGINE
    with _ENGINE_LOCK:
        if _ENGINE is None:
            _ENGINE = markdown.Markdown(
                extensions=_EXTENSIONS,
                extension_configs={
                    "toc": {
                        "permalink": False,
                        "toc_depth": "1-3",
                        "slugify": _slugify,
                        "separator": "-",
                    }
                },
            )
        return _ENGINE


def _convert(body: str) -> tuple[str, list[dict[str, Any]]]:
    """Markdown → HTML，顺带取出标题大纲。"""
    with _RENDER_LOCK:
        engine = _engine()
        engine.reset()
        rendered = engine.convert(body)
        outline = _flatten_toc(getattr(engine, "toc_tokens", []))
    return rendered, outline


def _flatten_toc(tokens: Any, out: list[dict[str, Any]] | None = None) -> list[dict[str, Any]]:
    """把 toc_tokens 摊平成 ``[{level, id, text}]``。"""
    result = out if out is not None else []
    for token in tokens or []:
        result.append(
            {
                "level": int(token.get("level", 1)),
                "id": str(token.get("id", "")),
                "text": _plain_text(str(token.get("name", ""))),
            }
        )
        _flatten_toc(token.get("children"), result)
    return result


def _plain_text(text: str) -> str:
    """去掉标题里的行内标记，只留文字。"""
    return re.sub(r"<[^>]+>", "", text).strip()


# ---------------------------------------------------------------- Hexo 标签

_RAW_MARK = "\ue000"
_RAW_END = "\ue001"

_CODEBLOCK_RE = re.compile(
    r"\{%\s*codeblock(?:\s+([^\n]*?))?\s*%\}(.*?)\{%\s*endcodeblock\s*%\}",
    re.DOTALL,
)
_RAW_RE = re.compile(r"\{%\s*raw\s*%\}(.*?)\{%\s*endraw\s*%\}", re.DOTALL)
_INLINE_TAG_RE = re.compile(r"\{%\s*([a-zA-Z_][\w-]*)\s*([^%]*?)\s*%\}")
_FENCE_LINE_RE = re.compile(r"^(`{3,}|~{3,})")
_INLINE_CODE_RE = re.compile(r"(`+)(.+?)\1")
_TASK_MARKER_RE = re.compile(r"^(\s*(?:[-*+]|\d+[.)])\s+)\[([ xX])\]\s+")


def _split_args(text: str) -> list[str]:
    """切标签参数，引号里的空格不算分隔符。"""
    return [
        token.group(0).strip("\"'")
        for token in re.finditer(r"\"[^\"]*\"|'[^']*'|\S+", text or "")
    ]


def _fence_for(code: str) -> str:
    """给代码块选一个足够长的围栏，免得代码里的 ``` 把块提前关掉。"""
    longest = 0
    for match in re.finditer(r"`+", code):
        longest = max(longest, len(match.group(0)))
    return "`" * max(3, longest + 1)


def _replace_codeblock(match: re.Match[str]) -> str:
    args = _split_args(match.group(1) or "")
    language = args[0] if args else ""
    code = match.group(2).strip("\n")
    fence = _fence_for(code)
    return f"{fence}{language}\n{code}\n{fence}"


def _replace_tag(match: re.Match[str]) -> str:
    """把一个 Hexo 标签换成等价的 Markdown。"""
    name = match.group(1).lower()
    args = _split_args(match.group(2) or "")

    if name == "asset_img":
        if not args:
            return match.group(0)
        path = args[0]
        alt = args[1] if len(args) > 1 else ""
        return f"![{alt}]({path})"

    if name in ("youtube", "vimeo"):
        if not args:
            return match.group(0)
        video_id = args[0]
        host = "youtube.com/watch?v=" if name == "youtube" else "vimeo.com/"
        return f"[{name}: {video_id}](https://{host}{video_id})"

    if name == "post_link":
        if not args:
            return match.group(0)
        slug = args[0].strip("/")
        title = args[1] if len(args) > 1 else slug
        return f"[{title}](/{slug}/)"

    if name == "link":
        if len(args) < 2:
            return match.group(0)
        text, url = args[0], args[1]
        return f"[{text}]({url})"

    if name == "asset_path":
        if not args:
            return match.group(0)
        return args[0]

    # 不认识的标签不该原样印在预览里（用户会以为是文章内容），
    # 但也不该悄悄消失——标出来，用户才知道是插件没被预览支持。
    return f'<code class="hexo-tag">{{% {name} %}}</code>'


def _transform_text(text: str) -> str:
    """普通文本段：Hexo 标签 + 删除线。"""
    if not text:
        return text
    text = _INLINE_TAG_RE.sub(_replace_tag, text)
    return re.sub(r"~~(?=\S)(.+?)(?<=\S)~~", r"<del>\1</del>", text)


def _replace_task_marker(line: str) -> str:
    """把任务列表的 ``- [ ]`` 换成占位方块。

    Python-Markdown 不认 GitHub 的任务列表语法，``- [ ] 写完了`` 会原样
    印出 ``[ ]``。这里在渲染前换成一个 ``<span>``，由 CSS 画成方块——
    **不用 ``<input type=checkbox>``**：预览页带着能改文件的桥接，
    表单元素没必要带进来。
    """
    match = _TASK_MARKER_RE.match(line)
    if not match:
        return line

    done = match.group(2).lower() == "x"
    marker = '<span class="task-box is-done"></span>' if done else '<span class="task-box"></span>'
    return match.group(1) + marker + " " + line[match.end() :]


def _transform_line(line: str) -> str:
    """一行里的行内代码要保护起来——代码里的 ``*`` 不是强调标记。"""
    line = _replace_task_marker(line)
    pieces: list[str] = []
    index = 0
    for match in _INLINE_CODE_RE.finditer(line):
        pieces.append(_transform_text(line[index : match.start()]))
        pieces.append(match.group(0))
        index = match.end()
    pieces.append(_transform_text(line[index:]))
    return "".join(pieces)


def _transform_segments(source: str) -> str:
    """逐行处理，围栏代码块里的内容一个字都不动。"""
    result: list[str] = []
    in_fence = False
    fence_char = ""
    fence_len = 0

    for line in source.split("\n"):
        stripped = line.strip()
        if in_fence:
            result.append(line)
            if stripped.startswith(fence_char * fence_len):
                in_fence = False
            continue

        match = _FENCE_LINE_RE.match(stripped)
        if match:
            in_fence = True
            fence_char = match.group(1)[0]
            fence_len = len(match.group(1))
            result.append(line)
            continue

        result.append(_transform_line(line))

    return "\n".join(result)


def _preprocess(source: str) -> str:
    """渲染前的源码改写。"""
    # 1. codeblock 块：内容是代码，先转成围栏代码块
    source = _CODEBLOCK_RE.sub(_replace_codeblock, source)

    # 2. raw 块：内容不能被标签处理，但仍然要走 Markdown。
    #    先挖成占位符，标签处理完再放回去。
    raw_blocks: list[str] = []

    def _stash_raw(match: re.Match[str]) -> str:
        raw_blocks.append(match.group(1))
        return f"{_RAW_MARK}{len(raw_blocks) - 1}{_RAW_END}"

    source = _RAW_RE.sub(_stash_raw, source)

    # 3. 逐段替换标签与删除线
    source = _transform_segments(source)

    # 4. raw 内容放回去
    for index, block in enumerate(raw_blocks):
        source = source.replace(f"{_RAW_MARK}{index}{_RAW_END}", block)

    return source


# ---------------------------------------------------------------- 代码高亮

_CODE_BLOCK_RE = re.compile(
    r'<pre><code(?: class="language-([^"]*)")?>(.*?)</code></pre>', re.DOTALL
)


def _highlight_code(text: str) -> str:
    """给代码块加 pygments token class——颜色由 CSS 负责，class 由 pygments 负责。"""

    def replace(match: re.Match[str]) -> str:
        language = (match.group(1) or "").strip()
        body = html.unescape(match.group(2))

        if not language:
            return f'<pre class="code"><code>{html.escape(body)}</code></pre>'

        try:
            from pygments import highlight
            from pygments.formatters import HtmlFormatter
            from pygments.lexers import get_lexer_by_name

            lexer = get_lexer_by_name(language, stripall=False)
            inner = highlight(body, lexer, HtmlFormatter(nowrap=True))
        except Exception:
            # 词法器不认识这个语言（或者 pygments 不可用）时退回纯文本，
            # 预览必须永远能显示点什么。
            inner = html.escape(body)

        safe_language = html.escape(language, quote=True)
        return (
            f'<pre class="code"><code class="language-{safe_language}">{inner}</code></pre>'
        )

    return _CODE_BLOCK_RE.sub(replace, text)


# ---------------------------------------------------------------- 消毒

_ALLOWED_TAGS = frozenset(
    {
        "p", "br", "hr",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "ul", "ol", "li", "dl", "dt", "dd",
        "blockquote", "pre", "code", "span",
        "a", "img",
        "table", "thead", "tbody", "tfoot", "tr", "th", "td", "col", "colgroup",
        "strong", "em", "b", "i", "u", "s", "del", "ins", "mark", "small",
        "sub", "sup", "abbr", "cite", "q", "time",
        "figure", "figcaption", "details", "summary",
        "video", "audio", "source", "picture",
        "kbd", "samp", "var", "wbr",
        "div", "section", "article", "header", "footer", "nav", "aside", "main",
    }
)

#: 连内容一起丢掉的标签。
_DROP_WITH_CONTENT = frozenset(
    {
        "script", "style", "iframe", "object", "embed", "applet",
        "form", "input", "button", "select", "option", "optgroup", "textarea",
        "link", "meta", "base", "frame", "frameset", "noscript",
        "template", "svg", "math", "canvas", "portal", "marquee",
        "xmp", "plaintext", "listing",
    }
)

_VOID_TAGS = frozenset(
    {
        "br", "hr", "img", "source", "wbr", "col", "area", "embed", "param",
        "input", "link", "meta", "track",
    }
)

#: 任何标签都通用的属性。**事件属性（``on*``）和 ``style`` 不在这里**——
#: 白名单本身就把它们挡掉了，不需要再单独判一次。
_GLOBAL_ATTRS = frozenset({"id", "title", "class", "dir", "lang"})

_TAG_ATTRS: dict[str, frozenset[str]] = {
    "a": frozenset({"href", "rel", "target"}),
    "img": frozenset({"src", "alt", "width", "height", "loading", "decoding", "align"}),
    "td": frozenset({"colspan", "rowspan", "align", "valign"}),
    "th": frozenset({"colspan", "rowspan", "align", "valign", "scope"}),
    "ol": frozenset({"start", "type"}),
    "col": frozenset({"span"}),
    "colgroup": frozenset({"span"}),
    "details": frozenset({"open"}),
    "video": frozenset(
        {"controls", "poster", "width", "height", "loop", "muted", "preload"}
    ),
    "audio": frozenset({"controls", "loop", "muted", "preload"}),
    "source": frozenset({"src", "type", "srcset", "media", "sizes"}),
    "blockquote": frozenset({"cite"}),
    "q": frozenset({"cite"}),
    "del": frozenset({"cite", "datetime"}),
    "ins": frozenset({"cite", "datetime"}),
    "time": frozenset({"datetime"}),
}

_NUMERIC_ATTRS = frozenset(
    {"colspan", "rowspan", "start", "width", "height", "span", "size"}
)

_BOOLEAN_ATTRS = frozenset({"open", "controls", "loop", "muted"})

_SAFE_URL_SCHEMES = frozenset({"http", "https", "mailto", "tel", "ftp"})

_DATA_IMAGE_RE = re.compile(
    r"^data:image/(png|jpe?g|gif|webp|bmp|avif|svg\+xml);base64,[A-Za-z0-9+/=]+$",
    re.IGNORECASE,
)

_SAFE_TEXT_RE = re.compile(r"^[^\x00-\x1f<>\"]*$")
_SAFE_ID_RE = re.compile(r"^[\w\-:.]+$", re.UNICODE)
_SAFE_CLASS_RE = re.compile(r"^[A-Za-z0-9_\- ]+$")
_ARIA_RE = re.compile(r"^aria-[a-z]+$")


def _safe_url(value: str, *, allow_data: bool = False) -> str | None:
    """URL 白名单。返回 None 表示这个地址不能用。"""
    raw = (value or "").strip()
    if not raw:
        return None

    if raw.startswith("#"):
        return raw

    lowered = raw.lower()
    if lowered.startswith("data:"):
        if allow_data and _DATA_IMAGE_RE.match(raw):
            return raw
        return None

    scheme = re.match(r"^([a-z][a-z0-9+.\-]*):", lowered)
    if scheme:
        return raw if scheme.group(1) in _SAFE_URL_SCHEMES else None

    # 相对路径。带反斜杠的一律拒绝（那是 Windows 路径，不是 URL）。
    if "\\" in raw:
        return None
    return raw


class _Sanitizer(HTMLParser):
    """白名单消毒器。

    规则：

    - 白名单外的标签：拆掉标签，保留内容（``<center>`` 里的字还要看得见）。
    - 危险标签（``script`` / ``style`` / ``iframe`` 等）：连内容一起丢。
    - 属性：只有白名单里的能留；``on*`` 事件属性和 ``javascript:`` 地址
      一律剥掉；``style`` 属性不给（能注入 CSS）。
    - ``<img src>`` 交给 resolver 重写（预览要显示站点里的图片）。
    """

    def __init__(self, resolver: Callable[[str], str | None] | None = None) -> None:
        super().__init__(convert_charrefs=False)
        self._out: list[str] = []
        self._skip_tag = ""
        self._skip_depth = 0
        self._resolver = resolver

    # -- 输出 --

    def result(self) -> str:
        return "".join(self._out)

    # -- 标签 --

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if self._skip_tag:
            if tag == self._skip_tag:
                self._skip_depth += 1
            return

        if tag in _DROP_WITH_CONTENT:
            if tag == "iframe":
                # iframe 不能在预览里跑，但地址值得留个链接，
                # 不然用户看不出文章里嵌了什么。
                src = dict(attrs).get("src") or ""
                url = _safe_url(src)
                if url:
                    self._out.append(
                        '<p class="embed-note"><a href="'
                        + html.escape(url, quote=True)
                        + '" target="_blank" rel="noopener noreferrer">'
                        + html.escape(url)
                        + "</a></p>"
                    )
            self._skip_tag = tag
            self._skip_depth = 1
            return

        if tag not in _ALLOWED_TAGS:
            return

        rendered = self._render_attrs(tag, attrs)
        if tag in _VOID_TAGS:
            self._out.append(f"<{tag}{rendered} />")
        else:
            self._out.append(f"<{tag}{rendered}>")

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if self._skip_tag:
            return
        if tag in _DROP_WITH_CONTENT:
            return
        if tag not in _ALLOWED_TAGS:
            return
        rendered = self._render_attrs(tag, attrs)
        if tag in _VOID_TAGS:
            self._out.append(f"<{tag}{rendered} />")
        else:
            self._out.append(f"<{tag}{rendered}></{tag}>")

    def handle_endtag(self, tag: str) -> None:
        if self._skip_tag:
            if tag == self._skip_tag:
                self._skip_depth -= 1
                if self._skip_depth <= 0:
                    self._skip_tag = ""
            return
        if tag in _VOID_TAGS or tag not in _ALLOWED_TAGS:
            return
        self._out.append(f"</{tag}>")

    # -- 文本 --

    def handle_data(self, data: str) -> None:
        if self._skip_tag:
            return
        self._out.append(
            data.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        )

    def handle_entityref(self, name: str) -> None:
        if self._skip_tag:
            return
        self._out.append(f"&{name};")

    def handle_charref(self, name: str) -> None:
        if self._skip_tag:
            return
        self._out.append(f"&#{name};")

    def handle_comment(self, data: str) -> None:
        # Hexo 用 ``<!-- more -->`` 控制摘要，预览里要藏起来。
        return

    def handle_decl(self, decl: str) -> None:
        return

    def unknown_decl(self, data: str) -> None:
        return

    def handle_pi(self, data: str) -> None:
        return

    # -- 属性 --

    def _render_attrs(self, tag: str, attrs: list[tuple[str, str | None]]) -> str:
        allowed = _GLOBAL_ATTRS | _TAG_ATTRS.get(tag, frozenset())
        parts: list[str] = []

        for raw_name, raw_value in attrs:
            name = raw_name.lower()
            value = raw_value if raw_value is not None else ""

            if name.startswith("aria-"):
                if not _ARIA_RE.match(name):
                    continue
            elif name not in allowed:
                continue

            cleaned = self._clean_attr(tag, name, value)
            if cleaned is None:
                continue

            if name in _BOOLEAN_ATTRS and not cleaned:
                parts.append(f" {name}")
            else:
                parts.append(f' {name}="{html.escape(cleaned, quote=True)}"')

        return "".join(parts)

    def _clean_attr(self, tag: str, name: str, value: str) -> str | None:
        """清一个属性的值。返回 None 表示这个属性不能用。

        **能不能用这个属性由 ``_render_attrs`` 的名字白名单决定**，这里只管
        值长什么样。两处各管一件事，不重复判断。
        """
        if name == "id":
            return value if _SAFE_ID_RE.match(value) else None

        if name == "class":
            return value if _SAFE_CLASS_RE.match(value) else None

        if name in ("href", "src", "poster", "cite"):
            allow_data = name == "src" and tag == "img"
            url = _safe_url(value, allow_data=allow_data)
            if url is None:
                return None
            if name == "src" and tag == "img" and self._resolver is not None:
                resolved = self._resolver(url)
                if resolved:
                    url = resolved
            return url

        if name in _NUMERIC_ATTRS:
            return value if value.isdigit() else None

        if name in _BOOLEAN_ATTRS:
            return value

        if name == "target":
            return "_blank" if value.strip().lower() == "_blank" else None

        # 其余允许的文本类属性：没有控制字符和尖括号就留着
        return value if _SAFE_TEXT_RE.match(value) else None


def sanitize_html(text: str, resolver: Callable[[str], str | None] | None = None) -> str:
    """把一段 HTML 过一遍白名单消毒。"""
    if not text:
        return ""
    sanitizer = _Sanitizer(resolver)
    sanitizer.feed(text)
    sanitizer.close()
    return sanitizer.result()


# ---------------------------------------------------------------- 对外接口


@dataclass
class RenderResult:
    """一次渲染的结果。"""

    html: str
    title: str = ""
    tags: list[str] | None = None
    categories: list[str] | None = None
    is_draft: bool = False
    word_count: int = 0
    reading_minutes: int = 0
    outline: list[dict[str, Any]] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "html": self.html,
            "title": self.title,
            "tags": self.tags or [],
            "categories": self.categories or [],
            "draft": self.is_draft,
            "wordCount": self.word_count,
            "readingMinutes": self.reading_minutes,
            "outline": self.outline,
        }


def _reading_minutes(count: int) -> int:
    """阅读时长（分钟）。中文约 350 字/分钟。"""
    if count <= 0:
        return 0
    return max(1, round(count / 350))


def render_markdown(text: str, resolver: Callable[[str], str | None] | None = None) -> str:
    """渲染 Markdown 片段，返回 HTML。

    只渲染「正文」，不碰 front matter —— 输入里如果有 front matter，
    会被切掉再渲染。``resolver`` 用来重写图片地址。
    """
    if not text:
        return ""

    _, body = frontmatter.split(text)
    return _render_body(body, resolver)


def render_markdown_document(
    text: str, resolver: Callable[[str], str | None] | None = None
) -> RenderResult:
    """渲染整篇文章，顺带把 front matter 里的元信息带出来。

    预览面板要用标题、标签、草稿状态渲染头部信息，所以这里一并返回。
    ``resolver`` 用来把文章里的图片地址换成预览能加载的地址。
    """
    front, body = frontmatter.split(text or "")
    prepared = _preprocess(body)
    rendered, outline = _convert(prepared)
    highlighted = _highlight_code(rendered)
    safe = sanitize_html(highlighted, resolver=resolver)

    count = word_count(body)
    return RenderResult(
        html=safe,
        title=front.title,
        tags=front.tags,
        categories=front.categories,
        is_draft=front.is_draft,
        word_count=count,
        reading_minutes=_reading_minutes(count),
        outline=outline,
    )


def _render_body(body: str, resolver: Callable[[str], str | None] | None = None) -> str:
    """正文 → HTML。"""
    if not body.strip():
        return ""
    prepared = _preprocess(body)
    rendered, _ = _convert(prepared)
    return sanitize_html(_highlight_code(rendered), resolver=resolver)
