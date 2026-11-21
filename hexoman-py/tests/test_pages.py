"""页面管理（PageStore）。"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from hexoman import frontmatter
from hexoman.model import Site
from hexoman.pages import PageKind, PageStore, PageStoreError


@pytest.fixture
def site(tmp_path: Path) -> Site:
    root = tmp_path / "blog"
    (root / "source" / "_posts").mkdir(parents=True)
    (root / "source" / "about").mkdir(parents=True)
    (root / "source" / "friends").mkdir(parents=True)

    (root / "package.json").write_text('{"dependencies": {"hexo": "^7"}}', encoding="utf-8")
    (root / "_config.yml").write_text("title: t\ntheme: yun\n", encoding="utf-8")

    (root / "source" / "about" / "index.md").write_text(
        "---\ntitle: 关于我\nlayout: about\n---\n正文\n", encoding="utf-8"
    )
    (root / "source" / "friends" / "index.md").write_text(
        "---\ntitle: 友链\nlayout: friends\ntags:\n  - 交友\n---\n正文\n", encoding="utf-8"
    )
    (root / "source" / "standalone.md").write_text("没有 front matter 的单页", encoding="utf-8")
    (root / "source" / "_posts" / "hello.md").write_text(
        "---\ntitle: 你好\n---\n文章正文\n", encoding="utf-8"
    )
    (root / "source" / "images").mkdir()
    (root / "source" / "images" / "a.png").write_bytes(b"\x89PNG\r\n\x1a\n")
    (root / "source" / ".hidden").mkdir()
    (root / "source" / ".hidden" / "secret.md").write_text("x", encoding="utf-8")

    return Site(path=str(root), last_opened=1.0)


def test_scan_finds_pages_and_posts(site: Site):
    pages = PageStore.scan(site)
    relatives = {page.relative_path for page in pages}

    assert "about/index.md" in relatives
    assert "friends/index.md" in relatives
    assert "standalone.md" in relatives
    assert "_posts/hello.md" in relatives


def test_scan_skips_hidden_directories(site: Site):
    relatives = {page.relative_path for page in PageStore.scan(site)}
    assert not any(".hidden" in item for item in relatives)


def test_scan_marks_posts(site: Site):
    pages = {page.relative_path: page for page in PageStore.scan(site)}
    assert pages["_posts/hello.md"].is_post is True
    assert pages["about/index.md"].is_post is False


def test_scan_sorts_posts_first(site: Site):
    pages = PageStore.scan(site)
    assert pages[0].is_post is True


def test_scan_sorts_posts_first_even_when_a_page_is_newer(site: Site):
    """文章排在前面靠的是 is_post，不是修改时间。

    fixture 里文章本来就是最后写的、mtime 最新，所以只断言「第一个是文章」
    两种实现都能过。这里把文章改老、页面改新，只有 is_post 这一项还能让它排第一。
    """
    root = Path(site.path) / "source"
    os.utime(root / "_posts" / "hello.md", (1_000_000, 1_000_000))
    os.utime(root / "about" / "index.md", (2_000_000, 2_000_000))

    pages = PageStore.scan(site)
    assert pages[0].is_post is True
    assert pages[0].relative_path == "_posts/hello.md"


def test_kind_detection(site: Site):
    pages = {page.relative_path: page for page in PageStore.scan(site)}
    assert pages["about/index.md"].kind == PageKind.INDEXED
    assert pages["standalone.md"].kind == PageKind.STANDALONE


def test_scan_reads_title_from_front_matter(site: Site):
    pages = {page.relative_path: page for page in PageStore.scan(site)}
    assert pages["about/index.md"].title == "关于我"


def test_scan_falls_back_to_slug_for_title(site: Site):
    pages = {page.relative_path: page for page in PageStore.scan(site)}
    assert pages["standalone.md"].title == "standalone"


def test_url_generation(site: Site):
    pages = {page.relative_path: page for page in PageStore.scan(site)}
    assert pages["about/index.md"].url == "/about/"
    assert pages["standalone.md"].url == "/standalone/"


def test_pages_only_excludes_posts(site: Site):
    pages = PageStore.pages_only(site)
    assert pages
    assert all(not page.is_post for page in pages)


def test_slug_from():
    assert PageStore.slug_from("about/index.md") == "about"
    assert PageStore.slug_from("about.md") == "about"
    assert PageStore.slug_from("index.md") == "首页"


def test_sanitize_keeps_chinese_and_rejects_traversal():
    assert PageStore.sanitize("关于 我") == "关于-我"
    assert PageStore.sanitize("a/b") == "a-b"
    assert PageStore.sanitize("../etc") == ""
    assert PageStore.sanitize("   ") == ""
    assert PageStore.sanitize("---a---") == "a"


def test_is_valid_slug():
    assert PageStore.is_valid_slug("about")
    assert PageStore.is_valid_slug("关于")
    assert not PageStore.is_valid_slug("../x")
    assert not PageStore.is_valid_slug("")


def test_create_makes_index_md(site: Site):
    page = PageStore.create(site, "links", "友情链接", layout="page")

    path = Path(site.path) / "source" / "links" / "index.md"
    assert path.is_file()
    assert page.relative_path == "links/index.md"
    assert page.kind == PageKind.INDEXED

    front, body = PageStore.load(page)
    assert front.title == "友情链接"
    assert front.get_str("layout") == "page"
    assert "在这里写页面内容" in body


def test_create_rejects_duplicate(site: Site):
    with pytest.raises(PageStoreError) as error:
        PageStore.create(site, "about", "重复")
    assert error.value.code == "alreadyExists"


def test_create_rejects_bad_slug(site: Site):
    with pytest.raises(PageStoreError) as error:
        PageStore.create(site, "../evil", "x")
    assert error.value.code == "invalidSlug"


def test_create_sanitizes_slug(site: Site):
    page = PageStore.create(site, "my page", "我的页面")
    assert page.slug == "my-page"
    assert (Path(site.path) / "source" / "my-page" / "index.md").is_file()


def test_fields_put_known_keys_first(site: Site):
    pages = {page.relative_path: page for page in PageStore.scan(site)}
    front, _ = PageStore.load(pages["friends/index.md"])
    fields = PageStore.fields(front)

    keys = [field.key for field in fields]
    assert "title" in keys
    assert "layout" in keys
    assert "tags" in keys
    # title 在 layout 前面，layout 在 tags 前面
    assert keys.index("title") < keys.index("layout")
    assert keys.index("layout") < keys.index("tags")


def test_fields_detect_block_list(site: Site):
    pages = {page.relative_path: page for page in PageStore.scan(site)}
    front, _ = PageStore.load(pages["friends/index.md"])
    fields = {field.key: field for field in PageStore.fields(front)}

    assert fields["tags"].kind == "list"
    assert fields["tags"].items == ["交友"]


def test_fields_mark_unknown_keys(site: Site):
    front = frontmatter.FrontMatter(present=True)
    front.raw_lines = ["title: x", "my_custom_key: 自定义"]
    fields = {field.key: field for field in PageStore.fields(front)}

    assert fields["my_custom_key"].is_known is False
    assert fields["my_custom_key"].kind == "passthrough"


def test_update_field_changes_only_that_key(site: Site):
    pages = {page.relative_path: page for page in PageStore.scan(site)}
    page = pages["about/index.md"]

    PageStore.update_field(page, "title", "新的标题")

    front, body = PageStore.load(page)
    assert front.title == "新的标题"
    assert front.get_str("layout") == "about"
    assert body.strip() == "正文"


def test_update_field_coerces_boolean(site: Site):
    pages = {page.relative_path: page for page in PageStore.scan(site)}
    page = pages["about/index.md"]

    PageStore.update_field(page, "draft", "yes", kind="boolean")
    front, _ = PageStore.load(page)
    assert front.get_str("draft") == "true"

    PageStore.update_field(page, "draft", "false", kind="boolean")
    front, _ = PageStore.load(page)
    assert front.get_str("draft") == "false"


def test_update_field_coerces_integer(site: Site):
    pages = {page.relative_path: page for page in PageStore.scan(site)}
    page = pages["about/index.md"]

    PageStore.update_field(page, "order", "12", kind="integer")
    assert PageStore.load(page)[0].get_str("order") == "12"

    PageStore.update_field(page, "order", "abc", kind="integer")
    assert PageStore.load(page)[0].get_str("order") == "0"


def test_add_and_remove_field(site: Site):
    pages = {page.relative_path: page for page in PageStore.scan(site)}
    page = pages["about/index.md"]

    PageStore.add_field(page, "comments", "true")
    assert PageStore.load(page)[0].get_str("comments") == "true"

    PageStore.remove_field(page, "comments")
    assert PageStore.load(page)[0].get("comments") is None


def test_save_preserves_body_bytes(site: Site):
    pages = {page.relative_path: page for page in PageStore.scan(site)}
    page = pages["about/index.md"]

    front, body = PageStore.load(page)
    front.set("description", "SEO 描述")
    PageStore.save(page, front, body)

    text = Path(page.path).read_text(encoding="utf-8")
    assert "description: SEO 描述" in text
    assert text.rstrip().endswith("正文")


def test_delete_removes_file_and_empty_directory(site: Site):
    pages = {page.relative_path: page for page in PageStore.scan(site)}
    page = pages["about/index.md"]
    directory = Path(page.path).parent

    PageStore.delete(page)

    assert not Path(page.path).exists()
    assert not directory.exists()


def test_delete_keeps_directory_with_other_files(site: Site):
    pages = {page.relative_path: page for page in PageStore.scan(site)}
    page = pages["about/index.md"]
    extra = Path(page.path).parent / "extra.md"
    extra.write_text("x", encoding="utf-8")

    PageStore.delete(page)

    assert not Path(page.path).exists()
    assert extra.is_file()


def test_delete_standalone_keeps_source_directory(site: Site):
    pages = {page.relative_path: page for page in PageStore.scan(site)}
    page = pages["standalone.md"]

    PageStore.delete(page)

    assert not Path(page.path).exists()
    assert (Path(site.path) / "source").is_dir()


def test_scan_on_missing_source_returns_empty(tmp_path: Path):
    site = Site(path=str(tmp_path / "empty"), last_opened=0.0)
    assert PageStore.scan(site) == []


def test_save_at_path_works(site: Site, tmp_path: Path):
    target = tmp_path / "x" / "y.md"
    front = frontmatter.FrontMatter(present=True)
    front.set("title", "直接写")

    PageStore.save_at_path(str(target), front, "正文")

    assert target.is_file()
    assert "title: 直接写" in target.read_text(encoding="utf-8")
