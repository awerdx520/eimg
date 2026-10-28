#!/usr/bin/env python3
"""ollama-stub.py —— ollama HTTP API 的最小 stub（ERT 端到端夹具，仅标准库）。

为什么需要它：`bin/eimg-ocr` 的 ollama 后端要真发 HTTP 才能验证「探测 → `/api/chat`
识别 → 逐行成块」整条链，而测试阶段禁止 `ollama pull`（不下载模型）、也不能依赖
网络外部资源。

用法（ERT 侧用 `make-process` 起它，读 stdout 首行拿端口）：

    OLLAMA_STUB_MODE=vision python3 -u test/fixtures/ollama-stub.py
    PORT 53211                      <- stdout 首行；端口由内核分配

`OLLAMA_STUB_MODE` 只影响 `POST /api/show` 与 `POST /api/chat` 的应答：

    vision（默认） → `capabilities` 含 `vision`；chat 回「回显行 + 两行中文」
    novision       → `capabilities` 只有 `completion`
    missing        → HTTP 404 + `{"error": "model not found"}`
    fenced         → 同 vision，但 chat 的 content 被 ``` 围栏包裹（剥围栏用例）
    redirect       → chat 返回 302 + `Location: /api/chat2`（拒绝跟随用例）
    huge           → chat 声明 `Content-Length` 为 32 MB 但只写十几字节
                     （响应体上限用例；实现按 header 就拒，不必真传 32 MB）
    trickle        → `/api/show` 与 `/api/chat` 都走慢速滴流：每 0.5 秒写 1 字节、
                     持续 12 秒（探测整体超时用例；单次 socket 超时对滴流无效）
    chat-trickle   → `/api/show` 正常回 vision，只有 `/api/chat` 滴流
                     （识别整体超时用例；直接调 `run_ollama`，不经过 CLI 探测）

除 `novision` / `missing` 外，`/api/show` 恒回 vision——否则「后端不可用」会先一步
拦下命令，chat 分支的用例根本走不到。

端口为什么让内核分配（绑定 0）而不是写死：本机 WSL2 是 mirrored 网络模式，端口
空间与 Windows 共享，固定端口可能与 Windows 侧监听撞 EADDRINUSE——那时 WSL 内
`ss` 看不到占用者，排查成本远高于回读端口。

`POST /api/chat` 把收到的请求关键字段回显进 content 首行（形如
`[stub] model=… stream=… temperature=… images=… keep_alive=…`），后面跟两行固定
中文：ERT 既能断言「请求形态对不对」，也能断言「多行文本真的被逐行渲染」。
"""

import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

# `GET /api/tags` 的固定应答：两个模型名，供「模型未安装」分支文案里的「已装：」断言。
MODELS = [{"name": "stub-model"}, {"name": "vision-model:7b"}]

# `huge` 模式声明的 `Content-Length`（16 MB × 2）。刻意与 CLI 侧的
# `OLLAMA_MAX_RESPONSE`（16 MB）对齐着写：**不从 CLI 导入**——stub 要能独立运行，
# 且「声明值远大于上限」这件事本身就是被测契约，写死比耦合更可靠。
OLLAMA_MAX_RESPONSE = 16 * 1024 * 1024

# `/api/chat` content 的两行固定文本（VLM 多行输出的替身）。
CHAT_LINES = ["第一行文字", "第二行文字"]

# 滴流模式的节奏：每 0.5 秒写 1 个字节，持续 12 秒。
#
# 时长要同时满足两件事：① 明显长于被测的整体预算（CLI 探测是 3 秒，用例里
# `run_ollama(timeout=3)` 也是 3 秒），否则「预算到点就放弃」与「对端正常写完」区分不开；
# ② 远小于识别预算（300 秒），别让一条用例等成分钟级。
TRICKLE_SECONDS = 12.0
TRICKLE_INTERVAL = 0.5

# 滴流响应声明的 `Content-Length`。刻意取一个**远小于** 16 MB 响应体上限的小值：
# 本模式要测的是「整体预算」，不是「响应体过大」——声明大了会让客户端在读之前就
# 按 header 拒掉，两个失败原因的文案完全一样，用例就测不到预算那层了。
# 同时也永不写满它（12 秒只写 24 字节），好让客户端始终处在「还没读完」的状态。
TRICKLE_LENGTH = 1000


def show_response(mode):
    """把 MODE 映射成 `POST /api/show` 的 `(状态码, 响应体)`。"""
    if mode == "missing":
        return 404, {"error": "model not found"}
    # 只有 `novision` 才算「不支持视觉」；`fenced` / `redirect` / `huge` 都要先让探测
    # 通过，chat 分支才有机会被走到。
    capabilities = ["completion"] if mode == "novision" else ["completion", "vision"]
    return 200, {"capabilities": capabilities, "details": {"family": "stub"}}


