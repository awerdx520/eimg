;;; eimg-transient.el --- eimg 的 transient 菜单：三组动作与三个会话内 infix  -*- lexical-binding: t; byte-compile-warnings: (not unresolved noruntime) -*-

;; Author: thomas
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, tools, ocr
;; URL: https://github.com/awerdx520/eimg

;;; Commentary:

;; 本文件只做一件事：把 `eimg-ocr' 的入口命令收成一个 `eimg-menu'，外加三个
;; **会话内有效**的 infix（后端 / 语言 / DPI）。
;;
;; 四条设计约束，改动时不要打破：
;;   1. **延迟加载**：`eimg.el' **不** require 本文件，因此 `(require 'eimg)' 之后
;;      `(featurep 'transient)' 仍是 nil——不按菜单的人不为 transient 付启动成本。
;;      首次 `M-x eimg-menu' 由 straight 生成的 autoloads 触发整文件加载；
;;      `;;;###autoload' cookie 是这条链路的唯一入口，删掉后菜单就只剩
;;      「void-function eimg-menu」。
;;   2. **infix 不改 defcustom**：三个 infix 的取值由 `eimg-ocr--menu-args' 解析成
;;      配置 plist，再作为 ARGS 传给 OCR 命令（ARGS 优先于 defcustom）。在菜单里
;;      换一次后端不该悄悄改掉用户配置——否则「我只在这个菜单里试了下 tesseract」
;;      会变成「配置文件被改了」，而且退出 Emacs 后还在。优先级链的落地位置是
;;      `eimg-ocr--run'：`ARGS' > `eimg-ocr--config-defaults'（defcustom）> CLI 默认，
;;      因此菜单只需给出**改过的那几项**，其余键自动落到用户配置上。
;;   3. **菜单项全部直连本包命令**：截图（`eimg-capture'）与插入
;;      （`eimg-insert-path' / `eimg-insert-display'）都已在本包内，菜单里不再有
;;      「转调到别处、缺失时报错」的中间层——项指向哪个命令，按键就执行哪个命令，
;;      不存在「菜单显示得出来、按下去才说能力缺失」的两套真相。
;;   4. **安装只在用户手里**：`eimg-ocr-setup-help' 只把指引写进 buffer，绝不执行
;;      任何安装命令（后端与语言数据动辄几百 MB、数分钟，必须由用户显式触发）。
;;      注意它的**定义位置**是 `eimg-ocr.el'（同理 `eimg-ocr-show-result-buffer' /
;;      `eimg-ocr-open-directory'）：本文件只在菜单 suffix 表里引用符号。定义若留在
;;      本文件，autoload 就会指向 `"eimg-transient"'，用户按 `SPC i m r' 看一眼结果
;;      也得先加载整份菜单文件与 `transient'。
;;
;; 键位（与计划 D8 一致）：
;;   采集：`s' 截图（写历史、返回路径）/ `o' 截图并识别 / `h' 历史截图识别
;;   文件：`f' 选择文件识别 / `p' 插入图片链接 / `b' 插入内联图片
;;   系统：`?' 列出后端 / `r' 查看结果 / `d' 打开截图目录 / `S' 安装指引
;;
;; 三处需要说明的实现选择：
;;   - `o' / `h' / `f' 绑的是 `eimg-menu-run-*' 薄包装（而非 `eimg-ocr-region' 等
;;     本体）：transient 调用 suffix 走 `call-interactively'，**不会**把 infix 取值
;;     当参数传进去，因此必须有一层把 `(eimg-ocr--menu-args)' 作为 ARGS 显式传入。
;;     OCR 命令本身保持与菜单无关（`&optional ARGS' 是唯一接口）。
;;   - `s' / `p' / `b' 直接绑本包命令，不经任何包装：它们不接受 infix 参数
;;     （截图工具与插入格式都与后端 / 语言 / DPI 无关），少一层包装就少一处
;;     「文案分叉」的机会。
;;   - `?' 在 transient 自己的 `transient-map' 里是 `transient-help'，本菜单把它
;;     覆盖成「列出后端」（需求如此）。菜单内仍有 `C-h' 可查帮助。

;;; Code:

(require 'cl-lib)
(require 'subr-x)
;; 菜单本体依赖 `transient'：`transient-define-prefix' / `transient-define-argument'
;; 是宏，定义时必须已加载——这正是本文件被做成「按需加载」的原因（见 Commentary 1）。
(require 'transient)
(require 'eimg-capture)
(require 'eimg-insert)
(require 'eimg-ocr)

;;;; ── 1. 三个会话内 infix ────────────────────────────────────────────────

;; 三个 infix 都用 `transient-option'：这类参数在 argv 里的形态是
;; `--选项=值'，与 `bin/eimg-ocr' 的选项语法同构，解析侧只需按 "=" 切一刀。
;; `:choices' 是手快时的候选，不是白名单——CLI 才是取值的最终裁判（非法后端由它
;; 给出退出码 5）。

(transient-define-argument eimg-menu--backend ()
  "OCR 后端（会话内覆盖，不写入任何 defcustom）。"
  :description "后端"
  :class 'transient-option
  :key "-b"
  :argument "--backend="
  :choices '("auto" "rapidocr" "ollama" "tesseract"))

(transient-define-argument eimg-menu--lang ()
  "tesseract 语言（会话内覆盖，不写入任何 defcustom）。"
  :description "语言"
  :class 'transient-option
  :key "-l"
  :argument "--lang="
  :choices '("chi_sim+eng" "eng"))

(transient-define-argument eimg-menu--dpi ()
  "渲染 DPI（会话内覆盖，不写入任何 defcustom）。"
  :description "DPI"
  :class 'transient-option
  :key "-D"
  :argument "--dpi="
  :choices '("200" "300"))

;;;; ── 2. infix 取值 → 配置 plist ─────────────────────────────────────────

(defconst eimg-transient--option-plist-keys
  '(("--backend" . :backend)
    ("--lang"    . :lang)
    ("--dpi"     . :dpi))
  "菜单 infix 的 CLI 选项名到配置 plist 键的映射。
**顺序即解析结果顺序**（`(:backend … :lang … :dpi …)`）：让返回的 plist 与参数
书写顺序无关，测试可以用 `equal' 逐字断言，日志里两次调用也能直接 diff。")

(defconst eimg-transient--numeric-keys '(:dpi)
  "需要转成数字的配置键。
`eimg-core-build-args' 对数字与字符串都能正确落成 argv（`number-to-string' /
原样），但 plist 里留整数更诚实：下游若做数值比较（如 DPI 上下限）不必再解析一次。")

(defun eimg-transient--option-value (args option)
  "从 ARGS（`transient-args' 的返回值）里取 OPTION 的取值；没有时返回 nil。
ARGS 的每项形如 `--backend=tesseract'；不带 `=' 的项（无值状态）视为未设置。"
  (let ((prefix (concat option "=")))
    (cl-loop for arg in args
             when (and (stringp arg) (string-prefix-p prefix arg))
             return (substring arg (length prefix)))))

;; 函数名沿用 `eimg-ocr--' 前缀（而不是 `eimg-transient--'）：它产出的是 **OCR 侧**
;; 的配置 plist，语义归属 OCR 而不是菜单；菜单只是它的唯一调用者。本文件加载即可
;; 使用，无需 eimg-ocr.el 认识 transient。
(defun eimg-ocr--menu-args ()
  "把 `eimg-menu' 的 infix 取值解析成 `eimg-core-build-args' 认的配置 plist。
返回 nil 表示「菜单里没动过任何 infix」——此时调用方应完全按 defcustom / 内置
默认走，不要塞一个空 plist 进去（空 plist 与 nil 对 `plist-get' 等价，但对
「用户到底有没有表达意图」这件事不等价，日志与测试都想区分）。

DPI 取不到正整数时原样返回字符串：宁可让 CLI 报参数错误（退出码 5，文案明确），
也不要在这一层悄悄丢掉用户输的值。"
  (let ((args (transient-args 'eimg-menu))
        result)
    (dolist (entry eimg-transient--option-plist-keys)
      (when-let* ((value (eimg-transient--option-value args (car entry))))
        (let ((key (cdr entry)))
          (setq result
                (append result
                        (list key
                              (if (memq key eimg-transient--numeric-keys)
                                  (let ((number (string-to-number value)))
                                    (if (> number 0) number value))
                                value)))))))
    result))

;;;; ── 3. 把 infix 取值传进 OCR 命令的薄包装 ──────────────────────────────

;; 为什么需要这一层：transient 调 suffix 用 `call-interactively'，suffix 只能通过
;; `transient-args' 自己取 infix 值。OCR 命令的接口是 `&optional ARGS'（T5c 定的），
;; 于是「把 `(eimg-ocr--menu-args)' 显式传进去」这件事必须有人做——就是这三个函数。
;; 它们不带任何逻辑，也不吞错：OCR 侧怎么报错，菜单里就怎么报。

(defun eimg-menu-run-region ()
  "框选屏幕区域识别，infix 取值作为 ARGS 传给 `eimg-ocr-region'。"
  (interactive)
  (eimg-ocr-region (eimg-ocr--menu-args)))

(defun eimg-menu-run-history ()
  "从历史截图里挑一张识别，infix 取值作为 ARGS 传给 `eimg-ocr-history'。"
  (interactive)
  (eimg-ocr-history (eimg-ocr--menu-args)))

(defun eimg-menu-run-file ()
  "选一个图片或 PDF 识别，infix 取值作为 ARGS 传给 `eimg-ocr-file'。"
  (interactive)
  (eimg-ocr-file (eimg-ocr--menu-args)))

;;;; ── 4. 菜单本体 ────────────────────────────────────────────────────────

;;; ── autoload：为什么写成显式 `(autoload …)' 而不用 cookie + 宏 ※

;; `transient-define-prefix' 虽然登记了 `autoload-macro = expand'，但
;; `loaddefs-generate' 要展开它就必须**先 load 本文件**，而这一步实测会失败：
;;   - 输出文件不在仓库根时，loaddefs 记下的是相对输出目录的路径（`../eimg-transient'），
;;     `load' 按 `default-directory' 解析 → `file-missing'；
;;   - 输出文件在仓库根时能 load，但 loaddefs 处在「正在扫文件」的上下文里，
;;     `cl-lib' / `jka-compr' 报 `Recursive load'。
;; 两次失败后 loaddefs 会把 `;;;###autoload' 后的**宏调用原样**抄进 autoloads 文件——
;; 那份文件一被加载就要有 `transient-define-prefix'，等于每台机器启动即加载
;; transient，正好否掉 Commentary 第 1 条。
;; 因此 cookie 下面紧跟一个**纯数据**的 autoload 声明（loaddefs 逐字复制、零依赖），
;; 真正的 `transient-define-prefix' 放在它之后：首次 `M-x eimg-menu' 由 autoload 触发
;; 加载整个文件，此时才需要 transient。改这段前先跑一遍 `loaddefs-generate' 验证。

;;;###autoload
(autoload 'eimg-menu "eimg-transient" nil t)
(transient-define-prefix eimg-menu ()
  "eimg：截图与 OCR 的菜单入口。
三组动作（采集 / 文件 / 系统）+ 三个会话内 infix（`-b' 后端 / `-l' 语言 /
`-D' DPI）。infix 只对**本次**调用生效，不改任何 defcustom。"
  ["识别选项"
   ("-b" eimg-menu--backend)
   ("-l" eimg-menu--lang)
   ("-D" eimg-menu--dpi)]
  ["采集"
   ("s" "截图" eimg-capture)
   ("o" "截图并识别" eimg-menu-run-region)
   ("h" "历史截图识别" eimg-menu-run-history)]
  ["文件"
   ("f" "选择文件识别" eimg-menu-run-file)
   ("p" "插入图片链接" eimg-insert-path)
   ("b" "插入内联图片" eimg-insert-display)]
  ["系统"
   ("?" "列出后端" eimg-ocr-list-backends)
   ("r" "查看结果" eimg-ocr-show-result-buffer)
   ("d" "打开截图目录" eimg-ocr-open-directory)
   ("S" "安装指引" eimg-ocr-setup-help)])

(provide 'eimg-transient)

;;; eimg-transient.el ends here
