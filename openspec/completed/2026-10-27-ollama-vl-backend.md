# ollama 视觉模型（VLM）OCR 后端接入

## 当前状态

- 阶段：Phase 4（Review & Document）· **已完成并归档（2026-10-27）**
- 已确认：方案 ✅、计划 ✅、实现 ✅（`make test` 154/154）、审查 ✅（code-reviewer 通过；security-reviewer 的 3 medium 中 2 项已修 + 1 项部分修，余项记 tech-debt）
- 下一步：无（后续见 `openspec/tech-debt.md` 的 ollama 相关条目）

## 目标

给 eimg 的 OCR 能力新增第三个后端 `ollama`：通过本地 ollama 服务的视觉语言模型（VLM）识别图片与 PDF 页，与既有 `rapidocr` / `tesseract` 并列，且**不破坏任何既有契约**：

1. CLI 仍为 **stdlib-only 单文件**（不引入 requests / httpx / PIL）；
2. 退出码契约（0/2/3/4/5）不变，`pages`/`blocks` 形状不变；
3. 配置链（ARGS > defcustom > config.json > CLI 默认）不变，只新增两个键；
4. `auto` 顺序变为 `rapidocr → ollama → tesseract`（用户拍板：ollama 在 rapidocr 之后、tesseract 之前）；
5. **模型必须显式指定**（用户拍板）：不做自动挑 vision 模型、不写死默认模型名；未配置即判 ollama 不可用并给出配置指引；
6. **本轮不下载任何模型**（用户拍板）：端到端验证用 stub HTTP 服务，真实推理列为「未验证项」。

## 背景与已核实事实

| 事实 | 来源 |
|---|---|
| 本机 ollama 仅 Windows 侧安装（v0.32.5），`127.0.0.1:11434` 在跑，WSL 经 mirrored 直通可达（curl 200） | 实测 |
| 本机**零视觉模型**：仅 `qwen2.5-coder:1.5b-instruct-q8_0`，`/api/show` 的 `capabilities` 无 `vision` | 实测（`/api/tags` + `/api/show` 双路核对） |
| WSL 内无 `ollama` 可执行文件 → 可用性判据必须是 **HTTP 可达**，不能用 `shutil.which("ollama")` | 实测 |
| `bin/eimg-ocr` 是 stdlib-only 单文件，源码显式约定不 import 第三方（第 10、27 行注释） | 代码 |
| `sort_blocks_reading_order` 对**全无坐标的块整页原样返回**（不排序、不丢弃） | `bin/eimg-ocr:683-755` |
| `probe_backends(lang, python, tessdata_dir, only=None)` 已支持只探测指定后端 | `bin/eimg-ocr:562-594` |
| `~/.local/share/eimg/config.json` 现只有 `python` 一个键 | 实测 |
| `make py-check` 只做 `py_compile`，CLI 侧**没有** Python 单测框架 | `Makefile` |
| `/api/chat` 的 `messages[].images` 接收 base64 列表；`/api/show` 返回 `capabilities`；`stream:false` 关闭流式 | ollama 官方 API 文档 |
| 本机 `no_proxy` 未设置（本地 HTTP 须显式绕代理） | `rules/environment.md` |

## 设计

### D-A 后端顺序与 auto 语义

- `BACKEND_ORDER = ("rapidocr", "ollama", "tesseract")`。
- `--backend` 的 `choices` 由 `BACKEND_ORDER + ("auto",)` 自动派生，无需另改。
- `auto` 语义不变：按 `BACKEND_ORDER` 顺序取第一个 `available=true`。因此本机默认行为不变（rapidocr 可用）；只有在 rapidocr 不可用、且 ollama 已显式配置视觉模型时才会走 VLM。

### D-B 配置链（三层 + config.json）

取值优先级（高到低），与既有 `--python` 完全同构：

