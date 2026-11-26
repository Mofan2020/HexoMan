"""``window.hexoman`` 这一层的接口行为。

这些测试用假 runner，**不会跑真的 hexo / git**。
"""

from __future__ import annotations

from pathlib import Path

from hexoman.process import NullCommandRunner, ProcessResult


class TestState:
    def test_get_state_returns_strings_and_sites(self, api, fake_site):
        api._site_list.add(fake_site.path)

        state = api.getState()

        assert state["ok"] is True
        assert state["language"] in ("zh", "en")
        assert "nav.posts" in state["strings"]
        assert len(state["sites"]) == 1

    def test_get_state_without_site_has_null_info(self, api):
        state = api.getState()

        assert state["siteInfo"] is None
        assert state["sites"] == []


class TestLanguageSwitch:
    def test_switch_language_returns_new_strings(self, api):
        result = api.setLanguage("en")

        assert result["ok"] is True
        assert result["language"] == "en"
        assert result["strings"]["nav.posts"] == "Posts"

    def test_switch_language_is_persisted(self, api, tmp_path: Path):
        api.setLanguage("en")

        assert api._settings.language == "en"
        assert api._settings_store.load().language == "en"

    def test_switch_language_rejects_unknown(self, api):
        result = api.setLanguage("fr")

        assert result["ok"] is False
        assert api._settings.language != "fr"


class TestSites:
    def test_add_site(self, api, fake_site):
        result = api.addSite(fake_site.path)

        assert result["ok"] is True
        assert result["currentSitePath"] == fake_site.path
        assert len(result["sites"]) == 1

    def test_add_site_rejects_non_hexo(self, api, tmp_path: Path):
        root = tmp_path / "not-hexo"
        root.mkdir()

        result = api.addSite(str(root))

        assert result["ok"] is False
        assert result["error"] == "notHexoSite"

    def test_add_site_rejects_empty_path(self, api):
        result = api.addSite("")

        assert result["ok"] is False

    def test_remove_site_keeps_files(self, api, fake_site):
        api.addSite(fake_site.path)

        # 移除当前站点会被拒绝
        result = api.removeSite(fake_site.path)
        assert result["ok"] is False
        assert result["error"] == "cannotRemoveCurrent"

        assert Path(fake_site.path, "_config.yml").exists()

    def test_remove_site_when_not_current(self, api, fake_site, tmp_path: Path):
        api.addSite(fake_site.path)

        other_root = tmp_path / "other"
        other_root.mkdir()
        (other_root / "package.json").write_text('{"dependencies": {"hexo": "^7"}}')
        (other_root / "_config.yml").write_text("title: t\n")

        api.addSite(str(other_root))
        result = api.removeSite(fake_site.path)

        assert result["ok"] is True
        assert Path(fake_site.path, "_config.yml").exists()

    def test_select_site(self, api, fake_site):
        api.addSite(fake_site.path)

        result = api.selectSite(fake_site.path)

        assert result["ok"] is True
        assert result["currentSitePath"] == fake_site.path

    def test_site_list_persists(self, api, fake_site):
        api.addSite(fake_site.path)

        stored = api._settings_store.load()
        assert len(stored.sites) == 1
        assert stored.last_site_path == fake_site.path


class TestPosts:
    def test_list_posts_empty_without_site(self, api):
        result = api.listPosts()

        assert result["ok"] is True
        assert result["posts"] == []

    def test_create_and_list(self, api, fake_site):
        api.addSite(fake_site.path)

        created = api.createPost("测试文章", ["python"], ["技术"], "正文内容", False)
        assert created["ok"] is True

        listed = api.listPosts()
        assert len(listed["posts"]) == 1
        assert listed["posts"][0]["title"] == "测试文章"
        assert listed["posts"][0]["tags"] == ["python"]
        assert "python" in listed["tags"]

    def test_create_rejects_empty_title(self, api, fake_site):
        api.addSite(fake_site.path)

        result = api.createPost("   ", [], [], "", False)

        assert result["ok"] is False

    def test_save_post_updates_fields(self, api, fake_site):
        api.addSite(fake_site.path)
        created = api.createPost("旧标题", [], [], "旧正文", False)
        path = created["post"]["path"]

        result = api.savePost(path, "新标题", "新正文", "2026-11-20 10:00:00", ["a"], ["b"], True)

        assert result["ok"] is True
        assert result["post"]["title"] == "新标题"
        assert result["post"]["body"] == "新正文"
        assert result["post"]["tags"] == ["a"]
        assert result["post"]["draft"] is True

    def test_save_post_preserves_unknown_front_matter(self, api, fake_site, make_post):
        api.addSite(fake_site.path)
        path = make_post(
            fake_site, "keep.md", front="title: t\ncustom: 保留我", body="x"
        )

        api.savePost(str(path), "新标题", "新正文", "", [], [], False)

        text = Path(path).read_text(encoding="utf-8")
        assert "custom: 保留我" in text

    def test_delete_post(self, api, fake_site):
        api.addSite(fake_site.path)
        created = api.createPost("待删除", [], [], "", False)

        result = api.deletePost(created["post"]["path"])

        assert result["ok"] is True
        assert api.listPosts()["posts"] == []

    def test_get_post(self, api, fake_site):
        api.addSite(fake_site.path)
        created = api.createPost("详情", [], [], "正文", False)

        result = api.getPost(created["post"]["path"])

        assert result["ok"] is True
        assert result["post"]["body"] == "正文"


