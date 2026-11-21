"""git 状态解析与命令组装。

**单元测试不许跑真的 git**——全部用假 runner。
"""

from __future__ import annotations

from pathlib import Path

from hexoman.git_service import GitService, parse_porcelain_v2
from hexoman.model import Site
from hexoman.process import NullCommandRunner, ProcessResult


class TestParsePorcelainV2:
    def test_parses_branch(self):
        output = "# branch.oid abc123\n# branch.head main\n# branch.upstream origin/main\n"

        status = parse_porcelain_v2(output)

        assert status.branch == "main"
        assert status.upstream == "origin/main"

    def test_detached_head(self):
        status = parse_porcelain_v2("# branch.head (detached)\n")

        assert status.branch == "detached"

    def test_parses_ahead_behind(self):
        status = parse_porcelain_v2("# branch.ab +3 -2\n")

        assert status.ahead == 3
        assert status.behind == 2

    def test_untracked_files(self):
        output = "? new-file.txt\n"

        status = parse_porcelain_v2(output)

        assert status.untracked == ["new-file.txt"]

    def test_staged_and_modified(self):
        output = "1 M. N... 100644 100644 100644 aaa bbb staged.txt\n"

        status = parse_porcelain_v2(output)

        assert status.staged == ["staged.txt"]
        assert status.modified == []

    def test_modified_only(self):
        output = "1 .M N... 100644 100644 100644 aaa bbb changed.txt\n"

        status = parse_porcelain_v2(output)

        assert status.modified == ["changed.txt"]
        assert status.staged == []

    def test_both_staged_and_modified(self):
        output = "1 MM N... 100644 100644 100644 aaa bbb both.txt\n"

        status = parse_porcelain_v2(output)

        assert status.staged == ["both.txt"]
        assert status.modified == ["both.txt"]

    def test_conflicted(self):
        output = "u UU N... 100644 100644 100644 100644 aaa bbb ccc conflict.txt\n"

        status = parse_porcelain_v2(output)

        assert status.conflicted == ["conflict.txt"]

    def test_rename_uses_target_path(self):
        """重命名条目有两个路径（``新\\t旧``），只取新的。"""
        output = "2 R. N... 100644 100644 100644 aaa bbb R100 new.txt\told.txt\n"

        status = parse_porcelain_v2(output)

        assert status.staged == ["new.txt"]

    def test_path_with_spaces_is_kept_whole(self):
        """路径里有空格不能被切开——只能按固定字段数切。"""
        output = "1 .M N... 100644 100644 100644 aaa bbb my file.txt\n"

        status = parse_porcelain_v2(output)

        assert status.modified == ["my file.txt"]

    def test_ignored_files_are_skipped(self):
        status = parse_porcelain_v2("! ignored.txt\n")

        assert status.untracked == []
        assert status.modified == []
        assert status.staged == []

    def test_clean_status(self):
        status = parse_porcelain_v2("# branch.head main\n")

        assert status.is_clean is True
        assert status.change_count == 0

    def test_dirty_status(self):
        status = parse_porcelain_v2("? a.txt\n? b.txt\n")

        assert status.is_clean is False
        assert status.change_count == 2


class TestGitService:
    def test_status_uses_fake_runner(self, fake_site: Site):
        runner = NullCommandRunner(
            ProcessResult(exit_code=0, output="# branch.head main\n")
        )
        service = GitService(fake_site, runner)

        status = service.status()

        assert status is not None
        assert status.branch == "main"
        assert runner.calls[0]["args"][:3] == ["git", "-C", fake_site.path]
        assert "--porcelain=v2" in runner.calls[0]["args"]

    def test_status_returns_none_on_failure(self, fake_site: Site):
        runner = NullCommandRunner(ProcessResult(exit_code=128, output="not a repo"))
        service = GitService(fake_site, runner)

        assert service.status() is None

    def test_log_parses_commits(self, fake_site: Site):
        runner = NullCommandRunner(
            ProcessResult(
                exit_code=0,
                output="abc1234\t张三\t2026-11-20\t第一次提交\ndef5678\t李四\t2026-11-19\t第二次提交\n",
            )
        )
        service = GitService(fake_site, runner)

        commits = service.log(limit=5)

        assert len(commits) == 2
        assert commits[0].short_hash == "abc1234"
        assert commits[0].subject == "第一次提交"
        assert commits[0].author == "张三"

    def test_log_returns_empty_on_failure(self, fake_site: Site):
        runner = NullCommandRunner(ProcessResult(exit_code=128, output=""))
        service = GitService(fake_site, runner)

        assert service.log() == []

    def test_commit_requires_message(self, fake_site: Site):
        runner = NullCommandRunner()
        service = GitService(fake_site, runner)

        result = service.commit("   ")

        assert result.success is False
        assert runner.calls == []

    def test_commit_adds_then_commits(self, fake_site: Site):
        runner = NullCommandRunner()
        service = GitService(fake_site, runner)

        service.commit("提交信息")

        assert len(runner.calls) == 2
        assert "add" in runner.calls[0]["args"]
        assert "-A" in runner.calls[0]["args"]
        assert "commit" in runner.calls[1]["args"]

    def test_push_and_pull(self, fake_site: Site):
        runner = NullCommandRunner()
        service = GitService(fake_site, runner)

        service.push()
        service.pull()

        assert "push" in runner.calls[0]["args"]
        assert "--rebase" in runner.calls[1]["args"]

    def test_remotes_reads_git_config(self, fake_site: Site):
        git_dir = Path(fake_site.path) / ".git"
        git_dir.mkdir(parents=True, exist_ok=True)
        (git_dir / "config").write_text(
            '[remote "origin"]\n'
            "\turl = https://github.com/user/blog.git\n"
            "\tfetch = +refs/heads/*:refs/remotes/origin/*\n"
        )
        service = GitService(fake_site, NullCommandRunner())

        remotes = service.remotes()

        assert len(remotes) == 1
        assert "origin" in remotes[0]
        assert "https://github.com/user/blog.git" in remotes[0]

    def test_remotes_empty_without_git_dir(self, fake_site: Site):
        service = GitService(fake_site, NullCommandRunner())

        assert service.remotes() == []
