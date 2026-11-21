"""hexo-cli 自举、主题安装迁移、新建站点。

对应 Swift 侧 ``HexoCLIBootstrap.swift`` / ``HexoManModel.applyTheme``
/ ``HexoManModel.createSite`` 的测试。
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from hexoman.hexo_bootstrap import HexoCLIBootstrap, HexoSource, TEMPLATES
from hexoman.model import Site
from hexoman.process import CommandRunner, ProcessResult
from hexoman.site_creator import SiteCreator
from hexoman.theme_installer import ThemeInstaller


class FakeRunner(CommandRunner):
    """记录调用、不真的跑命令。"""

    def __init__(
        self,
        results: dict[str, ProcessResult] | None = None,
        on_run=None,
    ) -> None:
        super().__init__()
        self.calls: list[list[str]] = []
        self.results = results or {}
        self.which_map: dict[str, str] = {}
        self.on_run = on_run

    def run(self, args, cwd=None, timeout=None, env=None):  # type: ignore[override]
        self.calls.append(list(args))
        if self.on_run is not None:
            self.on_run(list(args))
        for prefix, result in self.results.items():
            if " ".join(args).startswith(prefix):
                return result
        return ProcessResult(exit_code=0, output="")

    def which(self, name: str) -> str | None:
        return self.which_map.get(name)

    def is_executable(self, path: str) -> bool:
        return bool(path) and os.path.isfile(path) and os.access(path, os.X_OK)


class TestLocateHexo:
    def test_custom_path_wins(self, tmp_path: Path):
        custom = tmp_path / "hexo"
        custom.write_text("#!/bin/sh\n", encoding="utf-8")
        custom.chmod(0o755)

        runner = FakeRunner()
        found = HexoCLIBootstrap.locate_hexo(str(custom), runner=runner)

        assert found is not None
        assert found[0] == str(custom)
        assert found[1] == HexoSource.CUSTOM

    def test_custom_path_that_does_not_exist_is_skipped(self, tmp_path: Path):
        runner = FakeRunner()
        found = HexoCLIBootstrap.locate_hexo(str(tmp_path / "nope"), runner=runner)

        # 没有别的来源可用时返回 None
        assert found is None

    def test_user_path_is_used_when_no_custom_path(self):
        runner = FakeRunner()
        runner.which_map["hexo"] = "/usr/local/bin/hexo"

        found = HexoCLIBootstrap.locate_hexo("", runner=runner)

        assert found is not None
        assert found[1] == HexoSource.USER_PATH

    def test_none_when_nothing_is_available(self):
        assert HexoCLIBootstrap.locate_hexo("", runner=FakeRunner()) is None


class TestManifest:
    def test_manifest_is_written_and_is_valid_json(self, tmp_path: Path):
        directory = tmp_path / "cli"
        directory.mkdir()

        assert HexoCLIBootstrap.write_manifest(str(directory)) is True

        import json

        data = json.loads((directory / "package.json").read_text(encoding="utf-8"))
        assert data["name"] == "hexoman-managed-cli"
        assert data["private"] is True
        assert "hexo-cli" in data["dependencies"]

    def test_manifest_write_failure_returns_false(self, tmp_path: Path):
        # 目录不存在时写不进去
        assert HexoCLIBootstrap.write_manifest(str(tmp_path / "missing")) is False


class TestEnsureHexo:
    def test_returns_existing_hexo_without_installing(self, tmp_path: Path):
        custom = tmp_path / "hexo"
        custom.write_text("#!/bin/sh\n", encoding="utf-8")
        custom.chmod(0o755)

        runner = FakeRunner()
        result = HexoCLIBootstrap.ensure_hexo(str(custom), runner=runner)

        assert result == str(custom)
        assert runner.calls == []

    def test_no_npm_means_no_install(self):
        runner = FakeRunner()
        assert HexoCLIBootstrap.ensure_hexo("", runner=runner) is None

    def test_installs_when_npm_exists(self, tmp_path: Path, monkeypatch):
        """没有现成 hexo 但有 npm 时，现场装一份到自有目录。"""
        monkeypatch.setattr(
            HexoCLIBootstrap, "install_directory", staticmethod(lambda: str(tmp_path / "cli"))
        )

        managed = tmp_path / "cli" / "node_modules" / ".bin" / "hexo"

        def simulate_install(args):
            # npm install 跑完之后 hexo 才出现在 bin 目录里
            if "install" in args:
                managed.parent.mkdir(parents=True, exist_ok=True)
                managed.write_text("#!/bin/sh\n", encoding="utf-8")
                managed.chmod(0o755)

        runner = FakeRunner(on_run=simulate_install)
        runner.which_map["npm"] = "/usr/local/bin/npm"

        result = HexoCLIBootstrap.ensure_hexo("", runner=runner)

        assert result == str(managed)
        assert any("install" in " ".join(call) for call in runner.calls)


class TestTemplates:
    def test_two_templates_available(self):
        keys = [item.key for item in TEMPLATES]
        assert "starter" in keys
        assert "standard" in keys

    def test_starter_passes_template_argument(self):
        starter = next(item for item in TEMPLATES if item.key == "starter")
        assert starter.init_arguments("blog") == ["init", "blog", "--template", "hexo-starter"]

    def test_standard_has_no_template_argument(self):
        standard = next(item for item in TEMPLATES if item.key == "standard")
        assert standard.init_arguments("blog") == ["init", "blog"]


class TestSiteCreator:
    def test_valid_site_names(self):
        assert SiteCreator.is_valid_site_name("my-blog") is True
        assert SiteCreator.is_valid_site_name("  my-blog  ") is True

    def test_invalid_site_names(self):
        assert SiteCreator.is_valid_site_name("") is False
        assert SiteCreator.is_valid_site_name(".") is False
        assert SiteCreator.is_valid_site_name("..") is False
        assert SiteCreator.is_valid_site_name("a/b") is False
        assert SiteCreator.is_valid_site_name("a\\b") is False

    def test_create_rejects_bad_name(self, tmp_path: Path):
        result = SiteCreator.create("bad/name", str(tmp_path), runner=FakeRunner())

        assert result.ok is False
        assert result.error == "invalidName"

    def test_create_rejects_missing_parent(self, tmp_path: Path):
        result = SiteCreator.create(
            "blog", str(tmp_path / "nope"), runner=FakeRunner()
        )

        assert result.ok is False
        assert result.error == "parentMissing"

    def test_create_rejects_existing_target(self, tmp_path: Path):
        (tmp_path / "blog").mkdir()

        result = SiteCreator.create("blog", str(tmp_path), runner=FakeRunner())

        assert result.ok is False
        assert result.error == "alreadyExists"

    def test_create_without_hexo_fails(self, tmp_path: Path):
        """用户压根没装 node/npm 时直接失败，不白等一次 npm 报错。"""
        result = SiteCreator.create("blog", str(tmp_path), runner=FakeRunner())

        assert result.ok is False
        assert result.error == "hexoUnavailable"


class TestThemeInstaller:
    def test_write_theme_replaces_existing_line(self, tmp_path: Path):
        config = tmp_path / "_config.yml"
        config.write_text("title: x\ntheme: old\n", encoding="utf-8")

        ThemeInstaller.write_theme(Site(path=str(tmp_path)), "new")

        assert config.read_text(encoding="utf-8") == "title: x\ntheme: new\n"

    def test_write_theme_appends_when_missing(self, tmp_path: Path):
        """没有 theme 键时追加一行。

        与 Swift 的 ``writeTheme`` 行为一致：Swift 侧也是 ``components(separatedBy: "\\n")``
        之后直接 ``append``，所以原文以换行结尾时中间会多出一个空行。
        """
        config = tmp_path / "_config.yml"
        config.write_text("title: x\n", encoding="utf-8")

        ThemeInstaller.write_theme(Site(path=str(tmp_path)), "new")

        assert config.read_text(encoding="utf-8") == "title: x\n\ntheme: new"

    def test_write_theme_creates_file_when_missing(self, tmp_path: Path):
        ThemeInstaller.write_theme(Site(path=str(tmp_path)), "new")

        assert (tmp_path / "_config.yml").read_text(encoding="utf-8").strip() == (
            "theme: new"
        )

    def test_migration_is_none_for_same_theme(self, tmp_path: Path):
        (tmp_path / "_config.yml").write_text("theme: yun\n", encoding="utf-8")

        plan = ThemeInstaller.compute_migration(Site(path=str(tmp_path)), "yun")

        assert plan is None

    def test_migration_is_none_without_old_theme_config(self, tmp_path: Path):
        (tmp_path / "_config.yml").write_text("theme: yun\n", encoding="utf-8")

        plan = ThemeInstaller.compute_migration(Site(path=str(tmp_path)), "next")

        assert plan is None

    def test_migration_lists_shared_keys(self, tmp_path: Path):
        """老主题配过的公共项，新主题 sample 里也有 → 列进迁移清单。"""
        (tmp_path / "_config.yml").write_text("theme: yun\n", encoding="utf-8")
        (tmp_path / "_config.yun.yml").write_text(
            "title: 我的博客\nsubtitle: 副标题\n", encoding="utf-8"
        )

        sample = tmp_path / "node_modules" / "hexo-theme-next"
        sample.mkdir(parents=True)
        (sample / "_config.yml").write_text(
            "title: Default\nsubtitle: Default subtitle\n", encoding="utf-8"
        )

        plan = ThemeInstaller.compute_migration(Site(path=str(tmp_path)), "next")

        assert plan is not None
        assert plan.from_theme == "yun"
        assert plan.to_theme == "next"
        assert plan.has_items is True

        keys = {entry.key for entry in plan.entries}
        assert "title" in keys
        assert "subtitle" in keys

        title = next(entry for entry in plan.entries if entry.key == "title")
        assert title.current_value == "我的博客"

    def test_migration_dict_shape(self, tmp_path: Path):
        (tmp_path / "_config.yml").write_text("theme: yun\n", encoding="utf-8")
        (tmp_path / "_config.yun.yml").write_text("title: 我的博客\n", encoding="utf-8")

        sample = tmp_path / "node_modules" / "hexo-theme-next"
        sample.mkdir(parents=True)
        (sample / "_config.yml").write_text("title: Default\n", encoding="utf-8")

        plan = ThemeInstaller.compute_migration(Site(path=str(tmp_path)), "next")
        data = plan.to_dict() if plan else {}

        assert data["fromTheme"] == "yun"
        assert data["toTheme"] == "next"
        assert data["hasItems"] is True
        assert isinstance(data["entries"], list)
        assert "key" in data["entries"][0]
        assert "currentValue" in data["entries"][0]
