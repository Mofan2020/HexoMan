"""日志面板（ShellRunner）与环境文档数据。"""

from __future__ import annotations

import pytest

from hexoman.environment_docs import EnvironmentDocs
from hexoman.process import NullCommandRunner, ProcessResult
from hexoman.shell_runner import LogLine, ShellRunner, display_command, strip_ansi


# -- ANSI --------------------------------------------------------------


def test_strip_ansi_removes_colour_codes():
    assert strip_ansi("\x1b[31m红色\x1b[0m失败") == "红色失败"


def test_strip_ansi_keeps_chinese_after_escape():
    """Swift 版「遇到字母就结束」会把中文当成 CSI 结束符，把正文吃掉。"""
    text = "\x1b[1m中文标题\x1b[22m"
    assert strip_ansi(text) == "中文标题"


def test_strip_ansi_passthrough_without_escape():
    assert strip_ansi("普通文本") == "普通文本"


def test_log_line_display_text_strips():
    line = LogLine(text="\x1b[32mok\x1b[0m", stream="stdout")
    assert line.display_text == "ok"


def test_display_command_quotes_spaces():
    assert display_command("/bin/sh", ["-c", "echo hi"]) == '$ /bin/sh -c "echo hi"'


# -- 日志 --------------------------------------------------------------


def test_emit_and_clear():
    runner = ShellRunner(NullCommandRunner())
    runner.emit("hello")
    assert len(runner.lines) == 1

    runner.clear()
    assert runner.lines == []


def test_log_is_capped():
    runner = ShellRunner(NullCommandRunner(), max_lines=10)
    for index in range(50):
        runner.emit(f"line {index}")

    lines = runner.lines
    assert len(lines) == 10
    # 保留的是最新的那些
    assert lines[-1].text == "line 49"


def test_run_records_command_and_output():
    fake = NullCommandRunner(ProcessResult(exit_code=0, output="INFO generated 42 files\n"))
    runner = ShellRunner(fake)

    result = runner.run("generate", "hexo", ["generate"], ".")

    assert result.success
    texts = [line.text for line in runner.lines]
    assert any("$ hexo generate" in text for text in texts)
    assert any("generated 42 files" in text for text in texts)
    assert any("退出码 0" in text for text in texts)


def test_run_marks_stderr_on_failure():
    fake = NullCommandRunner(ProcessResult(exit_code=1, output="fatal: nope"))
    runner = ShellRunner(fake)

    runner.run("git", "git", ["status"])

    assert any(line.stream == "stderr" for line in runner.lines)


def test_start_service_returns_empty_on_spawn_failure():
    runner = ShellRunner(NullCommandRunner())
    assert runner.start_service("preview", "hexo", ["server"]) == ""


def test_stop_all_on_empty_is_safe():
    runner = ShellRunner(NullCommandRunner())
    runner.stop_all()
    assert runner.jobs == {}


def test_split_lines_drops_blank():
    assert ShellRunner.split_lines("a\n\nb\r\n") == ["a", "b"]


def test_log_dicts_are_serialisable():
    runner = ShellRunner(NullCommandRunner())
    runner.emit("x", "stdout")
    data = runner.log_dicts()[0]
    assert data["text"] == "x"
    assert "timestamp" in data


# -- 环境文档 ----------------------------------------------------------


def test_docs_sections_complete():
    ids = [section.id for section in EnvironmentDocs.SECTIONS]
    assert ids == [
        "overview",
        "node",
        "nvm",
        "git",
        "hexo",
        "shell",
        "troubleshoot",
        "privacy",
    ]


def test_docs_find():
    assert EnvironmentDocs.find("node") is not None
    assert EnvironmentDocs.find("nope") is None


def test_docs_sections_have_summary():
    assert all(section.summary for section in EnvironmentDocs.SECTIONS)


def test_docs_commands_are_raw_strings():
    node = EnvironmentDocs.find("node")
    assert node is not None
    commands = {item.command for item in node.commands}
    # 命令是用户要复制进终端的字符，必须是原文
    assert "brew install node" in commands


def test_docs_troubleshoot_has_commands():
    section = EnvironmentDocs.find("troubleshoot")
    assert section is not None
    assert len(section.commands) >= 3


def test_docs_privacy_has_no_commands():
    section = EnvironmentDocs.find("privacy")
    assert section is not None
    assert section.commands == []


def test_docs_to_list_is_serialisable():
    data = EnvironmentDocs.to_list()
    assert len(data) == 8
    assert all("title" in item for item in data)


def test_every_section_is_referenced_or_standalone():
    known = {section.id for section in EnvironmentDocs.SECTIONS}
    for section in EnvironmentDocs.SECTIONS:
        for target in section.see_also:
            assert target in known, f"{section.id} 指向了不存在的章节 {target}"
