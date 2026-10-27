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
;; （新 completion category 的标准注册方式），**不**构成 HACK；它与上面的
;; keymap 定义都放在 `with-eval-after-load' 内，避免启动期硬依赖 embark。
(with-eval-after-load 'embark
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

(provide 'eimg-embark)

;;; eimg-embark.el ends here