| 键 | CLI 参数 | 配置文件键 | 内置默认 |
|---|---|---|---|
| 模型 | `--ollama-model NAME` | `config.json` 的 `ollama_model` | **无**（缺失即不可用） |
| 服务地址 | `--ollama-url URL` | `config.json` 的 `ollama_url` | `DEFAULT_OLLAMA_URL = "http://127.0.0.1:11434"` |

- 实现方式：把现有 `_config_python()` 泛化为 `_config_get(key) -> str | None`（读 `_config_path()` 的 JSON、取字符串键、strip 后非空才返回、任何 OSError/ValueError 静默返回 nil），`_config_python()` 保留为 `return _config_get("python")` 的薄包装以最小化改动面。
- 新增 `_config_ollama_model()` / `_config_ollama_url()` 两个薄包装（同样走 `_config_get`）。
- 解析函数：`_ollama_model(explicit)` = `explicit or _config_ollama_model()`；`_ollama_url(explicit)` = `explicit or _config_ollama_url() or DEFAULT_OLLAMA_URL`。

### D-C 探测契约 `_probe_ollama(model, url)`

返回 dict，形状与其它后端一致，**额外**带 `model` 与 `url` 两个字段供识别阶段复用（`reason` 不能复用来传模型名——rapidocr 用 `reason` 传解释器路径，语义不同不要混）：

```
{"name": "ollama", "available": bool, "reason": str, "model": str | None, "url": str}
```

判定顺序与 `reason` 文案（文案必须含下列关键字，便于测试与用户排障）：

1. `model` 为空 / None → `available=False`，`reason = "未配置 ollama 模型：用 --ollama-model NAME 或 config.json 的 ollama_model 键指定"`。**此分支不发任何网络请求。**
2. 发 `POST {url}/api/show`，body `{"model": model}`，超时 `OLLAMA_PROBE_TIMEOUT = 3` 秒，**必须绕过代理**（`urllib.request.build_opener(urllib.request.ProxyHandler({}))`）。
   - 连接被拒 / 超时 / DNS 失败 / URLError → `available=False`，`reason = "ollama 服务不可达（{url}）：{简短原因}"`。
   - HTTP 404 或响应体 `error` 字段含 `not found` → `available=False`，`reason = "模型 {model} 未安装（{url}）；已装：{逗号分隔的模型名列表}；用 ollama pull {model} 安装"`。已装列表通过一次 `GET {url}/api/tags` 获取（**仅在此失败分支发这个请求**，成功路径一次请求即可）；`/api/tags` 也失败时列表写 `"（无法获取）"`。
   - 其它非 200 → `available=False`，`reason = "ollama 探测失败（HTTP {code}）：{响应体前 200 字符}"`。
   - 200 且可解析 JSON：取 `capabilities`（list）。**判据**：`"vision" in capabilities`。
     - 含 → `available=True`，`reason = "{model}（{url}，vision）"`。
     - 不含 → `available=False`，`reason = "模型 {model} 不支持视觉（capabilities: {逗号分隔}）；请换一个视觉模型"`。
     - `capabilities` 缺失或非 list → 按「不支持视觉」处理，reason 里注明 `capabilities 缺失`。
3. 所有 HTTP 请求都必须：`Content-Type: application/json`、`ProxyHandler({})` 绕代理、超时上限明确、异常一律捕获成 `available=False`（**探测永不 raise 到 main**）。

### D-D 识别契约 `run_ollama(image_path, model, url, timeout=OLLAMA_TIMEOUT)`

1. 读文件字节 → `base64.b64encode(...).decode("ascii")`。
2. `POST {url}/api/chat`，body：

```
{
  "model": model,
  "messages": [{"role": "user", "content": OLLAMA_PROMPT, "images": [<base64>]}],
  "stream": false,
  "options": {"temperature": 0},
  "keep_alive": "5m"
}
```

`OLLAMA_PROMPT` 固定为（中文，要求只输出文字）：

```
识别这张图片中的所有文字，按阅读顺序逐行输出。只输出文字本身，不要任何解释、不要 Markdown 代码块、不要行号或标注。没有文字时输出空字符串。
```

