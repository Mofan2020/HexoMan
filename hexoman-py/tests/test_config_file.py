"""配置文件读写（ConfigFile / ConfigStore）。"""

from __future__ import annotations

from pathlib import Path

import pytest

from hexoman.config_file import ConfigFile, ConfigStore, ConfigStoreError
from hexoman.model import Site


@pytest.fixture
def site(tmp_path: Path) -> Site:
    root = tmp_path / "blog"
    root.mkdir()
    (root / "_config.yml").write_text("title: 我的博客\ntheme: yun\n", encoding="utf-8")
    (root / "_config.yun.yml").write_text("avatar:\n  rounded: true\n", encoding="utf-8")
    (root / "_config.next.yml").write_text("scheme: Muse\n", encoding="utf-8")
    (root / "notes.txt").write_text("x", encoding="utf-8")
    (root / "package.json").write_text("{}", encoding="utf-8")
    return Site(path=str(root), last_opened=1.0)


def test_list_puts_main_config_first(site: Site):
    files = ConfigStore.list(site)
    names = [item.name for item in files]

    assert names[0] == "_config.yml"
    assert set(names) == {"_config.yml", "_config.next.yml", "_config.yun.yml"}


def test_list_ignores_non_config_files(site: Site):
    names = {item.name for item in ConfigStore.list(site)}
    assert "notes.txt" not in names
    assert "package.json" not in names


def test_subtitles(site: Site):
    files = {item.name: item for item in ConfigStore.list(site)}
    assert files["_config.yml"].subtitle == "站点主配置"
    assert "yun" in files["_config.yun.yml"].subtitle


def test_is_modified_tracks_contents(site: Site):
    files = ConfigStore.list(site)
    config = files[0]

    assert config.is_modified is False
    config.contents += "\nauthor: me\n"
    assert config.is_modified is True


def test_top_level_keys(site: Site):
    config = ConfigStore.load(str(Path(site.path) / "_config.yml"))
    assert config.top_level_keys == ["theme", "title"]


def test_load_missing_file_returns_empty(tmp_path: Path):
    config = ConfigStore.load(str(tmp_path / "nope.yml"))
    assert config.contents == ""
    assert config.is_modified is False


def test_save_writes_and_verifies(site: Site):
    path = str(Path(site.path) / "_config.yml")
    config = ConfigStore.load(path)
    config.contents = "title: 改过了\ntheme: landscape\n"

    ConfigStore.save(config)

    assert Path(path).read_text(encoding="utf-8") == config.contents


def test_mark_saved_clears_modified_flag(site: Site):
    path = str(Path(site.path) / "_config.yml")
    config = ConfigStore.load(path)
    config.contents += "\nfoo: bar\n"

    saved = ConfigStore.mark_saved(config)

    assert saved.is_modified is False
    assert saved.contents == config.contents


def test_save_creates_missing_directories(tmp_path: Path):
    target = tmp_path / "deep" / "dir" / "_config.yml"
    config = ConfigFile(path=str(target), name="_config.yml", contents="a: 1\n")

    ConfigStore.save(config)

    assert target.is_file()


def test_save_verification_failure_raises(tmp_path: Path, monkeypatch):
    """写入后内容对不上时必须报错。

    这是「界面显示已保存、磁盘上是旧内容」这类最难排查的问题的防线。
    """
    target = tmp_path / "c.yml"
    target.write_text("old", encoding="utf-8")
    config = ConfigFile(path=str(target), name="c.yml", contents="new")

    # 模拟「写完但读回来不一致」
    import hexoman.config_file as module

    monkeypatch.setattr(module, "read_text", lambda path: "something else")

    with pytest.raises(ConfigStoreError) as error:
        ConfigStore.save(config)
    assert error.value.code == "writeVerificationFailed"
