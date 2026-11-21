"""测试共享的夹具。

**测试绝不碰用户的真实站点目录**——所有站点都在 ``tmp_path`` 里造。
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from hexoman.model import Site  # noqa: E402


@pytest.fixture
def fake_site(tmp_path: Path) -> Site:
    """造一个假的 Hexo 站点。

    结构与真实站点一致：``package.json``（声明 hexo 依赖）、
    ``_config.yml``、``source/_posts/``。
    """
    root = tmp_path / "my-blog"
    (root / "source" / "_posts").mkdir(parents=True)

    (root / "package.json").write_text(
        json.dumps(
            {
                "name": "my-blog",
                "dependencies": {"hexo": "^7.0.0", "hexo-theme-yun": "^1.0.0"},
            },
            indent=2,
        ),
        encoding="utf-8",
    )

    (root / "_config.yml").write_text(
        "title: 我的博客\n"
        "url: https://example.com\n"
        "theme: yun\n"
        "author: tester\n",
        encoding="utf-8",
    )

    return Site(path=str(root), last_opened=1000.0)


@pytest.fixture
def make_post(tmp_path: Path):
    """往站点里写一篇文章的工厂函数。"""

    def _make(
        site: Site,
        filename: str,
        front: str = "",
        body: str = "正文内容",
    ) -> Path:
        directory = Path(site.path) / "source" / "_posts"
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / filename
        content = ""
        if front:
            content += "---\n" + front.strip("\n") + "\n---\n"
        content += body
        path.write_text(content, encoding="utf-8")
        return path

    return _make


@pytest.fixture
def api(tmp_path: Path):
    """一个 API 实例，设置文件落在 tmp_path 里。"""
    from hexoman.api import HexoManAPI
    from hexoman.process import NullCommandRunner
    from hexoman.settings import SettingsStore

    store = SettingsStore(path=str(tmp_path / "settings.json"))
    return HexoManAPI(settings_store=store, runner=NullCommandRunner())
