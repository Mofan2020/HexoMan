"""第五阶段：预览的文章接口。

预览里的图片要能显示出来。文章里写的是站点内的相对路径，界面从
``file://`` 打开时加载不到，后端得把它换成本地资源服务的地址。
"""

from __future__ import annotations

import json
from pathlib import Path

from hexoman.model import Site


class TestPreviewImageResolution:
    def _site_with_image(self, tmp_path: Path) -> Site:
        root = tmp_path / "blog"
        (root / "source" / "images" / "2026").mkdir(parents=True)
        (root / "source" / "images" / "2026" / "shot.png").write_bytes(
            b"\x89PNG\r\n\x1a\nfake"
        )
        (root / "source" / "_posts").mkdir(parents=True)
        (root / "_config.yml").write_text("title: 博客\n", encoding="utf-8")
        # 站点要被 ``addSite`` 认出来，得有 package.json 且声明了 hexo 依赖
        (root / "package.json").write_text(
            json.dumps({"name": "blog", "dependencies": {"hexo": "^7.0.0"}}),
            encoding="utf-8",
        )
        return Site(path=str(root), last_opened=1000.0)

    def _use_site(self, api, site: Site) -> None:
        assert api.addSite(site.path)["ok"] is True

    def test_site_relative_image_is_rewritten(self, api, tmp_path: Path):
        site = self._site_with_image(tmp_path)
        self._use_site(api, site)

        result = api.renderMarkdown("![截图](/images/2026/shot.png)")

        assert result["ok"] is True
        assert "/source/images/2026/shot.png" in result["html"]
        assert result["html"].count("http://127.0.0.1:") == 1

    def test_image_next_to_the_post_is_rewritten(self, api, tmp_path: Path):
        """相对路径先按文章所在目录找——Hexo 的资源文件夹就是这么用的。"""
        site = self._site_with_image(tmp_path)
        self._use_site(api, site)
        post = Path(site.path) / "source" / "_posts" / "hello.md"
        post.write_text("正文", encoding="utf-8")
        (post.parent / "pic.png").write_bytes(b"\x89PNG\r\n\x1a\nfake")

        result = api.renderMarkdown("![图](pic.png)", str(post))

        assert "/source/_posts/pic.png" in result["html"]

    def test_missing_image_keeps_the_original_address(self, api, tmp_path: Path):
        """找不到文件就原样返回——预览里显示裂图，比悄悄换掉诚实。"""
        site = self._site_with_image(tmp_path)
        self._use_site(api, site)

        result = api.renderMarkdown("![没有]( /images/nope.png )")

        assert "nope.png" in result["html"]

    def test_remote_image_is_left_alone(self, api, tmp_path: Path):
        site = self._site_with_image(tmp_path)
        self._use_site(api, site)

        result = api.renderMarkdown("![远](https://example.com/a.png)")

        assert 'src="https://example.com/a.png"' in result["html"]

    def test_without_a_site_images_are_left_alone(self, api):
        result = api.renderMarkdown("![图](/images/a.png)")

        assert 'src="/images/a.png"' in result["html"]


class TestPreviewPayload:
    def test_payload_carries_what_the_preview_header_needs(self, api):
        result = api.renderMarkdown(
            "---\ntitle: 我的文章\ntags:\n  - 随笔\n---\n"
            "# 标题\n\n正文内容\n"
        )

        assert result["title"] == "我的文章"
        assert result["tags"] == ["随笔"]
        assert result["wordCount"] > 0
        assert result["readingMinutes"] >= 1
        assert result["outline"]
        assert result["outline"][0]["text"] == "标题"

    def test_preview_html_has_no_script(self, api):
        """预览页带着能改文件的桥接，脚本不能进来。"""
        result = api.renderMarkdown("<script>alert(1)</script>\n\n正文")

        assert "<script" not in result["html"]
        assert "正文" in result["html"]
