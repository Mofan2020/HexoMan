"""文章的读写、搜索、筛选。"""

from __future__ import annotations

import datetime
from pathlib import Path

from hexoman import posts as posts_module
from hexoman.model import Site, slugify, word_count


class TestLoad:
    def test_loads_markdown_files_only(self, fake_site: Site, make_post):
        make_post(fake_site, "a.md", front="title: A")
        make_post(fake_site, "b.markdown", front="title: B")
        (Path(fake_site.path) / "source" / "_posts" / "note.txt").write_text("x")

        loaded = posts_module.load_posts(fake_site)

        assert len(loaded) == 2
        assert {post.title for post in loaded} == {"A", "B"}

    def test_sorted_by_date_descending(self, fake_site: Site, make_post):
        make_post(fake_site, "old.md", front="title: Old\ndate: 2020-01-01 00:00:00")
        make_post(fake_site, "new.md", front="title: New\ndate: 2024-01-01 00:00:00")

        loaded = posts_module.load_posts(fake_site)

        assert loaded[0].title == "New"
        assert loaded[-1].title == "Old"

    def test_missing_directory_returns_empty(self, tmp_path: Path):
        site = Site(path=str(tmp_path / "nothing"))

        assert posts_module.load_posts(site) == []


class TestRead:
    def test_reads_front_and_body(self, fake_site: Site, make_post):
        path = make_post(
            fake_site, "post.md", front="title: 标题\ntags:\n  - a", body="正文"
        )

        post = posts_module.read_post(str(path))

        assert post is not None
        assert post.title == "标题"
        assert post.body == "正文"
        assert post.tags == ["a"]
        assert post.slug == "post"
        assert post.filename == "post.md"

    def test_missing_file_returns_none(self, tmp_path: Path):
        assert posts_module.read_post(str(tmp_path / "nope.md")) is None


class TestCreate:
    def test_creates_file_with_front_matter(self, fake_site: Site):
        post = posts_module.create_post(
            fake_site, "我的新文章", body="内容", tags=["python"], categories=["技术"]
        )

        assert Path(post.file_path).exists()
        assert post.title == "我的新文章"
        assert post.tags == ["python"]
        assert post.categories == ["技术"]

    def test_duplicate_title_gets_suffix(self, fake_site: Site):
        first = posts_module.create_post(fake_site, "同名文章")
        second = posts_module.create_post(fake_site, "同名文章")

        assert first.file_path != second.file_path
        assert Path(second.file_path).exists()
        assert Path(first.file_path).exists()

    def test_draft_flag_is_written(self, fake_site: Site):
        post = posts_module.create_post(fake_site, "草稿", is_draft=True)

        assert post.is_draft is True


class TestSave:
    def test_save_preserves_unknown_front_matter_keys(self, fake_site: Site, make_post):
        path = make_post(
            fake_site,
            "keep.md",
            front="title: 旧\ncustom: 保留我\nlayout: post",
            body="旧正文",
        )

        post = posts_module.read_post(str(path))
        assert post is not None
        post.front.set("title", "新")
        post.body = "新正文"
        posts_module.save_post(post)

        text = Path(path).read_text(encoding="utf-8")

        assert "custom: 保留我" in text
        assert "layout: post" in text
        assert "title: 新" in text
        assert "新正文" in text

    def test_save_updates_body(self, fake_site: Site, make_post):
        path = make_post(fake_site, "body.md", front="title: t", body="旧")

        post = posts_module.read_post(str(path))
        assert post is not None
        post.body = "新内容"
        saved = posts_module.save_post(post)

        assert saved.body == "新内容"

    def test_save_is_atomic_no_temp_left_behind(self, fake_site: Site, make_post):
        path = make_post(fake_site, "atomic.md", front="title: t", body="x")

        post = posts_module.read_post(str(path))
        assert post is not None
        post.body = "y"
        posts_module.save_post(post)

        leftovers = list(Path(post.file_path).parent.glob("*.hexoman-tmp"))
        assert leftovers == []


class TestDraft:
    def test_set_draft_writes_flag(self, fake_site: Site, make_post):
        path = make_post(fake_site, "d.md", front="title: t", body="x")

        post = posts_module.read_post(str(path))
        assert post is not None

        updated = posts_module.set_draft(post, True)
        assert updated.is_draft is True

        updated = posts_module.set_draft(updated, False)
        assert updated.is_draft is False


