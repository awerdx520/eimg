# 技术债

## 本文件约定

- 只记工程侧债务。用户可见的契约与边界写进 `README.org`（`* 已知边界` 与后端各节），本文件只留一行指针（见文末「已转入 README（非债）」）。
- 关闭条目必须给出日期与可验证证据（决策编号 / commit / 测试文件与用例名），并移入文末「已关闭（索引）」——不留整段旧正文。
- 每条必须有「现状 / 影响 / 验证方式 / 改进方向」四段；「改进方向」为「无」时必须写清是能力边界而非缺陷。
- 标题带级别与成本：`（P1/P2/P3 · 成本 S/M/L）`。P1 = 修法明确且低风险；P2 = 需业务决策或中件；P3 = 需新能力或环境限制。

## `--pdf-pages` 对多 PDF 混排重复生效（P2 · 成本 S · 需先定语义）

现状：多个 PDF 输入时页码范围对每个文件都套用；若第二个文件页数不足，整体以退出码 3 失败，前面文件已识别出的结果被一并丢弃（一次失败的识别成本是整批栅格化 + OCR）。

影响：批量场景无法用页码参数，用户只能拆成多次调用。

验证方式：两个 PDF（3 页 + 1 页）带 `--pdf-pages 2`，断言当前行为（整批失败、退出码 3）；改为逐文件跳过后断言第一份结果保留、第二份跳过并计入 stderr 汇总。

改进方向：需要一次契约决策——「逐文件跳过并继续」（更符合批量直觉，但「参数错误」变成「部分成功」，退出码要有新语义，例如 0 + stderr 警告）vs 维持「整批失败」（简单、可预测）。在决定前，多文件混排不要带 `--pdf-pages`。

## 阅读顺序排序只还原单栏横排（P3 · 成本 L）

现状：`sort_blocks_reading_order` 只做「按 y 中心聚行 + 行内按 x0 从左到右」这一维还原，前提是单栏横排。多栏（双栏论文 / 并排代码）会把左右栏聚成同一行、输出左右交错；竖排会一字一行；跨行块（整段贴图、跨行大标题）的 cy 落在所跨多行之间，被插到中间位置；容差取「所有块高度中位数的一半」，整页都是超大块时会大到把相邻行并成一行。

影响：内容不缺、顺序错，下游摘要与翻译质量下降；多栏与竖排版面尤其明显。

验证方式：多栏 fixture（两块 x 区间不重叠、y 区间重叠）断言输出为「左栏全部行 → 右栏全部行」；竖排 fixture 断言按列右到左、列内上到下；现有单栏用例必须继续通过。

改进方向：需要栏检测（按 x 投影切栏）+ 书写方向判定（竖排按 y 优先、x 递减），属 P4 范畴。当前实现刻意只做最保守的一维聚类——宁可排错也不猜版面；改动前必须先用 fixture 锁住现状，避免「改一处、错两处」。

## 交互入口在 daemon / 批处理下会阻塞（P2 · 成本 M）

现状：OCR 本身全异步（`eimg-ocr--start` 立即返回，收尾由 sentinel 完成），但「取输入」与「取确认」两段仍是同步的：`eimg-ocr-region` 经 `call-interactively` 等外部截图进程；`eimg-ocr-file` 用 `read-file-name`；`eimg-ocr-history` 用 `completing-read`；`eimg-ocr-write-file` 覆盖前 `y-or-n-p`。

影响：无 attached frame 或 `noninteractive` 时阻塞或直接失败（ERT 用例里靠 `cl-letf` 打桩绕过，未覆盖真实 daemon 路径）。从 `emacsclient -e`、定时任务调这些命令不要指望能返回。

验证方式：`emacs --batch` 下调用四个入口，断言在 1 秒内以明确错误结束（`user-error` 指路到非交互入口）而非挂起。

改进方向：给三个入口补「非交互参数入口」（直接吃文件路径、不弹选择器），复用同一条 OCR 编排路径；截图选区域本质上要人操作，`eimg-ocr-region` 保持只支持交互。

