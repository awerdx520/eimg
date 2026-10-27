;;; eimg-embark.el --- embark 集成：图片候选的 `C-.' 动作菜单  -*- lexical-binding: t; byte-compile-warnings: (not unresolved noruntime) -*-

;; Author: ThomasDon
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, tools, images
;; URL: https://github.com/awerdx520/eimg

;;; Commentary:

;; 本文件把 eimg 的图片候选接进 embark：在选择界面里按 `C-.' 得到「插入链接 /
;; 插入内联图片 / 打开 / 删除 / 复制路径」的动作菜单。
;;
;; 一条设计约束，改动时不要打破：
;; **顶层零第三方依赖**：只 require 同仓库模块（`eimg-core' / `eimg-insert'）。
;; embark 本体在 `with-eval-after-load 'embark' 之后才被引用——它是第三方包，
;; 在 headless 的 `emacs -Q' 测试进程里不存在，顶层 `require 'embark' 会让
;; `make test' 直接失败。

;;; Code:

(require 'eimg-core)
(require 'eimg-insert)

;;;; ── 1. embark 动作 ─────────────────────────────────────────────────────

(defun eimg-embark-insert-link (x)
  "embark 动作：在光标处插入 X 指向图片的链接（支持 multitarget 列表）。"
  (dolist (path (eimg-select--paths x))
    (insert (eimg-insert--format-link path))))

(defun eimg-embark-insert-image (x)
  "embark 动作：把 X 指向图片插入为内联图片（支持 multitarget 列表）。"
  (dolist (path (eimg-select--paths x))
    (eimg-insert-display path)))

;;;; ── 2. 动作菜单与注册 ──────────────────────────────────────────────────

;; HACK: H3 —— 显式定义 "i"/"b" 覆盖 `embark-general-map' 的同名键位
;; （`embark-general-map' 里 "i" = `embark-insert'，本表用 `:parent' 继承它
;; 之后再用自己的 "i" 顶掉；"b" 在该 keymap 链上未占用，属新增键位）。
;; 说明：`(add-to-list 'embark-keymap-alist …)' 是 embark 文档化的公开扩展点
;; （新 completion category 的标准注册方式），**不**构成 HACK；keymap 定义与注册
;; 都放进 `eimg-embark-register'，由文件末尾的 after-load 钩子触发，避免启动期
;; 硬依赖 embark。

;; 为什么注册要抽成**函数**而不是把 `defvar-keymap' / `add-to-list' 直接写在
;; `with-eval-after-load' 体内：宿主用 `:defer t' 延迟加载本包后，本文件启动时
;; 不加载，`C-.' 会因 `embark-keymap-alist' 缺 `eimg/image' 而静默失效。补偿只能
;; 靠 autoloads 文件携带一条「embark 出现后干活」的 form，而这条 form **不能是
;; `(require 'eimg-embark)'**：embark 加载完成时 autoloads 的钩子被触发 → require
;; 本文件 → 本文件顶层同一条钩子在「embark 已 loaded」的上下文里立即执行 → 再
;; require 正在加载的 feature → `Recursive ‘require’ for feature ‘eimg-embark’'
;; 直接报错，keymap 与注册一起废掉（实测，见本仓 `openspec/tech-notes` 与
;; `test/eimg-autoload-test.el`）。改成「调用一个 autoload 的函数」后链路是自洽的：
;; 文件未加载 → autoload 触发加载 → 加载完成后函数已定义 → 调用一次；文件在
;; embark 已加载的上下文里被加载 → 同一条 form 只是立即调用一个**幂等**函数，
;; 不引回自身。

;;;###autoload
(autoload 'eimg-embark-register "eimg-embark")

(defun eimg-embark-register ()
  "把 `eimg/image' 的动作菜单注册进 embark（幂等）。
`defvar-keymap' 走 `defvar' 语义：重复调用不会重建已绑定的 keymap；
`add-to-list' 本身幂等。因此「autoloads 加载一次 + 本文件加载一次」两条路径
都调用本函数也安全。"
  (defvar-keymap eimg-image-map
    :name "eimg/image 动作菜单"
    :parent embark-general-map
    "i" #'eimg-embark-insert-link
    "b" #'eimg-embark-insert-image
    "RET" #'find-file
    "f" #'find-file
    "o" #'find-file-other-window
    "x" #'embark-open-externally
    "d" #'delete-file
    "w" #'embark-copy-as-kill)
  ;; 注册值必须是**已定义**的 keymap 符号：embark 的
  ;; `embark--raw-action-keymap' 对 `embark-keymap-alist' 的取值做
  ;; `(mapcar #'symbol-value (ensure-list ...))'，写成别的名字会在按 `C-.'
  ;; 时 void-variable（故此处必须与上方 `defvar-keymap' 的名字完全一致，
  ;; 且必须与 `eimg-select--read' 的 `:category' 逐字相同）。
  (add-to-list 'embark-keymap-alist '(eimg/image eimg-image-map)))

;;;; ── 3. 延迟加载补偿（autoloads 唯一入口） ──────────────────────────────

;; 这条 form 是 `C-.' 在 `:defer t' 下仍然可用的唯一保证：加载 autoloads 时只
;; 登记一个 after-load 钩子，不加载任何 eimg 文件；embark 加载完成（或已加载则
;; 立即）才调用 `eimg-embark-register'，而它经 autoload 拉入本文件。
;; 形态必须是**纯数据**调用（`loaddefs-generate' 逐字抄进 autoloads）；
;; 改写成 `(require 'eimg-embark)' 会递归，改写成 defun 包装则永远不被触发。
;;;###autoload
(with-eval-after-load 'embark (eimg-embark-register))

(provide 'eimg-embark)

;;; eimg-embark.el ends here