class TestDelete:
    def test_delete_removes_file_from_posts_dir(self, fake_site: Site, make_post):
        path = make_post(fake_site, "gone.md", front="title: t", body="x")

        post = posts_module.read_post(str(path))
        assert post is not None
        posts_module.delete_post(post)

        assert not Path(path).exists()


class TestFilter:
    def _posts(self, fake_site: Site, make_post):
        make_post(
            fake_site,
            "a.md",
            front="title: Python 入门\ntags:\n  - python\ncategories:\n  - 技术",
            body="讲 Python 的",
        )
        make_post(
            fake_site,
            "b.md",
            front="title: 草稿文章\ntags:\n  - 随笔\ndraft: true",
            body="还没写完",
        )
        return posts_module.load_posts(fake_site)

    def test_filter_by_published(self, fake_site: Site, make_post):
        loaded = self._posts(fake_site, make_post)

        result = posts_module.filter_posts(loaded, status="published")

        assert [post.title for post in result] == ["Python 入门"]

    def test_filter_by_draft(self, fake_site: Site, make_post):
        loaded = self._posts(fake_site, make_post)

        result = posts_module.filter_posts(loaded, status="draft")

        assert [post.title for post in result] == ["草稿文章"]

    def test_filter_all(self, fake_site: Site, make_post):
        loaded = self._posts(fake_site, make_post)

        assert len(posts_module.filter_posts(loaded, status="all")) == 2

    def test_search_matches_title(self, fake_site: Site, make_post):
        loaded = self._posts(fake_site, make_post)

        result = posts_module.filter_posts(loaded, search="python")

        assert [post.title for post in result] == ["Python 入门"]

    def test_search_matches_body(self, fake_site: Site, make_post):
        loaded = self._posts(fake_site, make_post)

        result = posts_module.filter_posts(loaded, search="没写完")

        assert [post.title for post in result] == ["草稿文章"]

    def test_search_matches_tag(self, fake_site: Site, make_post):
        loaded = self._posts(fake_site, make_post)

        result = posts_module.filter_posts(loaded, search="随笔")

        assert [post.title for post in result] == ["草稿文章"]

    def test_search_is_case_insensitive(self, fake_site: Site, make_post):
        loaded = self._posts(fake_site, make_post)

        result = posts_module.filter_posts(loaded, search="PYTHON")

        assert len(result) == 1

    def test_search_no_match_returns_empty(self, fake_site: Site, make_post):
        loaded = self._posts(fake_site, make_post)

        assert posts_module.filter_posts(loaded, search="不存在的词") == []

    def test_filter_by_tag(self, fake_site: Site, make_post):
        loaded = self._posts(fake_site, make_post)

        result = posts_module.filter_posts(loaded, tag="python")

        assert len(result) == 1


class TestCollect:
    def test_collect_tags_and_categories(self, fake_site: Site, make_post):
        make_post(fake_site, "a.md", front="title: a\ntags:\n  - x\ncategories:\n  - c")
        make_post(fake_site, "b.md", front="title: b\ntags:\n  - y\ncategories:\n  - c")
        loaded = posts_module.load_posts(fake_site)

        assert posts_module.collect_tags(loaded) == ["x", "y"]
        assert posts_module.collect_categories(loaded) == ["c"]


class TestSlugify:
    def test_keeps_chinese(self):
        assert slugify("我的博客文章") == "我的博客文章"

    def test_keeps_alphanumerics(self):
        assert slugify("hello world") == "hello-world"

    def test_collapses_punctuation(self):
        """标点折叠成连字符，两个词不能被粘在一起。"""
        assert slugify("a/b") == "a-b"
        assert slugify("a///b") == "a-b"

    def test_empty_becomes_untitled(self):
        assert slugify("!!!") == "untitled"


class TestWordCount:
    def test_counts_chinese_characters(self):
        assert word_count("你好世界") == 4

    def test_counts_latin_words(self):
        assert word_count("hello world") == 2

    def test_ignores_code_blocks(self):
        assert word_count("正文\n```\ncode here\n```") == 2

    def test_empty_is_zero(self):
        assert word_count("") == 0
