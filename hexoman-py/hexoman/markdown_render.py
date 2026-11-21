"""Markdown 渲染 + 代码高亮。

这是 Python 版新增的重点功能：Swift 原版没有内置预览。

两个必须做对的地方：

1. **front matter 不能进正文。** front matter 是 YAML 头部，渲染成 HTML
   会在预览顶部冒出一堆 ``---`` 和元数据。渲染前先切掉。
2. **代码块要高亮。** 用 pygments 拿 token，再交给 CSS 上色——pygments
   自己只管「这段代码是关键字还是字符串」，颜色是主题的事。
"""

from __future__ import annotations

import html
import re
from dataclasses import dataclass
from typing import Any

from . import frontmatter

__all__ = ["render_markdown", "render_markdown_document", "RenderResult"]

_FENCE_RE = re.compile(r"^(```|~~~)\s*([^\s`]*)\s*$")
_INLINE_CODE_RE = re.compile(r"`([^`\n]+)`")
_HTML_COMMENT_RE = re.compile(r"<!--.*?-->", re.DOTALL)


@dataclass
class RenderResult:
    """一次渲染的结果。"""

    html: str
    title: str = ""
    tags: list[str] | None = None
    categories: list[str] | None = None
    is_draft: bool = False

    def to_dict(self) -> dict[str, Any]:
        return {
            "html": self.html,
            "title": self.title,
            "tags": self.tags or [],
            "categories": self.categories or [],
            "draft": self.is_draft,
        }


def render_markdown(text: str) -> str:
    """渲染 Markdown 片段，返回 HTML。

    只渲染「正文」，不碰 front matter —— 输入里如果有 front matter，
    会被切掉再渲染。
    """
    if not text:
        return ""

    _, body = frontmatter.split(text)
    return _render_body(body)


def render_markdown_document(text: str) -> RenderResult:
    """渲染整篇文章，顺带把 front matter 里的元信息带出来。

    预览面板要用标题、标签、草稿状态渲染头部信息，所以这里一并返回。
    """
    front, body = frontmatter.split(text)
    return RenderResult(
        html=_render_body(body),
        title=front.title,
        tags=front.tags,
        categories=front.categories,
        is_draft=front.is_draft,
    )


def _render_body(body: str) -> str:
    """把正文渲染成 HTML。

    刻意不引入完整 Markdown 引擎（markdown-it / mistune）：我们要的只是
    标题、列表、表格、引用、代码块、图片、链接这几样。少一个依赖就少一
    处版本冲突，Hexo 生态用户大多自己就装了 Node 工具链。
    """
    if not body.strip():
        return ""

    lines = body.replace("\r\n", "\n").split("\n")
    out: list[str] = []
    index = 0
    total = len(lines)

    while index < total:
        line = lines[index]

        # 空行直接跳过。不推进 index 的话外层循环会原地打转——
        # 这是真的发生过一次的死循环，不是理论风险。
        if not line.strip():
            out.append("")
            index += 1
            continue

        # 代码块：整块吃掉，交给高亮器
        fence = _FENCE_RE.match(line.strip())
        if fence:
            marker = fence.group(1)
            language = fence.group(2).strip()
            code_lines: list[str] = []
            index += 1
            while index < total and not lines[index].strip().startswith(marker):
                code_lines.append(lines[index])
                index += 1
            index += 1  # 跳过收尾的 ```
            out.append(_render_code_block("\n".join(code_lines), language))
            continue

        # HTML 注释：Hexo 用 `<!-- more -->` 控制摘要，预览里要藏起来
        comment = _HTML_COMMENT_RE.match(line.strip())
        if comment:
            out.append("")
            index += 1
            continue

        # 标题
        heading = re.match(r"^(#{1,6})\s+(.*)$", line)
        if heading:
            level = len(heading.group(1))
            content = _render_inline(heading.group(2).strip())
            out.append(f"<h{level}>{content}</h{level}>")
            index += 1
            continue

        # 水平线
        if re.match(r"^\s*([-*_])\s*\1\s*\1[\s\-*_]*$", line):
            out.append("<hr />")
            index += 1
            continue

        # 引用
        if line.lstrip().startswith(">"):
            block: list[str] = []
            while index < total and lines[index].lstrip().startswith(">"):
                block.append(lines[index].lstrip()[1:].strip())
                index += 1
            out.append(f"<blockquote>{_render_body(chr(10).join(block))}</blockquote>")
            continue

        # 列表（有序 / 无序，支持缩进嵌套）
        list_match = re.match(r"^(\s*)([-*+]|\d+[.)])\s+(.*)$", line)
        if list_match:
            items, index = _consume_list(lines, index)
            out.append(items)
            continue

        # 表格
        if "|" in line and index + 1 < total and re.match(r"^\s*\|?[\s:|-]+\|[\s:|-]*$", lines[index + 1]):
            table, index = _consume_table(lines, index)
            out.append(table)
            continue

        # 段落
        paragraph: list[str] = []
        while index < total:
            current = lines[index]
            if not current.strip():
                break
            if (
                _FENCE_RE.match(current.strip())
                or re.match(r"^(#{1,6})\s+", current)
                or current.lstrip().startswith(">")
                or re.match(r"^(\s*)([-*+]|\d+[.)])\s+", current)
            ):
                break
            paragraph.append(current.strip())
            index += 1

        if paragraph:
            out.append("<p>" + "<br />".join(_render_inline(item) for item in paragraph) + "</p>")

    return "\n".join(part for part in out if part)