## 多页 PDF 每页独立起进程，rapidocr 模型每页重新加载（P2 · 成本 M）

现状：`recognize_pdf` 先 `pdftoppm` 栅格化，再逐页 `recognize_image` → 每页一个子进程；rapidocr 的内联脚本每页重新导入 onnxruntime 并加载检测/识别模型（实测冷启动 8–10 秒），10 页文档≈10 次冷启动。超时只在单页粒度（`RAPIDOCR_TIMEOUT = 180` / `TESSERACT_TIMEOUT = 120` 落在每次 `subprocess.run`），CLI 无整体超时、也无 `--timeout`。

影响：多页文档的耗时被模型加载淹没；elisp 侧 `eimg-ocr-timeout`（整体定时器 → `delete-process`）到点取消，表现为「到点被取消」而不是「慢慢跑完」，且已识别页一并丢弃。

验证方式：固定 10 页 fixture，记录改造前后 `--format json` 的总耗时与 `elapsed` 字段；断言 blocks 逐字段一致。

改进方向：单进程识别多页——一次 `subprocess.run` 传多张图，Python 侧循环识别并把每页 block 合并进同一份 JSON，模型只加载一次。两条取舍需先定：① 错误粒度（一页失败是丢整份还是跳过该页）；② 超时语义从「每页上限」改为「总量上限 + 每页软上限」，CLI 退出码 4 与 elisp 超时文案都要跟着重做。

## ollama（VLM）后端的四条边界（P2/P3 · 成本 M）

现状与分级：
- **无 box/conf**（P3，能力边界）：VLM 只回纯文本，`conf` 恒 `0.0`、`box` 恒 `None`，`sort_blocks_reading_order` 退化为原样返回；下游若按置信度过滤会把结果整体当作「低置信」。
- **多页 PDF 每页一次推理**（P2，与上条「多页 PDF」同源同解）：模型驻留靠 `keep_alive:"5m"`，但每页仍是一次完整请求；elisp 侧整体 `eimg-ocr-timeout`（默认 300s）会先于单页 `OLLAMA_TIMEOUT`（300s）触发。
- **只支持 png/jpg/jpeg**（P3，有意行为）：CLI 无 PIL 无法转码，tiff/gif/webp 直接退出码 3；`auto` 锁定 ollama 时按设计不回退 tesseract（`resolve_backend` 只挑一次，动态回退会让结果不可预测）。
- **输出格式漂移未充分防御**（P2）：只剥了 Markdown 三反引号围栏，编号列表、解释性前缀、空行结构等漂移未处理；真实 VLM 识别质量与稳定性**未验证**（端到端只用 `test/fixtures/ollama-stub.py`）。

影响：位置能力对该后端整体不可用；速度与输入格式受限；输出形态可能随模型漂移。

验证方式：stub 增「编号列表前缀」「解释性前言」两种输出模式，断言解析后 blocks 不含前缀行；真实模型质量需人工抽样，记入 L3 手工清单。

改进方向：格式漂移可加通用清洗（去前言、剥列表序号）；「无 box」与「只支持三种格式」属能力边界与有意行为，不修。

## CLI 输出兼容无自动化回归（P2 · 成本 S）

现状：「不传 `--page-images-dir` 时 json/text/lines 逐字节一致」目前靠手工快照（18/18 对比），项目无 Python 测试框架。

影响：后续改动 CLI 输出路径时可能静默破坏兼容，CI 抓不到。

验证方式：固定 fixtures + 期望 stdout 文件，对三种 `--format` 各断言逐字节相等。

改进方向：加一个最小快照测试（或把对比脚本固化成 `make` 目标）。ERT 已能 `call-process` 跑真 CLI（见 `test/eimg-ocr-ollama-test.el`），无需引入 pytest。

## `eimg-select--preview-fit` 与 `eimg-core-fit-size` 逻辑重复（P2 · 成本 S）

现状：两处各有一套「按 frame 尺寸算缩放比与显示像素」的换算，P1 刻意未重构（避免触碰截图链路）。

