# 决策日志

格式：日期 + 决策 + 理由。编号只增不改；被推翻的决策保留原文并追加「已被 Dx 取代」。

## D1 仓库形态与接入方式（2026-10-27）

- **决策**：eimg 是独立 git 仓库（本地 `~/Workspace/eimg`，远端 `git@github.com:awerdx520/eimg.git`
  尚未创建〔该状态已过时，见 D9：远端已创建并推送〕），thomas-emacs 通过 straight `:local-repo` 直连接入，
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
- **已被 D10 取代（2026-10-27）**：截图能力已迁入本仓，探测链只剩
  「`eimg-ocr-capture-function` → `eimg-capture`」，菜单项改为直连本包命令。

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

## D9 远端仓库创建与传输方式（2026-10-27）

- **决策**：远端 `https://github.com/awerdx520/eimg.git` 已创建，`main` 分支已推送并建立
  跟踪（`origin/main`）。传输方式取 **HTTPS**，而非 D1 预设的 SSH。
- **理由**：本机到 `github.com:22` 与 `ssh.github.com:443` 均被重置
  （`kex_exchange_identification: read: Connection reset by peer`），SSH 路径不可用；同时
  `el-chronos` / `cn-word-boundary` / `seshat` 三个自研仓的 `origin` 全部是 HTTPS，跟随家族
  惯例可减少一次凭据体系分支。代价是推送依赖 credential store（`credential.helper = store`）。
- **不变**：D1 的附则一（不登记 `versions.lock.el`）与附则二（`:files` 排除 autoloads）继续
  有效，不受传输方式影响。

## D10 截图能力迁移（2026-10-27）

- **决策**：把截图链路整体迁入 eimg，切成四个模块——`eimg-capture.el`（采集：外部命令
  调用、目标文件命名、历史读写）、`eimg-select.el`（选择：consult 多源候选、posframe
  预览、尺寸换算）、`eimg-insert.el`（插入：四模式格式分派、选区当路径、内联显示）、
  `eimg-embark.el`（embark 动作菜单）。宿主仓库只保留接线（straight recipe、键位、
  三个配置项的 `setq`），不再持有实现。D5 的软依赖探测链随之取消：运行期只剩
  「`eimg-ocr-capture-function` → `eimg-capture`」，一个都没有才 `user-error`。
- **理由**：① 跨仓软依赖把契约写在对方 docstring 里，`make test` 看不到，上游改一行
  成功分支的返回值，识别会静默退化成「什么也没发生」；② 四个模块的可执行代码约 87%
  可原样搬移（只有命名与 `init-const` 常量引用要改），迁移成本远低于长期维护两份真相；
  ③ 键位与历史文件路径保持零变化，用户感知不到迁移（迁移不做任何键位重排）。
- **风险处置**：唯一有状态的是截图历史文件——若两套采集并存，同一张截图会被写进两份
  历史、候选列表出现重复。故分两步并在**同一轮**完成：先建四模块但不接线（宿主仍是
  唯一采集方，历史只写旧文件），确认模块自身测试全绿后原子切换（一次性改宿主接线 +
  OCR 探测链），切换后只有 `eimg-capture` 会写历史。不做「双写兼容期」：双写本身就会
  制造重复候选，而 eimg 与宿主读写的是同一个 plist 形态，切换不需要数据迁移。
- **附则一**：包内**不提供** `+thomas/*` 兼容 alias（`+thomas/screenshot` /
  `+thomas/insert-image-path` / `+thomas/insert-image-display` 一律不再可用）。理由是
  alias 会让「迁移完成」变成永久半迁移状态，且 `+thomas/` 前缀在本仓是外来命名。
  宿主的旧键位改指新命令即可，用户侧无需知道旧名。
- **附则二**：embark 动作 category 由宿主命名改为 `eimg/image`，注册值仍是**已定义**的
  keymap 符号（`eimg-image-map`），与 `eimg-select--read` 的 `:category` 逐字一致——
  embark 对 `embark-keymap-alist` 的取值做 `symbol-value`，差一个字符就是按 `C-.` 时
  `void-variable`。

