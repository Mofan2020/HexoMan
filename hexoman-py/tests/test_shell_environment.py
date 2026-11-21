"""shell 环境抓取与工具链体检。"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from hexoman.hexo_environment import HexoEnvironment, ToolchainInfo, ToolProbe
from hexoman.process import NullCommandRunner, ProcessResult
from hexoman.shell_environment import (
    ShellEnvironment,
    ShellEnvironmentResolver,
    fallback_path_entries,
)


# -- ShellEnvironment --------------------------------------------------


def test_executable_path_scans_path(tmp_path: Path):
    binary = tmp_path / "hexo"
    binary.write_text("#!/bin/sh\n", encoding="utf-8")
    binary.chmod(0o755)

    environment = ShellEnvironment(variables={}, rc_files=[], path=str(tmp_path))
    assert environment.executable_path("hexo") == str(binary)


def test_executable_path_returns_none_when_missing(tmp_path: Path):
    environment = ShellEnvironment(variables={}, rc_files=[], path=str(tmp_path))
    assert environment.executable_path("nope") is None


def test_executable_path_absolute(tmp_path: Path):
    binary = tmp_path / "x"
    binary.write_text("", encoding="utf-8")
    binary.chmod(0o755)

    environment = ShellEnvironment(variables={}, rc_files=[], path="")
    assert environment.executable_path(str(binary)) == str(binary)


def test_path_summary_prefers_homebrew():
    environment = ShellEnvironment(
        variables={},
        rc_files=[],
        path="/usr/bin:/opt/homebrew/bin:/bin",
    )
    assert "homebrew" in environment.path_summary
    assert "共 3 项" in environment.path_summary


def test_rc_summary():
    environment = ShellEnvironment(
        variables={}, rc_files=["/Users/x/.zshenv", "/Users/x/.zshrc"], path="/bin"
    )
    assert environment.rc_summary == ".zshenv → .zshrc"


def test_rc_summary_when_empty():
    environment = ShellEnvironment(variables={}, rc_files=[], path="/bin")
    assert "未找到" in environment.rc_summary


def test_parse_env_output():
    output = "HOME=/Users/x\0PATH=/opt/homebrew/bin:/usr/bin\0SHLVL=2\0ZSH_VERSION=5.9\0"

    environment = ShellEnvironmentResolver.parse(output)

    assert environment is not None
    assert environment.path == "/opt/homebrew/bin:/usr/bin"
    # 运行时变量必须丢掉，否则 npm 脚本会以为自己在交互 shell 里
    assert "SHLVL" not in environment.variables
    assert "ZSH_VERSION" not in environment.variables


def test_parse_returns_none_without_path():
    assert ShellEnvironmentResolver.parse("HOME=/x\0") is None


def test_parse_keeps_home():
    environment = ShellEnvironmentResolver.parse("PATH=/bin\0")
    assert environment is not None
    assert environment.variables["HOME"]


def test_bootstrap_script_sources_rc_files():
    script = ShellEnvironmentResolver.bootstrap_script("")

    assert ".zshenv" in script
    assert ".zprofile" in script
    assert ".zshrc" in script
    # source 失败不能中断整个探测
    assert "|| true" in script
    # 用 env -0 输出，不受 locale 影响
    assert "env -0" in script


def test_bootstrap_script_custom_rc_only():
    script = ShellEnvironmentResolver.bootstrap_script("/custom/.zshrc")

    assert "'/custom/.zshrc'" in script
    assert ".zprofile" not in script


def test_shell_quote_escapes_single_quotes():
    assert ShellEnvironmentResolver.shell_quote("a'b") == "'a'\\''b'"


def test_bootstrap_script_includes_fallback_entries():
    if os.name == "nt":
        pytest.skip("Windows 没有 brew 前缀")
    script = ShellEnvironmentResolver.bootstrap_script("")
    assert "/opt/homebrew/bin" in script


def test_fallback_path_entries_empty_on_windows():
    # 只断言当前平台的行为正确，不在测试里伪造 os.name
    entries = fallback_path_entries()
    if os.name == "nt":
        assert entries == []
    else:
        assert "/usr/bin" in entries


# -- 工具链体检 --------------------------------------------------------


def test_tool_probe_display():
    probe = ToolProbe(name="node", path="/opt/homebrew/bin/node", version="20.1.0")
    assert probe.is_available
    # 只留尾部三段，完整路径在详情里再看
    assert probe.display_version == "20.1.0 · homebrew/bin/node"


def test_tool_probe_missing():
    probe = ToolProbe(name="node")
    assert not probe.is_available
    assert probe.display_version == "未找到"


def test_inspect_with_fake_runner():
    runner = NullCommandRunner(ProcessResult(exit_code=0, output="v20.1.0\n"))
    info = HexoEnvironment.inspect(runner, environment=None, uses_shell_environment=False)

    assert info.node.is_available
    assert info.node.version == "20.1.0"
    assert info.environment == {}


def test_inspect_marks_missing_tools():
    runner = NullCommandRunner(ProcessResult(exit_code=127, output="not found"))
    info = HexoEnvironment.inspect(runner, environment=None, uses_shell_environment=False)

    assert not info.node.is_available
    assert not info.git.is_available
    combined = "\n".join(info.warnings)
    # 无论这台机器上有没有 brew node，都必须给出关于 node 的可操作诊断
    assert "node" in combined
    assert "git" in combined


def test_diagnose_mentions_node_path_when_installed_but_hidden():
    info = ToolchainInfo()
    info.node = ToolProbe("node")
    info.git = ToolProbe("git", path="/usr/bin/git")

    # 伪造「系统里能找到 node」
    import hexoman.hexo_environment as module

    original = module.HexoEnvironment.brew_or_nvm_node_path
    module.HexoEnvironment.brew_or_nvm_node_path = staticmethod(lambda: "/opt/homebrew/bin/node")
    try:
        warnings = HexoEnvironment.diagnose(info, environment=None, uses_shell_environment=False)
    finally:
        module.HexoEnvironment.brew_or_nvm_node_path = original

    assert any("不在 HexoMan 当前的 PATH" in warning for warning in warnings)


def test_diagnose_warns_about_old_node():
    info = ToolchainInfo()
    info.node = ToolProbe("node", path="/usr/bin/node", version="14.0.0")
    info.git = ToolProbe("git", path="/usr/bin/git")

    warnings = HexoEnvironment.diagnose(info, environment=None, uses_shell_environment=False)
    assert any("14.0.0" in warning for warning in warnings)


def test_is_recent_enough():
    assert HexoEnvironment.is_recent_enough("v20.1.0")
    assert HexoEnvironment.is_recent_enough("18.0.0")
    assert not HexoEnvironment.is_recent_enough("v16.0.0")
    # 读不懂的版本号不该报警
    assert HexoEnvironment.is_recent_enough("weird")


def test_clean_version_strips_prefix():
    assert HexoEnvironment.clean_version("v20.1.0\nextra\n") == "20.1.0"
    assert HexoEnvironment.clean_version("") == ""


def test_toolchain_is_usable():
    info = ToolchainInfo()
    assert not info.is_usable
    info.global_hexo = ToolProbe("hexo", path="/usr/local/bin/hexo")
    assert info.is_usable


def test_toolchain_to_dict_has_all_probes():
    data = ToolchainInfo().to_dict()
    for key in ("node", "npm", "npx", "globalHexo", "git", "warnings", "isUsable"):
        assert key in data
