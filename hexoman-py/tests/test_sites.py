"""站点判定、探测、增删切换。"""

from __future__ import annotations

import json
from pathlib import Path

from hexoman import sites
from hexoman.model import Site


class TestIsHexoSite:
    def test_accepts_valid_site(self, fake_site: Site):
        assert sites.is_hexo_site(fake_site.path) is True

    def test_rejects_missing_config(self, tmp_path: Path):
        root = tmp_path / "no-config"
        root.mkdir()
        (root / "package.json").write_text('{"dependencies": {"hexo": "^7"}}')

        assert sites.is_hexo_site(str(root)) is False

    def test_rejects_missing_package(self, tmp_path: Path):
        root = tmp_path / "no-package"
        root.mkdir()
        (root / "_config.yml").write_text("title: t\n")

        assert sites.is_hexo_site(str(root)) is False

    def test_rejects_package_without_hexo(self, tmp_path: Path):
        root = tmp_path / "not-hexo"
        root.mkdir()
        (root / "package.json").write_text('{"dependencies": {"express": "^4"}}')
        (root / "_config.yml").write_text("title: t\n")

        assert sites.is_hexo_site(str(root)) is False

    def test_accepts_hexo_in_dev_dependencies(self, tmp_path: Path):
        root = tmp_path / "dev-hexo"
        root.mkdir()
        (root / "package.json").write_text('{"devDependencies": {"hexo": "^7"}}')
        (root / "_config.yml").write_text("title: t\n")

        assert sites.is_hexo_site(str(root)) is True

    def test_rejects_empty_path(self):
        assert sites.is_hexo_site("") is False

    def test_falls_back_to_text_match_on_broken_json(self, tmp_path: Path):
        """package.json 语法坏了也不能漏判站点。"""
        root = tmp_path / "broken"
        root.mkdir()
        (root / "package.json").write_text('{ "dependencies": { "hexo": "^7", }')
        (root / "_config.yml").write_text("title: t\n")

        assert sites.is_hexo_site(str(root)) is True


class TestResolvePaths:
    def test_default_paths(self, fake_site: Site):
        source, posts = sites.resolve_paths(fake_site)

        assert source == str(Path(fake_site.path) / "source")
        assert posts == str(Path(fake_site.path) / "source" / "_posts")

    def test_honors_source_dir_and_new_dir(self, tmp_path: Path):
        root = tmp_path / "custom"
        root.mkdir()
        (root / "package.json").write_text('{"dependencies": {"hexo": "^7"}}')
        (root / "_config.yml").write_text(
            "title: t\nsource_dir: src\nnew_dir: articles\n"
        )

        site = Site(path=str(root))
        source, posts = sites.resolve_paths(site)

        assert source == str(root / "src")
        assert posts == str(root / "src" / "articles")

    def test_never_raises_on_missing_config(self, tmp_path: Path):
        root = tmp_path / "empty"
        root.mkdir()
        site = Site(path=str(root))

        source, posts = sites.resolve_paths(site)

        assert source.endswith("source")
        assert posts.endswith("_posts")


class TestInspect:
    def test_reads_site_metadata(self, fake_site: Site):
        info = sites.inspect_site(fake_site)

        assert info.title == "我的博客"
        assert info.url == "https://example.com"
        assert info.theme == "yun"
        assert info.hexo_version == "^7.0.0"
        assert info.theme_version == "^1.0.0"
        assert info.dependencies_installed is False
        assert info.post_count == 0

    def test_detects_installed_dependencies(self, fake_site: Site):
        bin_dir = Path(fake_site.path) / "node_modules" / ".bin"
        bin_dir.mkdir(parents=True)
        (bin_dir / "hexo").write_text("#!/bin/sh\n")

        info = sites.inspect_site(fake_site)

        assert info.dependencies_installed is True

    def test_counts_posts_and_build_output(self, fake_site: Site, make_post):
        make_post(fake_site, "a.md", front="title: A", body="正文")
        make_post(fake_site, "b.md", front="title: B", body="正文")
        (Path(fake_site.path) / "public").mkdir()
        (Path(fake_site.path) / "public" / "index.html").write_text("x")

        info = sites.inspect_site(fake_site)

        assert info.post_count == 2
        assert info.has_build_output is True
        assert info.build_file_count == 1


class TestSiteList:
    def test_add_rejects_non_hexo_site(self, tmp_path: Path):
        root = tmp_path / "nope"
        root.mkdir()

        site_list = sites.SiteList()
        assert site_list.add(str(root)) is False
        assert site_list.sites == []

    def test_add_accepts_hexo_site(self, fake_site: Site):
        site_list = sites.SiteList()
        assert site_list.add(fake_site.path) is True
        assert len(site_list.sites) == 1
        assert site_list.current_path == fake_site.path

    def test_add_same_site_twice_does_not_duplicate(self, fake_site: Site):
        site_list = sites.SiteList()
        site_list.add(fake_site.path)
        site_list.add(fake_site.path)

        assert len(site_list.sites) == 1

    def test_remove_keeps_files_on_disk(self, fake_site: Site):
        """移除只动列表，磁盘文件一个字节都不能少。"""
        site_list = sites.SiteList()
        site_list.add(fake_site.path)
        site_list.remove(fake_site.path)

        assert site_list.sites == []
        assert Path(fake_site.path, "_config.yml").exists()
        assert Path(fake_site.path, "package.json").exists()

    def test_remove_clears_current(self, fake_site: Site):
        site_list = sites.SiteList()
        site_list.add(fake_site.path)
        site_list.remove(fake_site.path)

        assert site_list.current_path == ""

    def test_sites_sorted_by_last_opened_desc(self, tmp_path: Path, fake_site: Site):
        older = fake_site
        newer_root = tmp_path / "newer"
        (newer_root / "source" / "_posts").mkdir(parents=True)
        (newer_root / "package.json").write_text('{"dependencies": {"hexo": "^7"}}')
        (newer_root / "_config.yml").write_text("title: t\n")
        newer = Site(path=str(newer_root))

        site_list = sites.SiteList([older, newer])
        site_list.select(older.path)

        assert site_list.sites[0].path == older.path

    def test_select_refreshes_timestamp(self, fake_site: Site):
        site_list = sites.SiteList([Site(path=fake_site.path, last_opened=0.0)])
        site_list.select(fake_site.path)

        assert site_list.sites[0].last_opened > 0

    def test_round_trips_through_dict(self, fake_site: Site):
        site_list = sites.SiteList()
        site_list.add(fake_site.path)

        restored = sites.SiteList.from_dict(site_list.to_dict())

        assert len(restored.sites) == 1
        assert restored.current_path == fake_site.path


class TestNormalizePath:
    def test_trailing_separator_is_stripped(self, tmp_path: Path):
        from hexoman.model import normalize_path

        root = tmp_path / "site"
        root.mkdir()

        assert normalize_path(str(root) + "/") == normalize_path(str(root))

    def test_empty_path_stays_empty(self):
        from hexoman.model import normalize_path

        assert normalize_path("") == ""
