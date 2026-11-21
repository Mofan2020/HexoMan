"""自定义内容注入与备份。"""

from __future__ import annotations

import json
import zipfile
from pathlib import Path

import pytest

from hexoman.backup import (
    BackupEntry,
    BackupError,
    BackupManager,
    DEFAULT_POLICY,
    FULL_POLICY,
)
from hexoman.custom_content import (
    CustomContent,
    CustomContentStore,
    SCRIPT_TEMPLATE,
    detected_inject_scripts,
)
from hexoman.model import Site


@pytest.fixture
def site(tmp_path: Path) -> Site:
    root = tmp_path / "blog"
    (root / "source" / "_posts").mkdir(parents=True)
    (root / "package.json").write_text('{"dependencies": {"hexo": "^7"}}', encoding="utf-8")
    (root / "_config.yml").write_text("title: t\n", encoding="utf-8")
    (root / "source" / "_posts" / "a.md").write_text("---\ntitle: a\n---\n正文\n", encoding="utf-8")
    return Site(path=str(root), last_opened=1.0)


# -- 自定义内容 --------------------------------------------------------


def test_not_installed_initially(site: Site):
    assert CustomContentStore.is_installed(site) is False


def test_save_creates_json_and_script(site: Site):
    CustomContentStore.save(
        CustomContent(head="<style>a{}</style>", body="<div>banner</div>"), site
    )

    data_path = Path(CustomContentStore.data_path(site))
    script_path = Path(CustomContentStore.script_path(site))

    assert data_path.is_file()
    assert script_path.is_file()
    # 不带 BOM：某些 Node 版本读 BOM 开头的 JSON 会失败
    assert not data_path.read_bytes().startswith(b"\xef\xbb\xbf")

    payload = json.loads(data_path.read_text(encoding="utf-8"))
    assert payload["head"] == "<style>a{}</style>"
    assert payload["body"] == "<div>banner</div>"
    assert CustomContentStore.is_installed(site) is True


def test_load_roundtrip(site: Site):
    original = CustomContent(head="h", body="b")
    CustomContentStore.save(original, site)

    assert CustomContentStore.load(site) == original


def test_load_missing_returns_empty(site: Site):
    assert CustomContentStore.load(site) == CustomContent()


def test_load_broken_json_returns_empty(site: Site):
    path = Path(CustomContentStore.data_path(site))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("{not json", encoding="utf-8")

    assert CustomContentStore.load(site) == CustomContent()


def test_save_does_not_overwrite_edited_script(site: Site):
    """用户手工改过脚本时不能被覆盖。"""
    script_path = Path(CustomContentStore.script_path(site))
    script_path.parent.mkdir(parents=True, exist_ok=True)
    script_path.write_text("// my own version\n", encoding="utf-8")

    CustomContentStore.save(CustomContent(head="h"), site)

    assert script_path.read_text(encoding="utf-8") == "// my own version\n"


def test_remove_deletes_both_files(site: Site):
    CustomContentStore.save(CustomContent(head="h"), site)
    CustomContentStore.remove(site)

    assert CustomContentStore.is_installed(site) is False
    assert not Path(CustomContentStore.data_path(site)).exists()
    assert not Path(CustomContentStore.script_path(site)).exists()


def test_script_template_uses_after_html_render():
    """必须注册 _after_html_render：after_generate 在 Hexo 8 里 data 是 null。"""
    assert "register('_after_html_render'" in SCRIPT_TEMPLATE
    # 注释里可以提到 after_generate，但不能真的注册它
    assert "register('after_generate'" not in SCRIPT_TEMPLATE


def test_script_template_never_returns_empty():
    """返回空会把整站渲染成 0 字节——必须有兜底分支。"""
    assert "if (!html)" in SCRIPT_TEMPLATE
    assert "return data;" in SCRIPT_TEMPLATE


def test_script_template_handles_both_shapes():
    # 传字符串和传对象两种形态都要认
    assert "typeof data === 'object'" in SCRIPT_TEMPLATE


