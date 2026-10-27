# OCR 位置对齐（P1–P4）

## 当前状态
- 阶段：Phase 4（Complete）· P1 已交付并归档（2026-10-27）
- 已确认：方案 ✅（用户 2026-10-27 确认）、计划 ✅（plan-reviewer「有条件通过」+ 2 项 major 已修订，用户 2026-10-27 确认）
- 进度：P1（T1–T9 + T10 + 审查修复 6 项）全部完成，L1 / L2 / L3 全绿，实测结论见下文「P1 执行结果」
- 后续：P2 / P3 / P4 仅有概要，后续另立计划推进；本文件归档至 `openspec/completed/`

## 目标

让 OCR 结果不止文字正确，**位置也与原图对得上**，并把翻译作为可插拔层叠加到同一坐标模型上。四项能力：

1. **P1 坐标地基 + 联动高亮**：结果 buffer 可打开联动视图——原图带框 + 文本列表，光标双向联动。
2. **P2 翻译层 + 合成图导出**：译文按 `box` 盖在原图对应位置，可一键导出 SVG 合成图。
3. **P3 版面排布**：结果文本按原图缩进与列位置排布（`eimg-ocr-report-style` 新增 `layout` 档）。
4. **P4 阅读顺序**：多栏 / 竖排 / 表格的阅读顺序还原（CLI `--reading-order auto`，默认保持现状）。

## 设计

### 根本问题（第一性原理）

「位置对得上」拆到不可再分的事实只有三条：

1. **坐标系必须闭合**：每个 `box` 是某个具体位图的像素坐标，定位需要「哪个位图 + 该位图多大 + 显示缩放比」三者齐备。目前 `box` 有，但 PDF 的页图被 CLI 用完即删，坐标系断在 PDF 路径上（图片输入可由 `:config :file` + `image-size` 补齐）。
2. **Emacs 不能在位图上作画**：buffer 中的 image 是原子对象，overlay / text property 作用于字符位置，无法在图像内部画框写字。覆盖层只能是**合成新图（SVG）**或**旁边浮 childframe**。
3. **版面顺序 ≠ 版面位置**：`sort_blocks_reading_order` 输出一维序列，位置信息在排序中被消耗。B（版面排布）在 elisp 渲染层用 `box` 决定缩进；D（阅读顺序）在 CLI 排序层用 `box` 决定先后——两件事必须分层解决。

### 假设清单

| # | 假设 | 来源 |
|---|---|---|
| 1 | `box` 是行级包围盒（tesseract 按行并集、rapidocr 按行归一），非字符级 | 事实✓ |
| 2 | 翻译层要「译文盖在原图对应位置」，且翻译实现可插拔、由用户配置 | 用户显式 |
| 3 | `svg` / `posframe` 本机均可用 | 事实✓（`featurep` 实测 true） |
| 4 | 用 SVG 合成统一承担「联动高亮」与「导出合成图」，避免两套坐标算法 | 假设?（若实测中文在 librsvg 下渲染不佳，译文改走 childframe，框仍用 SVG） |
| 5 | PDF 页图落临时目录、结果 buffer 关闭即清理，不污染用户目录 | 用户显式（关键取舍已定） |
| 6 | 版面排布作为 `eimg-ocr-report-style` 新增第三档 `layout`，不改 `org` / `text` 现有输出 | 假设? |
| 7 | 阅读顺序新算法用 `--reading-order` 开关，默认 `line`（现状） | 假设? |
| 8 | ollama（VLM）后端无 box，位置能力对它整体降级为不可用，不假装支持 | 事实✓ |
| 9 | json 的 `source` 只有 basename，但 elisp 侧 `:config :file` 有绝对路径，图片输入无需改 CLI 契约 | 事实✓ |
| 10 | librsvg 能渲染 `<image href="data:image/png;base64,…">` 内嵌底图（无外部文件引用） | 假设?（由 P1 T1 的第 ② 项验证；不成立则合成方案退化为 childframe 画框） |

### 关键取舍