影响：修一处缩放策略时容易漏另一处，视觉上表现为「截图预览与联动视图缩放不一致」。

验证方式：重构前先给两处各补一条「同输入同输出」的 ERT（core 侧已有 `eimg-ocr-view-test-geometry-uses-fit-size`），重构后两文件用例全绿。

改进方向：让 `eimg-select--preview-fit` 改用 `eimg-core-fit-size`（需保留 `:chars-w` / `:chars-h` 的计算），触及截图链路，需单独验证。

## 网络对端输入与下载入口的加固缺口（P2/P3 · 成本 S–M）

现状（安全审查发现，本轮均**不可利用**——默认配置下不成立，记录以备入口放宽时收口）：
- `bin/eimg-ocr-setup` 的 `download()` 用裸 `urlopen`：默认 opener 含 `file:` / `data:` / `ftp:` handler 且跟随 3xx 重定向。当前 `TESSDATA_URLS` 硬编码 https，故不可利用；一旦将来支持镜像覆盖（`--tessdata-url` 等），立刻变成「读本地任意文件写入 tessdata」或 SSRF 探测内网。改进方向：scheme 白名单 + 拒绝重定向 + 显式构造 `OpenerDirector` 去掉不需要的 handler（**必须保留环境代理能力**，否则企业网下载会断）。
- `.part` 半成品用固定文件名 + `open("wb")`（跟随符号链接，CWE-59 / CWE-377）：仅当 `--tessdata-dir` 指向他人可写目录时，本地攻击者可预置符号链接覆写目标文件。改进方向：`tempfile.mkstemp(dir=destination.parent, ...)`（自带 `O_EXCL|O_NOFOLLOW`）。
- `bin/eimg-ocr` 把对端响应体前 200 字符与模型名原样回显（CWE-150，既有行为，非本轮引入）：恶意 ollama 返回含 `\x1b]0;` / `\r` 的错误体可改写终端标题、伪造输出行。改进方向：统一 `_sanitize_snippet()` 剥 C0 控制字符后再截断。
- CLI 的 `OLLAMA_TIMEOUT`（300 秒）与 elisp 的 `eimg-ocr-timeout`（300 秒）相同，Emacs 内的定时器通常先到，用户看到的是「OCR 超时（124）」而不是 CLI 新增的「ollama 整体超时」文案——新分支的排障价值在 elisp 路径上被削弱。改进方向：CLI 侧预算调到略小于 elisp（如 240 秒），或让 elisp 超时文案附带 stderr 尾部原因。

影响：只在「后端或镜像指向不可信主机」「tessdata 目录在他人可写位置」这类前提下成立；默认配置不成立。

验证方式：加固后补三条用例——非 http/https scheme 被拒、重定向到异主机被拒、`.part` 落在符号链接上不覆写目标；超时抢跑项在调整预算后断言 elisp 路径能看到 CLI 的「整体超时」文案。

改进方向：见各条；属纵深防御，优先级低于「阅读顺序」与「多页单进程」两项。

## 联动视图遗留项（P2/P3 · 成本 S–L）

P1（坐标地基 + 联动高亮）验收后剩余五项，逐项标级别：

