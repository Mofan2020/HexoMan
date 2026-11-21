"""主题市场 = 内置精选 + 联网补全。

对应 Swift 侧的 ``ThemeRegistry.swift``。

## 联网行为有边界

- 只读 npm registry（``registry.npmjs.org``）拿主题包元数据
- 不传用户站点信息
- 不写、不传 Cookie
- 完全离线也能用离线精选列表

「是否允许联网补全」由用户在设置项里放明——默认关，首次进主题市场时提示
一次，后面可去设置里再次切换。

## npm registry 协议

    GET https://registry.npmjs.org/-/v1/search?text=hiro-theme&size=25

响应是 JSON，``objects[]`` 是搜索结果，每个 item 含
``package.{name, version, description, links, publisher, date}``。

## 一个曾经让整个功能静默失效的坑

``package.publisher`` 在 search 接口里是**对象** ``{"email":..,"username":..}``，
不是字符串。Swift 版曾经把它声明成 ``String?``，真实响应一解码就
``typeMismatch`` 抛出去，整个 ``objects`` 全废，再被 catch 吞掉、静默退回离线
10 条——表现就是「开了联网也搜不到，一条在线结果都没有」。

这里从一开始就**同时接受对象和裸字符串**，并且把失败原因写进
``last_error``，界面能如实显示「为什么搜不到」。
"""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Callable

from .theme_manager import ThemeCatalog

__all__ = ["RegistryPackage", "ThemeRegistry", "ThemeLog"]

#: npm 搜索 API。固定 endpoint，不让用户改（避免被投毒）。
SEARCH_ENDPOINT = "https://registry.npmjs.org/-/v1/search"

#: 单页结果数。npm 上限是 250，hexo 主题总共不到 100 个，25 个一页就够。
PAGE_SIZE = 25


@dataclass
class RegistryPackage:
    """npm registry 上的单个主题包。

    不是 npm 的完整 schema，只取 HexoMan 关心的几个字段。
    """

    #: 包名（含 ``hexo-theme-`` 前缀）
    name: str
    version: str = ""
    description: str = ""
    author: str = ""
    homepage: str = ""
    #: npm 上的周下载量（按 popularity 粗估）。用来给候选排序。
    weekly_downloads: int = 0
    date: str = ""

    @property
    def id(self) -> str:
        return self.name

    @property
    def short_name(self) -> str:
        from .theme_manager import ThemeManager

        return ThemeManager.short_name(self.name)

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "shortName": self.short_name,
            "version": self.version,
            "description": self.description,
            "author": self.author,
            "homepage": self.homepage,
            "weeklyDownloads": self.weekly_downloads,
            "date": self.date,
        }


class ThemeLog:
    """主题市场联网行为的统一日志出口。

    之前 Swift 版 ``search`` 的失败路径是纯静默 fallback，导致「HTTP 200 但
    解码全废」和「真的断网」在界面上完全一样，排查只能靠猜。上一版就是因此
    误判成「搜索能走通」，实际上一条在线结果都进不来。

    这里把每次搜索的结论留在实例上（``last_error`` / ``last_status``），
    诊断页和界面都能直接看到。
    """

    def __init__(self) -> None:
        self.last_error: str = ""
        self.last_status: int | None = None
        self.last_query: str = ""
        self.last_object_count: int = 0
        self.last_kept_count: int = 0

    def success(self, query: str, object_count: int, kept_count: int) -> None:
        self.last_error = ""
        self.last_status = None
        self.last_query = query
        self.last_object_count = object_count
        self.last_kept_count = kept_count

    def failure(self, query: str, error: str, status: int | None = None) -> None:
        self.last_error = error
        self.last_status = status
        self.last_query = query

    def to_dict(self) -> dict[str, Any]:
        return {
            "error": self.last_error,
            "status": self.last_status,
            "query": self.last_query,
            "objectCount": self.last_object_count,
            "keptCount": self.last_kept_count,
        }