3. 解析响应 JSON 的 `message.content`（字符串）。
4. 文本清理（顺序固定）：
   a. `strip()`；
   b. 若整段以 ` ``` ` 开头的三反引号围栏包裹，且首行只有三个反引号（可带语言名）而末行是三个反引号，则去掉首末两行；
   c. 按 `\n` 切行，逐行 `strip()`，**丢弃空行**；
   d. 每行 → `make_block(line, 0.0, None)`（`conf` 拿不到一律 0.0，`box` 为 None）。
5. 失败分支全部映射为 `fail(EXIT_OCR_FAILED, ...)`，文案必须以 `识别失败: {image_path}（…）` 开头：
   - `subprocess` 无关，HTTP 超时 → `识别失败: {path}（ollama 超时: 超过 {timeout} 秒未完成）`；
   - `URLError` → `识别失败: {path}（无法连接 ollama 服务 {url}: {原因}）`；
   - HTTP 非 200 → `识别失败: {path}（ollama 退出码 HTTP {code}: {响应体前 200 字符}）`；
   - JSON 解析失败 → `识别失败: {path}（ollama 响应不是合法 JSON: {原因}）`；
   - `message.content` 缺失/非字符串 → `识别失败: {path}（ollama 响应缺少 message.content）`；
   - 清理后没有任何行 → `识别失败: {path}（ollama 未识别出任何文字）`（不要返回空列表让 main 去报「未产出任何文本页」，那样文案更含糊）。
6. `OLLAMA_TIMEOUT = 300`（单页，VLM 首次加载模型慢）；常量放在 `TESSERACT_TIMEOUT` 之后并写注释说明取值理由。

### D-E 扩展名限制（ollama 分支专属）

`OLLAMA_SUFFIXES = (".png", ".jpg", ".jpeg")`。在 `recognize_image` 的 ollama 分支里，若 `path.suffix.lower()` 不在其中 → `fail(EXIT_BAD_INPUT, f"无法读取输入: {path}（ollama 后端只支持 png/jpg/jpeg；tiff/gif/webp 请用 rapidocr 或 tesseract）")`。

理由：CLI 无 PIL 无法转码，ollama 对 tiff/gif/webp 的解码支持不确定（假设未实测）；明确拒绝优于静默失败。PDF 栅格化产物恒为 png，因此 PDF 路径不受影响。

**auto 语义边界（有意）**：`auto` 一旦锁定 ollama，后续遇到不支持的格式直接退出码 3，**不回退**到 tesseract——`resolve_backend` 只挑一次后端。详见「注意事项」第 11 条。

### D-F blocks 形状与排序

- ollama 的 blocks **全部无 box**（`None`）、`conf` 恒 `0.0`。
- 复用 `sort_blocks_reading_order`：它对全无坐标的块「整页原样返回」，因此 ollama 的输出顺序 = 模型给的行序，不做任何二次猜测。**不要**为 ollama 写特例跳过排序（保持单一归一入口）。
- `serialize_json` 会把 `backend` 写成 `"ollama"`（走既有 `backend.get("name")` 路径，无需改动）。

### D-G elisp 侧改动规格

1. `eimg-core.el`：
   - `eimg-core-option-args` 末尾（`:tessdata-dir` 之后）追加两条：`(:ollama-model . "--ollama-model")`、`(:ollama-url . "--ollama-url")`。顺序固定，新增键排在最末，既有键相对顺序不变。
   - `eimg-core-exit-hints` 的 2 号提示追加 ollama 的配置方式（在原字符串末尾补：`；或配置 ollama 视觉模型（--ollama-model / config.json 的 ollama_model）后走 ollama 后端`）。
2. `eimg-ocr.el`：
   - `eimg-ocr-backend` 的 `:type` choice 增加 `(const :tag "ollama" "ollama")`。
   - 新增 `defcustom eimg-ocr-ollama-model`：`:type '(choice (const :tag "未配置（ollama 不可用）" nil) string)`，`:group 'eimg`，默认 nil；docstring 说明「必须显式指定，未配置则该后端判不可用；落成 CLI 参数 `--ollama-model`；ARGS 显式给出 `:ollama-model` 时以 ARGS 为准」。
   - 新增 `defcustom eimg-ocr-ollama-url`：`:type '(choice (const :tag "交给 CLI 默认（http://127.0.0.1:11434）" nil) string)`，默认 nil；docstring 说明落成 `--ollama-url`。
   - `eimg-ocr--config-defaults` 返回的 plist 末尾（`:tessdata-dir` 之后）追加 `:ollama-model eimg-ocr-ollama-model`、`:ollama-url eimg-ocr-ollama-url`；docstring 补一句「两者为 nil 时同样不进 argv，CLI 自己用内置默认 URL / 判 ollama 不可用」。
