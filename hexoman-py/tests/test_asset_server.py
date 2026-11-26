"""预览用的本地静态资源服务。

重点是安全规则：token 不对、目录不在白名单、路径越界，一律 404。
路径解析拆成了纯函数（``resolve_asset_path``），这几条不用起网络就能测。
"""

from __future__ import annotations

import socket
import urllib.error
import urllib.request
from pathlib import Path

import pytest

from hexoman import asset_server
from hexoman.asset_server import AssetServer, resolve_asset_path


@pytest.fixture()
def site_root(tmp_path: Path) -> Path:
    """一个假的站点目录。"""
    (tmp_path / "source" / "images").mkdir(parents=True)
    (tmp_path / "source" / "images" / "a.png").write_bytes(b"\x89PNG\r\n\x1a\nfake")
    (tmp_path / "public").mkdir()
    (tmp_path / "public" / "index.html").write_text("<html></html>", encoding="utf-8")
    (tmp_path / "secret.txt").write_text("不该被读到", encoding="utf-8")
    (tmp_path / "themes").mkdir()
    (tmp_path / "themes" / "config.yml").write_text("theme: yun", encoding="utf-8")
    return tmp_path


class TestPathResolution:
    def test_source_file_is_found(self, site_root: Path):
        target = resolve_asset_path(
            site_root, "tok", "/tok/source/images/a.png"
        )

        assert target is not None
        assert target.name == "a.png"

    def test_public_file_is_found(self, site_root: Path):
        target = resolve_asset_path(site_root, "tok", "/tok/public/index.html")

        assert target is not None

    def test_wrong_token_is_rejected(self, site_root: Path):
        assert resolve_asset_path(site_root, "tok", "/other/source/images/a.png") is None

    def test_directory_outside_whitelist_is_rejected(self, site_root: Path):
        """``themes`` 与站点根目录下的文件都不该被服务。"""
        assert resolve_asset_path(site_root, "tok", "/tok/themes/config.yml") is None
        assert resolve_asset_path(site_root, "tok", "/tok/secret.txt") is None

    def test_path_traversal_is_rejected(self, site_root: Path):
        """``..`` 不能爬到站点外面去。"""
        assert resolve_asset_path(site_root, "tok", "/tok/source/../secret.txt") is None
        assert (
            resolve_asset_path(site_root, "tok", "/tok/source/../../etc/passwd") is None
        )

    def test_encoded_traversal_is_rejected(self, site_root: Path):
        """百分号编码的 ``..`` 也要挡住——请求路径是会被解码的。"""
        assert (
            resolve_asset_path(site_root, "tok", "/tok/source/%2e%2e/secret.txt")
            is None
        )

    def test_missing_file_is_rejected(self, site_root: Path):
        assert resolve_asset_path(site_root, "tok", "/tok/source/nope.png") is None

    def test_no_root_is_rejected(self):
        assert resolve_asset_path(None, "tok", "/tok/source/a.png") is None


class TestServer:
    def test_url_contains_the_token(self, site_root: Path):
        server = AssetServer()
        server.set_root(site_root)
        server.start()
        try:
            url = server.url_for("source/images/a.png")
        finally:
            server.stop()

        assert server.token in url
        assert url.endswith("/source/images/a.png")

    def test_url_is_empty_before_start(self, site_root: Path):
        """没起服务就没有端口，URL 给不出东西——这是对的，不要瞎编一个。"""
        server = AssetServer()
        server.set_root(site_root)

        assert server.url_for("source/images/a.png") == ""

    def test_server_serves_the_file_over_loopback(self, site_root: Path):
        """真起一个服务，取一次文件。"""
        server = AssetServer()
        server.set_root(site_root)
        server.start()
        try:
            url = server.url_for("source/images/a.png")
            request = urllib.request.Request(url)
            with urllib.request.urlopen(request, timeout=5) as response:
                body = response.read()
                content_type = response.headers.get("Content-Type", "")
        finally:
            server.stop()

        assert body.startswith(b"\x89PNG")
        assert content_type == "image/png"

    def test_server_refuses_a_wrong_token(self, site_root: Path):
        server = AssetServer()
        server.set_root(site_root)
        server.start()
        try:
            url = server.url_for("source/images/a.png").replace(
                server.token, "wrong"
            )
            with pytest.raises(urllib.error.HTTPError) as info:
                urllib.request.urlopen(urllib.request.Request(url), timeout=5)
        finally:
            server.stop()

        assert info.value.code == 404

    def test_stop_closes_the_port(self, site_root: Path):
        server = AssetServer()
        server.set_root(site_root)
        server.start()
        host, port = server.base_url.replace("http://", "").split(":")
        server.stop()

        with pytest.raises(OSError):
            with socket.create_connection((host, int(port)), timeout=2):
                pass

    def test_base_url_is_empty_before_start(self):
        assert AssetServer().base_url == ""
