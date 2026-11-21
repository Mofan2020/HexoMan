"""hexo 命令的组装与执行。

**单元测试不许跑真的 hexo**——全部用假 runner。
"""

from __future__ import annotations

import os
from pathlib import Path

from hexoman.hexo_cli import HexoService, resolve_invocation
from hexoman.model import Site
from hexoman.process import NullCommandRunner, ProcessResult


class FakeRunner(NullCommandRunner):
    """能指定「哪些命令存在」的假 runner。"""

    def __init__(
        self,
        executables: set[str] | None = None,
        which: dict[str, str] | None = None,
        result: ProcessResult | None = None,
    ) -> None:
        super().__init__(result)
        self.executables = executables or set()
        self.which_map = which or {}

    def is_executable(self, path: str) -> bool:
        return path in self.executables

    def which(self, name: str) -> str | None:
        return self.which_map.get(name)


class TestResolveInvocation:
    def test_custom_path_wins(self, fake_site: Site):
        runner = FakeRunner(executables={"/custom/hexo"})
        local = fake_site.node_modules_bin
        runner.executables.add(local)

        invocation = resolve_invocation(fake_site, "/custom/hexo", runner)

        assert invocation.executable == "/custom/hexo"
        assert invocation.source == "custom"

    def test_local_dependency_wins_over_path(self, fake_site: Site):
        local = fake_site.node_modules_bin
        runner = FakeRunner(
            executables={local}, which={"hexo": "/usr/local/bin/hexo"}
        )

        invocation = resolve_invocation(fake_site, "", runner)

        assert invocation.executable == local
        assert invocation.source == "local"

    def test_user_path_used_when_no_local(self, fake_site: Site):
        runner = FakeRunner(which={"hexo": "/usr/local/bin/hexo"})

        invocation = resolve_invocation(fake_site, "", runner)

        assert invocation.executable == "/usr/local/bin/hexo"
        assert invocation.source == "path"

    def test_falls_back_to_npx(self, fake_site: Site):
        runner = FakeRunner()

        invocation = resolve_invocation(fake_site, "", runner)

        assert invocation.executable == "npx"
        assert invocation.prefix_arguments == ["hexo"]
        assert invocation.source == "npx"

    def test_invalid_custom_path_is_ignored(self, fake_site: Site):
        runner = FakeRunner(which={"hexo": "/usr/local/bin/hexo"})

        invocation = resolve_invocation(fake_site, "/nope/hexo", runner)

        assert invocation.executable == "/usr/local/bin/hexo"


class TestCommands:
    def test_generate_command(self, fake_site: Site):
        local = fake_site.node_modules_bin
        runner = FakeRunner(executables={local})
        service = HexoService(fake_site, "", runner)

        executable, args = service.generate()

        assert executable == local
        assert args == ["generate"]

    def test_clean_command(self, fake_site: Site):
        local = fake_site.node_modules_bin
        runner = FakeRunner(executables={local})
        service = HexoService(fake_site, "", runner)

        executable, args = service.clean()

        assert args == ["clean"]

    def test_server_command_has_port(self, fake_site: Site):
        local = fake_site.node_modules_bin
        runner = FakeRunner(executables={local})
        service = HexoService(fake_site, "", runner)

        executable, args = service.server(4000)

        assert args == ["server", "-p", "4000"]

    def test_server_with_drafts_adds_flag(self, fake_site: Site):
        """草稿在预览里默认不存在，要加 ``--draft``。"""
        local = fake_site.node_modules_bin
        runner = FakeRunner(executables={local})
        service = HexoService(fake_site, "", runner)

        executable, args = service.server(4000, drafts=True)

        assert "--draft" in args

    def test_server_without_drafts_has_no_flag(self, fake_site: Site):
        local = fake_site.node_modules_bin
        runner = FakeRunner(executables={local})
        service = HexoService(fake_site, "", runner)

        executable, args = service.server(4000, drafts=False)

        assert "--draft" not in args

    def test_preview_url(self, fake_site: Site):
        service = HexoService(fake_site, "", FakeRunner())

        assert service.preview_url(4000) == "http://localhost:4000"

    def test_command_preview_is_readable(self, fake_site: Site):
        local = fake_site.node_modules_bin
        runner = FakeRunner(executables={local})
        service = HexoService(fake_site, "", runner)

        preview = service.command_preview("generate")

        assert preview.startswith("$ ")
        assert "generate" in preview


class TestExecution:
    def test_run_generate_uses_fake_runner(self, fake_site: Site):
        local = fake_site.node_modules_bin
        runner = FakeRunner(
            executables={local},
            result=ProcessResult(exit_code=0, output="generated"),
        )
        service = HexoService(fake_site, "", runner)

        result = service.run_generate()

        assert result.success is True
        assert result.output == "generated"
        assert runner.calls[0]["args"] == [local, "generate"]
        assert runner.calls[0]["cwd"] == fake_site.path

    def test_run_clean_uses_fake_runner(self, fake_site: Site):
        local = fake_site.node_modules_bin
        runner = FakeRunner(executables={local})
        service = HexoService(fake_site, "", runner)

        service.run_clean()

        assert runner.calls[0]["args"] == [local, "clean"]

    def test_failed_command_reports_error_summary(self, fake_site: Site):
        local = fake_site.node_modules_bin
        runner = FakeRunner(
            executables={local},
            result=ProcessResult(exit_code=1, output="line1\nline2\nERROR: boom"),
        )
        service = HexoService(fake_site, "", runner)

        result = service.run_generate()

        assert result.success is False
        assert result.error_summary is not None
        assert "ERROR: boom" in result.error_summary

    def test_start_server_returns_process_and_preview(self, fake_site: Site):
        local = fake_site.node_modules_bin
        runner = FakeRunner(executables={local})
        service = HexoService(fake_site, "", runner)

        process, preview = service.start_server(4000)

        # 假 runner 的 spawn 返回 None —— 界面要能处理这个情况
        assert process is None
        assert "server" in preview

    def test_stop_server_with_none_is_safe(self, fake_site: Site):
        service = HexoService(fake_site, "", FakeRunner())

        service.stop_server(None)  # 不该抛异常
