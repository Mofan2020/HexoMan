"""自定义内容注入：「我想加个 banner / 统计代码 / 自定义 CSS，该往哪填？」

对应 Swift 侧的 ``CustomContent.swift``。

## 这是小白卡住频率最高的问题

答案对绝大多数用户都是「不知道」。常见误区是去 ``themes/landscape/layout/``
里改模板——那在 ``npm install`` 时会被直接覆盖，升级主题就白改一次。

## 做法

自动在站点里生成一对文件：

    <站点>/scripts/hexoman-inject.json   ← 你填的 HTML，HexoMan 管理
    <站点>/scripts/hexoman-inject.js     ← 注入逻辑，HexoMan 管理

生成的脚本走 Hexo 的 ``_after_html_render`` 钩子（**不是** ``after_generate``——
Hexo 8 里那个钩子的 data 是 null，拿不到 HTML 字符串），在每页的
``</head>`` / ``</body>`` 前插入内容。

放在 ``scripts/`` 目录而不是主题源码里，有三个好处：

- 升级主题、重新 ``npm install`` 都不会丢
- 不依赖主题支不支持某个注入目录，换任何主题都通用
- 删掉这两个文件就等于彻底关掉这个功能，没有任何残留
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .model import Site, read_text

__all__ = [
    "CustomContent",
    "CustomContentStore",
    "DetectedInjectScript",
]

#: 数据文件名。
DATA_FILE_NAME = "hexoman-inject.json"
#: 脚本文件名。
SCRIPT_FILE_NAME = "hexoman-inject.js"

#: 注入脚本模板。
#:
#: 写成纯 CommonJS、不引任何依赖，是为了在 Hexo 6/7/8 上都能跑。刻意不硬编码
#: 用户填的内容——内容放 JSON，脚本只管读，这样用户想手动微调 HTML 时也不需要
#: 碰 JS。
#:
#: **兼容两种入参形态是这里最重要的一件事。** ``_after_html_render`` 在不同
#: Hexo 版本里传的东西不一样：Hexo 8.1.2 实测传的是**字符串**，而传
#: ``{ path, content }`` 对象的版本也存在。早期版本这里写死 ``data.content``，
#: 在 8.1.2 上会让 filter 返回 ``undefined``——后果不是「没注入」，而是
#: **整站 HTML 被渲染成 0 字节**。所以这里先归一化成字符串，并且**任何分支
#: 都保证返回值非空**。
SCRIPT_TEMPLATE = """//
//  hexoman-inject.js
//  由 HexoMan 生成
//
//  作用：把 hexoman-inject.json 里填的 HTML 插到每页的 </head> 和 </body> 之前。
//  想改内容请用 HexoMan 的「配置 → 自定义内容」，或直接编辑同目录的 json。
//  删掉 hexoman-inject.json 和本文件即可完全关闭这个功能。
//

const fs = require('fs');
const path = require('path');

const dataFile = path.join(__dirname, 'hexoman-inject.json');

function loadContent() {
  try {
    return JSON.parse(fs.readFileSync(dataFile, 'utf8')) || {};
  } catch (error) {
    // 文件还没建或者写坏了，都按「不注入」处理，绝不让 hexo build 因此崩掉
    return {};
  }
}