class ThemeRegistry:
    """在线搜索 + 离线 fallback 混合层。

    离线时直接返回 :class:`ThemeCatalog` 的内置精选；在线时往 npm registry
    查关键词，结果合并：

    1. 离线精选排前面（永远在那儿）
    2. 联网结果按下载量排序、去重
    3. 不覆盖用户的「已安装主题」——那是单独的 ``ThemeManager.installed()``
    """

    def __init__(
        self,
        fetch: Callable[[str, float], bytes] | None = None,
        logger: ThemeLog | None = None,
        timeout: float = 10.0,
    ) -> None:
        #: 可注入的 HTTP 取数函数（测试用，避免真的联网）
        self._fetch = fetch or _default_fetch
        self.log = logger or ThemeLog()
        self.timeout = timeout

    # -- 搜索 ---------------------------------------------------------

    def search(
        self, query: str = "", enabled: bool = False
    ) -> list[RegistryPackage]:
        """搜索 hexo 主题。

        ``enabled=False`` 时只返回离线精选——这是默认行为，用户没主动开
        联网就不该被联出去。
        """
        if not enabled:
            return self.offline_catalog(query)

        # 每次搜索重新开始记日志，别让上一次的结论污染这一次。
        self.log.last_error = ""

        try:
            online = self.fetch_online(query)
        except Exception as error:  # noqa: BLE001 - 任何失败都退回离线
            # 联网失败（断网、超时、JSON 解析错）一律退化到离线模式。
            # 用户体验比显示错误好——主题页本来就有「离线」按钮文案。
            # 但**必须留痕**，否则「解码全废」和「真的断网」长得一模一样。
            #
            # 已经记过更具体的错误（比如解码失败）就不要被这层的泛化消息盖掉。
            if not self.log.last_error:
                self.log.failure(query, str(error), getattr(error, "status", None))
            return self.offline_catalog(query)

        # 合并：离线精选永远在最前（用户已经知道 / 信任的），后面是联网结果。
        # 重名时**离线精选胜**——内置里写的是经手工核对过元数据的。
        seen: set[str] = set()
        merged: list[RegistryPackage] = []

        for item in self.offline_catalog(query):
            if item.name not in seen:
                seen.add(item.name)
                merged.append(item)

        for item in online:
            if item.name not in seen:
                seen.add(item.name)
                merged.append(item)

        return merged

    # -- 离线精选 -----------------------------------------------------

    @staticmethod
    def offline_catalog(query: str = "") -> list[RegistryPackage]:
        """把内置 :class:`ThemeCatalog` 转成 :class:`RegistryPackage`。

        这里**不**查 npm——本地数据，下载量永远是 0。
        """
        trimmed = query.strip().lower()
        results: list[RegistryPackage] = []

        for item in ThemeCatalog.ITEMS:
            if trimmed and not _matches(item, trimmed):
                continue
            results.append(
                RegistryPackage(
                    name=item.package_name,
                    version="",
                    description=item.summary,
                    author=item.author,
                    homepage=item.homepage,
                )
            )

        return results

    # -- 联网 ---------------------------------------------------------

    def fetch_online(self, query: str) -> list[RegistryPackage]:
        """调 npm search。

        用文本匹配关键词（不是 ``keywords:`` 字段过滤）——hexo 主题的
        keywords 不一定含 ``hexo-theme``（很多主题用 ``blog`` ``static``），
        文本匹配更可靠。
        """
        trimmed = query.strip()
        params = urllib.parse.urlencode(
            {
                "text": trimmed if trimmed else "hexo-theme",
                "size": str(PAGE_SIZE),
            }
        )
        url = f"{SEARCH_ENDPOINT}?{params}"

        payload = self._fetch(url, self.timeout)
        try:
            data = json.loads(payload.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as error:
            self.log.failure(query, f"decode: {error}", 200)
            raise

        objects = data.get("objects") if isinstance(data, dict) else None
        if not isinstance(objects, list):
            self.log.failure(query, "响应里没有 objects 数组", 200)
            return []

        results: list[RegistryPackage] = []
        for entry in objects:
            if not isinstance(entry, dict):
                continue
            package = entry.get("package")
            if not isinstance(package, dict):
                continue

            name = package.get("name")
            if not isinstance(name, str) or not name.startswith("hexo-theme-"):
                continue

            results.append(
                RegistryPackage(
                    name=name,
                    version=_text(package.get("version")),
                    description=_text(package.get("description")),
                    # npm 不同接口在 publisher 上并不一致：search 返回对象，
                    # 少数据接口返回裸字符串。两种都认。
                    author=_publisher_name(package.get("publisher")),
                    homepage=_homepage(package.get("links")),
                    weekly_downloads=_weekly_downloads(entry),
                    date=_text(package.get("date")),
                )
            )

        # 按下载量倒序：用户想先看到「大家在用的」
        results.sort(key=lambda item: item.weekly_downloads, reverse=True)

        self.log.success(query, len(objects), len(results))
        return results


def _default_fetch(url: str, timeout: float) -> bytes:
    """默认的 HTTP 取数。只 GET，不带 cookie。"""
    request = urllib.request.Request(  # noqa: S310 - 固定 https endpoint
        url,
        headers={
            # npm 要求带 Accept 头才能返回 JSON（否则返回 HTML）。
            "Accept": "application/json",
            "User-Agent": "HexoMan-Py/0.1 (+https://github.com/Mofan2020/HexoMan)",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310
            return response.read()
    except urllib.error.HTTPError as error:
        error.status = error.code  # type: ignore[attr-defined]
        raise


def _text(value: Any) -> str:
    return value if isinstance(value, str) else ""


def _publisher_name(value: Any) -> str:
    """``publisher`` 既可能是对象也可能是裸字符串。"""
    if isinstance(value, dict):
        username = value.get("username")
        return username if isinstance(username, str) else ""
    if isinstance(value, str):
        return value
    return ""


def _homepage(links: Any) -> str:
    if isinstance(links, dict):
        homepage = links.get("homepage")
        if isinstance(homepage, str):
            return homepage
    return ""


def _weekly_downloads(entry: dict[str, Any]) -> int:
    """npm popularity 是 0~1，乘 10 万估下载量（粗估，仅用于排序）。"""
    score = entry.get("score")
    if not isinstance(score, dict):
        return 0
    detail = score.get("detail")
    if not isinstance(detail, dict):
        return 0
    popularity = detail.get("popularity")
    if not isinstance(popularity, (int, float)):
        return 0
    return int(popularity * 100_000)


def _matches(item: Any, query: str) -> bool:
    """离线搜索的匹配判定。查询词已 lowercased。

    覆盖用户真会敲的东西：主题短名、完整包名（``hexo-theme-yun``）、作者、
    描述。以前只比 name / description / author 三个字段，于是敲
    ``hexo-theme-`` 这种前缀全查不到——用户以为搜索坏了。
    """
    haystacks = [
        item.name,
        item.package_name,
        item.author,
        item.homepage,
        item.summary,
    ]
    return any(query in haystack.lower() for haystack in haystacks if haystack)
