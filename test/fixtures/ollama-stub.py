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
from http.server import BaseHTTPRequestHandler, HTTPServer

# `GET /api/tags` 的固定应答：两个模型名，供「模型未安装」分支文案里的「已装：」断言。
MODELS = [{"name": "stub-model"}, {"name": "vision-model:7b"}]

# `huge` 模式声明的 `Content-Length`（16 MB × 2）。刻意与 CLI 侧的
# `OLLAMA_MAX_RESPONSE`（16 MB）对齐着写：**不从 CLI 导入**——stub 要能独立运行，
# 且「声明值远大于上限」这件事本身就是被测契约，写死比耦合更可靠。
OLLAMA_MAX_RESPONSE = 16 * 1024 * 1024

# `/api/chat` content 的两行固定文本（VLM 多行输出的替身）。
CHAT_LINES = ["第一行文字", "第二行文字"]


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
            self._reply(*show_response(mode))
        elif route == "/api/chat":
            if mode == "redirect":
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