| 决策点 | 选择 | 理由 / 备选 |
|---|---|---|
| 高亮实现 | SVG 合成重绘（底图 base64 缓存，只重拼 `<rect>`） | 位置精确、滚动缩放不漂移、与合成图导出复用同一渲染器；备选 childframe 叠加（滚动需重算、多框需多 frame） |
| 底图内嵌方式 | base64 data URI（`<image href="data:...">`） | Emacs 的 svg 加载禁外部文件引用；若 librsvg 实测不支持 data URI（假设 #10），退化为 childframe 画框 + 纯文本列表 |
| 原图尺寸来源 | elisp `image-size` 实测 | 图片输入零契约改动；PDF 页图路径由 CLI 给出后同样可测 |
| PDF 页图存放 | 临时目录 + buffer 本地变量记录，`kill-buffer-hook` 清理 | 备选持久缓存 `~/.cache/eimg/pages/` |
| 新模块划分 | `eimg-ocr-view.el`（P1）/ `eimg-ocr-translate.el`（P2） | 守「顶层零第三方依赖」：gptel 在函数体内 require |

### 模块边界

```
P1: bin/eimg-ocr             +--page-images-dir；page 结构 +"image"
    eimg-core.el             option 表加一条；新增纯函数 fit-size / block-box
    eimg-ocr-view.el  (新)   版面模型 + SVG 合成 + 联动 buffer/mode
    eimg-ocr.el              pages 存 buffer-local；PDF 注入 :page-images-dir；v 键
    eimg-transient.el        菜单接入「联动视图」
    eimg.el                  require eimg-ocr-view
P2: eimg-ocr-translate.el (新) defcustom 函数槽 + gptel/ollama 实现 + 异步编排
P3: eimg-core.el             +render-layout；eimg-ocr-report-style 加 layout 档
P4: bin/eimg-ocr             +--reading-order（栏检测 + 书写方向）
```

### 主要风险

1. ~~**SVG `<image>` data URI 不被支持**~~ **已由 T1 证伪（2026-10-27）——该风险不成立**；**新暴露的实际风险**是「跨机器无 CJK 字体时 `<text>` 静默渲染空白」（无墨迹、不报错，`U+FFFD` 有墨迹 10.95% 与中文 10.70% 相近，故不能靠「有墨迹」判定）。原文保留如下：若 T1 的 ② 项失败，P1 的联动画框退化为 childframe 叠加，P2 的合成图导出需重设计（可能改为「原图 + 译文列表」的双栏形态）。必须由 T1 先证伪，不得跳过。其余操作级风险（CLI 输出兼容、SVG 禁外部引用、batch 无真实渲染、ollama 无 box 降级、PDF 页图同源、只读 buffer 重绘等）见文末 `## 注意事项`。

## 任务

### P1 坐标地基 + 联动高亮（本轮执行）

- [x] T1 SVG 渲染能力冒烟验证（依赖：无）【已完成 2026-10-27】
  - 在 verify 隔离实例里验证**两件**事，缺一不可：
    ① 含中文 `<text>` 的 SVG 能 `create-image` 且 `image-size` 成功 —— 决定 P2 的译文能否走 SVG 渲染；
    ② `<image href="data:image/png;base64,…">` 内嵌底图能渲染出非空白内容（`image-size` 成功 + 渲染结果非空白）—— 决定 P1 的合成方案是否成立。
  - 交付：验证用的 elisp 片段 + 两条独立结论（① / ② 分别记「成立」或「不成立 + 具体报错」）。
  - 失败分支：①中文失败 → P2 译文改 childframe，P1 不受影响；②base64 失败 → P1 的联动画框改为 childframe 叠加，且 P2 的合成图导出需重设计（报告中明确写出）。
  - **必须先做**：它同时决定 P1 与 P2 的渲染路径，成本极低但结论影响方案。
  - **结论**：① 中文 `<text>` 成立（但本机靠 Sarasa fallback，`Noto Sans CJK SC` 并不存在）；② `<image>` base64 内嵌成立，`href` 与 `xlink:href` 输出逐字节一致。
  - **方法论修正**：`emacs -Q --batch` **不能**做图像验证（`image-size` 报 "Window system frame should be used"），必须用 GUI frame；`create-image` 对坏数据永不报错、`image-size` 成功也不证明内嵌渲染成功，唯一有效判据是像素统计（`rsvg-convert` + ImageMagick）。
  - **带进设计的 5 条约束**：`preserveAspectRatio="none"` 才能铺满；元素顺序 `image → rect → text`；`(let ((max-image-size nil)) ...)` 防大图被拒；base64 体积 1.33×（大图先降采样）；`font-family` 用 fallback 列表（`Noto Sans CJK SC, Source Han Sans SC, Sarasa Gothic SC, WenQuanYi Zen Hei, sans-serif`），跨机无 CJK 字体会静默渲染空白，P2 需前置检查。