def _render_code_block(code: str, language: str) -> str:
    """代码块 → 带 pygments token class 的 HTML。

    pygments 只负责分类（``k`` 是关键字、``s`` 是字符串），颜色由 CSS 决定，
    这样深浅色主题能共用同一份标记。
    """
    escaped = html.escape(code)

    if not language:
        return f'<pre class="code"><code>{escaped}</code></pre>'

    try:
        from pygments import highlight
        from pygments.formatters import HtmlFormatter
        from pygments.lexers import get_lexer_by_name

        lexer = get_lexer_by_name(language, stripall=False)
        formatter = HtmlFormatter(nowrap=True)
        highlighted = highlight(code, lexer, formatter)
        return f'<pre class="code"><code class="language-{html.escape(language)}">{highlighted}</code></pre>'
    except Exception:
        # 词法器不认识这个语言（或 pygments 不可用）时退回纯文本，
        # 预览必须永远能显示点什么。
        return f'<pre class="code"><code class="language-{html.escape(language)}">{escaped}</code></pre>'


def _render_inline(text: str) -> str:
    """行内渲染：行内代码、链接、图片、粗体、斜体、删除线。

    顺序有讲究：**先把需要原样输出的部分（代码、链接、图片）存成占位符，
    再对剩下的纯文本做 HTML 转义，最后还原占位符**。

    反过来做（先替换成 HTML 再整体转义）会把 ``href="..."`` 的引号转义成
    ``&quot;``，链接直接坏掉——这个 bug 真的发生过。

    另外，行内代码必须先抽出来，否则代码里的 ``*`` 会被当成强调标记。
    """
    placeholders: list[str] = []

    def stash(markup: str) -> str:
        placeholders.append(markup)
        return f"\x00{len(placeholders) - 1}\x00"

    # 1. 行内代码
    text = _INLINE_CODE_RE.sub(
        lambda m: stash(f"<code>{html.escape(m.group(1))}</code>"), text
    )

    # 2. 图片：先于链接处理，``![alt](src)`` 的前半段不是链接
    text = re.sub(
        r"!\[([^\]]*)\]\(\s*([^)\s]+)(?:\s+&quot;([^&]*)&quot;)?\s*\)",
        lambda m: stash(
            f'<img src="{html.escape(m.group(2))}" alt="{html.escape(m.group(1))}" '
            f'class="markdown-image" />'
        ),
        text,
    )

    # 3. 链接
    text = re.sub(
        r"\[([^\]]+)\]\(\s*([^)\s]+)(?:\s+&quot;([^&]*)&quot;)?\s*\)",
        lambda m: stash(
            f'<a href="{html.escape(m.group(2))}" target="_blank" '
            f'rel="noopener noreferrer">{html.escape(m.group(1))}</a>'
        ),
        text,
    )

    # 4. 剩下的都是纯文本，转义
    text = html.escape(text)

    # 5. 强调
    text = re.sub(r"\*\*\*(.+?)\*\*\*", r"<strong><em>\1</em></strong>", text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<em>\1</em>", text)
    text = re.sub(r"~~(.+?)~~", r"<del>\1</del>", text)

    # 6. 还原占位符
    def restore(match: re.Match[str]) -> str:
        return placeholders[int(match.group(1))]

    return re.sub(r"\x00(\d+)\x00", restore, text)


def _consume_list(lines: list[str], start: int) -> tuple[str, int]:
    """吃掉一个列表块，返回 HTML 和结束下标。"""
    index = start
    total = len(lines)
    items: list[str] = []
    ordered = bool(re.match(r"^\s*\d+[.)]\s+", lines[start]))
    base_indent = len(lines[start]) - len(lines[start].lstrip())

    while index < total:
        line = lines[index]
        if not line.strip():
            # 空行后面如果还是列表项就继续，否则列表结束
            if index + 1 < total and re.match(
                r"^(\s*)([-*+]|\d+[.)])\s+", lines[index + 1]
            ):
                index += 1
                continue
            break

        match = re.match(r"^(\s*)([-*+]|\d+[.)])\s+(.*)$", line)
        if not match:
            break

        indent = len(match.group(1))
        content = match.group(3).strip()

        if indent <= base_indent:
            items.append(content)
            index += 1
            continue

        # 缩进更深：并入上一项的正文
        if items:
            items[-1] = items[-1] + "\n" + content
        index += 1

    rendered = "".join(f"<li>{_render_inline(item)}</li>" for item in items)
    tag = "ol" if ordered else "ul"
    return f"<{tag}>{rendered}</{tag}>", index


def _consume_table(lines: list[str], start: int) -> tuple[str, int]:
    """吃掉一个 Markdown 表格。"""
    index = start
    total = len(lines)

    header = [cell.strip() for cell in lines[index].strip().strip("|").split("|")]
    index += 2  # 跳过分隔行

    rows: list[list[str]] = []
    while index < total and "|" in lines[index] and lines[index].strip():
        rows.append([cell.strip() for cell in lines[index].strip().strip("|").split("|")])
        index += 1

    head = "".join(f"<th>{_render_inline(cell)}</th>" for cell in header)
    body = "".join(
        "<tr>" + "".join(f"<td>{_render_inline(cell)}</td>" for cell in row) + "</tr>"
        for row in rows
    )
    return f"<table><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table>", index