// 关键：必须用 _after_html_render。
// after_generate 在 Hexo 8 里拿到的 data 是 null，没有 HTML 字符串可用。
hexo.extend.filter.register('_after_html_render', function (data) {
  // 不同 Hexo 版本传的形态不一样，先统一成字符串再处理。
  // 这里绝不能想当然写 data.content —— 在传字符串的版本上那会是 undefined。
  const isObject = data !== null && typeof data === 'object';
  const original = isObject ? (data.content || '') : String(data === undefined || data === null ? '' : data);

  let html = original;
  const content = loadContent();

  if (content.head) {
    html = html.indexOf('</head>') >= 0
      ? html.replace('</head>', content.head + '\\n</head>')
      : content.head + '\\n' + html;
  }

  if (content.body) {
    html = html.indexOf('</body>') >= 0
      ? html.replace('</body>', content.body + '\\n</body>')
      : html + '\\n' + content.body;
  }

  // 兜底：任何情况下都不能返回空。返回空等于把用户整个站点渲染成 0 字节。
  if (!html) {
    return data;
  }

  return isObject ? Object.assign({}, data, { content: html }) : html;
});
"""


@dataclass
class CustomContent:
    """用户想在每页插入的自定义内容。"""

    #: 插在 ``</head>`` 之前。放 CSS、统计脚本、字体。
    head: str = ""
    #: 插在 ``</body>`` 之前。放 banner 挂件、悬浮按钮。
    body: str = ""

    @property
    def is_empty(self) -> bool:
        return not self.head.strip() and not self.body.strip()

    def to_dict(self) -> dict[str, Any]:
        return {"head": self.head, "body": self.body, "isEmpty": self.is_empty}


class CustomContentStore:
    """读写注入配置与脚本。"""

    # -- 路径 ---------------------------------------------------------

    @staticmethod
    def data_path(site: Site) -> str:
        return str(Path(site.path) / "scripts" / DATA_FILE_NAME)

    @staticmethod
    def script_path(site: Site) -> str:
        return str(Path(site.path) / "scripts" / SCRIPT_FILE_NAME)

    @staticmethod
    def is_installed(site: Site) -> bool:
        """站点是否已经启用了注入。"""
        return (
            Path(CustomContentStore.data_path(site)).is_file()
            or Path(CustomContentStore.script_path(site)).is_file()
        )

    # -- 读 -----------------------------------------------------------

    @staticmethod
    def load(site: Site) -> CustomContent:
        """读回用户填的内容。文件不存在或格式不对都按空处理。"""
        text = read_text(CustomContentStore.data_path(site))
        if text is None:
            return CustomContent()

        try:
            data = json.loads(text)
        except ValueError:
            return CustomContent()

        if not isinstance(data, dict):
            return CustomContent()

        head = data.get("head")
        body = data.get("body")
        return CustomContent(
            head=head if isinstance(head, str) else "",
            body=body if isinstance(body, str) else "",
        )

    # -- 写 -----------------------------------------------------------

    @staticmethod
    def save(content: CustomContent, site: Site) -> None:
        """保存内容。

        顺带把脚本文件一起写上——用户不该需要点两次才生效。
        """
        directory = Path(site.path) / "scripts"
        directory.mkdir(parents=True, exist_ok=True)

        # 带 BOM 的 JSON 在某些 Node 版本上会解析失败，所以显式用不带 BOM 的 UTF-8。
        payload = {"head": content.head, "body": content.body}
        data_path = Path(CustomContentStore.data_path(site))
        temp = data_path.with_name(data_path.name + ".hexoman-tmp")
        temp.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        os.replace(temp, data_path)

        script_path = Path(CustomContentStore.script_path(site))
        if not script_path.is_file():
            script_path.write_text(SCRIPT_TEMPLATE, encoding="utf-8")

    @staticmethod
    def remove(site: Site) -> None:
        """关掉注入：删掉这两个文件。站点回到「完全没动过」的状态。"""
        for path in (
            CustomContentStore.data_path(site),
            CustomContentStore.script_path(site),
        ):
            try:
                Path(path).unlink(missing_ok=True)
            except OSError:
                pass


@dataclass
class DetectedInjectScript:
    """站点 ``scripts/`` 目录下一个**会往生成结果里插东西**的脚本。

    为什么需要识别：

    Hexo 会自动加载站点根目录 ``scripts/`` 下的所有 js，所以用户（或者教程、
    AI）完全可能自己放一个 ``banner.js`` 之类的注入脚本。这种脚本完全有效，
    但 HexoMan 原先只认自己那两个文件名，于是会出现**界面说「未启用」、站点上
    横幅其实天天在显示**的错位——用户会以为自己配错了，实际上是工具没看见。

    识别出来之后至少能如实告诉用户「你已经有注入脚本了」，指出它在插什么、
    插到哪，避免再配一份导致同一段内容出现两次。
    """

    path: str
    file_name: str
    #: 注册的 Hexo 钩子名，例如 ``_after_html_render``
    hooks: list[str] = None  # type: ignore[assignment]
    #: 插入的位置，例如 ``</body>``
    inserts_into: list[str] = None  # type: ignore[assignment]
    #: 脚本里引用的外部资源（src/href）
    external_sources: list[str] = None  # type: ignore[assignment]
    #: 是否是 HexoMan 自己生成的那个
    is_managed_by_hexoman: bool = False

    def __post_init__(self) -> None:
        if self.hooks is None:
            self.hooks = []
        if self.inserts_into is None:
            self.inserts_into = []
        if self.external_sources is None:
            self.external_sources = []

    @property
    def id(self) -> str:
        return self.path

    @property
    def summary(self) -> str:
        """一句话概括。"""
        if not self.hooks:
            return "未识别到 Hexo 钩子"
        parts = [", ".join(self.hooks)]
        if self.inserts_into:
            parts.append("插入到 " + "、".join(self.inserts_into) + " 前")
        return " · ".join(parts)

    @property
    def source_description(self) -> str:
        if not self.external_sources:
            return "没有引用外部资源"
        return "\n".join(self.external_sources)

    def to_dict(self) -> dict[str, Any]:
        return {
            "path": self.path,
            "fileName": self.file_name,
            "hooks": list(self.hooks),
            "insertsInto": list(self.inserts_into),
            "externalSources": list(self.external_sources),
            "isManagedByHexoMan": self.is_managed_by_hexoman,
            "summary": self.summary,
            "sourceDescription": self.source_description,
        }


_HOOK_PATTERN = re.compile(
    r"""hexo\.extend\.filter\.register\s*\(\s*['"]([^'"]+)['"]"""
)
_REFERENCE_PATTERN = re.compile(r"""(?:src|href)\s*=\s*['"]([^'"]+)['"]""")
_JS_URL_PATTERN = re.compile(r"""['"](https?://[^'"]+?\.js)['"]""")

#: 太大的文件不扫，免得为了一个 2MB 的库文件去跑一堆正则
_MAX_SCAN_BYTES = 512 * 1024


def detected_inject_scripts(site: Site) -> list[DetectedInjectScript]:
    """扫描站点的 ``scripts/`` 目录，找出所有注入脚本（含 HexoMan 自己的）。

    只认这几种「真的会改生成结果」的形式：

    - ``hexo.extend.filter.register('<hook>', …)``
    - 内容插到 ``</head>`` / ``</body>`` / ``</html>`` 前面

    刻意不做完整 JS 解析——站点里的脚本是用户自己写的，宁可漏报也不要给出一堆
    误报把界面搞脏。
    """
    scripts_dir = Path(site.path) / "scripts"
    if not scripts_dir.is_dir():
        return []

    results: list[DetectedInjectScript] = []

    for path in sorted(scripts_dir.rglob("*.js")):
        if any(part.startswith(".") for part in path.relative_to(scripts_dir).parts):
            continue

        try:
            if path.stat().st_size >= _MAX_SCAN_BYTES:
                continue
        except OSError:
            continue

        text = read_text(path)
        if text is None:
            continue

        hooks = _HOOK_PATTERN.findall(text)
        inserts = [
            tag for tag in ("</head>", "</body>", "</html>") if tag in text
        ]

        # 只有「注册了钩子」或「提到了插入位置」才算是注入脚本。
        # scripts/ 里经常还放着别的工具脚本，不能一律当成注入。
        if not hooks and not inserts:
            continue

        sources = _REFERENCE_PATTERN.findall(text) + _JS_URL_PATTERN.findall(text)

        relative = path.relative_to(scripts_dir)
        results.append(
            DetectedInjectScript(
                path=str(path),
                file_name=path.name,
                hooks=sorted(set(hooks)),
                inserts_into=inserts,
                external_sources=sorted(set(sources)),
                is_managed_by_hexoman=(path.name == SCRIPT_FILE_NAME),
            )
        )

    results.sort(key=lambda item: item.file_name)
    return results