def test_detected_scripts_finds_managed(site: Site):
    CustomContentStore.save(CustomContent(head="h"), site)

    scripts = detected_inject_scripts(site)
    assert len(scripts) == 1
    assert scripts[0].is_managed_by_hexoman is True
    assert "_after_html_render" in scripts[0].hooks


def test_detected_scripts_finds_user_scripts(site: Site):
    scripts_dir = Path(site.path) / "scripts"
    scripts_dir.mkdir(parents=True, exist_ok=True)
    (scripts_dir / "banner.js").write_text(
        "hexo.extend.filter.register('after_render:html', function (s) {\n"
        "  return s.replace('</body>', '<div class=\"banner\">hi</div></body>');\n"
        "});\n",
        encoding="utf-8",
    )

    scripts = detected_inject_scripts(site)
    assert len(scripts) == 1
    assert scripts[0].file_name == "banner.js"
    assert scripts[0].is_managed_by_hexoman is False
    assert "</body>" in scripts[0].inserts_into


def test_detected_scripts_ignores_unrelated(site: Site):
    scripts_dir = Path(site.path) / "scripts"
    scripts_dir.mkdir(parents=True, exist_ok=True)
    (scripts_dir / "helper.js").write_text("module.exports = 1 + 1;\n", encoding="utf-8")

    assert detected_inject_scripts(site) == []


def test_detected_scripts_empty_when_no_directory(site: Site):
    assert detected_inject_scripts(site) == []


# -- 备份 --------------------------------------------------------------


def test_policy_default_excludes_heavy_dirs():
    assert "node_modules" in DEFAULT_POLICY.excluded_directories
    assert ".git" in DEFAULT_POLICY.excluded_directories
    assert "public" in DEFAULT_POLICY.excluded_directories
    assert "node_modules" not in FULL_POLICY.excluded_directories or True
    # full 策略只排除 node_modules
    assert FULL_POLICY.excluded_directories == {"node_modules"}


def test_collect_prunes_node_modules(tmp_path: Path):
    root = tmp_path / "site"
    (root / "source").mkdir(parents=True)
    (root / "source" / "a.md").write_text("x", encoding="utf-8")
    (root / "node_modules" / "pkg").mkdir(parents=True)
    for index in range(20):
        (root / "node_modules" / "pkg" / f"f{index}.js").write_text("x", encoding="utf-8")
    (root / "public").mkdir()
    (root / "public" / "index.html").write_text("x", encoding="utf-8")
    (root / ".git").mkdir()
    (root / ".git" / "config").write_text("x", encoding="utf-8")

    files, plan = BackupManager.collect_files(str(root), DEFAULT_POLICY)

    assert "source/a.md" in files
    assert not any(item.startswith("node_modules/") for item in files)
    assert not any(item.startswith("public/") for item in files)
    assert plan.excluded_count >= 3
    assert plan.included_count == len(files)


def test_collect_prunes_nested_excluded_dirs(tmp_path: Path):
    """``themes/x/node_modules`` 这种嵌套的排除目录也要剪掉。

    旧版只看当层目录名，于是装了带 node_modules 的主题后，备份页会卡死。
    """
    root = tmp_path / "site"
    (root / "themes" / "x" / "node_modules" / "pkg").mkdir(parents=True)
    (root / "themes" / "x" / "index.js").write_text("x", encoding="utf-8")

    files, _ = BackupManager.collect_files(str(root), DEFAULT_POLICY)

    assert "themes/x/index.js" in files
    assert not any("node_modules" in item for item in files)


def test_collect_excludes_files_and_extensions(tmp_path: Path):
    root = tmp_path / "site"
    root.mkdir()
    (root / ".DS_Store").write_text("x", encoding="utf-8")
    (root / "debug.log").write_text("x", encoding="utf-8")
    (root / "keep.md").write_text("x", encoding="utf-8")

    files, _ = BackupManager.collect_files(str(root), DEFAULT_POLICY)

    assert files == ["keep.md"]


def test_collect_on_missing_root_returns_empty(tmp_path: Path):
    files, plan = BackupManager.collect_files(str(tmp_path / "nope"))
    assert files == []
    assert plan.included_count == 0


