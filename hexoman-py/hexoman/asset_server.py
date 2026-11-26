"""预览用的本地静态资源服务。

文章里的图片写的是站点内的相对路径（``/images/2026/11/a.png``），而界面
是从 ``file://`` 打开的——相对路径会指到文件系统根目录，必然裂图。

这里起一个只读的小 HTTP 服务，把站点目录里的文件按 URL 暴露出来：

- 只绑 ``127.0.0.1``，外面的机器连不上。
- URL 里带一个随机 token，别的进程猜不到路径。
- 只服务 ``<站点>/source`` 与 ``<站点>/public`` 两个目录。
- 路径越界（``..``）一律 404。

不做的事：不写文件、不删文件、不代理外部请求。它只负责「把一个文件读出来
发给预览页」。
"""

from __future__ import annotations

import mimetypes
import secrets
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

__all__ = ["AssetServer"]

#: 只服务这两个子目录。``source`` 是用户放的源文件，``public`` 是 hexo
#: 生成的产物（站点配了 ``public_dir`` 时会用）。
ALLOWED_DIRS = ("source", "public")

_MAX_FILE_BYTES = 64 * 1024 * 1024


def resolve_asset_path(root: Path | None, token: str, request_path: str) -> Path | None:
    """把请求路径解析成要服务的文件。

    解析不出来（token 不对、目录不在白名单、路径越界、文件不存在）就返回
    ``None``。**单独拆出来是为了能不起网络就测这几条安全规则**——路径
    越界这种洞，靠肉眼看代码看不出来。
    """
    if root is None or not token:
        return None

    path = unquote(urlparse(request_path).path)
    prefix = f"/{token}/"
    if not path.startswith(prefix):
        return None

    relative = path[len(prefix) :]
    parts = [part for part in relative.split("/") if part not in ("", ".")]
    if not parts or parts[0] not in ALLOWED_DIRS:
        return None

    # 基准目录是**允许的那个子目录**，不是站点根目录。
    # 拿站点根当基准的话，`source/../secret.txt` 解析完还在站点里，
    # 却已经爬出了 `source/`——越界检查就成了摆设。
    try:
        base = (root / parts[0]).resolve()
        target = (base / Path(*parts[1:])).resolve()
        target.relative_to(base)
    except (OSError, ValueError):
        return None

    if not target.is_file():
        return None
    return target


class _Handler(BaseHTTPRequestHandler):
    server_version = "HexoManAssets"
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler 的约定
        self._serve(with_body=True)

    def do_HEAD(self) -> None:  # noqa: N802
        self._serve(with_body=False)

    def log_message(self, format: str, *args: object) -> None:
        """别把访问记录刷到控制台。"""
        return

    # -- 内部 --

    def _serve(self, *, with_body: bool) -> None:
        server = self.server  # type: ignore[assignment]
        root: Path | None = getattr(server, "root", None)
        token: str = getattr(server, "token", "")

        target = resolve_asset_path(root, token, self.path)
        if target is None:
            self._fail(404)
            return

        try:
            size = target.stat().st_size
            if size > _MAX_FILE_BYTES:
                self._fail(413)
                return
            data = target.read_bytes()
        except OSError:
            self._fail(404)
            return

        content_type = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if with_body:
            self.wfile.write(data)

    def _fail(self, code: int) -> None:
        body = b"not found"
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            pass


class AssetServer:
    """给预览页提供站点内文件的只读服务。

    用法::

        server = AssetServer()
        server.set_root(site_path)
        server.start()
        url = server.url_for("source/images/a.png")
        ...
        server.stop()
    """

    def __init__(self, host: str = "127.0.0.1") -> None:
        self._host = host
        self._token = secrets.token_urlsafe(12)
        self._root: Path | None = None
        self._server: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None
        # 必须是可重入的锁：``start()`` 持着锁时还要读 ``base_url``，
        # 而 ``base_url`` 自己也要加锁——普通 Lock 在这里会把自己锁死。
        self._lock = threading.RLock()

    # -- 属性 --

    @property
    def root(self) -> Path | None:
        return self._root

    @property
    def token(self) -> str:
        return self._token

    @property
    def base_url(self) -> str:
        """服务根地址。没启动时是空串。"""
        with self._lock:
            if self._server is None:
                return ""
            host, port = self._server.server_address[:2]
            return f"http://{host}:{port}"

    # -- 生命周期 --

    def set_root(self, root: str | Path | None) -> None:
        """换站点。服务本身不用重启——每次请求都按当前 root 解析。"""
        self._root = Path(root) if root else None

    def start(self) -> str:
        """启动服务，返回根地址。已经在跑就直接返回。"""
        with self._lock:
            if self._server is not None:
                return self.base_url

            server = ThreadingHTTPServer((self._host, 0), _Handler)
            server.daemon_threads = True
            # keep-alive 的连接会让处理线程停在 readline 上等着下一个请求。
            # 不关掉这个开关，`server_close()` 会去 join 它们，于是 stop() 卡死。
            server.block_on_close = False
            server.root = self._root  # type: ignore[attr-defined]
            server.token = self._token  # type: ignore[attr-defined]
            self._server = server

            thread = threading.Thread(
                target=server.serve_forever,
                name="hexoman-assets",
                daemon=True,
            )
            thread.start()
            self._thread = thread
            return self.base_url

    def stop(self) -> None:
        """停掉服务。"""
        with self._lock:
            server = self._server
            self._server = None
            self._thread = None
        if server is not None:
            server.shutdown()
            server.server_close()

    # -- 拼地址 --

    def url_for(self, relative: str) -> str:
        """站点根目录下的相对路径 → 可访问的 URL。"""
        base = self.base_url
        if not base:
            return ""
        cleaned = str(relative).replace("\\", "/").lstrip("/")
        return f"{base}/{self._token}/{cleaned}"
