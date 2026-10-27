# 决策日志

格式：日期 + 决策 + 理由。编号只增不改；被推翻的决策保留原文并追加「已被 Dx 取代」。

## D1 仓库形态与接入方式（2026-10-27）

- **决策**：eimg 是独立 git 仓库（本地 `~/Workspace/eimg`，远端 `git@github.com:awerdx520/eimg.git`
  尚未创建），thomas-emacs 通过 straight `:local-repo` 直连接入，
  `:files ("eimg*.el" (:exclude "eimg-autoloads.el"))`、`:build (:not compile native-compile)`。
- **附则一：不登记 `versions.lock.el`**。`:local-repo` 下 straight 用的是开发仓 live HEAD，
  lock 条目无效；`M-x straight-freeze-versions` 一旦误跑，会把本地 HEAD 写回 lock，制造
  「lock 说某版本、实际跑另一个」的漂移。
- **附则二：`:files` 必须显式 `(:exclude "eimg-autoloads.el")`**。straight 的 autoloads
  步骤要写同名文件，不排除会把它软链进 build 目录后**穿透写回源仓库**（生成物进版本库，
  且与源文件必然漂移）。
- **理由**：OCR 能力（CLI + elisp 交互）与 thomas-emacs 的截图 / 插入能力并行演进，独立
  仓库让 eimg 能在 `emacs -Q` 下自测、也让 `make full-check` 不依赖宿主配置；`:build` 禁
  编译使源码改动即时可见（改完 `straight-rebuild-package` 即生效，无需 push / pull / 重启）。

## D2 模块边界：core / ocr / transient 三层（2026-10-27）

- **决策**：
  - `eimg-core.el` = **纯逻辑**：退出码映射、plist → argv、CLI JSON → 页/块、org 与纯文本
    渲染、临时文件名。不启动子进程、不碰 buffer、不读环境变量。
  - `eimg-ocr.el` = **进程层 + 呈现层 + 编排层**：`make-process` 异步调用、四态收尾、进度
    状态、结果 buffer 与键位、三个入口命令。
  - `eimg-transient.el` = **只做菜单聚合**：三组动作 + 三个会话内 infix，不含识别逻辑。
  - `eimg.el` = 版本常量 `eimg-version` + 加载 `eimg-core` / `eimg-ocr`，**不** require
    `eimg-transient`。
- **理由**：纯逻辑不碰 I/O 才能被 ERT 完整离线覆盖（不需要真跑 OCR）；进程层与呈现层分离
  保证「一次识别」只有一条收尾路径，避免长出「一处失败给提示、另一处失败静默」的分裂；
  菜单独立成文件是 D8 的前提。零第三方依赖是硬边界：`eimg-core` / `eimg-ocr` 顶层只能
  require 内置库，否则 headless 的 `emacs -Q` 测试进程直接加载失败。

## D3 CLI 契约与退出码是单一事实来源（2026-10-27）

- **决策**：OCR 后端通过统一 CLI 契约（`bin/eimg-ocr`）+ 退出码解耦；elisp 侧**只按退出码
  分支，不解析 stderr 文案**。退出码语义的唯一来源是 `eimg-core-exit-codes` /
  `eimg-core-exit-hints`，`bin/eimg-ocr` 的 `EXIT_*` 常量与之一一对应，README 的退出码表
  也照此抄写。
- **错误文案映射表**：

  | 码 | 含义 | stderr 关键子串 | elisp 侧提示来源 |
  |----|------|------------------|-------------------|
  | 0 | 成功（含 `--list-backends` 查询结果） | — | — |
  | 2 | 无可用 OCR 后端 | `未找到可用的 OCR 后端` | `eimg-core-exit-hint` 指向 `--rapidocr` / `--tessdata` |
  | 3 | 输入不可读 / 不存在 / 不支持格式 / 页码越界 / PDF 无法栅格化 | `无法读取输入` | `eimg-core-exit-hint` 列支持的扩展名 |
  | 4 | 识别失败（含后端超时） | `识别失败` | 提示换后端或提高 `--dpi` |
  | 5 | 参数错误 | `参数错误` | 提示看 `--help` |

- **理由**：stderr 文案会随版本、locale、后端日志变化，退出码稳定；把「码 → 文案 + 排障
  提示」收成一张表，CLI 加一个码时只需改一处，不会出现「CLI 报了个码、elisp 显示未知错误」。
  超时用伪退出码 124（沿用 coreutils `timeout` 约定）与 CLI 自己的 0/2/3/4/5 不冲突。

## D4 安装必须显式（2026-10-27）

