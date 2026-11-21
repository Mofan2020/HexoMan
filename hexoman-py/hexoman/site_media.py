"""往站点里放图片。

对应 Swift 侧的 ``SiteMedia.swift``。

## 为什么要有这一层

Hexo 的图片有两种写法：

- ``![](/images/x.png)``——放 ``source/images`` 下，**任何主题、任何配置都认**
- ``{% asset_img %}``——文章资源文件夹，要求站点开了 ``post_asset_folder``

后者依赖配置，前者永远能用，所以这里一律写前者。

## 三个决定（和 Swift 版一致）

- **放 ``source/images/<年>/``**：``source/`` 就是站点根，主题怎么换这个路径都不变。
- **同名不覆盖，加 ``-1``、``-2``**：截图默认文件名大量重名（「截屏2026-11-13」），
  覆盖掉的话正文里先插的那张会在用户不知情时被换掉。
- **HEIC 转 PNG**：iPhone 截图默认是 HEIC，浏览器不认，原样插进去只会得到
  一张裂图。

## 与 Swift 版的差异

Swift 用 ``NSBitmapImageRep`` 重编码；Python 版在 Pillow 可用时用它转，
不可用时**原样写入但扩展名仍给 png**（和 Swift 转换失败时的行为一致）。
装不装 Pillow 都不影响其它功能。
"""

from __future__ import annotations

import datetime as _dt
import os
import re
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

__all__ = ["StoredMedia", "SiteMedia"]

#: 支持直接落盘的扩展名。HEIC/HEIF 例外——浏览器不认，得转 PNG。
WRITABLE_EXTENSIONS = frozenset({"png", "jpg", "jpeg", "gif", "webp", "svg", "avif"})


@dataclass
class StoredMedia:
    """一次插图的结果。"""

    #: 磁盘上的绝对路径
    path: str
    #: 相对站点根目录的路径，以 ``/`` 开头，如 ``/images/2026/hello-1.png``
    relative_path: str
    #: 直接能贴进正文的 Markdown
    markdown: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "path": self.path,
            "relativePath": self.relative_path,
            "markdown": self.markdown,
        }


class SiteMedia:
    """插图。"""

    # -- 路径 ---------------------------------------------------------

    @staticmethod
    def image_directory(site: str, date: _dt.date | None = None) -> Path:
        """``<site>/source/images/<yyyy>``。"""
        year = str((date or _dt.date.today()).year)
        return Path(site) / "source" / "images" / year

    @staticmethod
    def sanitize(raw: str) -> str:
        """文件名里能用的字符：字母数字、汉字、``-``、``_``。其余折成 ``-``。"""
        # 保留中文、字母、数字；其余一律换成短横线
        cleaned = re.sub(r"[^0-9A-Za-z一-鿿_-]", "-", raw)
        while "--" in cleaned:
            cleaned = cleaned.replace("--", "-")
        cleaned = cleaned.strip("-_ ")
        if not cleaned:
            cleaned = "image"
        return cleaned[:60]

    @staticmethod
    def unique_destination(directory: Path, base: str, extension: str) -> Path:
        """在目录里挑一个没被占用的文件名：``base-1.png``、``base-2.png``……

        **不覆盖已有文件**。同名图很常见，覆盖掉的话正文里先插的那张会在
        用户不知情的时候换掉。
        """
        stem = SiteMedia.sanitize(base)
        suffix = extension.lower()

        for index in range(1, 10000):
            candidate = directory / f"{stem}-{index}.{suffix}"
            if not candidate.exists():
                return candidate

        # 一万张同名图是不可能的，兜底给个唯一名字，别转死循环。
        unique = uuid.uuid4().hex[:8]
        return directory / f"{stem}-{unique}.{suffix}"

    # -- 存图 ---------------------------------------------------------

    @staticmethod
    def store(
        data: bytes,
        filename: str,
        site: str,
        base: str = "",
        date: _dt.date | None = None,
    ) -> StoredMedia:
        """把一张图写进站点，返回可以直接插进正文的 Markdown。"""
        payload, extension = SiteMedia.normalize(data, filename)

        directory = SiteMedia.image_directory(site, date)
        directory.mkdir(parents=True, exist_ok=True)

        stem = base.strip() or "image"
        destination = SiteMedia.unique_destination(directory, stem, extension)

        temp = destination.with_name(destination.name + ".hexoman-tmp")
        temp.write_bytes(payload)
        os.replace(temp, destination)

        year = directory.name
        relative_path = f"/images/{year}/{destination.name}"

        return StoredMedia(
            path=str(destination),
            relative_path=relative_path,
            markdown=SiteMedia.markdown(relative_path, SiteMedia.alt_text(filename)),
        )

    @staticmethod
    def markdown(relative_path: str, alt: str = "") -> str:
        """Markdown 引用。前后各留一个空行由调用方决定——这里只给这一行。"""
        trimmed = alt.strip()
        return f"![{trimmed if trimmed else '图片'}]({relative_path})"

    @staticmethod
    def alt_text(filename: str) -> str:
        """从文件名取 alt 文案。"""
        stem = os.path.splitext(os.path.basename(filename))[0]
        return stem.strip()

    # -- 格式归一 -----------------------------------------------------

    @staticmethod
    def normalize(data: bytes, filename: str) -> tuple[bytes, str]:
        """返回要写盘的字节和建议扩展名。

        HEIC/HEIF 是 iPhone 截图的默认格式，浏览器不认；原样插进去只会得到
        一张裂图。这里尽量转成 PNG。
        """
        raw_extension = os.path.splitext(filename)[1].lstrip(".").lower()
        extension = raw_extension or SiteMedia.sniff_extension(data)

        if extension in ("heic", "heif"):
            converted = SiteMedia.png_bytes(data)
            # 转不动也照写，至少名字是对的（和 Swift 版行为一致）
            return (converted if converted else data), "png"

        if extension == "jpeg":
            return data, "jpg"

        if extension in WRITABLE_EXTENSIONS:
            return data, extension

        return data, SiteMedia.sniff_extension(data)

    @staticmethod
    def sniff_extension(data: bytes) -> str:
        """数据本身的第一段字节就够判断常见图片格式了。"""
        head = data[:12]
        if head.startswith(b"\x89PNG"):
            return "png"
        if head.startswith(b"\xff\xd8\xff"):
            return "jpg"
        if head.startswith(b"GIF"):
            return "gif"
        if len(head) >= 12 and head[:4] == b"RIFF" and head[8:12] == b"WEBP":
            return "webp"
        return "png"

    @staticmethod
    def png_bytes(data: bytes) -> bytes | None:
        """把图片解码再编成 PNG；解不开或没有 Pillow 就返回 ``None``。"""
        try:
            from io import BytesIO

            from PIL import Image  # type: ignore[import-not-found]
        except ImportError:
            return None

        try:
            with Image.open(BytesIO(data)) as image:
                buffer = BytesIO()
                image.save(buffer, format="PNG")
                return buffer.getvalue()
        except Exception:
            return None

    @staticmethod
    def read_file(path: str) -> bytes | None:
        """读磁盘上的图片（拖进来的文件走这条）。"""
        try:
            return Path(path).read_bytes()
        except OSError:
            return None
