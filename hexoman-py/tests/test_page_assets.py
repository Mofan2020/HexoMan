"""页面关联资源与引用索引。"""

from __future__ import annotations

from pathlib import Path

import pytest

from hexoman.model import Site
from hexoman.page_assets import PageAssetScanner
from hexoman.page_reference import PageReferenceIndex
from hexoman.pages import PageStore


@pytest.fixture
def site(tmp_path: Path) -> Site:
    root = tmp_path / "blog"
    (root / "source" / "_posts").mkdir(parents=True)
    (root / "source" / "girls").mkdir(parents=True)
    (root / "source" / "css").mkdir(parents=True)
    (root / "source" / "js").mkdir(parents=True)

    (root / "package.json").write_text('{"dependencies": {"hexo": "^7"}}', encoding="utf-8")
    (root / "_config.yml").write_text("title: t\n", encoding="utf-8")

    (root / "source" / "girls" / "index.md").write_text(
        "---\n"
        "title: 可爱的女孩子\n"
        "layout: girls\n"
        "permalink: /girls/\n"
        "tags:\n"
        "  - 二次元\n"
        "---\n"
        '<link rel="stylesheet" href="/css/girls.css">\n'
        '<script src="/js/girls.js"></script>\n'
        '<script src="https://cdn.example.com/x.js"></script>\n'
        '<link href="/css/missing.css">\n',
        encoding="utf-8",
    )
    (root / "source" / "css" / "girls.css").write_text("body{}", encoding="utf-8")
    (root / "source" / "js" / "girls.js").write_text("console.log(1)", encoding="utf-8")

    return Site(path=str(root), last_opened=1.0)


def _page(site: Site, relative: str):
    for page in PageStore.scan(site):
        if page.relative_path == relative:
            return page
    raise AssertionError(relative)


# -- 关联资源 ----------------------------------------------------------


def test_scan_finds_explicit_references(site: Site):
    page = _page(site, "girls/index.md")
    assets = {asset.site_path: asset for asset in PageAssetScanner.scan(site, page)}

    assert "/css/girls.css" in assets
    assert assets["/css/girls.css"].origin == "explicit"
    assert assets["/css/girls.css"].byte_size > 0
    assert "/js/girls.js" in assets


def test_scan_excludes_online_resources(site: Site):
    page = _page(site, "girls/index.md")
    paths = {asset.site_path for asset in PageAssetScanner.scan(site, page)}
    assert not any("cdn.example.com" in path for path in paths)


def test_scan_marks_missing(site: Site):
    page = _page(site, "girls/index.md")
    assets = {asset.site_path: asset for asset in PageAssetScanner.scan(site, page)}

    assert assets["/css/missing.css"].origin == "missing"
    assert assets["/css/missing.css"].source_path == ""


def test_scan_missing_sorted_last(site: Site):
    page = _page(site, "girls/index.md")
    assets = PageAssetScanner.scan(site, page)
    assert assets[-1].origin == "missing"


def test_scan_convention_fallback(tmp_path: Path):
    root = tmp_path / "s"
    (root / "source" / "about").mkdir(parents=True)
    (root / "source" / "css").mkdir(parents=True)
    (root / "source" / "about" / "index.md").write_text("---\ntitle: x\n---\n正文\n", encoding="utf-8")
    (root / "source" / "css" / "about.css").write_text("a{}", encoding="utf-8")

    site = Site(path=str(root), last_opened=0.0)
    page = _page(site, "about/index.md")
    assets = {asset.site_path: asset for asset in PageAssetScanner.scan(site, page)}

    assert "/css/about.css" in assets
    assert assets["/css/about.css"].origin == "convention"


def test_convention_without_file_is_dropped(tmp_path: Path):
    root = tmp_path / "s"
    (root / "source" / "about").mkdir(parents=True)
    (root / "source" / "about" / "index.md").write_text("正文\n", encoding="utf-8")

    site = Site(path=str(root), last_opened=0.0)
    page = _page(site, "about/index.md")
    assert PageAssetScanner.scan(site, page) == []


def test_local_references_rules():
    text = (
        '<link href="/css/a.css">'
        '<script src="/js/b.js"></script>'
        '<script src="https://cdn.x/c.js"></script>'
        '<script src="//cdn.x/d.js"></script>'
        '<a href="/archives/">归档</a>'
    )
    references = PageAssetScanner.local_references(text)

    assert "/css/a.css" in references
    assert "/js/b.js" in references
    assert not any("cdn" in item for item in references)
    # 路由链接不是资源
    assert "/archives/" not in references


def test_local_references_dedupes():
    text = '<script src="/js/a.js"></script><script src="/js/a.js"></script>'
    assert PageAssetScanner.local_references(text) == ["/js/a.js"]


def test_asset_to_dict_has_labels(site: Site):
    page = _page(site, "girls/index.md")
    asset = PageAssetScanner.scan(site, page)[0]
    data = asset.to_dict()

    assert data["kindLabel"] in ("样式", "脚本", "图片", "其他")
    assert data["originLabel"] in ("引用", "推断", "缺失")


# -- 引用索引 ----------------------------------------------------------


def test_references_by_path_link(site: Site, tmp_path: Path):
    posts = Path(site.path) / "source" / "_posts"
    (posts / "a.md").write_text(
        "---\ntitle: 文章 A\n---\n看看 [这个](/girls/) 页面\n", encoding="utf-8"
    )

    page = _page(site, "girls/index.md")
    references = PageReferenceIndex.references(page, site)

    assert any(item.match_kind == "pathLink" for item in references)
    assert references[0].post_title == "文章 A"


def test_references_by_permalink(site: Site):
    posts = Path(site.path) / "source" / "_posts"
    (posts / "b.md").write_text("---\ntitle: B\n---\n[链接](/girls/)\n", encoding="utf-8")

    page = _page(site, "girls/index.md")
    references = PageReferenceIndex.references(page, site)
    assert references


def test_references_by_shared_tag(site: Site):
    posts = Path(site.path) / "source" / "_posts"
    (posts / "c.md").write_text(
        "---\ntitle: C\ntags:\n  - 二次元\n---\n没有链接\n", encoding="utf-8"
    )

    page = _page(site, "girls/index.md")
    references = PageReferenceIndex.references(page, site)
    assert any(item.match_kind == "tag" and item.match_snippet == "二次元" for item in references)


def test_references_skip_unrelated_posts(site: Site):
    posts = Path(site.path) / "source" / "_posts"
    (posts / "d.md").write_text("---\ntitle: D\n---\n完全无关\n", encoding="utf-8")

    page = _page(site, "girls/index.md")
    assert PageReferenceIndex.references(page, site) == []


def test_references_empty_when_no_posts(tmp_path: Path):
    root = tmp_path / "empty"
    (root / "source" / "about").mkdir(parents=True)
    (root / "source" / "about" / "index.md").write_text("x", encoding="utf-8")

    site = Site(path=str(root), last_opened=0.0)
    page = _page(site, "about/index.md")
    assert PageReferenceIndex.references(page, site) == []
