"""第二阶段的 JS API：页面 / 配置 / 主题 / 备份 / 环境。

所有测试都在 ``tmp_path`` 里造站点，**绝不碰用户真实目录**。
备份目录也注入到临时目录，不写进用户的 Application Support。
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from hexoman.api import HexoManAPI
from hexoman.process import NullCommandRunner, ProcessResult
from hexoman.settings import SettingsStore


@pytest.fixture
def site_root(tmp_path: Path) -> Path:
    root = tmp_path / "blog"
    (root / "source" / "_posts").mkdir(parents=True)
    (root / "source" / "about").mkdir(parents=True)
    (root / "node_modules" / "hexo-theme-yun").mkdir(parents=True)
    (root / "node_modules" / "hexo-theme-landscape").mkdir(parents=True)

    (root / "package.json").write_text(
        json.dumps({"name": "blog", "dependencies": {"hexo": "^7.0.0"}}), encoding="utf-8"
    )
    (root / "_config.yml").write_text(
        "# 站点配置\ntitle: 我的博客\ntheme: yun\nurl: https://example.com\n", encoding="utf-8"
    )
    (root / "_config.yun.yml").write_text(
        "# 主题配置\ntitle: 旧标题\navatar:\n  url: /images/old.png\n", encoding="utf-8"
    )
    (root / "node_modules" / "hexo-theme-yun" / "package.json").write_text(
        json.dumps({"name": "hexo-theme-yun", "version": "1.0.0"}), encoding="utf-8"
    )
    (root / "node_modules" / "hexo-theme-landscape" / "package.json").write_text(
        json.dumps({"name": "hexo-theme-landscape", "version": "7.0.0"}), encoding="utf-8"
    )
    (root / "source" / "about" / "index.md").write_text(
        "---\ntitle: 关于我\nlayout: about\n---\n正文\n", encoding="utf-8"
    )
    (root / "source" / "_posts" / "hello.md").write_text(
        "---\ntitle: 你好\n---\n看看 [/about/](/about/)\n", encoding="utf-8"
    )

    return root


@pytest.fixture
def api(tmp_path: Path, site_root: Path) -> HexoManAPI:
    store = SettingsStore(path=str(tmp_path / "settings.json"))
    instance = HexoManAPI(
        settings_store=store,
        runner=NullCommandRunner(),
        backup_directory=str(tmp_path / "backups"),
    )
    assert instance.addSite(str(site_root))["ok"] is True
    return instance


# -- 设置 --------------------------------------------------------------


def test_get_settings(api: HexoManAPI):
    result = api.getSettings()
    assert result["ok"] is True
    assert result["settings"]["serverPort"] == 4000


def test_update_settings_ignores_unknown_keys(api: HexoManAPI):
    result = api.updateSettings({"previewDrafts": True, "totallyUnknown": "x"})
    assert result["ok"] is True
    assert result["settings"]["previewDrafts"] is True
    assert "totallyUnknown" not in result["settings"]


def test_update_settings_validates_port(api: HexoManAPI):
    api.updateSettings({"serverPort": 99999})
    assert api.getSettings()["settings"]["serverPort"] == 4000

    api.updateSettings({"serverPort": 5000})
    assert api.getSettings()["settings"]["serverPort"] == 5000


def test_prepare_environment_respects_setting(api: HexoManAPI):
    api.updateSettings({"usesShellEnvironment": False})
    result = api.prepareEnvironment()
    assert result["ok"] is True
    assert result["environment"] is None


# -- 页面 --------------------------------------------------------------


def test_list_pages(api: HexoManAPI):
    result = api.listPages()
    relatives = {page["relativePath"] for page in result["pages"]}

    assert "about/index.md" in relatives
    assert "_posts/hello.md" in relatives
    assert result["pageCount"] == 1
    assert result["postCount"] == 1


def test_get_page_returns_fields(api: HexoManAPI):
    pages = api.listPages()["pages"]
    target = next(page for page in pages if page["relativePath"] == "about/index.md")

    result = api.getPage(target["path"])

    assert result["ok"] is True
    assert result["body"].strip() == "正文"
    keys = [field["key"] for field in result["fields"]]
    assert "title" in keys
    assert "layout" in keys


def test_get_page_not_found(api: HexoManAPI):
    assert api.getPage("/nope.md")["ok"] is False


def test_create_page(api: HexoManAPI, site_root: Path):
    result = api.createPage("links", "友情链接", layout="page")

    assert result["ok"] is True
    assert result["page"]["relativePath"] == "links/index.md"
    assert (site_root / "source" / "links" / "index.md").is_file()


def test_create_page_duplicate(api: HexoManAPI):
    result = api.createPage("about", "重复")
    assert result["ok"] is False
    assert result["error"] == "alreadyExists"


def test_create_page_empty_title(api: HexoManAPI):
    assert api.createPage("x", "  ")["error"] == "titleEmpty"


def test_save_page_updates_fields_and_body(api: HexoManAPI):
    pages = api.listPages()["pages"]
    target = next(page for page in pages if page["relativePath"] == "about/index.md")

    result = api.savePage(
        target["path"],
        body="新正文\n",
        fields=[
            {"key": "title", "value": "新的关于", "kind": "text"},
            {"key": "draft", "value": "true", "kind": "boolean"},
            {"key": "order", "value": "7", "kind": "integer"},
        ],
    )

    assert result["ok"] is True
    reloaded = api.getPage(target["path"])
    fields = {field["key"]: field for field in reloaded["fields"]}
    assert fields["title"]["value"] == "新的关于"
    assert fields["draft"]["value"] == "true"
    assert fields["order"]["value"] == "7"
    assert reloaded["body"].strip() == "新正文"
    # 没传的字段保持原样
    assert fields["layout"]["value"] == "about"


def test_delete_page(api: HexoManAPI, site_root: Path):
    pages = api.listPages()["pages"]
    target = next(page for page in pages if page["relativePath"] == "about/index.md")

    assert api.deletePage(target["path"])["ok"] is True
    assert not (site_root / "source" / "about" / "index.md").exists()


def test_page_assets(api: HexoManAPI):
    pages = api.listPages()["pages"]
    target = next(page for page in pages if page["relativePath"] == "about/index.md")

    result = api.getPageAssets(target["path"])
    assert result["ok"] is True
    assert isinstance(result["assets"], list)


def test_page_references(api: HexoManAPI):
    pages = api.listPages()["pages"]
    target = next(page for page in pages if page["relativePath"] == "about/index.md")

    result = api.getPageReferences(target["path"])
    assert result["ok"] is True
    assert any(item["postTitle"] == "你好" for item in result["references"])


# -- 配置 --------------------------------------------------------------


def test_list_config_files(api: HexoManAPI):
    result = api.listConfigFiles()
    names = [item["name"] for item in result["files"]]

    assert names[0] == "_config.yml"
    assert "_config.yun.yml" in names


def test_get_config_schema(api: HexoManAPI):
    path = api.listConfigFiles()["files"][0]["path"]
    result = api.getConfigSchema(path)

    assert result["ok"] is True
    fields = {field["id"]: field for field in result["fields"]}
    assert fields["title"]["label"] == "站点标题"
    assert fields["theme"]["value"] == "yun"


def test_update_config_value_preserves_comments(api: HexoManAPI, site_root: Path):
    path = api.listConfigFiles()["files"][0]["path"]

    assert api.updateConfigValue(path, "title", "新站点名")["ok"] is True

    text = (site_root / "_config.yml").read_text(encoding="utf-8")
    assert "title: 新站点名" in text
    assert "# 站点配置" in text


def test_update_config_value_rejects_unwritable(api: HexoManAPI):
    path = api.listConfigFiles()["files"][0]["path"]
    assert api.updateConfigValue(path, "no.such.path", "x")["error"] == "pathNotWritable"


def test_save_config_file_verifies(api: HexoManAPI, site_root: Path):
    path = str(site_root / "_config.yml")
    result = api.saveConfigFile(path, "title: 手改\n")

    assert result["ok"] is True
    assert (site_root / "_config.yml").read_text(encoding="utf-8") == "title: 手改\n"


def test_config_sync_shows_differences(api: HexoManAPI):
    result = api.getConfigSync()
    keys = {item["key"] for item in result["differences"]}

    assert result["themeConfigPath"].endswith("_config.yun.yml")
    assert "title" in keys


def test_apply_config_sync(api: HexoManAPI, site_root: Path):
    result = api.applyConfigSync()
    assert result["ok"] is True
    assert "站点标题" in result["changed"]

    text = (site_root / "_config.yun.yml").read_text(encoding="utf-8")
    assert "title: 我的博客" in text
    assert "# 主题配置" in text


def test_apply_theme_only_to_site(api: HexoManAPI, site_root: Path):
    result = api.applyThemeOnlyToSite("avatar.url", "/images/from-theme.png")
    assert result["ok"] is True

    text = (site_root / "_config.yml").read_text(encoding="utf-8")
    assert "/images/from-theme.png" in text


# -- 主题 --------------------------------------------------------------


def test_list_themes(api: HexoManAPI):
    result = api.listThemes()
    names = [item["name"] for item in result["themes"]]

    assert result["activeTheme"] == "yun"
    assert set(names) >= {"yun", "landscape"}
    assert result["themes"][0]["name"] == "yun"


def test_switch_theme(api: HexoManAPI, site_root: Path):
    result = api.switchTheme("hexo-theme-landscape")

    assert result["ok"] is True
    assert "theme: landscape" in (site_root / "_config.yml").read_text(encoding="utf-8")


def test_switch_theme_refuses_uninstalled(api: HexoManAPI):
    result = api.switchTheme("hexo-theme-not-installed")
    assert result["ok"] is False
    assert result["error"] == "themeNotInstalled"


def test_create_theme_config(api: HexoManAPI, site_root: Path):
    result = api.createThemeConfig("landscape")

    assert result["ok"] is True
    assert (site_root / "_config.landscape.yml").is_file()


def test_search_themes_offline(api: HexoManAPI):
    result = api.searchThemes("yun")

    assert result["ok"] is True
    assert result["online"] is False
    assert any(item["name"] == "hexo-theme-yun" for item in result["results"])


# -- 备份 --------------------------------------------------------------


def test_backup_plan(api: HexoManAPI):
    result = api.getBackupPlan()
    assert result["ok"] is True
    assert result["plan"]["includedCount"] >= 3


def test_create_list_restore_delete_backup(api: HexoManAPI, site_root: Path):
    created = api.createBackup()
    assert created["ok"] is True
    path = created["backup"]["path"]

    listed = api.listBackups()
    assert any(item["path"] == path for item in listed["backups"])

    (site_root / "source" / "about" / "index.md").write_text("改坏了", encoding="utf-8")
    assert api.restoreBackup(path)["ok"] is True
    assert "正文" in (site_root / "source" / "about" / "index.md").read_text(encoding="utf-8")

    assert api.deleteBackup(path)["ok"] is True
    assert not Path(path).exists()


# -- 自定义内容 --------------------------------------------------------


def test_custom_content_roundtrip(api: HexoManAPI, site_root: Path):
    assert api.getCustomContent()["installed"] is False

    saved = api.saveCustomContent(head="<style>a{}</style>", body="<div>x</div>")
    assert saved["ok"] is True

    loaded = api.getCustomContent()
    assert loaded["installed"] is True
    assert loaded["content"]["head"] == "<style>a{}</style>"
    assert len(loaded["scripts"]) == 1

    assert api.removeCustomContent()["ok"] is True
    assert api.getCustomContent()["installed"] is False


def test_list_and_instantiate_snippets(api: HexoManAPI):
    snippets = api.listSnippets()["snippets"]
    assert snippets

    result = api.instantiateSnippet("google-analytics", {"ga": "G-TEST"})
    assert result["ok"] is True
    assert "G-TEST" in result["code"]


def test_instantiate_unknown_snippet(api: HexoManAPI):
    assert api.instantiateSnippet("nope", {})["ok"] is False


# -- 环境 --------------------------------------------------------------


def test_inspect_environment(api: HexoManAPI):
    api.updateSettings({"usesShellEnvironment": False})
    result = api.inspectEnvironment()

    assert result["ok"] is True
    assert "node" in result["toolchain"]
    assert isinstance(result["toolchain"]["warnings"], list)


def test_environment_docs(api: HexoManAPI):
    result = api.getEnvironmentDocs()
    ids = [section["id"] for section in result["sections"]]

    assert "node" in ids
    assert "troubleshoot" in ids


# -- Git ---------------------------------------------------------------


def test_commit_requires_message(api: HexoManAPI):
    assert api.commitGit("   ")["error"] == "messageEmpty"


def test_push_and_pull_return_runner_result(api: HexoManAPI):
    runner = NullCommandRunner(ProcessResult(exit_code=0, output="ok"))
    api._runner = runner

    assert api.pushGit()["ok"] is True
    assert api.pullGit()["ok"] is True


# -- 状态 --------------------------------------------------------------


def test_state_exposes_pages_capability(api: HexoManAPI):
    """getState 要带上新页面需要的开关，前端不用再单独问一遍。"""
    state = api.getState()
    assert state["ok"] is True
    assert "onlineThemeSearch" in state["settings"]


def test_shutdown_clears_server(api: HexoManAPI):
    assert api.shutdown()["ok"] is True