- [x] T2 CLI 新增 `--page-images-dir DIR`（依赖：无）
  - `build_parser` 加参数与 `--help` 文案；DIR 不可创建 / 不可写 → 参数错误（退出码 5）。
  - **路径一律先 `resolve()`**：`recognize_pdf` 把栅格化的每页 PNG 复制到 DIR（命名 `<源文件名主干>-p<页码>.png`），page 写入的 `"image"` 必须是 `Path.resolve()` 后的绝对路径；图片输入同理（用户可能传相对路径，不 resolve 则「绝对路径」契约不成立）。
  - **输出必须是条件性的（数据链路必经点）**：`serialize_json`（`bin/eimg-ocr` 约 1283 行起）当前**显式重建** `{page, source, blocks}` 三键，会丢弃 `make_page` 新加的键——必须在 `--page-images-dir` 显式给出时才追加 `"image"`，且 `source` / `blocks` 的位置与顺序不变。只改 `make_page` 不改 `serialize_json`，elisp 侧永远拿不到 `image`。
  - **向后兼容是硬约束**：不传该参数时 json / text / lines 三种输出与今天逐字节一致。用固定 fixtures（一张 PNG + 一个 2 页 PDF）分别跑三种格式，改动前后 stdout diff 必须为空；该对比本轮为手工快照（项目无 Python 测试框架，缺口记入 tech-debt）。
- [x] T3 `eimg-core` 纯逻辑扩展（依赖：T2 的字段名）
  - `eimg-core-option-args` 加 `(:page-images-dir . "--page-images-dir")`（顺序接在 `:ollama-url` 之后）。
  - 新增 `eimg-core-fit-size`：`(宽 高 上限宽 上限高)` → `(:scale :px-w :px-h)`，非正整数输入返回 nil，等比缩放、`scale` 夹在 0.01–1.0。
  - 新增 `eimg-core-block-box`：取块的 `box`，校验为 4 个数字的列表（允许 float），非法返回 nil。
  - 断言 `eimg-core--normalize-page` 对新增 `image` 字段原样保留（现有实现用 `assq-delete-all 'blocks` 应已保留，需用例锁定）。
- [x] T4 `eimg-ocr.el` 接线（依赖：T2、T3）
  - `eimg-ocr--run`：输入含 `.pdf` 时创建临时目录并注入 `:page-images-dir`，目录路径记进 meta `:pages-dir`。
  - `eimg-ocr--show-result`：把 pages 结构存进结果 buffer 的 buffer-local 变量（供视图重建），并把 `:pages-dir` 记进去；`kill-buffer-hook` 清理临时目录。
  - `eimg-ocr-mode-map` 加 `v` → `eimg-ocr-view`（现有 y/i/w/g/q/k 键位不变）。
  - **旧目录清理**：`eimg-ocr-rerun`（`g` 键）复用同一结果 buffer，重新识别会覆盖 buffer-local 的 `:pages-dir`；覆盖前必须先删除上一轮目录——清理职责不能只靠 `kill-buffer-hook`，否则每次重跑泄漏一个临时目录。
- [x] T5 新文件 `eimg-ocr-view.el`（依赖：T3、T4）
  - 版面模型：页 → 图路径 / 像素宽高（`image-size`）、显示缩放比（`eimg-core-fit-size`）。
  - SVG 合成器：底图 base64 内嵌（librsvg 禁外部引用）+ 每块 `<rect>`，当前块用异色描边；底图 base64 按文件 + mtime 缓存，重绘只重拼 rect 部分。
  - 视图 buffer + `eimg-ocr-view-mode`（`special-mode` 派生）：上半 SVG 合成图、下半文本列表（每行带块索引 text property）。
  - 双向联动：文本行光标移动 → 重绘高亮对应块；图上 `:map` 热区点击 → 跳到对应文本行。
  - 键位：`n` / `p` 上下块、`RET` 跳到原图位置、`o` 打开原图、`g` 重绘、`q` 关闭；多页时跨页边界自动换页。
  - 无 box 的块（ollama 后端）→ 明确降级：视图只显示文本列表 + 一行提示，不画框。
  - **SVG 生成硬约束（由 T1 实测）**：`href`（或 `xlink:href`，二者择一，推荐 `href` 并始终写 `xmlns`）；`preserveAspectRatio="none"`；元素顺序 `image → rect → text`；合成与 `image-size` 调用必须 `(let ((max-image-size nil)) ...)` 包一层。
  - **降采样**：底图 base64 体积约 1.33×，画布尺寸过大（如 >2000px 宽）时先按比例降采样再内嵌，并把缩放比记进版面模型（框坐标同步缩放）。
