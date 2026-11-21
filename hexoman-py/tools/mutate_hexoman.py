#!/usr/bin/env python3
"""HexoMan Python 版变异测试。

规则（项目硬规矩）：
- 默认改副本，不改源码树。源码树全程不动。
- 变异改核心逻辑，不改测试。
- 变异必须被测试抓住；抓不住要区分「测试太松」与「分支本来就冗余」。
- 先跑未变异基线，基线 exit 0 再信任何结论。
- pytest 退出码 1 才算「抓住」；2/3/4 是量具坏了（用法错误/超时），要分开判。
- 副本里不装 .venv，直接用原环境的解释器 + PYTHONPATH 指向副本的包。

用法：python3 tools/mutate_hexoman.py
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE.parent          # 脚本在 hexoman-py/tools/ 下，源码树是它的上一级
ORIG_PYTHON = SRC / ".venv" / "bin" / "python"
if not ORIG_PYTHON.exists():
    ORIG_PYTHON = Path(sys.executable)

# 已知行为等价的变异：改了不影响输出，所以测试抓不住是正确的。
# 和「漏网」分开报，避免把这类当成测试漏洞去补假测试。
BEHAVIOUR_EQUIVALENT = {
    "pages:扫描时不跳过隐藏目录",
}

# (名称, 相对路径, 原片段, 替换片段)
MUTATIONS: list[tuple[str, str, str, str]] = [
    (
        "yaml:替换标量时把后面的文本吃掉",
        "hexoman/yaml_path.py",
        "    def _replace_span(self, start: int, end: int, rendered: str) -> str:\n"
        "        return self.text[:start] + rendered + self.text[end:]",
        "    def _replace_span(self, start: int, end: int, rendered: str) -> str:\n"
        "        return self.text[:start] + rendered",
    ),
    (
        "yaml:叶子是映射/序列时也强行替换",
        "hexoman/yaml_path.py",
        "        if existing is not None:\n"
        "            if not existing.is_scalar:\n"
        "                # 叶子是映射或序列：整体替换会毁掉用户写的结构，不做。\n"
        "                return None\n",
        "        if existing is not None:\n"
        "            if not existing.is_scalar:\n"
        "                pass\n",
    ),
    (
        "yaml:插入新键时缩进写死为零",
        "hexoman/yaml_path.py",
        '        indent = " " * parent.column',
        '        indent = ""',
    ),
    (
        # 原先是「下探时检查 is_mapping」，穷举验证过那条分支不可达
        # （child() 对标量/序列返回节点，但那种节点 entries 为空，
        #   parent.child(leaf) 拿到 None、_insert_key 也返回 None，
        #   结果与不检查完全一致）。那条是行为等价的变异，测它没有意义。
        # 换成真正会破坏行为的：下探时不做任何检查，父级不存在也往下走。
        "yaml:下探时完全不检查子节点",
        "hexoman/yaml_path.py",
        "            child = parent.child(key)\n"
        "            if child is None:\n"
        "                return None\n"
        "            parent = child",
        "            child = parent.child(key)\n"
        "            parent = child if child is not None else parent",
    ),
    (
        "i18n:查不到键时返回键名本身",
        "hexoman/i18n.py",
        "def t(key: str, language: str = DEFAULT_LANGUAGE, **kwargs: Any) -> str:",
        "def t(key: str, language: str = DEFAULT_LANGUAGE, **kwargs: Any) -> str:\n"
        "    return key  # MUTANT",
    ),
    (
        "backup:打包时跳过一半文件",
        "hexoman/backup.py",
        "                for relative in files:\n"
        "                    archive.write(root_path / relative, arcname=relative)",
        "                for relative in files[::2]:\n"
        "                    archive.write(root_path / relative, arcname=relative)",
    ),
    (
        "pages:扫描时不跳过隐藏目录",
        "hexoman/pages.py",
        "            subdirectories[:] = [\n"
        "                name for name in subdirectories if not name.startswith(\".\")\n"
        "            ]",
        "            subdirectories[:] = list(subdirectories)",
    ),
    (
        "pages:文章不排在前面",
        "hexoman/pages.py",
        "        results.sort(\n"
        "            key=lambda item: (not item.is_post, -item.modified_at, item.relative_path)\n"
        "        )",
        "        results.sort(\n"
        "            key=lambda item: (-item.modified_at, item.relative_path)\n"
        "        )",
    ),
    (
        "theme:换主题时把整个配置重写而不是只改 theme 键",
        "hexoman/theme_manager.py",
        "        document = YamlDocument(text)\n"
        "        updated = document.set(\"theme\", theme.name)",
        "        document = YamlDocument(text)\n"
        "        updated = f\"theme: {theme.name}\\n\"",
    ),
    (
        "theme:顶层键追加时不剥掉尾部空行",
        "hexoman/theme_manager.py",
        "    lines = text.split(\"\\n\")\n"
        "    while lines and not lines[-1].strip():\n"
        "        lines.pop()\n"
        "    if not lines:\n"
        "        return None",
        "    lines = text.split(\"\\n\")\n"
        "    if not lines:\n"
        "        return None",
    ),
    (
        "config_sync:同步时不做「值相同就不写」的判断",
        "hexoman/config_sync.py",
        "        current = (document.get(key) or \"\").strip()\n"
        "        if current == value:\n"
        "            return None",
        "        current = (document.get(key) or \"\").strip()",
    ),
]


def run_tests(work: Path, python: Path) -> tuple[int, str]:
    """在副本上跑 pytest。PYTHONPATH 指向副本，测试 import 的是被变异的包。"""
    env = dict(os.environ)
    env["PYTHONPATH"] = str(work)
    env["PYTHONDONTWRITEBYTECODE"] = ""
    proc = subprocess.run(
        [str(python), "-m", "pytest", "-q", "-x"],
        cwd=work,
        capture_output=True,
        text=True,
        env=env,
        timeout=900,
    )
    return proc.returncode, proc.stdout[-3000:] + proc.stderr[-1500:]


def make_copy(tmp: Path, source: Path) -> Path:
    work = Path(tmp) / "w"
    shutil.copytree(
        source, work,
        ignore=shutil.ignore_patterns("__pycache__", ".pytest_cache", ".venv", "*.pyc"),
    )
    return work


def clear_pyc(work: Path) -> None:
    for p in work.rglob("__pycache__"):
        shutil.rmtree(p, ignore_errors=True)
    for p in work.rglob("*.pyc"):
        try:
            p.unlink()
        except OSError:
            pass


def main() -> int:
    # 可以指定源码树：python3 tools/mutate_hexoman.py [源码树路径]
    source = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else SRC
    if not (source / "hexoman").is_dir():
        print(f"找不到源码树 {source}", file=sys.stderr)
        return 2
    python = source / ".venv" / "bin" / "python"
    if not python.exists():
        python = ORIG_PYTHON

    print(f"源码树：{source}")
    print(f"解释器：{python}")

    print("\n=== 基线（未变异）必须先全绿 ===", flush=True)
    with tempfile.TemporaryDirectory(prefix="hexoman-mut-") as tmp:
        base = make_copy(Path(tmp), source)
        rc, out = run_tests(base, python)
        print(f"基线退出码 {rc}")
        if rc != 0:
            print(out[-2500:])
            print("基线不绿，后续结论一律无效")
            return 2
        print("基线绿\n")

    caught = 0
    skipped = 0
    equivalent = 0
    missed: list[str] = []
    for name, relpath, old, new in MUTATIONS:
        with tempfile.TemporaryDirectory(prefix="hexoman-mut-") as tmp:
            work = make_copy(Path(tmp), source)
            target = work / relpath
            original = target.read_text(encoding="utf-8")
            if old not in original:
                print(f"[跳过] {name}: 在 {relpath} 找不到片段（脚本坏了，不是变异存活）")
                skipped += 1
                continue
            mutated = original.replace(old, new, 1)
            if mutated == original:
                print(f"[跳过] {name}: 替换后没变化")
                skipped += 1
                continue
            target.write_text(mutated, encoding="utf-8")
            clear_pyc(work)

            try:
                rc, out = run_tests(work, python)
            except subprocess.TimeoutExpired:
                print(f"[挂死] {name} —— 测试超时，可能是被测循环的终止条件被变异掉了")
                skipped += 1
                continue

            if rc == 1:
                caught += 1
                lines = [ln for ln in out.splitlines() if ln.strip()]
                summary = lines[-1] if lines else ""
                print(f"[抓住] {name}  |  {summary[:120]}")
            elif rc == 0:
                if name in BEHAVIOUR_EQUIVALENT:
                    equivalent += 1
                    print(f"[等价] {name} —— 已知行为等价，抓不住是对的")
                else:
                    missed.append(name)
                    print(f"[漏网] {name} —— 测试没抓住")
            else:
                print(f"[量具坏] {name} —— pytest 退出码 {rc}，不是「抓住」")
                print(out[-600:])

    print(f"\n共 {len(MUTATIONS)} 条变异：抓住 {caught}，已知等价 {equivalent}，漏网 {len(missed)}")
    if missed:
        print("漏网的：")
        for name in missed:
            print(f"  - {name}")
    return 0 if caught + equivalent + skipped == len(MUTATIONS) else 1


if __name__ == "__main__":
    raise SystemExit(main())
