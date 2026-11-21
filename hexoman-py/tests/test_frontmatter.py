"""front matter 的解析与回写。

重点验证「读到什么样，写回去就还什么样」这条底线。
"""

from __future__ import annotations

from hexoman import frontmatter


class TestSplit:
    def test_no_front_matter_keeps_body_untouched(self):
        text = "# 标题\n\n正文"
        front, body = frontmatter.split(text)

        assert front.present is False
        assert body == text
        assert front.title == ""

    def test_splits_front_matter_and_body(self):
        text = "---\ntitle: 第一篇\n---\n正文在这里\n"

        front, body = frontmatter.split(text)

        assert front.present is True
        assert front.title == "第一篇"
        assert body == "正文在这里\n"

    def test_unterminated_front_matter_is_treated_as_body(self):
        """``---`` 没闭合时不能给用户文件补一个莫名其妙的块。"""
        text = "---\ntitle: 坏的\n\n正文"

        front, body = frontmatter.split(text)

        assert front.present is False
        assert body == text

    def test_crlf_is_normalized(self):
        text = "---\r\ntitle: 测试\r\n---\r\n正文"

        front, body = frontmatter.split(text)

        assert front.present is True
        assert front.title == "测试"
        assert "\r" not in body


class TestFields:
    def test_reads_title_date_tags_categories(self):
        text = (
            "---\n"
            "title: 我的文章\n"
            "date: 2026-11-20 10:30:00\n"
            "tags:\n"
            "  - python\n"
            "  - hexo\n"
            "categories:\n"
            "  - 技术\n"
            "---\n"
            "正文"
        )

        front, _ = frontmatter.split(text)

        assert front.title == "我的文章"
        assert front.date is not None
        assert front.date.strftime("%Y-%m-%d %H:%M:%S") == "2026-11-20 10:30:00"
        assert front.tags == ["python", "hexo"]
        assert front.categories == ["技术"]

    def test_reads_inline_list(self):
        text = "---\ntitle: t\ntags: [a, b, c]\n---\n正文"

        front, _ = frontmatter.split(text)

        assert front.tags == ["a", "b", "c"]

    def test_reads_comma_separated_list(self):
        text = "---\ntitle: t\ntags: a, b\n---\n正文"

        front, _ = frontmatter.split(text)

        assert front.tags == ["a", "b"]

    def test_reads_draft_flag(self):
        front, _ = frontmatter.split("---\ntitle: t\ndraft: true\n---\n正文")
        assert front.is_draft is True

        front, _ = frontmatter.split("---\ntitle: t\ndraft: false\n---\n正文")
        assert front.is_draft is False

    def test_missing_draft_defaults_to_published(self):
        front, _ = frontmatter.split("---\ntitle: t\n---\n正文")
        assert front.is_draft is False

    def test_nested_block_is_preserved_verbatim(self):
        """嵌套映射块要原样保留。

        早期实现在这里会丢数据：列表套映射只读进第一项的 name，
        保存一次就只剩一条。保真优先于「解析得多聪明」。
        """
        text = (
            "---\n"
            "title: 角色表\n"
            "girls:\n"
            "  - name: 阿蕾奇诺\n"
            "    from: 原神\n"
            "    reason: 父亲！！！\n"
            "  - name: 哥伦比娅\n"
            "    from: 原神\n"
            "---\n"
            "正文"
        )

        front, _ = frontmatter.split(text)
        rendered = frontmatter.render(front, "正文")

        assert "阿蕾奇诺" in rendered
        assert "哥伦比娅" in rendered
        assert "reason: 父亲！！！" in rendered