3. `eimg-transient.el`：
   - `eimg-menu--backend` 的 `:choices` 改为 `'("auto" "rapidocr" "ollama" "tesseract")`。
   - **不新增**模型 / URL 的 infix（保持「三个会话内 infix」契约，模型属配置级选择）。

### D-H `bin/eimg-ocr-setup`

`run_check()` 里的 `cli.probe_backends(python=args.python, tessdata_dir=args.tessdata_dir)` 改为 `cli.probe_backends(python=args.python, tessdata_dir=args.tessdata_dir, ollama_model=None, ollama_url=None)`——**setup 不新增 `--ollama-model` / `--ollama-url` 参数**（`bin/eimg-ocr-setup` 的 argparse 里没有这两个选项，`args` 上根本没有这两个属性，写 `args.ollama_model` 会抛 `AttributeError`），一律传**字面量 `None`**；`probe_backends` 内部再走 `_ollama_model(None)` / `_ollama_url(None)`，从而自动读到 config.json 的键。并在 `--check` 输出末尾补一行指引：`note("ollama 后端：需 ollama pull 一个视觉模型，并在 config.json 写 ollama_model（或用 bin/eimg-ocr --ollama-model 临时指定）")`。

**不新增**任何 pull / 写配置动作（遵守 D4「安装必须显式」）。

## 任务

