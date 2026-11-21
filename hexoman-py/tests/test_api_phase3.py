"""第三阶段的 JS API：常用配置 / 新建站点 / 主题安装迁移 / Git 单文件。

所有测试都在 ``tmp_path`` 里造站点，**绝不碰用户真实目录**。
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from hexoman.api import HexoManAPI
from hexoman.process import CommandRunner, NullCommandRunner, ProcessResult
from hexoman.settings import SettingsStore


@pytest.fixture
def site_root(tmp_path: Path) -> Path:
    root = tmp_path / "blog"
    (root / "source" / "_posts").mkdir(parents=True)
    (root / "node_modules" / "hexo-theme-yun").mkdir(parents=True)

    (root / "package.json").write_text(
        json.dumps({"name": "blog", "dependencies": {"hexo": "^7.0.0"}}), encoding="utf-8"
    )
    (root / "_config.yml").write_text(
        "# 站点配置\ntitle: 我的博客\ntheme: yun\nurl: https://example.com\n", encoding="utf-8"
    )
    (root / "_config.yun.yml").write_text(
        "# 主题配置\ntitle: 旧标题\nsubtitle: 旧副标题\n", encoding="utf-8"
    )
    (root / "node_modules" / "hexo-theme-yun" / "package.json").write_text(
        json.dumps({"name": "hexo-theme-yun", "version": "1.0.0"}), encoding="utf-8"
    )

    return root


@pytest.fixture
def api(tmp_path: Path, site_root: Path) -> HexoManAPI:
    store = SettingsStore(path=str(tmp_path / "settings.json"))
    instance = HexoManAPI(settings_store=store, runner=NullCommandRunner())
    instance.addSite(str(site_root))
    instance.selectSite(str(site_root))
    return instance


class TestSiteSettingsApi:
    def test_returns_grouped_fields(self, api: HexoManAPI):
        result = api.getSiteSettings()

        assert result["ok"] is True
        groups = result["groups"]
        assert len(groups) == 4

        keys = [field["key"] for group in groups for field in group["fields"]]
        assert "title" in keys
        assert "per_page" in keys
        assert "github" in keys

    def test_current_values_are_filled_in(self, api: HexoManAPI):
        result = api.getSiteSettings()

        title = next(
            field
            for group in result["groups"]
            for field in group["fields"]
            if field["key"] == "title"
        )
        assert title["value"] == "我的博客"

    def test_labels_follow_the_current_language(self, api: HexoManAPI):
        api.setLanguage("en")
        result = api.getSiteSettings()

        title = next(
            field
            for group in result["groups"]
            for field in group["fields"]
            if field["key"] == "title"
        )
        assert title["label"] == "Site title"

    def test_nested_block_is_flagged(self, api: HexoManAPI, site_root: Path):
        (site_root / "_config.yml").write_text(
            "title: x\nindex_generator:\n  per_page: 10\n", encoding="utf-8"
        )

        result = api.getSiteSettings()
        field = next(
            item
            for group in result["groups"]
            for item in group["fields"]
            if item["key"] == "index_generator"
        )

        assert field["isNestedBlock"] is True

    def test_update_writes_only_that_line(self, api: HexoManAPI, site_root: Path):
        result = api.updateSiteSetting("", "title", "新标题")

        assert result["ok"] is True

        text = (site_root / "_config.yml").read_text(encoding="utf-8")
        assert "title: 新标题" in text
        assert "theme: yun" in text
        # 注释和其余行原样保留
        assert "# 站点配置" in text

    def test_update_refuses_nested_block(self, api: HexoManAPI, site_root: Path):
        (site_root / "_config.yml").write_text(
            "title: x\nindex_generator:\n  per_page: 10\n", encoding="utf-8"
        )

        result = api.updateSiteSetting("", "index_generator", "20")

        assert result["ok"] is False
        assert result["error"] == "keyHasNestedBlock"
        # 文件不能被改坏
        assert "per_page: 10" in (site_root / "_config.yml").read_text(encoding="utf-8")

    def test_update_without_site_fails(self, tmp_path: Path):
        store = SettingsStore(path=str(tmp_path / "settings.json"))
        instance = HexoManAPI(settings_store=store, runner=NullCommandRunner())

        assert instance.updateSiteSetting("", "title", "x")["ok"] is False


class TestSiteTemplates:
    def test_templates_are_listed_with_bilingual_titles(self, api: HexoManAPI):
        result = api.listSiteTemplates()

        assert result["ok"] is True
        keys = [item["key"] for item in result["templates"]]
        assert "starter" in keys
        assert "standard" in keys

        assert result["templates"][0]["title"] != ""

    def test_titles_follow_language(self, api: HexoManAPI):
        api.setLanguage("en")
        result = api.listSiteTemplates()

        assert result["templates"][0]["title"] != ""


class TestCreateSite:
    def test_rejects_empty_name(self, api: HexoManAPI, tmp_path: Path):
        result = api.createSite("", str(tmp_path))
        assert result["ok"] is False
        assert result["error"] == "invalidName"

    def test_rejects_empty_parent(self, api: HexoManAPI):
        result = api.createSite("blog", "")
        assert result["ok"] is False
        assert result["error"] == "parentEmpty"

    def test_failure_is_reported_with_a_message(self, api: HexoManAPI, tmp_path: Path):
        result = api.createSite("blog", str(tmp_path / "nope"))

        assert result["ok"] is False
        assert result["message"]

    def test_success_adds_the_site_to_the_list(self, tmp_path: Path):
        store = SettingsStore(path=str(tmp_path / "settings.json"))
        instance = HexoManAPI(settings_store=store, runner=NullCommandRunner())

        parent = tmp_path / "sites"
        parent.mkdir()
        target = parent / "blog"
        target.mkdir()
        (target / "package.json").write_text(
            json.dumps({"name": "blog", "dependencies": {"hexo": "^7.0.0"}}), encoding="utf-8"
        )
        (target / "_config.yml").write_text("title: x\n", encoding="utf-8")

        instance.addSite(str(target))

        paths = [site["path"] for site in instance.getState()["sites"]]
        assert str(target) in paths


class TestInstallDependencies:
    def test_without_site_fails(self, tmp_path: Path):
        store = SettingsStore(path=str(tmp_path / "settings.json"))
        instance = HexoManAPI(settings_store=store, runner=NullCommandRunner())

        result = instance.installDependencies()

        assert result["ok"] is False
        assert result["error"] == "noSite"


class TestThemeApi:
    def test_migration_without_site_fails(self, tmp_path: Path):
        store = SettingsStore(path=str(tmp_path / "settings.json"))
        instance = HexoManAPI(settings_store=store, runner=NullCommandRunner())

        assert instance.getThemeMigration("next")["ok"] is False

    def test_migration_plan_is_computed(self, api: HexoManAPI, site_root: Path):
        sample = site_root / "node_modules" / "hexo-theme-next"
        sample.mkdir(parents=True)
        (sample / "_config.yml").write_text("title: Default\nsubtitle: Default\n", encoding="utf-8")

        result = api.getThemeMigration("next")

        assert result["ok"] is True
        migration = result["migration"]
        assert migration is not None
        assert migration["fromTheme"] == "yun"
        assert migration["toTheme"] == "next"
        assert migration["hasItems"] is True

    def test_migration_without_keys_fails(self, api: HexoManAPI):
        result = api.applyThemeMigration([])

        assert result["ok"] is False
        assert result["error"] == "noKeys"

    def test_apply_migration_moves_values_to_site_config(
        self, api: HexoManAPI, site_root: Path
    ):
        result = api.applyThemeMigration(["title"])

        assert result["ok"] is True
        assert result["applied"] == 1

        site_text = (site_root / "_config.yml").read_text(encoding="utf-8")
        assert "title: 旧标题" in site_text

    def test_apply_migration_rejects_unknown_key(self, api: HexoManAPI):
        result = api.applyThemeMigration(["not-a-shared-key"])

        assert result["ok"] is False
        assert result["error"] == "nothingApplied"

    def test_apply_theme_rejects_bad_name(self, api: HexoManAPI):
        result = api.applyTheme("bad name!")

        assert result["ok"] is False
        assert result["error"] == "invalidName"


class TestGitFileApi:
    def test_stage_without_site_fails(self, tmp_path: Path):
        store = SettingsStore(path=str(tmp_path / "settings.json"))
        instance = HexoManAPI(settings_store=store, runner=NullCommandRunner())

        assert instance.stageGitFile("a.md")["ok"] is False
        assert instance.unstageGitFile("a.md")["ok"] is False
        assert instance.diffGitFile("a.md")["ok"] is False

    def test_stage_with_empty_path_fails(self, api: HexoManAPI):
        assert api.stageGitFile("")["error"] == "pathEmpty"

    def test_stage_calls_git_add(self, tmp_path: Path, site_root: Path):
        calls: list[list[str]] = []

        class RecordingRunner(CommandRunner):
            def run(self, args, cwd=None, timeout=None, env=None):  # type: ignore[override]
                calls.append(list(args))
                return ProcessResult(exit_code=0, output="")

        store = SettingsStore(path=str(tmp_path / "settings.json"))
        instance = HexoManAPI(settings_store=store, runner=RecordingRunner())
        instance.addSite(str(site_root))
        instance.selectSite(str(site_root))

        result = instance.stageGitFile("source/_posts/a.md")

        assert result["ok"] is True
        assert any("add" in call for call in calls)

    def test_unstage_calls_git_restore(self, tmp_path: Path, site_root: Path):
        calls: list[list[str]] = []

        class RecordingRunner(CommandRunner):
            def run(self, args, cwd=None, timeout=None, env=None):  # type: ignore[override]
                calls.append(list(args))
                return ProcessResult(exit_code=0, output="")

        store = SettingsStore(path=str(tmp_path / "settings.json"))
        instance = HexoManAPI(settings_store=store, runner=RecordingRunner())
        instance.addSite(str(site_root))
        instance.selectSite(str(site_root))

        result = instance.unstageGitFile("source/_posts/a.md")

        assert result["ok"] is True
        assert any("restore" in call for call in calls)


class TestStoreImages:
    def test_without_site_fails(self, tmp_path: Path):
        store = SettingsStore(path=str(tmp_path / "settings.json"))
        instance = HexoManAPI(settings_store=store, runner=NullCommandRunner())

        result = instance.storeImages(["/tmp/x.png"])

        assert result["ok"] is False
        assert result["error"] == "noSite"

    def test_empty_list_is_ok(self, api: HexoManAPI):
        result = api.storeImages([])

        assert result["ok"] is True
        assert result["markdown"] == []
        assert result["failed"] == 0

    def test_image_is_stored_into_the_site(self, api: HexoManAPI, site_root: Path, tmp_path: Path):
        source = tmp_path / "pic.png"
        source.write_bytes(b"\x89PNG\r\n\x1a\n" + b"0" * 32)

        result = api.storeImages([str(source)], base="shot")

        assert result["ok"] is True
        assert result["failed"] == 0
        assert len(result["markdown"]) == 1
        assert result["markdown"][0].startswith("![")
        assert "/images/" in result["markdown"][0]

    def test_unreadable_file_is_counted_as_failed(self, api: HexoManAPI, tmp_path: Path):
        missing = tmp_path / "nope.png"

        result = api.storeImages([str(missing)])

        assert result["ok"] is True
        assert result["failed"] == 1
        assert result["markdown"] == []


class TestApplyThemeReportsMigration:
    """换主题之后必须还能拿到「旧主题配过的值」清单。

    ``compute_migration`` 靠站点配置里那个 ``theme`` 和目标的差异认定哪份是
    旧主题配置。所以它必须在写新 ``theme`` 之前算 —— 顺手交换这两步，接口
    不会报错，只是清单永远为空。
    """

    def test_migration_survives_switching_the_theme(
        self, tmp_path: Path, site_root: Path
    ):
        new_theme = site_root / "node_modules" / "hexo-theme-anzhiyu"
        new_theme.mkdir(parents=True)
        (new_theme / "_config.yml").write_text("title: 新标题\n", encoding="utf-8")

        class InstallingRunner(CommandRunner):
            def which(self, name: str):  # type: ignore[override]
                return "/usr/bin/npm" if name == "npm" else None

            def run(self, args, cwd=None, timeout=None, env=None):  # type: ignore[override]
                return ProcessResult(exit_code=0, output="")

        store = SettingsStore(path=str(tmp_path / "settings.json"))
        instance = HexoManAPI(settings_store=store, runner=InstallingRunner())
        instance.addSite(str(site_root))
        instance.selectSite(str(site_root))

        result = instance.applyTheme("anzhiyu")

        assert result["ok"] is True
        assert result["activeTheme"] == "anzhiyu"
        assert result["migration"] is not None
        assert result["migration"]["fromTheme"] == "yun"
        assert result["migration"]["toTheme"] == "anzhiyu"
        assert result["migration"]["hasItems"] is True