class TestRender:
    def test_round_trip_preserves_unknown_keys(self):
        text = (
            "---\n"
            "title: 标题\n"
            "custom_field: 保持原样\n"
            "layout: post\n"
            "---\n"
            "正文"
        )

        front, body = frontmatter.split(text)
        rendered = frontmatter.render(front, body)

        assert "custom_field: 保持原样" in rendered
        assert "layout: post" in rendered
        assert rendered.endswith("正文")

    def test_update_only_touches_the_changed_key(self):
        text = "---\ntitle: 旧标题\nlayout: post\n---\n正文"

        front, body = frontmatter.split(text)
        front.set("title", "新标题")
        rendered = frontmatter.render(front, body)

        assert "title: 新标题" in rendered
        assert "layout: post" in rendered
        assert "旧标题" not in rendered

    def test_absent_front_matter_stays_absent(self):
        """没有 front matter 的文章保存后也不该凭空多出一个空块。"""
        front = frontmatter.FrontMatter(present=False)
        rendered = frontmatter.render(front, "只有正文")

        assert rendered == "只有正文"
        assert "---" not in rendered

    def test_set_tags_renders_block_list(self):
        front = frontmatter.FrontMatter(present=True)
        front.set("tags", ["python", "hexo"])

        rendered = frontmatter.render(front, "正文")

        assert "tags:" in rendered
        assert "  - python" in rendered
        assert "  - hexo" in rendered

    def test_set_draft_renders_boolean(self):
        front = frontmatter.FrontMatter(present=True)
        front.set("draft", True)

        assert "draft: true" in frontmatter.render(front, "正文")

        front.set("draft", False)
        assert "draft: false" in frontmatter.render(front, "正文")

    def test_set_new_key_appends(self):
        text = "---\ntitle: 标题\n---\n正文"

        front, body = frontmatter.split(text)
        front.set("description", "摘要")
        rendered = frontmatter.render(front, body)

        assert "description: 摘要" in rendered
        # 顺序保持：title 在前，新键追加在后
        assert rendered.index("title:") < rendered.index("description:")

    def test_remove_key(self):
        text = "---\ntitle: 标题\ndraft: true\n---\n正文"

        front, body = frontmatter.split(text)
        front.remove("draft")
        rendered = frontmatter.render(front, body)

        assert "draft" not in rendered
        assert "title: 标题" in rendered

    def test_value_with_colon_space_gets_quoted(self):
        """值里带「冒号+空格」必须加引号，否则 YAML 会读成嵌套结构。"""
        front = frontmatter.FrontMatter(present=True)
        front.set("description", "第一句: 第二句")

        rendered = frontmatter.render(front, "正文")

        assert 'description: "第一句: 第二句"' in rendered

    def test_url_with_colon_stays_unquoted(self):
        """``https://`` 里的冒号后面没有空格，YAML 读得对，不用加引号。"""
        front = frontmatter.FrontMatter(present=True)
        front.set("url", "https://example.com")

        rendered = frontmatter.render(front, "正文")

        assert "url: https://example.com" in rendered

    def test_url_with_anchor_is_quoted(self):
        """带 ``#`` 的 URL 必须加引号——``#`` 会被当成注释开头。"""
        front = frontmatter.FrontMatter(present=True)
        front.set("url", "https://example.com/#anchor")

        rendered = frontmatter.render(front, "正文")

        assert 'url: "https://example.com/#anchor"' in rendered

    def test_numeric_looking_string_stays_string(self):
        front = frontmatter.FrontMatter(present=True)
        front.set("order", "2026")

        rendered = frontmatter.render(front, "正文")

        assert 'order: "2026"' in rendered


class TestDates:
    def test_parses_common_formats(self):
        assert frontmatter.parse_date("2026-11-20") is not None
        assert frontmatter.parse_date("2026-11-20 10:30:00") is not None
        assert frontmatter.parse_date("2026-11-20T10:30:00") is not None
        assert frontmatter.parse_date("2026/11/20") is not None

    def test_rejects_garbage(self):
        assert frontmatter.parse_date("不是日期") is None
        assert frontmatter.parse_date("") is None

    def test_format_round_trip(self):
        import datetime

        value = datetime.datetime(2026, 11, 20, 10, 30, 0)
        assert frontmatter.format_date(value) == "2026-11-20 10:30:00"
        assert frontmatter.parse_date(frontmatter.format_date(value)) == value