def chat_response(body, mode):
    """把请求体 BODY 的形态回显进 content 首行，再补两行固定文本。

    `fenced` 模式把整段（含回显行）包进 Markdown 代码围栏：真实 VLM 即使被提示词
    明令禁止，仍常把答案塞进 ``` 块，CLI 侧必须能剥掉。
    """
    messages = body.get("messages") if isinstance(body.get("messages"), list) else []
    first = messages[0] if messages and isinstance(messages[0], dict) else {}
    images = first.get("images") if isinstance(first.get("images"), list) else []
    options = body.get("options") if isinstance(body.get("options"), dict) else {}
    head = "[stub] model={} stream={} temperature={} images={} keep_alive={}".format(
        body.get("model"),
        body.get("stream"),
        options.get("temperature"),
        len(images),
        body.get("keep_alive"),
    )
    content = "\n".join([head, *CHAT_LINES])
    if mode == "fenced":
        content = "```\n{}\n```".format(content)
    return 200, {"message": {"role": "assistant", "content": content}}


class Handler(BaseHTTPRequestHandler):
    """三个路由：`/api/tags`（GET）、`/api/show`、`/api/chat`（POST）；其余 404。"""

    server_version = "eimg-ollama-stub/1.0"

    def _reply(self, status, payload):
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _reply_redirect(self, location):
        """302 + Location：客户端应拒绝跟随（本 stub 不实现 `/api/chat2`）。"""
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _reply_oversized(self):
        """声明 32 MB 的 `Content-Length` 却只写十几字节。

        CLI 侧按 header 就该拒（`OLLAMA_MAX_RESPONSE` = 16 MB），因此不必真的传
        32 MB——真传会让这条用例慢上一个数量级，对断言没有任何额外价值。
        客户端提前关连接时本函数会吃 BrokenPipeError，静默掉即可（stderr 有输出
        会被 ERT 侧当成 CLI 报错而误判）。
        """
        payload = json.dumps({"message": {"role": "assistant", "content": "x"}}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(OLLAMA_MAX_RESPONSE * 2))
        self.end_headers()
        try:
            self.wfile.write(payload)
            self.wfile.flush()
        except OSError:
            pass

    def _reply_trickle(self):
        """慢速滴流响应：每 `TRICKLE_INTERVAL` 秒写 1 字节，持续 `TRICKLE_SECONDS` 秒。

        为什么要这个模式：`read(n)` 的语义是「读满 n 字节或 EOF」，滴流下每次底层读
        都有数据进来，**单次 socket 超时永远不会触发**，客户端会被吊到本函数自己
        结束为止。只有「整体预算」语义才能给出硬上限，本模式正是那条边界的夹具。

        客户端在预算耗尽时会主动关连接，那时的写会吃 `BrokenPipeError`（`OSError`
        子类），静默 return 即可——stub 的 stderr 必须零输出，否则 ERT 侧会把它当成
        CLI 自己报的错而误判。
        """
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(TRICKLE_LENGTH))
        self.end_headers()
        deadline = time.monotonic() + TRICKLE_SECONDS
        try:
            while time.monotonic() < deadline:
                time.sleep(TRICKLE_INTERVAL)
                self.wfile.write(b" ")
                self.wfile.flush()
        except OSError:
            return

    def _read_body(self):
        """读并解析请求体；坏 JSON / 空体一律归一成空 dict（stub 不因坏输入 500）。"""
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except (TypeError, ValueError):
            length = 0
        raw = self.rfile.read(length) if length > 0 else b""
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return {}
        return parsed if isinstance(parsed, dict) else {}

    def do_GET(self):  # noqa: N802  BaseHTTPRequestHandler 要求的命名
        if self.path.split("?")[0] == "/api/tags":
            self._reply(200, {"models": MODELS})
        else:
            self._reply(404, {"error": "not found"})

    def do_POST(self):  # noqa: N802  BaseHTTPRequestHandler 要求的命名
        body = self._read_body()
        route = self.path.split("?")[0]
        mode = os.environ.get("OLLAMA_STUB_MODE") or "vision"
        if route == "/api/show":
            if mode == "trickle":
                # 探测路径的滴流：`/api/show` 就慢，客户端在 3 秒预算到点时放弃。
                self._reply_trickle()
            else:
                self._reply(*show_response(mode))
        elif route == "/api/chat":
            if mode in ("trickle", "chat-trickle"):
                # `trickle` 连 chat 一起滴流（探测就先失败）；`chat-trickle` 只滴流 chat，
                # 好让调用方先通过探测再撞上识别侧的预算。
                self._reply_trickle()
            elif mode == "redirect":
                # 相对 Location 就够：CLI 侧在任何跟随动作之前就拒了，不需要真地址。
                self._reply_redirect("/api/chat2")
            elif mode == "huge":
                self._reply_oversized()
            else:
                self._reply(*chat_response(body, mode))
        else:
            self._reply(404, {"error": "not found"})

    def log_message(self, format, *args):  # noqa: A002
        """静默访问日志：stderr 有输出会被 ERT 侧当成 CLI 报错而误判。"""


def main():
    server = HTTPServer(("127.0.0.1", 0), Handler)
    # 端口回读协议：一行 `PORT <n>`，flush 后 ERT 立刻能读到（`-u` 保证不缓冲）。
    print("PORT {}".format(server.server_address[1]), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