- [x] T6 `eimg-transient.el` 菜单接入（依赖：T5）
  - 「系统」组（`?` / `r` / `d` / `S` 所在组）加一项「联动视图」（调用 `eimg-ocr-view`）；菜单项不因缺数据而隐藏，调用时 `user-error` 说明。
- [x] T7 `eimg.el` require `eimg-ocr-view`（依赖：T5）
  - 按 D2 的加载顺序放在 `eimg-ocr` 之后；确认 `emacs -Q --batch` 下可加载（顶层只 require 内置库）。
- [x] T8 测试（依赖：T3、T4、T5）
  - `test/eimg-core-test.el` 补充：option 顺序、`fit-size` 边界（nil / 缩放 / 夹取下限）、`block-box` 非法输入、normalize 保留 `image`。
  - `test/eimg-ocr-test.el` 补充：pages 进 buffer-local、PDF 注入 `:page-images-dir`、`v` 键绑定、临时目录清理。
  - 新增 `test/eimg-ocr-view-test.el`：SVG 字符串结构（含 `<image>` 与每块 `<rect>` 数量）、几何换算、热区坐标、无 box 降级路径。
  - 全部用例必须能在 `emacs -Q --batch` 下跑通（不依赖真实图形渲染，只断言 SVG 字符串结构与纯函数）。
  - **不得在 batch 下断言 `image-size` / `create-image` 结果**（T1 实测 batch 无 graphic frame，必报错）。若确需断言「SVG 能被加载」，可用 `(equal (image-size img t) '(30 . 30))` 作为加载失败的反向弱断言，但只能放在 GUI 环境用例里（用 `skip-unless (display-graphic-p)` 守卫）。
  - 像素级真渲染验证（非白像素占比）不进 ERT，作为 L3 的手工步骤或后续 `make` 集成目标。
- [x] T9 文档（依赖：T2–T8）
  - `README.org`：能力矩阵加「位置对齐 / 联动视图」行、命令与键位表、`--page-images-dir` 参数说明、PDF 页图生命周期说明。
  - `CHANGELOG.md` 追加本轮条目（简体中文）。

### P1 执行结果（2026-10-27）

逐条实测结论（每条都是当日跑出来的，不是设计推断）：

- **T1（SVG 能力）**：成立。「中文 `<text>`」靠 Sarasa fallback 出字形——本机**并无** `Noto Sans CJK SC`，故 `font-family` 必须写 fallback 列表；「`<image>` base64 内嵌」成立，`href` 与 `xlink:href` 两种写法的输出**逐字节一致**（择一即可，仍须带 `xmlns`）；`preserveAspectRatio="none"` 必需，否则底图不铺满画布；`max-image-size` 必须置 nil，否则大图被拒成占位尺寸；batch 下 `image-size` **不可用**（报 `Window system frame should be used`），图像验证只能进 GUI frame。
- **T2（CLI `--page-images-dir`）**：落地。不传该参数时 json / text / lines 三种格式输出与改动前**逐字节一致**（18/18 组对比 diff 为空）；传参时 page 结构多出 `image`（`resolve()` 后的绝对路径），`source` / `blocks` 的键序不变。
- **T3（`eimg-core` 纯逻辑）**：`fit-size` / `block-box` 两个纯函数落地，配套 12 个用例覆盖 nil / 缩放 / 夹取下限 / 非法 box / normalize 保留 `image`。
- **T4（`eimg-ocr` 接线）**：pages 结构进 buffer-local（`eimg-ocr--result-data`），PDF 路径注入 `:page-images-dir` 并记 `:pages-dir`，页图临时目录按**所有权记账**清理，结果 buffer 新增 `v` 键。
- **T5（`eimg-ocr-view.el`）**：SVG 合成 + 文本列表双向联动 + 四路降级（缺坐标 / 缺页图 / 超内嵌上限 / 无 SVG 支持）。重绘耗时从 62.6 ms 降到 2.2 ms（前缀缓存后，约 28×）。
- **T6 / T7（菜单与加载）**：transient「系统」组新增联动视图项（缺数据时 `user-error` 说明）；`eimg.el` 在 `eimg-ocr` 之后 require `eimg-ocr-view`，`emacs -Q --batch -L . -l eimg` 加载通过。
- **T8（测试）**：新增 `test/eimg-ocr-view-test.el` 等用例后 `make test` 203 绿（本轮 T 追加用例后为 206 绿）。
- **T9（文档）**：`README.org`（能力矩阵、命令与键位、`--page-images-dir`、页图生命周期）与 `CHANGELOG.md` 同步完成。
- **追加修复（计划外，审查与实测驱动）**：
  - **T10**：`eimg-ocr-rerun` 会误删正在使用的页图目录——「资源所有权」（`owned`）与「实际生效资源」（`effective`）混用所致，改为两条变量分离记账。
  - 审查修复 6 项：内嵌上限降级（不再尝试「先降采样再内嵌」）、SVG 前缀缓存、`owned` 泄漏、热区归一化、**坐标换算基准统一为 `px-w/width` / `px-h/height`（`--image-map` 与 `--posn-entry` 同源）**、`svg` 特性显式检查。
