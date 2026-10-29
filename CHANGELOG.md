# 更新日志

本项目所有值得注意的变更都记在这里。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号参考 [语义化版本](https://semver.org/lang/zh-CN/)。

## [未发布]

### 新增

- **交互命令的 autoload cookie**：13 个用户入口（截图 2 / 插入 2 / OCR 4 / 结果与安装
  相关 3 / 菜单 1 / embark 注册 1）带 `;;;###autoload`，宿主可用 `use-package :defer t`
  延迟加载本包而不丢按键——`make` 之外的文件名映射由 `loaddefs-generate` 按实际定义
  位置填写（不用 `use-package :commands`，它假设文件名等于符号名）。
- **embark 注册的延迟加载补偿**：`eimg-embark.el` 把注册抽成 `eimg-embark-register`
  并带 autoloads 补偿 form，`:defer t` 下 `C-.` 菜单仍在 embark 加载时注册。补偿**不能**
  写成 `(with-eval-after-load 'embark (require 'eimg-embark))`——那会 `Recursive require`。
- **`test/eimg-autoload-test.el`**：7 条用例锁定 cookie 覆盖、反向断言（buffer-only 命令
  不加 cookie）、embark 补偿形态、真跑 `loaddefs-generate` 的映射表、仅加载 autoloads 时
  的 `fboundp` / `autoloadp` 语义、「看结果 / 开目录 / 看指引不加载 transient」、以及
  embark 加载后的注册结果。
- **ollama 视觉模型（VLM）OCR 后端**：`bin/eimg-ocr` 新增第三个后端 `ollama`，走本地 ollama
  服务的 `/api/chat`（`stream:false`、`options.temperature:0`、`keep_alive:"5m"`、
  `messages[0].images` 传 base64）；可用性探测用 `POST /api/show` 读 `capabilities` 是否含
  `vision`。CLI 新增 `--ollama-model` / `--ollama-url`，`--list-backends` 与
  `bin/eimg-ocr-setup --check` 各多一行 ollama 状态与指引。
- **elisp 侧接入 ollama**：新增 defcustom `eimg-ocr-ollama-model` / `eimg-ocr-ollama-url`
  （默认 `nil` = 不传对应选项），`eimg-ocr-backend` 增加 `ollama` 取值，`eimg-core-option-args`
  末尾补两键，`eimg-core-exit-hints` 的 2 号提示补 ollama 一句，transient `-b` 的 choices
  增加 `ollama`，安装指引 `eimg-ocr--setup-help-text` 补 ollama 一条。
- **`test/fixtures/ollama-stub.py` + 6 条 stub 端到端 ERT**：用 stdlib `http.server` 起本地
  stub（`OLLAMA_STUB_MODE` 分 vision / novision / missing 三档），锁请求形态（chat 请求体、
  base64 图片、`stream:false`）与六条用例：vision 端到端产出多行文本 / 不支持视觉 /
  模型未安装（回显已装列表）/ 未配置模型 / 拒绝 tiff 等不支持后缀 / 收尾无残留进程。
  真实 VLM 识别质量未验证（本轮不下载模型）。
- **坐标对齐：`--page-images-dir` 与 json 的 `image` 字段**：CLI 把 PDF 每页栅格图落到指定
  目录（命名 `<源主干>-p<真实页码>.png`），json 的每页因此多一个 `image` 绝对路径；图片输入
  传该参数时 `image` 直接指向输入图本身（不复制文件）。目录不存在自动创建（含多级），建不出来
  / 不可写 / 已是普通文件按参数错误退出 5。**不传参数时 json / text / lines 三种输出与旧版逐
  字节一致**（旧版输出快照逐份对比验证），旧调用方与快照测试不受影响。
- **结果 buffer 的 `v` 键与联动视图 `eimg-ocr-view`**：上半部分是原图（PDF 输入是 CLI 栅格化
  出来的页图）带每块文字的坐标框、当前块异色描边 + 半透明填充，下半部分是该页文本列表；文本
  行光标移动 ↔ 图上框高亮双向联动，鼠标点图上的框跳到对应文本行。键位：`n` / `p` 跨页切块、
  `N` / `P` 换页、`RET` 复制当前块原文、`o` 打开当前页位图、`g` 重新取数并重渲、`q` 关闭。
  `RET` 由「跳到原图位置」改为复制——图片在 Emacs 里是不可分割的显示对象，没有「图片内位置」
  可供定位。
- **降级一律不报错**：结果 buffer 没有结构化数据 → `user-error` 并提示重新识别；后端不给 `box`
  （ollama 后端）→ 只显示文本列表并提示；找不到页图 / 读不出尺寸或内容 → 只显示文本，并在图区
  写明原因。缺 librsvg（`(image-type-available-p 'svg)` 为 nil）时图区画不出来，文本列表与光标
  联动仍可用。24 块一页时，光标移动触发的重绘约 2ms。
- **`eimg-core-fit-size` / `eimg-core-block-box`**：纯逻辑层新增两个函数（按上限换算缩放比与目标
  像素尺寸、从块 alist 取坐标框），预览与联动视图共用同一套换算与容错；异常输入一律返回 nil 而
  不 signal，坏的坐标只让那一块没有框。
- **transient 菜单「系统」组新增 `v`「联动视图」**：`eimg-menu` 里可直接进入视图。
- **底图内嵌上限 `eimg-ocr-view-max-embed-bytes`（默认 8 MB）**：单页底图字节数超过上限时
  不再把整张原图 base64 塞进 SVG，改为「只显示文本列表 + 一行可行动提示」（降低 `--dpi`
  重新识别，或裁剪图片后再识别）。Emacs 内置无法把图片缩放后导出字节（`create-image` 的
  `:width` 只影响显示），真降采样需要额外的图像后端；宁可明确降级，也不把几十 MB 的字符串
  塞进 SVG 让 `create-image` 解析卡死。判据只看 `stat`（`file-attribute-size`），不先读文件。
- **SVG 前缀缓存**：`--svg` 拆成「前缀（含底图 base64）+ `<rect>` 段」，前缀按
  `(路径 mtime size 原图宽高 显示宽高)` 缓存。24 块、5.6 MB SVG 的一页上，光标移动触发的
  重绘从 **62.6 ms/次** 降到 **2.2 ms/次**（GC 次数 7 → 3），且缓存命中与未命中产出的
  字符串逐字相同。

### 变更

- **rerun（`g`）的页图目录语义由「复用上一轮目录」改为「每轮新建目录 + 旧目录清理」**：
  这是修复「重跑页数变少时旧页图残留」的结构性改动，同时意味着 rerun 后结果 buffer
  指向的目录每次都是新的；决策与取舍见 `openspec/decisions.md` 的 D15 决策二。
- **`eimg-ocr-show-result-buffer` / `eimg-ocr-open-directory` / `eimg-ocr-setup-help`
  从 `eimg-transient.el` 移入 `eimg-ocr.el`**（连同 `eimg-ocr-setup-buffer-name` 与安装
  指引文本，后者改名 `eimg-ocr--setup-help-text`）。原因：autoload 记录的是命令的实际
  定义位置，三条命令留在菜单文件里就会生成 `(autoload … "eimg-transient")`，于是
  `SPC i m r`（只想看一眼上次的识别结果）先要把整份菜单文件与 `transient` 加载进来，
  正好否掉「不按菜单的人不为 transient 付成本」。放置判据是**依赖**而不是前缀：三条
  命令只用到 `eimg-ocr.el` 自己的常量。行为零变化，菜单里的符号引用照旧可用
  （`eimg-transient.el` 已 `(require 'eimg-ocr)`）。
- **autoload 映射表相应调整**：`eimg-ocr-test-generated-file-mapping` 里这三条从
  `eimg-transient` 改为 `eimg-ocr`，并新增 `eimg-autoload-test-ocr-utilities-load-no-transient`
  用例——仅加载 autoloads 时 `(featurep 'transient)` 为 nil 且三条命令的 autoload 文件名
  为 `"eimg-ocr"`。
- **测试产物排除规则**：`Makefile` 的 `EL_FILES` 排除模式从 `*-autoloads.el` 放宽到
  `*-autoloads*.el`（一次覆盖 `eimg-autoloads.el` / `-probe` / `-test-<pid>`），`.gitignore`
  与 `make clean` 同步覆盖 `*-autoloads-test*.el`——ERT 的 autoload 用例把生成物写到仓库根
  （`loaddefs-generate` 记的是相对输出目录的路径，写 `/tmp` 会得到解析不到的 `../eimg-*`），
  正常跑完即删，Ctrl-C 打断时会残留。
- **`auto` 后端顺序由 `rapidocr → tesseract` 改为 `rapidocr → ollama → tesseract`**：
  几何引擎可用时行为不变；只有 rapidocr 不可用时才轮到 VLM，而不是让低精度的 tesseract
  先吃掉请求。ollama 锁定后的输入不支持（tiff / gif / webp）直接退出码 3，不回退 tesseract。
- **ollama 模型无内置默认**：模型必须显式配置（`--ollama-model` / config.json 的
  `ollama_model`），未配置即判 ollama 不可用；URL 有默认 `http://127.0.0.1:11434`。
- **PDF 页图临时目录走「交接制」**：输入含 PDF 且调用方没显式给 `:page-images-dir` 时，
  `eimg-ocr--run` 自动建临时目录让 CLI 落每页栅格图，成功后连同结果交给结果 buffer；结果
  buffer 被 kill、或 `g` 重跑覆盖旧结果时清理旧目录（新结果不再引用它，不删就是每重跑一次泄漏
  一个目录），失败 / 取消 / 解析失败则当场删（这几条路上没有任何 buffer 接手）。删除前校验目录
  位于 `temporary-file-directory` 之下，元数据被改成任意路径也不会误删用户目录。单图输入不落
  页图，视图回退用 `:source` 原图。
- **参数校验优先于查询动作**：`--page-images-dir` 的校验在 `main()` 的 `try` 内、与 ollama URL
  校验同一口径，故 `--list-backends --page-images-dir /x` 也会顺手建出 `/x`（已知副作用，
  只会是一个空目录）。
- **联动视图的 SVG 前缀缓存由单条扩为容量 3 条的 LRU**：仍按
  `(路径 mtime size 原图宽高 显示宽高)` 做键，命中即把条目提到表头、超出容量砍表尾。两页之间
  来回翻着对比时不再每次重建几 MB 的底图 base64 字符串；单页内重绘的命中语义不变。
- **`openspec/tech-debt.md` 重构为「待办 / 已关闭 / 已转入 README」三区**：18 条压缩为 9 条
  待办（标题带 P 级与成本，正文固定「现状 / 影响 / 验证方式 / 改进方向」四段）、4 条已关闭
  索引（关闭必须给日期与可验证证据）、5 条指向 README 的指针（用户可见的边界不在两处重复
  维护）。
- **`README.org` 补齐三处用户可见信息**：CA 证书问题的成因与影响面（哪类解释器会撞、脚本
  如何按候选表兜底、不经脚本的下载仍会撞）、`--tessdata` 内容校验不通过时该改什么、
  `--list-backends` / `--check` 这类探测命令不要放进补全 / `init` / hook。「开发与验证」里的
  ERT 条数由 146（已漂移）更正为 215。

### 修复

- ollama 后端安全加固（Phase 4 审查驱动）：
  - `--ollama-url` 只接受 `http` / `https`，拒绝 `user:pass@` 形式与含空白字符的主机名（退出码 5），
    避免把图片发往任意协议/主机的输入面
  - 拒绝跟随 HTTP 重定向（302/307 不再被跟随），防止请求被引向别的主机
  - 错误文案与 `--list-backends` 的 `reason` 对 URL 中的 userinfo 做脱敏（`***@`），凭据不再进 stderr / buffer
  - `_probe_ollama` / `run_ollama` 捕获 `http.client.HTTPException`，非法 URL 不再打出 traceback、退出码回归 0/2/3/4/5 契约
  - ollama 响应体上限 16 MB、单张图片上限 32 MB（超限分别按退出码 4 / 3 处理）
- 联动视图审查修复：热区与 SVG 框共用同一份坐标归一（颠倒 / 越界 / 零尺寸的 block 不再「画得对
  却点不中」）；坐标换算基准统一为 `px-w/width` 与 `px-h/height`，热区正向换算与鼠标兜底反向
  换算互为逆运算（`:scale` 被钳到下限时两轴实际比例与之不自洽，故不参与换算）；`g` 重跑时按
  「所有权记账」清理——只删自己创建的页图目录，不再误删正在使用的那一个。
- **rerun 重跑页数变少时旧页图残留**：`g` 重跑不再复用同一个页图目录，改为每轮新建目录写入，
  旧目录由结果 buffer 的 stale-dir 清理删除——上一轮多出来的 `pN.png` 不会再留在正在使用的
  目录里冒充本轮结果。
- **ollama 探测与识别的超时改为整体预算**：3 秒探测、300 秒识别都改按「从现在到 deadline」
  计，连接、发送、读响应体共用同一份预算，慢速滴流不再能拖住 `--list-backends` / `--check`
  与识别；预算耗尽单独给「整体超时」文案，不再报成「不可达」（每块读取本身仍受单次 socket
  超时约束，故上限是「预算 + 一次底层读」）。
- **`--tessdata` 下载增加 SHA256 内容校验**：`chi_sim` / `eng` 的内容哈希钉在
  `bin/eimg-ocr-setup` 里，下载时增量计算比对，不一致即失败并删掉 `.part` 半成品；本地已存在
  且校验通过则跳过下载；未登记哈希时只给警告并退回体积校验，不再静默放行。
- **无 `pdfinfo` 时 `--pdf-pages` 部分越界不再静默截断**：越界判据从「总页数」扩展为
  「请求页数 vs 实际渲染页数」——`--pdf-pages 2-9` 打在 3 页文档上，即使没装 `pdfinfo`
  也以退出码 3 报错（文案给出越界页号与实际渲染页数），不再静默只识别 2 页。`pdfinfo`
  退化为文案增强（有它时仍报「共 3 页」）；多 PDF 混排 + 部分越界在两种环境下统一为
  整批失败。

### 测试

- 新增 8 条 ollama ERT：代码围栏剥除、拒绝重定向、响应体过大、非 http(s) URL、
  含凭据 URL 被拒且不泄漏、config.json 凭据不泄漏、超大图片被拒、`--list-backends` 行序

## [0.1.0] - 2026-10-27

首版交付两组能力：OCR（CLI、纯逻辑层、异步进程层、结果 buffer、transient 菜单）与截图链路
（采集、选择预览、图片插入、embark 集成）。后者四个模块从宿主仓库迁入，eimg 内不再有跨仓
软依赖，迁移决策见 `openspec/decisions.md` 的 D10。

### 新增

- **`bin/eimg-ocr` CLI**：多后端（`rapidocr` / `tesseract` / `auto`）、图片与 PDF 统一入参、
  PDF 经 `pdftoppm` 栅格化后逐页识别（`--pdf-pages` 选页、`--dpi` 控精度）、三种输出形态
  （`text` 页间 `\f` 分隔 / `lines` 每行一条 / `json` 结构化）、`--list-backends` 探测。
  退出码契约固定为 0/2/3/4/5，stderr 统一带 `eimg-ocr: ` 前缀。
- **`bin/eimg-ocr-setup` 安装与体检脚本**：`--check`（只读体检）/ `--reuse-pdf-toc-ocr`
  （复用已有 venv，只写配置）/ `--rapidocr`（新建 venv 并装依赖）/ `--tessdata`（下载
  chi_sim + eng），配 `--yes` / `--dry-run`（零写入零联网预览）/ `--python` /
  `--tessdata-dir`。模块顶层零 I/O，探测逻辑从 `bin/eimg-ocr` 复用。
- **`eimg-core.el` 纯逻辑层**：退出码 → 文案与排障提示（`eimg-core-exit-message` /
  `eimg-core-exit-hint`）、plist → argv 拼装（`eimg-core-build-args`，选项顺序固定）、
  CLI JSON → 页/块结构（`eimg-core-parse-json`）、org 与纯文本渲染
  （`eimg-core-render-org` / `eimg-core-render-text`）、临时文件命名。
- **`eimg-ocr.el` 异步进程层**：`make-process` 起 CLI，stdout / stderr 各一干净 buffer，
  四态收尾（完成 / 失败 / 取消 / 超时），整体超时 `eimg-ocr-timeout`，进度进模式行。
- **结果 buffer**：`eimg-ocr-mode`（派生自 `special-mode`）+ `*eimg-ocr*`，六条键位
  `y` 复制 / `i` 回插来源 buffer / `w` 存盘 / `g` 重跑 / `q` 关闭 / `k` 取消；
  首行元信息（org 风格 `# eimg-ocr: `、text 风格 `;; eimg-ocr: `）在复制 / 回插 / 存盘时剥离。
- **三个入口命令**：`eimg-ocr-region`（框选识别，`C-u` 同时插入）、`eimg-ocr-file`
  （选图片或 PDF）、`eimg-ocr-history`（从最近截图里挑）；另有 `eimg-ocr-cancel`、
  `eimg-ocr-list-backends`。三者与结果 buffer 的 `g` 共用同一条「拼参数 → 起进程 → 四态收尾」路径。
- **`eimg-transient.el` 菜单 `eimg-menu`**：三组动作（采集 `s/o/h`、文件 `f/p/b`、
  系统 `?/r/d/S`）+ 三个会话内 infix（`-b` 后端 / `-l` 语言 / `-D` DPI）。
- **`eimg.el`**：版本常量 `eimg-version` 与模块加载入口。
- **截图采集 `eimg-capture.el`**：`eimg-capture`（调外部截图工具，双条件判成功，
  截图画 `shot-<YYYYMMDD-HHMMSS>.png` 且绝不覆盖）、`eimg-capture-open-directory`，
  以及 plist 形态的截图历史（同一路径去重、按 `eimg-capture-history-size` LRU 截断、
  每次 push 立即落盘、读取只 `read` 不 `eval` 并逐条结构校验）。
- **选择预览 `eimg-select.el`**：consult 多源候选（截图历史 + 递归扫描
  `eimg-select-item-roots`）、右侧标注、posframe child frame 预览与尺寸换算
  （`eimg-select--preview-fit` 纯函数，超父 frame 上限时等比缩小而非静默裁剪）。
- **图片插入 `eimg-insert.el`**：`eimg-insert-path`（插入链接，`C-u` 内联）/
  `eimg-insert-display`（插入内联图片），四模式格式分派（裸路径 / org / markdown /
  其他）、选区文本当路径解析与替换、`image-scaling-factor` 中和。
- **embark 集成 `eimg-embark.el`**：completion category `eimg/image` 注册到
  `embark-keymap-alist`，`C-.` 动作菜单含 `i` 插入链接 / `b` 插入内联图片 / 打开 /
  删除 / 复制路径，multitarget 支持。
- **ERT 用例 123 条**（`test/eimg-core-test.el` / `test/eimg-ocr-test.el` /
  `test/eimg-transient-test.el` / `test/eimg-capture-test.el` /
  `test/eimg-select-test.el` / `test/eimg-insert-test.el`）+ fixtures
  （`test/fixtures/hello.png`、`test/fixtures/three-pages.pdf`）。

### 变更

- **截图链路命名统一为 `eimg-` 前缀**：宿主仓库的 `+thomas/screenshot*` 迁入后变为
  `eimg-capture*`，`+thomas/insert-image-path` / `+thomas/insert-image-display` 变为
  `eimg-insert-path` / `eimg-insert-display`；embark 动作 category 由宿主命名改为
  `eimg/image`。包内不提供 `+thomas/*` 兼容 alias（旧名一律不再可用）。
- **跨仓软依赖改为同仓直连**：`eimg-ocr--capture-function` 的探测链简化为
  「`eimg-ocr-capture-function` → `eimg-capture`」，删除对宿主截图命令的 `fboundp`
  探测；transient 菜单的 `s` / `p` / `b` 直连 `eimg-capture` / `eimg-insert-path` /
  `eimg-insert-display`，删掉两个转调桥接命令及其缺失文案函数。

### 修复

以下问题都在本轮实现过程中引入并当场修掉，记录于此以免回归：

- **sentinel 状态判定改用 `process-status`**：事件串对「因信号死亡」的描述取自
  `strsignal`，会经 gettext 翻译（本机 zh_CN 下是「已杀死」/「中断」），按 `killed` /
  `interrupt` 字面匹配恒不命中，取消与超时两条路径整个哑掉。改判 `process-status`
  （`exit` / `signal`）+ `process-exit-status`，与 locale 无关。
- **输出按阅读顺序排序**：CLI 侧新增 `sort_blocks_reading_order`（按 y 中心聚行 +
  行内按 x0），`text` / `lines` / `json` 三种格式共用同一份块序列。
- **tesseract 在 `--tessdata-dir` 下不再静默退化**：把配置名 `tsv` 放在命令行末尾的写法
  只在默认 tessdata 目录下可用，一旦传 `--tessdata-dir`，tesseract 只在该目录里找配置
  文件、直接失败。改用 `-c tessedit_create_tsv=1`（配置项而非配置文件），两种情形都成立。
- **截图函数返回值契约收紧**：`eimg-ocr--capture` 走 `call-interactively` 并把结果分三态
  报错（非字符串 / 路径不可读 / 函数自身 signal），文案可区分「命令没返回」与「返回了但
  文件不在」。
- **测试 TMPDIR 钉死**：`make test` 把 `TMPDIR` 显式指向 `$(CURDIR)/.tmp-test`，避免 ERT
  的 `make-temp-file` 产物随调用者环境漂到别的仓库（跨仓污染且测试自己看不见）。

以下两条是**真实安装后**（2026-10-27，`--rapidocr` + `--tessdata`）暴露的缺口，属 0.1.0
代码既有缺陷，故并入本节而非另起版本号（`eimg.el` 的 `Version: 0.1.0` 尚未打 tag）：

- **`--tessdata` 下载兜底 CA bundle**：解释器（本机 `/opt/miniforge/bin/python3`）编译期的
  openssl cafile 路径可能不存在，此时它既不读系统信任库、也不看 `SSL_CERT_FILE`，表现为
  `SSL: CERTIFICATE_VERIFY_FAILED ... unable to get local issuer certificate`——而系统信任
  库本身是好的（`curl` 能通）。现在 `download()` 先按
  `/etc/ssl/cert.pem` → `/etc/ssl/certs/ca-certificates.crt` →
  `/etc/pki/tls/certs/ca-bundle.crt` → `certifi.where()`（已安装才用，**不新增依赖**）逐项
  `load_verify_locations`，用第一个成功的，全不可用才回退 `ssl.create_default_context()`；
  证书类失败的错误文案带可执行指引（`SSL_CERT_FILE=/etc/ssl/cert.pem … --tessdata`）与
  本次实际用的 CA。实测：不设 `SSL_CERT_FILE` 时基线 `urlopen` 必失败，改后同一环境
  真实下载 chi_sim + eng 成功。
- **tesseract 默认使用 eimg 安装的语言数据**：`--tessdata` 把语言数据装到
  `~/.local/share/eimg/tessdata/`，但 CLI 只探 tesseract 的默认目录
  `/usr/share/tessdata`（本机只有 `afr`/`osd`）→ 装好却 `available=false`，且 elisp 侧没有
  任何途径传 `--tessdata-dir`。现在 CLI 在**未显式传入** `--tessdata-dir` 时自动使用该目录
  （前提：目录存在且含 `*.traineddata`），探测 `reason` 注明「默认使用 eimg 安装目录: …」，
  显式传入仍以显式为准；elisp 侧新增 defcustom `eimg-ocr-tessdata-dir`（默认 `nil` = 交给
  CLI），接入 `eimg-ocr--config-defaults` 的参数链。实测同一台机器上
  `--list-backends` 的 tesseract 由 `available=false` 变为 `available=true`，
  `bin/eimg-ocr --backend tesseract test/fixtures/hello.png` 输出 `Hello 世界`。

### 技术细节

- **elisp 侧零第三方依赖**：`eimg-core.el` / `eimg-ocr.el` 只 require 内置库（`cl-lib` /
  `subr-x` / `json`），保证能在 `emacs -Q --batch` 里加载，`make test` 不依赖 straight 构建路径。
- **transient 延迟加载**：`eimg.el` 不 require `eimg-transient.el`，`;;;###autoload` 之后紧跟
  一条**纯数据**的 `(autoload 'eimg-menu "eimg-transient" nil t)`——`loaddefs-generate` 会逐字
  复制它，不展开宏，因此 autoloads 文件被加载时不需要 `transient`；真正的
  `transient-define-prefix` 放在其后，首次 `M-x eimg-menu` 才加载整文件。
- **CLI 只依赖 Python 标准库**，且进程内永不 `import rapidocr` / numpy / PIL：那些库只装在
  某个 venv 里，识别一律 `subprocess` 起「探测到的目标解释器」跑内联脚本，结果经临时文件回传。
- **安装必须显式**：配置、`init`、任何 hook 都不下载不安装；`--dry-run` 提供零副作用预览。
- **不登记 `versions.lock.el`**：thomas-emacs 侧用 straight `:local-repo` 直连本地开发仓，
  lock 条目无效；`:files` 显式 `(:exclude "eimg-autoloads.el")`，避免生成物被软链后穿透写回源仓库。
