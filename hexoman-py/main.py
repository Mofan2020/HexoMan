#!/usr/bin/env python3
"""HexoMan 入口：起一个 pywebview 窗口。

对应 Swift 侧的 ``HexoManApp.swift``。职责很少——建窗口、把 API 挂上去、
开跑。业务逻辑都在 :mod:`hexoman` 里。

跑起来：

    python3 main.py
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

# 允许从源码目录直接跑（``python3 main.py``），不用先 ``pip install -e .``
sys.path.insert(0, str(Path(__file__).resolve().parent))

from hexoman.api import HexoManAPI  # noqa: E402
from hexoman.system_integration import platform_name  # noqa: E402

UI_DIR = Path(__file__).resolve().parent / "hexoman" / "ui"


def build_window(api: HexoManAPI):
    """建 pywebview 窗口。

    ``url`` 用 ``file://`` 指到打包好的 ``index.html``。CSS 和 JS 都是
    同目录的相对路径引用，所以整个 ``ui/`` 目录拷走也能跑。
    """
    import webview

    window = webview.create_window(
        "HexoMan",
        url=(UI_DIR / "index.html").as_uri(),
        js_api=api,
        width=1280,
        height=820,
        min_size=(960, 640),
        text_select=True,
    )
    return window


def main() -> int:
    try:
        import webview  # noqa: F401
    except ImportError:
        print(
            "缺少 pywebview。请先安装依赖：\n"
            "    python3 -m pip install -r requirements.txt",
            file=sys.stderr,
        )
        return 1

    api = HexoManAPI()

    # 探测一次用户真实的 shell 环境。从 Dock / 开始菜单启动的图形程序
    # 拿不到 .zshrc 里的 PATH，不探测的话「装了 node 却找不到」。
    # 只做一次，之后所有子进程都复用这份环境。
    try:
        api.prepareEnvironment()
    except Exception:  # noqa: BLE001 - 探测失败不该阻止应用启动
        pass

    window = build_window(api)

    # 关闭窗口时收尾：停掉预览服务、落盘设置
    def on_closing():
        api.shutdown()

    window.events.closing += on_closing

    print(f"HexoMan 启动中（{platform_name()}）…")
    webview.start()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