- [x] **T1** CLI 常量与参数：`BACKEND_ORDER` 加 ollama（位于 rapidocr 与 tesseract 之间）、新增 `DEFAULT_OLLAMA_URL` / `OLLAMA_PROBE_TIMEOUT=3` / `OLLAMA_TIMEOUT=300` / `OLLAMA_SUFFIXES` / `OLLAMA_PROMPT`；`build_parser()` 新增 `--ollama-model`、`--ollama-url` 两个选项（help 文案说明「未配置模型即判 ollama 不可用」「URL 默认值」）。验收：`bin/eimg-ocr --help` 出现两个新选项；`--backend` 的 choices 含 ollama。（依赖：无）
- [x] **T2** 配置读取泛化：`_config_get(key)` + `_config_python()` 薄包装 + `_config_ollama_model()` / `_config_ollama_url()` + `_ollama_model()` / `_ollama_url()` 解析函数。验收：py_compile 通过；函数可通过 `--list-backends` 间接生效（T5 后验证）。（依赖：T1）
- [x] **T3** 探测实现 `_probe_ollama(model, url)`，严格按 D-C 的五种 reason 文案；`probe_backends` 新增 `ollama_model=None, ollama_url=None` 参数，把 `probe_ollama` 注册进 `only` 映射表，全量探测顺序为 rapidocr → ollama → tesseract。**关键接线**：`probe_backends` 内部必须写 `_probe_ollama(_ollama_model(ollama_model), _ollama_url(ollama_url))`，**不能**把收到的原始参数直接下传给 `_probe_ollama`——否则 `None` 会恒落入「未配置模型」分支，config.json 的 `ollama_model` / `ollama_url` 键永远失效。验收：单测（T11 的 stub）覆盖 vision / no-vision / 404 / 不可达 / 未配置模型五种分支；且把 `ollama_model` 写进 config.json（或用 `XDG_DATA_HOME` 指向临时目录的临时配置）后，`bin/eimg-ocr --list-backends` 的 ollama 行显示该模型名而非「未配置」。（依赖：T2）
- [x] **T4** 识别实现 `run_ollama(...)` + `recognize_image` 的 ollama 分支 + D-E 的扩展名限制。**取值来源**：ollama 分支必须用探测 entry 的字段，即 `run_ollama(path, backend.get("model"), backend.get("url"))`；**不要**从 `args` 重新解析模型/URL——`auto` 选中 ollama 时 `args.ollama_model` 可能为 None（值来自 config.json）。验收：stub 端到端产出多行文本、退出码 0；非 png/jpg/jpeg 输入退出码 3。（依赖：T3）
- [x] **T5** `main()` 传参贯通：`probe_backends(..., ollama_model=args.ollama_model, ollama_url=args.ollama_url)`；`--list-backends` 输出自然多一行。验收：L3 的 `--list-backends` 四条输出正确。（依赖：T3）
- [x] **T6** `bin/eimg-ocr-setup` 的 `run_check` 传参与提示行（D-H）。验收：`bin/eimg-ocr-setup --check` 输出含 ollama 行与指引行；且在 config.json 写入 `ollama_model` 后，`--check` 的 ollama 行显示该模型名（证明 setup 侧也走了 config.json 解析，而不是恒「未配置」）。（依赖：T5）
- [x] **T7** `eimg-core.el` 两处改动（D-G 第 1 条）。验收（`grep` 即可核验，与测试同步无关）：`eimg-core-option-args` 含 `(:ollama-model . "--ollama-model")` 与 `(:ollama-url . "--ollama-url")` 两项且位于 `:tessdata-dir` 之后；`eimg-core-exit-hints` 的 2 号提示字符串含 `ollama` 字样。（依赖：无）
- [x] **T8** `eimg-ocr.el` 三处改动（D-G 第 2 条）。验收：defcustom 存在、默认 nil、custom-type 为 choice；`eimg-ocr--config-defaults` 含两键。（依赖：无）
- [x] **T9** `eimg-transient.el` 的 `:choices` 加 ollama（D-G 第 3 条）。验收：transient 测试断言 choices 含 ollama。（依赖：无）
- [x] **T10** 既有测试同步：`test/eimg-core-test.el` 的完整 argv 断言、`test/eimg-ocr-test.el` 的 defcustom/config-defaults 断言、`test/eimg-transient-test.el` 的 choices 断言全部更新且**新增**对应正向用例（两键为 nil 时不进 argv / 非 nil 时按固定位置进 argv / choices 含 ollama / hint 2 含 ollama 字样）。验收：`make test` 全绿。（依赖：T7、T8、T9）
- [x] **T11** 新增 `test/fixtures/ollama-stub.py`（stdlib `http.server`，约 60 行，**不得引入第三方依赖**）+ ERT stub 用例（约 120 行）：
  - stub 行为：`GET /api/tags` 返回含一个模型的列表；`POST /api/show` 按环境变量 `OLLAMA_STUB_MODE` 返回三种模式：`vision`（capabilities 含 vision）/ `novision`（capabilities 无 vision）/ `missing`（404 + `{"error":"model not found"}`）；`POST /api/chat` 返回 `{"message":{"role":"assistant","content":"<多行固定文本>"}}`，并把收到的请求关键字段回显进 content 首行，形如 `[stub] model=<M> stream=<b> temperature=<t> images=<n>`，供断言请求形态。
  - ERT 用例：`(skip-unless (executable-find "python3"))`；`make-process` 起 stub（**端口方案已定**：stub 用 `HTTPServer(("127.0.0.1", 0))` 由内核分配端口，绑定后把实际端口写成一行到 **stdout** 并 `flush`（形如 `PORT 53211`）；ERT 端用 `make-process :filter` 收集首行解析端口，**有界等待 ≤5 秒**（超时即 kill 并 fail，禁止无界循环）；随后做有界连接轮询（≤10 次 × 0.2 秒）确认可连；用例体包在 `unwind-protect` 中 `kill-process` + `delete-process` 收尾。不用固定端口：mirrored 模式下端口空间与 Windows 共享，固定端口可能撞 `Windows 侧监听` 而 `EADDRINUSE`）；断言：vision 模式下 `--backend ollama --ollama-model stub --ollama-url http://127.0.0.1:<port>` 退出码 0 且输出含多行文本与 `[stub] model=stub`；novision 模式退出码 2 且 stderr 含「不支持视觉」；missing 模式退出码 2 且 stderr 含「未安装」；无 `--ollama-model` 时退出码 2 且 stderr 含「未配置 ollama 模型」。验收：`make test` 全绿，且不残留进程与临时文件。（依赖：T4、T5）