- **L3 真实端到端**：9/9 通过——`hello.png` 真实 OCR 1.88 s、`three-pages.pdf` 5.14 s、图区 `image-size` 非占位、框数与块数一致、高亮随光标变化、`goto-entry` 命中、换页指向 p2、kill 后目录清理干净。

### P2 翻译层 + 合成图导出（概要，待 P1 完成后细化）

- [ ] `eimg-ocr-translate.el`：`eimg-ocr-translate-function` defcustom 函数槽（签名与异步契约在此期定稿）+ 两个内置实现（gptel 软依赖 / ollama 复用 CLI 通道）+ 结果缓存与失败降级。
- [ ] 联动视图：双行「原文 / 译文」、`t` 触发翻译、译文写入块结构的独立字段。
- [ ] 合成图导出：`E` 导出当前页 SVG（译文按 box 替换原文位置），文件名与落盘位置待定。

### P3 版面排布（概要）

- [ ] `eimg-core-render-layout`：按 `box` 的 x0 换算缩进（中文按 2 列宽折算）、按 y 聚行、表格按列对齐。
- [ ] `eimg-ocr-report-style` 加 `layout` 档；`org` / `text` 行为不变。
- [ ] tech-debt 关闭「阅读顺序排序只还原单栏横排」中与渲染相关的部分（顺序部分留 P4）。

### P4 阅读顺序（概要）

- [ ] CLI `--reading-order line|auto`，默认 `line`；`auto` 做栏检测（x 投影切栏）+ 书写方向判定。
- [ ] 失败或判不准时回退 `line` 顺序并在 stderr 提示，绝不静默排错。
- [ ] 技术债条目的三条失效场景（多栏 / 竖排 / 跨行块）逐条验收。

## 文档清单

| 文档 | 触及点 | 期次 |
|---|---|---|
| `README.org` | 能力矩阵、命令与键位、`--page-images-dir`、PDF 页图生命周期 | P1 |
| `README.org` | 翻译接口配置示例、`--reading-order`、`layout` 档 | P2–P4 |
| `CHANGELOG.md` | 每期条目 | P1–P4 |
| `openspec/decisions.md` | D13（P1 坐标模型 + SVG 合成）、P2 翻译函数槽契约、P4 阅读顺序开关 | 对应期 |
| `openspec/tech-debt.md` | 关闭「阅读顺序只单栏」；新增「`eimg-select` 与 `eimg-core` 尺寸换算重复」；新增「CLI 输出兼容无自动化回归（项目无 Python 测试框架）」；ollama 无 box 的位置能力边界 | P1 起逐期 |

## 验证标准