## D11 交互命令 autoload 策略：包内 cookie + embark 注册的补偿形态（2026-10-27）

- **决策**：13 个用户入口在**包内**加 `;;;###autoload`（12 个交互命令 + `eimg-embark-register`），
  文件名映射交给 `loaddefs-generate` 按实际定义位置生成；宿主侧只写 `:defer t`，
  **不用** `use-package :commands`。embark 的 `C-.` 注册由
  `;;;###autoload (with-eval-after-load 'embark (eimg-embark-register))` 承担，
  `eimg-embark-register` 经另一条纯数据 `autoload` 声明拉入 `eimg-embark.el`。
- **理由一（为什么不用 `:commands`）**：`:commands` 的隐式 autoload 假设「文件名 = 符号名」。
  本包三个命令是 `eimg-ocr-*` 前缀却定义在 `eimg-transient.el`
  （`eimg-ocr-show-result-buffer` / `-open-directory` / `-setup-help`——它们只服务菜单的
  「系统」组，且用 transient 侧的 buffer 名常量），`:commands` 会指向不存在的文件。包内
  cookie 的映射由 `loaddefs-generate` 生成，实测这三条正确指向 `eimg-transient`。
- **理由二（补偿为什么不能 require）**：`(with-eval-after-load 'embark (require 'eimg-embark))`
  会在真实链路里 **Recursive require**：embark 加载完成 → autoloads 的钩子触发 require →
  加载 `eimg-embark.el` → 文件顶层同一条钩子在「embark 已 loaded」的上下文立即执行 →
  再 require 正在加载的 feature → 报错，keymap 与注册一起废掉（实测：手动
  `--eval` 复现 `Recursive ‘require’ for feature ‘eimg-embark’`）。改成「调用一个 autoload
  函数」后链路自洽：未加载 → autoload 触发加载 → 加载完成后函数已定义 → 调用一次；
  已加载上下文里加载本文件 → 同一条 form 只调用一个幂等函数，不引回自身。
- **不变的判据**：`eimg-menu` 仍是「cookie + 纯数据 autoload 声明」（D8 的理由成立）；
  仅 `*eimg-ocr*` buffer 内使用的 5 条命令与菜单内部包装 `eimg-menu-run-*` 不加 cookie
  —— 它们工作时包必然已加载，加 cookie 只会把 buffer 内按键误当启动入口。
- **机械检查**：`test/eimg-autoload-test.el` 6 条用例（cookie 覆盖 + 反向断言 + embark
  补偿形态 + 真跑 `loaddefs-generate` 的 13 条映射 + 仅加载 autoloads 时
  `featurep-eimg=nil` / `fboundp` 为 t + embark 加载后注册成功）。
- **同日修正（2026-10-27，不推翻本决策）**：理由一里「三条命令定义在 `eimg-transient.el`」
  已不再成立——`eimg-ocr-show-result-buffer` / `-open-directory` / `-setup-help` 连同
  `eimg-ocr-setup-buffer-name` 与指引文本移入了 `eimg-ocr.el`。触发点是理由一本身：
  `loaddefs-generate` 「实测这三条正确指向 `eimg-transient`」既是 `:commands` 不可用的
  证据，也意味着按 `SPC i m r` 看结果要先加载整份菜单文件与 `transient`。放置判据因此
  明确为**依赖**而非前缀（三条命令只用 `eimg-ocr.el` 自己的常量），映射表三条改为
  `eimg-ocr`，并新增 `eimg-autoload-test-ocr-utilities-load-no-transient` 锁住
  「仅加载 autoloads 时 `(featurep 'transient)` 为 nil 且三条命令 autoload 文件名为
  `"eimg-ocr"`」。`eimg-menu` 仍指向 `eimg-transient`（D8 的结论不变）。
