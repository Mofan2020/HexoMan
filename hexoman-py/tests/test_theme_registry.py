"""主题市场：离线精选 + 联网补全。"""

from __future__ import annotations

import json

from hexoman.theme_registry import RegistryPackage, ThemeRegistry


def _payload(names: list[str], publisher=None, popularity: float = 0.5) -> bytes:
    objects = []
    for index, name in enumerate(names):
        objects.append(
            {
                "package": {
                    "name": name,
                    "version": f"1.0.{index}",
                    "description": f"{name} 的描述",
                    "publisher": publisher if publisher is not None else {"username": "someone"},
                    "links": {"homepage": f"https://example.com/{name}"},
                    "date": "2026-01-01",
                },
                "score": {"detail": {"popularity": popularity}},
            }
        )
    return json.dumps({"objects": objects}).encode("utf-8")


def test_offline_returns_catalog_only():
    registry = ThemeRegistry(fetch=lambda url, timeout: _payload([]))
    results = registry.search("", enabled=False)

    assert len(results) == 10
    assert all(item.weekly_downloads == 0 for item in results)


def test_offline_search_matches_package_name():
    results = ThemeRegistry.offline_catalog("hexo-theme-yun")
    assert [item.name for item in results] == ["hexo-theme-yun"]


def test_offline_search_matches_author():
    results = ThemeRegistry.offline_catalog("yunyoujun")
    assert results


def test_online_merges_and_dedupes():
    fetched = _payload(["hexo-theme-yun", "hexo-theme-brand-new"])

    registry = ThemeRegistry(fetch=lambda url, timeout: fetched)
    results = registry.search("", enabled=True)
    names = [item.name for item in results]

    # 离线精选在前，联网的新包在后面
    assert names[0] == "hexo-theme-yun"
    assert "hexo-theme-brand-new" in names
    # 重名不重复出现
    assert names.count("hexo-theme-yun") == 1


def test_online_filters_non_theme_packages():
    fetched = _payload(["left-pad", "hexo-theme-ok"])
    registry = ThemeRegistry(fetch=lambda url, timeout: fetched)

    results = registry.fetch_online("")
    assert [item.name for item in results] == ["hexo-theme-ok"]


def test_publisher_as_object_is_accepted():
    """``package.publisher`` 是对象——Swift 版曾把它当字符串，整批结果全废。

    这是「开了联网也搜不到」的真实根因，必须有测试盯着。
    """
    fetched = _payload(["hexo-theme-a"], publisher={"email": "x@y.z", "username": "alice"})
    registry = ThemeRegistry(fetch=lambda url, timeout: fetched)

    results = registry.fetch_online("")
    assert results[0].author == "alice"


def test_publisher_as_string_is_also_accepted():
    fetched = _payload(["hexo-theme-a"], publisher="bob")
    registry = ThemeRegistry(fetch=lambda url, timeout: fetched)

    assert registry.fetch_online("")[0].author == "bob"


def test_network_failure_falls_back_and_records_error():
    def boom(url: str, timeout: float) -> bytes:
        raise OSError("network down")

    registry = ThemeRegistry(fetch=boom)
    results = registry.search("", enabled=True)

    # 退回离线精选，而不是抛异常或返回空
    assert len(results) == 10
    # 但失败必须留痕——静默 fallback 会让「断网」和「解码全废」长得一样
    assert "network down" in registry.log.last_error


def test_decode_failure_recorded():
    registry = ThemeRegistry(fetch=lambda url, timeout: b"not json")
    results = registry.search("", enabled=True)

    assert len(results) == 10
    assert "decode" in registry.log.last_error


def test_success_recorded():
    fetched = _payload(["hexo-theme-yun"])
    registry = ThemeRegistry(fetch=lambda url, timeout: fetched)
    registry.search("", enabled=True)

    assert registry.log.last_error == ""
    assert registry.log.last_object_count == 1
    assert registry.log.last_kept_count == 1


def test_sorted_by_popularity():
    objects = {
        "objects": [
            {
                "package": {"name": "hexo-theme-low", "publisher": {"username": "a"}},
                "score": {"detail": {"popularity": 0.01}},
            },
            {
                "package": {"name": "hexo-theme-high", "publisher": {"username": "b"}},
                "score": {"detail": {"popularity": 0.9}},
            },
        ]
    }
    registry = ThemeRegistry(fetch=lambda url, timeout: json.dumps(objects).encode())
    results = registry.fetch_online("")

    assert results[0].name == "hexo-theme-high"


def test_malformed_score_does_not_crash():
    objects = {"objects": [{"package": {"name": "hexo-theme-x"}, "score": "weird"}]}
    registry = ThemeRegistry(fetch=lambda url, timeout: json.dumps(objects).encode())

    results = registry.fetch_online("")
    assert results[0].weekly_downloads == 0


def test_registry_package_short_name():
    package = RegistryPackage(name="hexo-theme-yun")
    assert package.short_name == "yun"