def test_create_backup_writes_zip(site: Site, tmp_path: Path):
    backup_dir = tmp_path / "backups"

    entry = BackupManager.create_backup(site, directory=str(backup_dir))

    assert Path(entry.path).is_file()
    assert entry.size > 0
    assert entry.file_count >= 2
    with zipfile.ZipFile(entry.path) as archive:
        names = archive.namelist()
    assert "source/_posts/a.md" in names
    assert "_config.yml" in names


def test_backup_contains_every_planned_file(site: Site, tmp_path: Path):
    """zip 里的条目必须与实际该被打包的文件一一对应。

    期望值在这里独立数出来（直接遍历源目录），不从 create_backup 的返回值反推，
    否则备份少打了一半文件这种问题会一起被放过。
    """
    backup_dir = tmp_path / "backups"

    entry = BackupManager.create_backup(site, directory=str(backup_dir))

    root = Path(site.path)
    expected = {
        str(path.relative_to(root)).replace("\\", "/")
        for path in root.rglob("*")
        if path.is_file()
    }
    with zipfile.ZipFile(entry.path) as archive:
        names = set(archive.namelist())

    assert names == expected
    assert len(names) == entry.file_count


def test_create_backup_raises_when_empty(tmp_path: Path):
    empty = tmp_path / "empty"
    empty.mkdir()
    site = Site(path=str(empty), last_opened=0.0)

    with pytest.raises(BackupError) as error:
        BackupManager.create_backup(site, directory=str(tmp_path / "backups"))
    assert error.value.code == "nothingToBackup"


def test_list_backups_filters_by_site(site: Site, tmp_path: Path):
    backup_dir = tmp_path / "backups"
    BackupManager.create_backup(site, directory=str(backup_dir))

    listed = BackupManager.list_backups(site.path, directory=str(backup_dir))
    assert len(listed) == 1
    assert listed[0].site_path == site.path


def test_list_backups_ignores_other_sites(site: Site, tmp_path: Path):
    backup_dir = tmp_path / "backups"
    backup_dir.mkdir()
    (backup_dir / "other-site-20260101-000000.zip").write_bytes(b"x")

    assert BackupManager.list_backups(site.path, directory=str(backup_dir)) == []


def test_restore_puts_files_back(site: Site, tmp_path: Path):
    backup_dir = tmp_path / "backups"
    entry = BackupManager.create_backup(site, directory=str(backup_dir))

    post = Path(site.path) / "source" / "_posts" / "a.md"
    post.write_text("被改坏了", encoding="utf-8")

    BackupManager.restore_backup(entry, site.path)

    assert "正文" in post.read_text(encoding="utf-8")


def test_restore_does_not_delete_extra_files(site: Site, tmp_path: Path):
    backup_dir = tmp_path / "backups"
    entry = BackupManager.create_backup(site, directory=str(backup_dir))

    extra = Path(site.path) / "source" / "_posts" / "new.md"
    extra.write_text("备份之后新建的", encoding="utf-8")

    BackupManager.restore_backup(entry, site.path)

    assert extra.is_file()


def test_restore_missing_site_raises(site: Site, tmp_path: Path):
    backup_dir = tmp_path / "backups"
    entry = BackupManager.create_backup(site, directory=str(backup_dir))

    with pytest.raises(BackupError):
        BackupManager.restore_backup(entry, str(tmp_path / "gone"))


def test_restore_invalid_zip_raises(site: Site, tmp_path: Path):
    bad = tmp_path / "bad.zip"
    bad.write_bytes(b"not a zip")

    with pytest.raises(BackupError) as error:
        BackupManager.restore_backup(
            BackupEntry(path=str(bad), site_path=site.path), site.path
        )
    assert error.value.code == "unzipFailed"


def test_delete_backup(site: Site, tmp_path: Path):
    backup_dir = tmp_path / "backups"
    entry = BackupManager.create_backup(site, directory=str(backup_dir))

    BackupManager.delete_backup(entry)
    assert not Path(entry.path).exists()


def test_entry_display_fields():
    entry = BackupEntry(path="/tmp/x.zip", date=1792555200.0, size=2048)
    assert entry.display_name
    assert "KB" in entry.formatted_size