- **L1**：`make check-parens`（全部 .el 括号平衡）+ `make py-check`（`bin/eimg-ocr` 语法）。
- **L2**：`make test`（ERT 全绿，含新增三处用例）。
- **L3**（verify 隔离实例，真实端到端）：
  - **前置**：验证渲染必须有 GUI frame（T1 实测 batch 下 `image-size` 直接报错）；verify 实例若 `display-graphic-p` 为 nil，则改用本机 WSLg 的 GUI Emacs（`DISPLAY=:0`）执行渲染相关断言，并在报告中如实注明环境。
  1. 用 `test/fixtures/` 的图片跑一次真实 OCR（走 `eimg-ocr--run`，不用交互命令）→ 结果 buffer 生成。
  2. 调用 `eimg-ocr-view` → 视图 buffer 里有 SVG 图与文本列表。
  3. 文本行之间移动 → 高亮块随之变化（断言 SVG 字符串中的 rect 描边色变化）。
  4. 用 `:map` 热区坐标模拟点击（直接调用视图的跳转函数）→ 文本行光标落到对应块。
  5. PDF 路径：跑一次真实 PDF（fixtures 若无则造一个 2 页 PDF）→ page 结构含 `image` 绝对路径且文件存在 → 视图可显示第 2 页。
  6. 收尾：`elisp_mcp_set_task auto` → `elisp_mcp_instance(action=stop, instance=verify)` → `instance_status` 确认。
- **不变量验证**：不传 `--page-images-dir` 时 CLI 输出与改动前逐字节一致（用固定 fixtures 对比 stdout）。
- **顶层零第三方依赖**：`emacs -Q --batch -L . -l eimg-ocr-view` 能加载成功。
- **自动化缺口**：CLI 输出兼容目前只能手工快照对比（项目无 Python 测试框架），已记入 tech-debt；不因此阻塞 P1。

## 注意事项

1. **CLI 输出兼容是硬约束**：任何新增字段只允许在显式传参时出现。改动后用同一 fixtures 对比 stdout，diff 必须为空。
2. **SVG 里不能引用外部文件**：Emacs 的 svg 加载禁外部引用，底图必须 base64 内嵌；大图 base64 会很大，必须做缓存（按路径 + mtime），否则每次重绘都读盘 + 编码。
3. **`emacs -Q --batch` 下没有真实渲染**：测试只断言 SVG 字符串与纯函数；真实渲染结论只能在 L3 的 daemon 环境得出。
4. **同一文件禁止并行编辑**：本轮 `eimg-ocr.el` / `eimg-core.el` 会被多次修改，必须串行 edit，每次改完重读确认（历史上有过并行 edit 后写覆盖前写、文件被破坏的事故）。
5. **`eimg-select.el` 不动**：`eimg-select--preview-fit` 与新的 `eimg-core-fit-size` 存在逻辑重复，本轮不重构（避免触碰截图链路），记进 tech-debt。
6. **ollama 后端无 box**：视图必须显式降级并可读地提示，不得画零尺寸框或把整页当一块。
7. **`image-size` 的调用前提**：必须 `create-image` 成功（依赖文件可读与格式受支持）；失败要降级为「无框视图 + 提示」，不能让视图打开即报错。
8. **PDF 页图与 box 必须同源**：页图只能来自 CLI 同一次栅格化（同 DPI），禁止 elisp 侧自行重新栅格化，否则框会整体偏移。
9. **inhibit-read-only**：视图 buffer 与结果 buffer 都是只读模式派生，重绘前必须 `let` 绑定 `inhibit-read-only` 且改完 `set-buffer-modified-p nil`。
10. **键位前缀**：新键位只用单键（`v` / `n` / `p` / `RET` / `o` / `g` / `q`），不用 `C-c` 前缀（用户保留空间）。
11. **跨机器无 CJK 字体会静默渲染空白**：SVG `<text>` 走 librsvg→pango→fontconfig 排版，与 Emacs 自身的字体配置**完全无关**（用户在 Emacs 里配的中文字体不会带进 SVG）。本机 `Noto Sans CJK SC` 并不存在、靠 Sarasa fallback 才出字形。P2 落地时必须（a）用 `font-family` fallback 列表，（b）加一次「系统是否有 CJK 字体」的前置检查，缺失时明确告警而不是渲染一张空白译文图。
12. **`rsvg-convert` / `create-image` 对坏内嵌资源静默失败**：退出码 0、无 stderr 警告，只是画面上没有图。任何「命令成功所以渲染成功」的推断都不成立；需要证据时只能做像素统计。