- [x] **T12** 全量验证：`make check-parens`、`make py-check`、`make test`，以及 L3 的真实 CLI 验证（见「验证标准」）。验收：三轮全绿 + L3 五条命令输出符合预期。（依赖：T1-T11）
- [x] **T13** 文档沉淀：`README.org`（顶部能力表加 ollama、依赖段加「可选：本地 ollama 服务 + 显式配置的视觉模型」、后端矩阵加一行、模型/URL 解析段、CLI 参数表加两行、菜单 infix 表更新 choices、defcustom 表加两行、示例命令）、`CHANGELOG.md`、`openspec/decisions.md` 追加 D12、`openspec/tech-debt.md` 追加两条（见「文档清单」）。（依赖：T12）

## 文档清单

| 文件 | 需要的更新 |
|---|---|
| `README.org` | 能力表（15 行附近）、依赖段（37 行附近）、后端矩阵（76-90 行）、**三处 auto 顺序文案改为 rapidocr → ollama → tesseract（能力表 15 行 / 矩阵 auto 行 82 行 / CLI 参数表 189 行 `--backend` 描述）**、CLI 参数表（189-196 行）、菜单表（278 行）、defcustom 表（305-309 行）、示例命令（204-220 行） |
| `CHANGELOG.md` | `Added`：ollama 视觉后端（`--ollama-model` / `--ollama-url`、`eimg-ocr-ollama-model` / `eimg-ocr-ollama-url`）；`Changed`：`auto` 顺序变为 rapidocr → ollama → tesseract |
| `openspec/decisions.md` | 新增 **D12 ollama 视觉后端接入**：stdlib-only HTTP、`/api/chat`、模型必须显式、auto 位置、按行切块无 box/conf、不 pull 模型 |
| `openspec/tech-debt.md` | ① VLM 无 box/conf → 版面顺序不可还原，与 tesseract 路线不可比；② 多页 PDF 每页一次推理（模型驻留靠 `keep_alive`），10 页可能分钟级，且 elisp 侧整体 `eimg-ocr-timeout`（默认 300s）会先于单页 `OLLAMA_TIMEOUT`（300s）触发，多页 PDF 走 ollama 实际会被整体超时截断；③ tiff/gif/webp 不支持（无 PIL 转码）；④ VLM 输出格式漂移（编号列表 / 解释性前缀 / 代码围栏之外的 Markdown 结构）未充分防御，真实推理质量未验证；⑤ 探测阶段给 `--list-backends` / `--check` 引入了本地 HTTP 请求（3 秒上限） |
| `bin/eimg-ocr` 模块头注释 | 说明新增 `urllib` / `base64` 仍属 stdlib，stdlib-only 约定未破 |
| `eimg-ocr.el` 的 `eimg-ocr-backend` docstring | 补 ollama 分支与「需配 `eimg-ocr-ollama-model`」 |
| `eimg-ocr.el` 的 `eimg-ocr--setup-help-text` | 安装指引文本补 ollama 一条（`ollama pull <视觉模型>` + 在 config.json 写 `ollama_model`），与 `bin/eimg-ocr-setup --check` 的提示行对称 |

## 验证标准