- **决策**：`:config`、`init`、任何 hook 都不安装、不下载；首次使用由用户显式执行
  `bin/eimg-ocr-setup`（`--check` / `--reuse-pdf-toc-ocr` / `--rapidocr` / `--tessdata`）。
  脚本另设 `--dry-run`：只打印将执行的命令与将下载的 URL 和目标路径，**零写入零联网**。
  Emacs 侧的 `eimg-ocr-setup-help` 只把指引写进 buffer，一条命令都不执行。
- **理由**：后端与语言数据动辄数百 MB、耗时数分钟，还要写 `~/.local/share` 或建 venv。
  隐式触发会让「打开一个菜单」变成「机器上多了个虚拟环境」，失败时连日志都找不到；
  `--dry-run` 是这条约束的出口——想先看清会做什么，有一个零副作用的入口。

## D5 截图能力软依赖（2026-10-27）

- **决策**：首轮不迁移截图能力。运行期按 `eimg-ocr-capture-function`（显式配置）→
  `eimg-capture` → `+thomas/screenshot` 的顺序用 `fboundp` 探测，取第一个可用者；
  一个都没有时 `user-error` 把用户指回 thomas-emacs。截图函数必须是**交互命令**，经
  `call-interactively` 调用，契约是「命令执行完毕后的返回值即截图文件绝对路径」。
- **理由**：两仓并行推进时，OCR 不该被截图迁移阻塞；探测用 `fboundp` 而**不** require 宿主
  文件，否则 `emacs -Q` 下加载即失败。迁移完成后让新函数占用 `eimg-capture` 这个名字，
  OCR 侧零改动。菜单项**不因软依赖缺失而隐藏**——项留着、调用时报错，用户才知道缺什么。

## D6 配置链：ARGS > defcustom > CLI 默认（2026-10-27）

- **决策**：三层优先级由 `eimg-ocr--run` 统一收口——调用方传入的 ARGS（配置 plist）显式
  给出的键 > `eimg-ocr--config-defaults` 里的 defcustom 取值 > CLI 自己的默认（值为 nil
  的键根本不进 argv）。菜单的 infix 只提供**改过的那几项**，其余自动落到用户配置上；
  唯一例外是 `:format`：ARGS 给了也忽略，argv 恒为 `--format json`。
- **理由**：菜单里换一次后端不该改掉用户配置（否则「我只试了下 tesseract」会变成「配置
  文件被改了」，退出 Emacs 后还在）。把链路收在 `--run` 一处，命令、菜单、重跑三条路径
  都走同一份默认值解析，不会出现「菜单里生效、命令里不生效」。

## D7 异步进程层与四态收尾（2026-10-27）

- **决策**：`eimg-ocr--start` **立即返回**进程对象，主线程从不为子进程让路；收尾一律由
  sentinel 完成，状态收敛为四态 `finished` / `failed` / `cancelled` / （超时按 `failed` +
  退出码 124）。状态判定用 `process-status` + `process-exit-status`，**禁止**匹配事件串文案。
  stderr 用自建 `make-pipe-process`（`:sentinel #'ignore'`）再接给 `:stderr`。
- **理由**：一次 OCR 十几秒，同步等会把用户界面卡住。事件串对「因信号死亡」的描述取自
  `strsignal`，会经 gettext 翻译（本机 zh_CN 下是「已杀死」/「中断」），按 `killed` /
  `interrupt` 字面匹配永远不命中——取消与超时两条路径整个哑掉，且风险形态是*假绿*
  （英文 locale 下全绿）。`make-process` 直接给 `:stderr` buffer 时 Emacs 会建内部 pipe
  进程，其默认 sentinel 往该 buffer 追加「Process … stderr finished」，污染原文。

## D8 transient 延迟加载（2026-10-27）

- **决策**：`eimg-menu` 用 `transient-define-prefix` 定义，但 autoload 写成
  `;;;###autoload` 下面紧跟的**纯数据声明** `(autoload 'eimg-menu "eimg-transient" nil t)`，
  真正的宏调用放在它之后；`eimg.el` 不 require 本文件。三个 infix 会话内生效，不改 defcustom。
- **理由**：`transient-define-prefix` 虽声明了 `autoload-macro = expand`，但
  `loaddefs-generate` 展开它必须先 load 本文件，而实测两种情形都失败（输出文件不在仓库根时
  记下的是相对路径 → `file-missing`；在仓库根时 loaddefs 正处在扫文件上下文 →
  `cl-lib` / `jka-compr` 报 `Recursive load`）。失败后 loaddefs 会把**宏调用原样**抄进
  autoloads 文件，那份文件一被加载就要有 `transient-define-prefix`，等于每台机器启动即加载
  transient——正好否掉「不按菜单的人不为它付启动成本」。纯数据声明能被逐字复制、零依赖。
