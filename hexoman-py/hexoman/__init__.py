"""HexoMan — Python + PyWebView 版的 Hexo 站点管理工具。

包内分层（界面不碰文件系统）：

- ``model`` / ``frontmatter`` / ``yamlutil``  —— 纯数据与解析
- ``sites`` / ``posts``                        —— 站点与文章的读写
- ``process`` / ``hexo_cli`` / ``git_service`` —— 外部命令
- ``markdown_render``                          —— Markdown 预览渲染
- ``system_integration``                       —— 平台差异集中地
- ``i18n``                                     —— 中英文案
- ``api``                                      —— 暴露给前端的 ``window.hexoman``
"""

__version__ = "0.1.0"

__all__ = ["__version__"]
