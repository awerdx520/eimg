# 更新日志

本项目所有值得注意的变更都记在这里。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号参考 [语义化版本](https://semver.org/lang/zh-CN/)。

## [未发布]

### 新增

- **交互命令的 autoload cookie**：13 个用户入口（截图 2 / 插入 2 / OCR 4 / 结果与安装
  相关 3 / 菜单 1 / embark 注册 1）带 `;;;###autoload`，宿主可用 `use-package :defer t`
  延迟加载本包而不丢按键——`make` 之外的文件名映射由 `loaddefs-generate` 按实际定义
  位置填写（`eimg-ocr-show-result-buffer` / `-open-directory` / `-setup-help` 定义在
  `eimg-transient.el`，故指向该文件；不用 `use-package :commands`，它假设文件名等于符号名）。
- **embark 注册的延迟加载补偿**：`eimg-embark.el` 把注册抽成 `eimg-embark-register`
  并带 autoloads 补偿 form，`:defer t` 下 `C-.` 菜单仍在 embark 加载时注册。补偿**不能**
  写成 `(with-eval-after-load 'embark (require 'eimg-embark))`——那会 `Recursive require`。
- **`test/eimg-autoload-test.el`**：6 条用例锁定 cookie 覆盖、反向断言（buffer-only 命令
  不加 cookie）、embark 补偿形态、真跑 `loaddefs-generate` 的映射表、仅加载 autoloads 时
  的 `fboundp` / `autoloadp` 语义、以及 embark 加载后的注册结果。

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
