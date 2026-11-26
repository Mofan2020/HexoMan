"""Markdown 渲染与代码高亮。

重点验证三件事：

1. **front matter 不能进正文**（它是 YAML 头部，不是文章内容）。
2. **代码块要有 pygments 的 token class**（颜色由 CSS 负责）。
3. **原始 HTML 要过白名单消毒**。预览页带着能改文件的桥接，
   一篇从网上抄来的文章里藏一段 ``<script>`` 就能直接调后端。
"""

from __future__ import annotations

from hexoman import markdown_render


class TestFrontMatterHandling:
    def test_front_matter_is_not_rendered(self):
        """front matter 是 YAML 头部，不能渲染进正文。"""
        text = "---\ntitle: 我的文章\ntags:\n  - python\n---\n# 正文标题\n"

        html = markdown_render.render_markdown(text)

        assert "正文标题" in html
        assert "<h1" in html
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

        assert "标题" in html
        assert "<p>正文</p>" in html


class TestBasicBlocks:
    def test_headings(self):
        html = markdown_render.render_markdown("## 二级标题")

        assert "<h2" in html
        assert "二级标题" in html

    def test_heading_gets_an_anchor_id(self):
        """标题带 id，大纲才能点得动。"""
        html = markdown_render.render_markdown("## 二级标题")

        assert 'id="二级标题"' in html

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

    def test_nested_list_keeps_its_level(self):
        """嵌套列表不能被拍平成同级——这是换引擎要修的头号毛病。"""
        html = markdown_render.render_markdown("- 一级\n    - 二级\n")

        assert html.count("<ul>") == 2

    def test_task_list_marker_becomes_a_box(self):
        html = markdown_render.render_markdown("- [ ] 待办\n- [x] 做完了\n")

        assert 'class="task-box"' in html
        assert 'class="task-box is-done"' in html
        assert "[ ]" not in html

    def test_blockquote(self):
        html = markdown_render.render_markdown("> 引用内容")

        assert "<blockquote>" in html
        assert "引用内容" in html

    def test_horizontal_rule(self):
        html = markdown_render.render_markdown("---")

        assert "<hr" in html

    def test_link(self):
        html = markdown_render.render_markdown("[链接](https://example.com)")

        assert 'href="https://example.com"' in html
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
        html = markdown_render.render_markdown(
            "```python\ndef hello():\n    return 1\n```"
        )

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

    def test_code_containing_fence_does_not_break_the_block(self):
        """代码里自己带 ``` 时，块不能被提前关掉。"""
        html = markdown_render.render_markdown("````\n```\ninner\n```\n````")

        assert "inner" in html


class TestHexoTags:
    """Hexo 的标签是它自己解析的，Markdown 引擎不认识，得先翻译。"""

    def test_codeblock_becomes_a_code_block(self):
        html = markdown_render.render_markdown(
            "{% codeblock python %}\nprint('hi')\n{% endcodeblock %}"
        )

        assert 'class="language-python"' in html
        assert "print" in html
        assert "codeblock" not in html

    def test_asset_img_becomes_an_image(self):
        html = markdown_render.render_markdown("{% asset_img images/a.png 说明 %}")

        assert "<img" in html
        assert "images/a.png" in html
        assert 'alt="说明"' in html

    def test_post_link_becomes_a_link(self):
        html = markdown_render.render_markdown("{% post_link about 关于 %}")

        assert 'href="/about/"' in html
        assert ">关于</a>" in html

    def test_unknown_tag_is_marked_not_dropped(self):
        """不认识的标签要标出来，不能悄悄消失，也不能原样印成正文。"""
        html = markdown_render.render_markdown("{% some_plugin arg %}")

        assert "hexo-tag" in html
        assert "some_plugin" in html

    def test_raw_block_content_is_not_tag_processed(self):
        """``{% raw %}`` 里的内容不该再被当成标签处理。"""
        html = markdown_render.render_markdown(
            "{% raw %}\n{% asset_img a.png %}\n{% endraw %}"
        )

        assert "<img" not in html
        assert "asset_img" in html

    def test_tag_inside_code_fence_is_left_alone(self):
        """代码块里的 ``{% %}`` 是代码，不是标签。"""
        html = markdown_render.render_markdown(
            "```\n{% asset_img a.png %}\n```"
        )

        assert "<img" not in html
        assert "asset_img" in html