- **L1**：`make check-parens`（逐文件 emacs -Q --batch check-parens）+ `make py-check`（`bin/` 两个脚本 py_compile）
- **L2**：`make test`（ERT 全绿，含 T11 的 stub 用例；无 python3 的机器 `skip-unless` 跳过而非变红）
- **L3**（真实环境，本机 ollama 服务在跑）：
  1. `bin/eimg-ocr --list-backends` → 三行后端：`rapidocr: available=true`、`ollama: available=false reason=未配置 ollama 模型…`、`tesseract: available=true`（顺序必须为 rapidocr → ollama → tesseract）
  2. `bin/eimg-ocr --backend ollama test/fixtures/hello.png` → 退出码 2，stderr 含「未配置 ollama 模型」
  3. `bin/eimg-ocr --backend ollama --ollama-model qwen2.5-coder:1.5b-instruct-q8_0 test/fixtures/hello.png` → 退出码 2，stderr 含「不支持视觉」
  4. `bin/eimg-ocr --backend ollama --ollama-model no-such-model-xyz test/fixtures/hello.png` → 退出码 2，stderr 含「未安装」与「已装」
  5. stub 全链路：起 `test/fixtures/ollama-stub.py`（vision 模式）→ `bin/eimg-ocr --backend ollama --ollama-model stub --ollama-url http://127.0.0.1:<port> test/fixtures/hello.png` → 退出码 0，stdout 为 stub 的多行文本
- **elisp 侧**：ERT 覆盖 argv 拼装（`--ollama-model` / `--ollama-url` 的 nil 与非 nil 两种形态）；不要求在隔离实例里真跑 OCR（stub 已覆盖 CLI 层）

## 注意事项

1. **stdlib-only 是硬不变量**：`bin/eimg-ocr` 与 `bin/eimg-ocr-setup` 只允许标准库；HTTP 用 `urllib.request`，编码用 `base64`。引入 requests/httpx 会破坏 `py-check` 之外的可移植性约定。
2. **绕代理**：所有本地 HTTP 必须 `build_opener(ProxyHandler({}))`；本机 `no_proxy` 未设，当前靠代理配置碰巧 bypass，不可依赖。
3. **探测永不 raise**：连接失败、超时、JSON 损坏一律转成 `available=False` + 明确的 `reason`；只有显式指定的后端不可用时才由 `resolve_backend` 抛退出码 2。
4. **不要复用 `reason` 传模型名**：rapidocr 用 `reason` 传解释器路径；ollama 的模型与 URL 放在 entry 的 `model` / `url` 字段。
5. **不要为 ollama 写排序特例**：`sort_blocks_reading_order` 对无 box 块原样返回，保持单一归一入口。
6. **模型必须显式**：任何"自动挑第一个 vision 模型"的实现都偏离用户决策，属返工。
7. **不下载模型**：实现与测试阶段禁止 `ollama pull`；端到端用 stub。真实推理质量在报告里标为「未验证项」。
8. **`--list-backends` 现在含一次本地 HTTP 探测**：ollama 未运行时是毫秒级 ECONNREFUSED，防火墙丢包场景最多等 3 秒；不要为此加大超时。
9. **测试收尾**：stub 进程必须 `kill` 且临时目录清理，`make test` 结束后不得残留进程（`pgrep -f ollama-stub` 应为空）。
10. **既有断言不会被新增键打红**：`eimg-core-build-args` 只为输入 plist 中**非 nil** 的键产出 argv，而既有两条用例的输入根本不含新键，输出不变、断言保持绿。因此 T10 的活是**新增**正向用例（新键为 nil 时不进 argv / 非 nil 时按固定位置进 argv），**不要**删改既有断言来「修红」——那样反而丢掉了旧覆盖。
11. **auto 锁定 ollama 后不做后端 fallback（有意）**：`--backend auto` 且 rapidocr 不可用、ollama 可用时，若输入是 tiff/gif/webp，会以退出码 3 失败而**不会**回头试 tesseract。`resolve_backend` 只挑一次后端；动态回退会让「这次到底用哪个后端」不可预测，属于偏离设计的改动。