class TestMarkdown:
    def test_render_markdown_strips_front_matter(self, api):
        result = api.renderMarkdown("---\ntitle: 不该出现\n---\n# 标题\n")

        assert result["ok"] is True
        assert "<h1" in result["html"]
        assert "标题" in result["html"]
        assert "不该出现" not in result["html"]

    def test_render_markdown_returns_metadata(self, api):
        result = api.renderMarkdown("---\ntitle: 我的\ntags:\n  - x\n---\n正文")

        assert result["title"] == "我的"
        assert result["tags"] == ["x"]


class TestOverview:
    def test_overview_without_site(self, api):
        result = api.getOverview()

        assert result["ok"] is True
        assert result["siteInfo"] is None

    def test_overview_with_site(self, api, fake_site):
        api.addSite(fake_site.path)

        result = api.getOverview()

        assert result["ok"] is True
        assert result["siteInfo"]["title"] == "我的博客"
        assert result["siteInfo"]["postCount"] == 0
        assert "hexoSourceKey" in result
        assert result["commandPreview"].startswith("$ ")


class TestBuildActions:
    def test_run_generate_without_site(self, api):
        result = api.runGenerate()

        assert result["ok"] is False
        assert result["error"] == "noSite"

    def test_run_generate_uses_fake_runner(self, api, fake_site):
        api.addSite(fake_site.path)
        api._runner = NullCommandRunner(
            ProcessResult(exit_code=0, output="INFO  generated")
        )

        result = api.runGenerate()

        assert result["ok"] is True
        assert "generated" in result["output"]

    def test_run_generate_reports_failure(self, api, fake_site):
        api.addSite(fake_site.path)
        api._runner = NullCommandRunner(
            ProcessResult(exit_code=1, output="ERROR: something broke")
        )

        result = api.runGenerate()

        assert result["ok"] is False
        assert result["exitCode"] == 1
        assert "something broke" in result["error"]

    def test_start_preview_without_site(self, api):
        result = api.startPreview()

        assert result["ok"] is False

    def test_stop_preview_is_safe(self, api):
        result = api.stopPreview()

        assert result["ok"] is True

    def test_refresh_git_without_site(self, api):
        result = api.refreshGit()

        assert result["ok"] is False


class TestShutdown:
    def test_shutdown_persists_settings(self, api, fake_site):
        api.addSite(fake_site.path)

        api.shutdown()

        stored = api._settings_store.load()
        assert len(stored.sites) == 1


class TestJsApiContract:
    """这一层的接口就是 JS API 本身，命名错了前端会直接崩。"""

    def test_public_methods_are_camel_case(self):
        """公开方法必须全是 camelCase。

        pywebview 把 Python 方法名原样暴露给 JS，前端按 camelCase 调。
        这里混入一个 snake_case 的公开方法，前端就会拿到 undefined。
        """
        from hexoman.api import HexoManAPI

        offenders = [
            name
            for name in dir(HexoManAPI)
            if not name.startswith("_")
            and callable(getattr(HexoManAPI, name))
            and "_" in name
        ]

        assert offenders == [], f"这些公开方法是 snake_case：{offenders}"

    def test_internal_state_is_underscore_prefixed(self):
        """内部状态必须加下划线前缀。

        pywebview 会递归暴露非可调用的对象属性——不加下划线的话
        设置文件里的站点列表也会变成 JS 可访问的东西。
        """
        from hexoman.api import HexoManAPI

        offenders = [
            name
            for name in dir(HexoManAPI)
            if not name.startswith("_")
            and not callable(getattr(HexoManAPI, name, None))
        ]

        assert offenders == [], f"这些属性没加下划线：{offenders}"

    def test_every_public_method_returns_json_serialisable_dict(self, api):
        """每个方法都要能 JSON 化——pywebview 靠这个传回前端。

        只测「无参可调」的方法（返回布尔或字典的那些），
        需要参数的方法由各自的测试覆盖。
        """
        import inspect
        import json

        for name in dir(api):
            if name.startswith("_"):
                continue
            method = getattr(api, name)
            if not callable(method):
                continue

            # 有必填参数的方法跳过：它们由各自的用例覆盖
            required = [
                parameter
                for parameter in inspect.signature(method).parameters.values()
                if parameter.default is inspect.Parameter.empty
                and parameter.kind
                in (
                    inspect.Parameter.POSITIONAL_ONLY,
                    inspect.Parameter.POSITIONAL_OR_KEYWORD,
                )
            ]
            if required:
                continue

            result = method()
            assert isinstance(result, dict), f"{name} 没返回 dict"
            json.dumps(result, ensure_ascii=False)
