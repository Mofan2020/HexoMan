"""插图（SiteMedia）与代码片段（SnippetLibrary）。"""

from __future__ import annotations

import datetime as _dt
from pathlib import Path

from hexoman.site_media import SiteMedia
from hexoman.snippet_library import SnippetLibrary


PNG = b"\x89PNG\r\n\x1a\n" + b"0" * 16
JPG = b"\xff\xd8\xff" + b"0" * 16


# -- SiteMedia ---------------------------------------------------------


def test_sanitize_replaces_bad_characters():
    assert SiteMedia.sanitize("截屏 2026-11-13") == "截屏-2026-11-13"
    assert SiteMedia.sanitize("a/b\\c") == "a-b-c"
    assert SiteMedia.sanitize("///") == "image"
    assert SiteMedia.sanitize("x" * 100) == "x" * 60


def test_image_directory_uses_year(tmp_path: Path):
    directory = SiteMedia.image_directory(str(tmp_path), _dt.date(2026, 5, 1))
    assert directory == tmp_path / "source" / "images" / "2026"


def test_unique_destination_does_not_overwrite(tmp_path: Path):
    first = SiteMedia.unique_destination(tmp_path, "pic", "png")
    assert first.name == "pic-1.png"

    first.write_bytes(PNG)
    second = SiteMedia.unique_destination(tmp_path, "pic", "png")
    assert second.name == "pic-2.png"


def test_store_writes_file_and_returns_markdown(tmp_path: Path):
    stored = SiteMedia.store(
        PNG, "截屏2026.png", str(tmp_path), base="hello", date=_dt.date(2026, 1, 2)
    )

    assert Path(stored.path).is_file()
    assert stored.relative_path.startswith("/images/2026/")
    assert stored.markdown.startswith("![截屏2026](")
    assert stored.markdown.endswith(")")


def test_store_never_overwrites_same_name(tmp_path: Path):
    first = SiteMedia.store(PNG, "a.png", str(tmp_path), base="same", date=_dt.date(2026, 1, 1))
    second = SiteMedia.store(PNG, "a.png", str(tmp_path), base="same", date=_dt.date(2026, 1, 1))

    assert first.relative_path != second.relative_path
    assert Path(first.path).is_file()
    assert Path(second.path).is_file()


def test_markdown_uses_placeholder_when_alt_empty():
    assert SiteMedia.markdown("/images/a.png", "") == "![图片](/images/a.png)"


def test_normalize_sniffs_extension():
    payload, extension = SiteMedia.normalize(PNG, "noext")
    assert extension == "png"
    payload, extension = SiteMedia.normalize(JPG, "noext")
    assert extension == "jpg"


def test_normalize_jpeg_becomes_jpg():
    assert SiteMedia.normalize(JPG, "a.jpeg") == (JPG, "jpg")


def test_normalize_unknown_extension_falls_back_to_sniff():
    payload, extension = SiteMedia.normalize(JPG, "a.xyz")
    assert extension == "jpg"


def test_sniff_detects_formats():
    assert SiteMedia.sniff_extension(PNG) == "png"
    assert SiteMedia.sniff_extension(JPG) == "jpg"
    assert SiteMedia.sniff_extension(b"GIF89a") == "gif"
    assert SiteMedia.sniff_extension(b"RIFF0000WEBP") == "webp"


def test_normalize_heic_keeps_png_name():
    """HEIC 浏览器不认，必须给 png 扩展名（转不动也照写）。"""
    payload, extension = SiteMedia.normalize(b"not-an-image", "photo.heic")
    assert extension == "png"


def test_alt_text_strips_extension():
    assert SiteMedia.alt_text("/tmp/我的图.png") == "我的图"


def test_read_file_missing_returns_none(tmp_path: Path):
    assert SiteMedia.read_file(str(tmp_path / "nope.png")) is None


# -- SnippetLibrary ----------------------------------------------------


def test_library_has_snippets():
    assert len(SnippetLibrary.ALL) >= 10
    assert SnippetLibrary.find("custom-css") is not None
    assert SnippetLibrary.find("nope") is None


def test_snippets_for_target():
    head = SnippetLibrary.snippets_for("head")
    body = SnippetLibrary.snippets_for("body")

    assert head and body
    assert all(item.target == "head" for item in head)
    assert all(item.target == "body" for item in body)


def test_instantiate_replaces_placeholders():
    snippet = SnippetLibrary.find("google-analytics")
    assert snippet is not None

    code, missing = SnippetLibrary.instantiate(snippet, {"ga": "G-ABC123"})

    assert "G-ABC123" in code
    assert "__GA_ID__" not in code
    assert missing == []


def test_instantiate_reports_missing_placeholders():
    snippet = SnippetLibrary.find("google-analytics")
    assert snippet is not None

    code, missing = SnippetLibrary.instantiate(snippet, {})

    # 没填的占位原样留着，但必须提醒
    assert "__GA_ID__" in code
    assert "衡量 ID" in missing


def test_instantiate_ignores_blank_values():
    snippet = SnippetLibrary.find("umami")
    assert snippet is not None

    code, missing = SnippetLibrary.instantiate(snippet, {"website": "   "})
    assert "__UMAMI_WEBSITE_ID__" in code
    assert missing


def test_snippet_without_placeholders_needs_nothing():
    snippet = SnippetLibrary.find("custom-css")
    assert snippet is not None

    code, missing = SnippetLibrary.instantiate(snippet, {})
    assert code == snippet.code
    assert missing == []


def test_target_labels():
    assert SnippetLibrary.find("custom-css").target_label == "</head> 前"
    assert SnippetLibrary.find("custom-js").target_label == "</body> 前"