class TestSanitizer:
    """原始 HTML 会原样透传，所以必须过一遍白名单。"""

    def test_script_is_removed_entirely(self):
        html = markdown_render.render_markdown("<script>alert(1)</script>")

        assert "<script" not in html
        assert "alert(1)" not in html

    def test_event_handlers_are_stripped(self):
        html = markdown_render.render_markdown(
            '<a href="https://example.com" onclick="steal()">点</a>'
        )

        assert "onclick" not in html
        assert "steal" not in html

    def test_javascript_urls_are_stripped(self):
        html = markdown_render.render_markdown("[点](javascript:alert(1))")

        assert "javascript:" not in html

    def test_style_attribute_is_stripped(self):
        """style 能注入 CSS，不能留。"""
        html = markdown_render.render_markdown(
            '<p style="position:fixed;inset:0">盖住整个窗口</p>'
        )

        assert "style=" not in html
        assert "盖住整个窗口" in html

    def test_safe_raw_html_is_kept(self):
        """Hexo 文章里写 ``<b>``、``<img align="right">`` 是常事，得留住。"""
        html = markdown_render.render_markdown('<b>粗</b> <img src="/a.png" align="right">')

        assert "<b>粗</b>" in html
        assert 'align="right"' in html

    def test_iframe_becomes_a_link(self):
        """iframe 不能在预览里跑，但地址要留个链接。"""
        html = markdown_render.render_markdown(
            '<iframe src="https://example.com/embed"></iframe>'
        )

        assert "<iframe" not in html
        assert "embed-note" in html
        assert "https://example.com/embed" in html

    def test_unknown_wrapper_tag_keeps_its_text(self):
        """``<center>`` 里的字还要看得见，只是标签被拆掉。"""
        html = markdown_render.render_markdown("<center>居中</center>")

        assert "居中" in html
        assert "<center" not in html


class TestOutline:
    def test_outline_lists_headings(self):
        result = markdown_render.render_markdown_document(
            "# 一级\n\n## 二级\n\n正文\n"
        )

        titles = [item["text"] for item in result.outline]
        assert "一级" in titles
        assert "二级" in titles

    def test_outline_ids_match_the_rendered_headings(self):
        """大纲的 id 必须在 HTML 里真实存在，点得动。"""
        result = markdown_render.render_markdown_document("# 一级标题\n")

        assert result.outline
        anchor = result.outline[0]["id"]
        assert f'id="{anchor}"' in result.html


class TestStats:
    def test_word_count_ignores_code_blocks(self):
        result = markdown_render.render_markdown_document(
            "正文几个字\n\n```\ncode block content\n```\n"
        )

        assert result.word_count >= 4
        assert result.word_count < 20

    def test_reading_time_is_derived_from_word_count(self):
        result = markdown_render.render_markdown_document("字" * 700)

        assert result.reading_minutes >= 1

    def test_empty_document_has_no_reading_time(self):
        result = markdown_render.render_markdown_document("")

        assert result.word_count == 0
        assert result.reading_minutes == 0


class TestImageResolver:
    def test_resolver_rewrites_image_source(self):
        def resolver(src):
            return "http://127.0.0.1:1234/token/source" + src

        html = markdown_render.render_markdown(
            "![图](/images/a.png)", resolver=resolver
        )

        assert 'src="http://127.0.0.1:1234/token/source/images/a.png"' in html

    def test_resolver_returning_none_keeps_the_original(self):
        def resolver(src):
            return None

        html = markdown_render.render_markdown(
            "![图](/images/a.png)", resolver=resolver
        )

        assert 'src="/images/a.png"' in html


class TestEscaping:
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
