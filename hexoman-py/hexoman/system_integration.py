"""与系统打交道的平台差异，全部集中在这里。

对应 Swift 侧的 ``SystemIntegration.swift``。存在的理由和 Swift 版一样：
「在文件管理器里显示」「用默认程序打开」这类事在 macOS 和 Windows 上
是两套完全不同的 API。散落在各处的话，改平台时会漏掉一半。

**这个模块里不允许出现 Linux 分支** —— 项目只支持 Windows 和 macOS，
写一个跑不到的分支等于给自己埋一个永远不会被发现的 bug。
"""

from __future__ import annotations

import os
import subprocess
import sys

__all__ = [
    "platform_name",
    "open_path",
    "reveal_in_file_manager",
    "open_url",
    "choose_directory",
    "choose_images",
    "copy_to_clipboard",
]


def platform_name() -> str:
    """当前平台的可读名字。"""
    if sys.platform == "darwin":
        return "macOS"
    if os.name == "nt":
        return "Windows"
    return sys.platform


def open_path(path: str) -> None:
    """用系统默认程序打开文件或目录。"""
    if not path or not os.path.exists(path):
        return

    if os.name == "nt":
        os.startfile(path)  # type: ignore[attr-defined]
    else:
        subprocess.run(["open", path], check=False)


def reveal_in_file_manager(path: str) -> None:
    """在文件管理器里选中这个文件。

    macOS 用 ``open -R``，Windows 用 ``explorer.exe /select,``。
    两者都是「打开目录并高亮选中项」，不会误删或移动任何东西。
    """
    if not path or not os.path.exists(path):
        return

    if os.name == "nt":
        subprocess.run(["explorer.exe", f"/select,{os.path.abspath(path)}"], check=False)
    else:
        subprocess.run(["open", "-R", path], check=False)


def open_url(url: str) -> None:
    """用默认浏览器打开 URL。"""
    if not url:
        return

    if os.name == "nt":
        os.startfile(url)  # type: ignore[attr-defined]
    else:
        subprocess.run(["open", url], check=False)


def choose_directory(title: str = "选择站点目录") -> str:
    """弹目录选择框。

    用 Tk 的原生文件对话框：macOS 上是 NSOpenPanel 风格，Windows 上是
    传统的「浏览文件夹」对话框，两个平台都是系统原生的。

    没有 Tk（无头环境、或者精简安装的 Python）时返回空字符串，
    让调用方退回到「手动粘贴路径」。
    """
    try:
        import tkinter
        from tkinter import filedialog
    except ImportError:
        return ""

    try:
        root = tkinter.Tk()
    except Exception:
        return ""

    try:
        root.withdraw()
        root.attributes("-topmost", True)
        selected = filedialog.askdirectory(title=title)
        return selected or ""
    except Exception:
        return ""
    finally:
        try:
            root.destroy()
        except Exception:
            pass


def choose_images(title: str = "选择图片") -> list[str]:
    """弹图片选择框（可多选），返回选中的文件路径。

    用 pywebview 自己的原生文件对话框：macOS 上是 NSOpenPanel，
    Windows 上是系统的打开对话框。没有窗口时（无头环境、单元测试）
    返回空列表，让调用方安静地什么都不做。
    """
    try:
        import webview
    except ImportError:
        return []

    try:
        window = webview.active_window()
    except Exception:
        return []

    if window is None:
        return []

    try:
        selected = window.create_file_dialog(
            allow_multiple=True,
            file_types=(
                "图片 (*.png;*.jpg;*.jpeg;*.gif;*.webp;*.bmp;*.heic;*.heif)",
            ),
        )
    except Exception:
        return []

    if not selected:
        return []
    return [str(item) for item in selected]


def copy_to_clipboard(text: str) -> bool:
    """把文本放进系统剪贴板。

    macOS 用 ``pbcopy``，Windows 用 ``clip``。都失败时返回 ``False``，
    界面据此提示用户手动复制。
    """
    if not text:
        return False

    try:
        if os.name == "nt":
            completed = subprocess.run(
                ["clip"], input=text, text=True, check=False, capture_output=True
            )
        else:
            completed = subprocess.run(
                ["pbcopy"], input=text, text=True, check=False, capture_output=True
            )
        return completed.returncode == 0
    except (OSError, ValueError):
        return False


def app_data_directory() -> str:
    """本应用的配置目录。

    macOS 是 ``~/Library/Application Support/HexoManPy``，
    Windows 是 ``%APPDATA%/HexoManPy``。跟系统的惯例走，别自造位置。

    **刻意不跟 Swift 版共用同一个目录**。Swift 版写的是
    ``~/Library/Application Support/HexoMan/settings.json``，字段名和语义
    都不完全一样（Swift 存 ``language: "system"``，Python 版不认这个值）。
    共用一个文件的话，两边会互相覆盖对方的设置——用户装了两个应用，
    结果 Swift 版的站点列表被 Python 版清掉。
    """
    if os.name == "nt":
        base = os.environ.get("APPDATA") or os.path.join(
            os.path.expanduser("~"), "AppData", "Roaming"
        )
    else:
        base = os.path.join(os.path.expanduser("~"), "Library", "Application Support")
    return os.path.join(base, "HexoManPy")