- **底图未真正降采样**（P2 · 成本 L）：超过 `eimg-ocr-view-max-embed-bytes`（默认 8 MB）即明确降级——不内嵌底图，只显示文本列表与可行动提示。高 DPI 扫描件在内置渲染路径下看不到图，用户需降低 `--dpi` 重识别或裁剪后重认。改进方向：引入可选外部图像后端（ImageMagick 等）做像素级降采样；P2 需要导出合成图时再评估是否接受该依赖。
- **内嵌上限按字节判、不按像素**（P2 · 成本 M）：判据是 `file-attribute-size`（只读元数据不读内容），高质量 JPEG 的 8 MB 可能解码出很大位图，仍会触发 `create-image` 的重解析开销。改进方向：改按像素判（宽 × 高 × 4 估算），但需先解码——与「不先把文件读进内存」的设计冲突，需重新设计判断入口。
- **`create-image` 每次全量重解析 SVG**（P3 · 成本 M）：前缀缓存（现为容量 3 的 LRU）只省了「重拼 MB 级字符串」，`create-image` 仍按整条 SVG 解析（`:map` 一变必须重造 image spec），单次重绘有约 2.2 ms 固定成本。改进方向：只能换渲染后端（例如底图与框分两层叠加），坐标对齐逻辑要重做。
- **ollama（VLM）后端无 `box`**（P3 · 能力边界）：见「ollama（VLM）后端的四条边界」第一条，不重复展开；改进方向：无。
- **`--posn-entry` 的真实鼠标点击未端到端验证**（P3 · 环境限制）：本环境无法合成 GTK 点击事件，只验证了热区形状 / 坐标 / ID / keymap 绑定，以及几何兜底路径（`--image-map` 与 `--posn-entry` 互为逆运算已有 ERT）。改进方向：在 GUI 环境加一条人工验证步骤（事件 → `[ID mouse-1]` → 命令 → 跳转），记入 L3 手工清单。

影响：高 DPI 扫描件的可视化降级；重绘有固定成本；真实点击链路只在代码层与单测层成立。

验证方式：逐项有对应 ERT（几何换算 / 内嵌上限 / 兜底路径互逆 / LRU 淘汰）或 L3 手工步骤；改动时按项验收。

改进方向：逐项见上（三项有明确方向，两项是能力边界与环境限制）。

## 已关闭（索引）

- 截图能力尚未迁移 —— 2026-10-27 关闭。证据：decisions D10（四模块迁入本仓，跨仓软依赖与两个转调桥接命令一并删除）。
- `+thomas/screenshot` 的返回值契约未经跨仓契约测试 —— 2026-10-27 关闭。证据：decisions D10 + `test/eimg-ocr-test.el` 第 8 节（四态契约）+ `eimg-capture-test-no-host-symbols`（源码边界）。
- 交互命令没有 `;;;###autoload`，可用性隐式依赖宿主不延迟加载 —— 2026-10-27 关闭。证据：decisions D11 + `test/eimg-autoload-test.el` 7 条用例（cookie 覆盖、真跑 `loaddefs-generate` 的 13 条映射、仅加载 autoloads 时 `featurep` 为 nil）。
- sentinel 状态判定不得依赖 event 文案 —— 2026-10-27 关闭。证据：decisions D7 + commit d128464。教训已固化为不变量：判据用 `process-status` + `process-exit-status`，禁止匹配事件串；风险形态是「英文 locale 全绿、中文 locale 全哑」的假绿。
- 无 pdfinfo 时部分页码越界会静默截断 —— 2026-10-29 关闭。证据：decisions D16 + `test/eimg-ocr-pdf-test.el` 四条用例（`eimg-ocr-pdf-test-partial-overflow-without-pdfinfo` / `-partial-overflow-with-pdfinfo` / `-valid-range-without-pdfinfo` / `-single-page-beyond-without-pdfinfo`）+ `bin/eimg-ocr` 的 `rasterize_pdf` 渲染页数判据。

## 已转入 README（非债）

以下条目是用户可见的契约与边界，权威描述在 `README.org`，本文件不再重复维护：

- tesseract 语言数据须显式安装一次 → `README.org` 的 `** 后端准备`（两条硬约束）。
- rapidocr 依赖 Python 环境（venv / onnxruntime / numpy / pillow）→ `README.org` 的 `** 后端矩阵`。
- 解释器自带 CA 配置可能与系统不一致 → `README.org` 的 `** 后端准备` 的 CA 段（脚本已按候选表兜底；不经本脚本的其它 Python 下载仍会撞）。
- ollama 默认端点无身份校验 → `README.org` 的 `** ollama 后端的安全边界`（回环端口不等于可信）。
- `--list-backends` / `--check` 会发一次本地 HTTP 请求 → `README.org` 的 `** 后端矩阵` 末段（不要放进补全 / `init` / hook）。
