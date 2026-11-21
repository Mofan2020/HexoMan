"""Markdown 渲染与代码高亮。

重点验证：**front matter 不能进正文**，以及代码块要有 pygments 的
token class（颜色由 CSS 负责）。
"""

from __future__ import annotations

from hexoman import markdown_render


class TestFrontMatterHandling:
    def test_front_matter_is_not_rendered(self):
        """front matter 是 YAML 头部，不能渲染进正文。"""
        text = "---\ntitle: 我的文章\ntags:\n  - python\n---\n# 正文标题\n"

        html = markdown_render.render_markdown(text)

        assert "<h1>正文标题</h1>" in html
        assert "我的文章" not in html
        assert "python" not in html

    def test_document_result_exposes_metadata(self):
        text = "---\ntitle: 我的文章\ntags:\n  - python\ndraft: true\n---\n正文"

        result = markdown_render.render_markdown_document(text)

        assert result.title == "我的文章"
        assert result.tags == ["python"]
        assert result.is_draft is True
        assert "正文" in result.html
        assert "我的文章" not in result.html

    def test_plain_markdown_renders(self):
        html = markdown_render.render_markdown("# 标题\n\n正文")

        assert "<h1>标题</h1>" in html
        assert "<p>正文</p>" in html


class TestBasicBlocks:
    def test_headings(self):
        html = markdown_render.render_markdown("## 二级标题")

        assert "<h2>二级标题</h2>" in html

    def test_paragraph_breaks(self):
        html = markdown_render.render_markdown("第一段\n\n第二段")

        assert html.count("<p>") == 2

    def test_bold_and_italic(self):
        html = markdown_render.render_markdown("**粗体** 和 *斜体*")

        assert "<strong>粗体</strong>" in html
        assert "<em>斜体</em>" in html

    def test_strikethrough(self):
        html = markdown_render.render_markdown("~~删除~~")

        assert "<del>删除</del>" in html

    def test_unordered_list(self):
        html = markdown_render.render_markdown("- 第一项\n- 第二项")

        assert "<ul>" in html
        assert html.count("<li>") == 2

    def test_ordered_list(self):
        html = markdown_render.render_markdown("1. 第一项\n2. 第二项")

        assert "<ol>" in html
        assert html.count("<li>") == 2

    def test_blockquote(self):
        html = markdown_render.render_markdown("> 引用内容")

        assert "<blockquote>" in html
        assert "引用内容" in html

    def test_horizontal_rule(self):
        html = markdown_render.render_markdown("---")

        assert "<hr />" in html

    def test_link(self):
        html = markdown_render.render_markdown("[链接](https://example.com)")

        assert '<a href="https://example.com"' in html
        assert ">链接</a>" in html

    def test_image(self):
        html = markdown_render.render_markdown("![替代文字](/images/a.png)")

        assert 'src="/images/a.png"' in html
        assert 'alt="替代文字"' in html

    def test_table(self):
        html = markdown_render.render_markdown(
            "| 名称 | 值 |\n| --- | --- |\n| a | 1 |\n| b | 2 |"
        )

        assert "<table>" in html
        assert "<th>名称</th>" in html
        assert "<td>2</td>" in html

    def test_inline_code(self):
        html = markdown_render.render_markdown("用 `print()` 输出")

        assert "<code>print()</code>" in html

    def test_html_comment_is_hidden(self):
        """Hexo 用 ``<!-- more -->`` 控制摘要，预览里要藏起来。"""
        html = markdown_render.render_markdown("前面\n\n<!-- more -->\n\n后面")

        assert "more" not in html
        assert "前面" in html
        assert "后面" in html


class TestCodeHighlighting:
    def test_code_block_gets_language_class(self):
        html = markdown_render.render_markdown("```python\nprint('hi')\n```")

        assert 'class="language-python"' in html
        assert "<pre" in html

    def test_code_block_has_pygments_tokens(self):
        """pygments 要把关键字标出来——颜色由 CSS 负责，class 由 pygments 负责。"""
        html = markdown_render.render_markdown("```python\ndef hello():\n    return 1\n```")

        # pygments 会给 def 标上 .k（keyword）
        assert 'class="k"' in html

    def test_unknown_language_falls_back_to_plain(self):
        """不认识的语言也要能显示，不能整个预览挂掉。"""
        html = markdown_render.render_markdown("```notalanguage\nsome code\n```")

        assert "some code" in html
        assert "<pre" in html

    def test_code_without_language_still_renders(self):
        html = markdown_render.render_markdown("```\nplain code\n```")

        assert "plain code" in html
        assert "<pre" in html

    def test_code_is_escaped(self):
        """代码里的 ``<`` 不能变成标签。"""
        html = markdown_render.render_markdown("```\n<div>hello</div>\n```")

        assert "&lt;div&gt;" in html
        assert "<div>hello</div>" not in html


class TestEscaping:
    def test_script_tags_are_escaped_in_text(self):
        html = markdown_render.render_markdown("<script>alert(1)</script>")

        assert "<script>" not in html
        assert "&lt;script&gt;" in html

    def test_inline_code_protects_markdown_syntax(self):
        """行内代码里的 ``*`` 不能被当成强调标记。"""
        html = markdown_render.render_markdown("`*not italic*`")

        assert "<em>" not in html
        assert "<code>*not italic*</code>" in html


class TestEmpty:
    def test_empty_input(self):
        assert markdown_render.render_markdown("") == ""

    def test_whitespace_only(self):
        assert markdown_render.render_markdown("   \n  \n") == ""
