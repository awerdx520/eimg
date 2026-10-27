;;; eimg-capture-test.el --- eimg-capture 与「本步未接线」不变量的 ERT 用例  -*- lexical-binding: t; -*-

;; Author: ThomasDon
;; Version: 0.1.0
;; Keywords: convenience, tools, images

;;; Commentary:

;; 覆盖 `eimg-capture' 的纯逻辑部分（历史去重 / LRU / 落盘往返 / 损坏降级 /
;; 目标文件防覆盖），以及四条**结构性不变量**——它们锁的是「这一层不许长回去」
;; 的形态，任一被悄悄拆掉的症状都属于事后难以归因的类型：
;;   - 四个迁移模块顶层零第三方 require（headless 测试进程没有这些包）；
;;   - 四个模块不得出现宿主符号（`thomas' 一律禁止）；
;;   - `eimg.el' 本步**不** require 新模块（否则采集命令与宿主实现并存，
;;     同一张截图会被写进两份历史）；
;;   - `(defgroup eimg' 全包只定义一次。
;;
;; 本文件自带 `(require 'eimg-capture)'：Makefile 按字母序加载 `TEST_FILES'，
;; `eimg-capture-test' 排在 `eimg-core-test' 之前，不能指望别的文件先把它拉进来。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'eimg-capture)
;; 迁移来的「三条入口命令」断言跨 capture / insert 两个模块（见任务约定），
;; 故这里额外 require `eimg-insert'；它只依赖同仓库模块与内置库，零第三方。
(require 'eimg-insert)

;;;; ── 测试辅助 ──────────────────────────────────────────────────────────

(defun eimg-capture-test--source (library)
  "返回同仓库 LIBRARY（如 \"eimg-capture\"）的源码文本。
`make test' 带 `-L .'，`locate-library' 直接命中仓库根；取不到时返回空串，
让断言以「找不到锚点」的形式失败而不是抛错。"
  (let ((path (locate-library library)))
    (if (not path)
        ""
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-string)))))

(defun eimg-capture-test--code-text (text)
  "剔除 TEXT 中整行注释，只留代码。
注释里为解释「为什么不做」必然出现被禁的字样（如 `(require 'consult ...)' 的
写法说明），全文断言会把正确实现判成失败。"
  (replace-regexp-in-string "^[ \t]*;;.*$" "" text))

(defun eimg-capture-test--top-level-requires (library)
  "收集 LIBRARY 中**顶层**（列 0）的 require 目标列表。
只统计列 0 的 require：函数体内的 `(require 'consult nil t)' 是约定的懒加载
写法，属允许项，不能与顶层硬依赖混为一谈。"
  (let ((code (eimg-capture-test--code-text
               (eimg-capture-test--source library)))
        (start 0)
        found)
    (while (string-match "^(require '\\([^][() \t]+\\)" code start)
      (push (match-string 1 code) found)
      (setq start (match-end 0)))
    (nreverse found)))

(defun eimg-capture-test--count (needle haystack)
  "统计 NEEDLE 在 HAYSTACK 中出现的次数（按字面量匹配）。"
  (let ((start 0)
        (count 0))
    (while (string-match (regexp-quote needle) haystack start)
      (setq count (1+ count)
            start (match-end 0)))
    count))

(defun eimg-capture-test--history-names (entries)
  "把历史 ENTRIES 归一化为文件名列表。
只比文件名，避免断言依赖临时目录的绝对路径。"
  (mapcar (lambda (entry)
            (file-name-nondirectory (or (plist-get entry :path) "")))
          entries))

;;;; ── 1. 入口命令 ────────────────────────────────────────────────────────

(ert-deftest eimg-capture-test-commands-defined ()
  "三条入口命令 fboundp 且 commandp；目录未配置时 `user-error'。"
  (dolist (cmd '(eimg-capture eimg-insert-path eimg-insert-display
                 eimg-capture-open-directory))
    (should (fboundp cmd))
    (should (commandp cmd)))
  ;; 目录未配置时必须 user-error 并指回 eimg 自己的 defcustom（不能静默写错
  ;; 目录，也不能再提宿主仓库的配置文件——那是迁移前的路径）
  (let ((eimg-capture-directory nil))
    (should-error (eimg-capture--directory) :type 'user-error))
  (let ((eimg-capture-history-file nil))
    (should-error (eimg-capture--history-file) :type 'user-error))
  ;; 配置项默认 nil：本模块不引用任何外部路径常量
  (should-not (default-value 'eimg-capture-directory))
  (should-not (default-value 'eimg-capture-history-file)))

;;;; ── 2. 历史（纯逻辑） ──────────────────────────────────────────────────

(ert-deftest eimg-capture-test-history-push-lru ()
  "`--history-push' 去重 + LRU 截断 + 落盘往返（临时文件，测完删除）。"
  (let* ((tmp (make-temp-file "eimg-capture-test-" nil ".eld"))
         (eimg-capture-history nil)
         (eimg-capture-history-file tmp)
         (eimg-capture-history-size 3))
    (unwind-protect
        (progn
          ;; 连 push 4 条 → 只保留最近 3 条，且最新在头部
          (dolist (name '("a" "b" "c" "d"))
            (eimg-capture--history-push (format "/tmp/%s.png" name)))
          (should (equal (eimg-capture-test--history-names
                          eimg-capture-history)
                         '("d.png" "c.png" "b.png")))
          ;; 去重：重复 push 同一路径只保留最新一条并置顶
          (eimg-capture--history-push "/tmp/b.png")
          (should (equal (eimg-capture-test--history-names
                          eimg-capture-history)
                         '("b.png" "d.png" "c.png")))
          ;; 落盘往返：清内存后能读回同一序列（读盘只 read 不 eval）
          (should (equal (eimg-capture-test--history-names
                          (let ((eimg-capture-history nil))
                            (eimg-capture--history-load)))
                         '("b.png" "d.png" "c.png")))
          ;; 条目结构：(:path <绝对路径> :time <字符串>)
          (let ((entry (car eimg-capture-history)))
            (should (stringp (plist-get entry :path)))
            (should (file-name-absolute-p (plist-get entry :path)))
            (should (stringp (plist-get entry :time)))))
      (when (file-exists-p tmp) (delete-file tmp)))))

(ert-deftest eimg-capture-test-history-load-corrupt ()
  "历史文件内容非法时 `--history-load' 返回 nil 且不抛错，后续 push 仍可用。

覆盖三种真实可能出现的非法形态：`read' 能读通但结构不对——字符串列表、顶层
单个 plist、完全不是列表。只判 `listp' 会把 `\"a\"' 当条目交给 `plist-get'，
push 时报 `wrong-type-argument'。同时反向断言「合法形态仍被采信」，防止修复
变成「一律拒绝」的过度修复。"
  (let* ((tmp (make-temp-file "eimg-capture-corrupt-" nil ".eld"))
         (eimg-capture-history nil)
         (eimg-capture-history-file tmp))
    (unwind-protect
        (progn
          (dolist (bad '("(\"a\" \"b\")" "(:path \"/x\")" "\"garbage\""))
            (with-temp-file tmp (insert bad))
            (setq eimg-capture-history nil)
            (should (null (eimg-capture--history-load)))
            ;; 结构校验命中后 push 必须照常工作（不 wrong-type-argument）
            (should (null (condition-case err
                              (progn
                                (eimg-capture--history-push "/tmp/ok.png")
                                nil)
                            (error err))))
            (setq eimg-capture-history nil))
          ;; 合法形态（list of plist，:path 为字符串）必须被采信
          (with-temp-file tmp
            (insert "((:path \"/tmp/a.png\" :time \"2026-10-24 00:00:00\"))"))
          (setq eimg-capture-history nil)
          (let ((data (eimg-capture--history-load)))
            (should (consp data))
            (should (equal (plist-get (car data) :path) "/tmp/a.png"))))
      (when (file-exists-p tmp) (delete-file tmp)))))

;;;; ── 3. 采集 ────────────────────────────────────────────────────────────

(ert-deftest eimg-capture-test-target-file-collision ()
  "同一秒内目标文件已存在时 `--target-file' 必须换名（-2），绝不覆盖。"
  (let* ((dir (make-temp-file "eimg-capture-dir-" t))
         (eimg-capture-directory dir))
    (unwind-protect
        (let* ((stem (concat "shot-" (format-time-string "%Y%m%d-%H%M%S")))
               (first (expand-file-name (concat stem ".png") dir)))
          (with-temp-file first (insert "x"))
          (let ((second (eimg-capture--target-file)))
            (should (stringp second))
            (should-not (equal second first))
            (should (string-match-p "-2\\.png\\'" second))
            (should (equal (file-name-directory second)
                           (file-name-as-directory dir)))))
      (delete-directory dir t))))

(ert-deftest eimg-capture-test-history-file-format ()
  "历史落盘格式不变量：`prin1' + `utf-8-unix'，读盘用 `read' 且不出现 `eval'。"
  (let ((src (eimg-capture-test--source "eimg-capture")))
    (should (string-match-p (regexp-quote "(prin1 eimg-capture-history") src))
    (should (string-match-p
             (regexp-quote "coding-system-for-write 'utf-8-unix") src))
    (should (string-match-p (regexp-quote "(read (current-buffer))") src))
    ;; 历史是数据不是程序：出现 eval 意味着读盘会执行文件内容
    (should-not (string-match-p "(eval " (eimg-capture-test--code-text src)))))

;;;; ── 4. 结构性不变量 ────────────────────────────────────────────────────

(defconst eimg-capture-test--migrated-modules
  '("eimg-capture" "eimg-select" "eimg-insert" "eimg-embark")
  "本步迁入的四个模块（库名，不含扩展名）。")

(ert-deftest eimg-capture-test-no-third-party-at-top-level ()
  "四个迁移模块的**顶层** require 只允许内置库与同仓库模块。

`emacs -Q' 测试进程的 load-path 上没有 consult / posframe / embark 等包，
顶层硬依赖会让 `make test' 直接失败；而函数体内的 `(require ... nil t)' 是
约定的懒加载写法，属允许项。"
  (let ((allowed '("cl-lib" "subr-x" "image" "json"
                   "eimg-core" "eimg-capture" "eimg-select" "eimg-insert")))
    (dolist (library eimg-capture-test--migrated-modules)
      (let ((requires (eimg-capture-test--top-level-requires library)))
        ;; 不允许「一个 require 都收集不到」蒙混过关（说明扫描本身失效）
        (should requires)
        (dolist (target requires)
          (should (member target allowed)))))))

(ert-deftest eimg-capture-test-no-host-symbols ()
  "四个迁移模块不得出现宿主符号，`eimg-core' 不得出现宿主常量前缀。

`thomas' 一词在四个模块里出现零次（宿主仓库的包名 / 文件名 / 键位 / 目录都带
它）；`eimg-core' 允许作者行，但不允许 `thomas-' 常量与 `+thomas/' 符号——
一旦引用宿主常量，本仓库就不能脱离宿主仓库独立加载。"
  (dolist (library eimg-capture-test--migrated-modules)
    ;; `case-fold-search' 必须为 nil：与验收用的 `grep -c "thomas"' 同语义，
    ;; 否则作者行里的大小写变体（如 `ThomasDon'）会被当成宿主符号。
    (let ((case-fold-search nil))
      (should-not (string-match-p "thomas"
                                  (eimg-capture-test--source library)))))
  (let ((core (eimg-capture-test--source "eimg-core")))
    (should core)
    (should-not (string-match-p "thomas-" core))
    (should-not (string-match-p (regexp-quote "+thomas/") core))))

(ert-deftest eimg-capture-test-eimg-el-does-not-require-new-modules ()
  "本步不接线：`eimg.el' 不得 require（甚至不得提及）四个新模块。

为什么必须锁：`eimg-ocr--capture-function' 的探测顺序是
「显式函数 → `eimg-capture' → 宿主截图命令」。一旦 `eimg.el' 把 `eimg-capture'
拉起来，用宿主配置的用户会同时拥有 eimg 与宿主两套采集实现，同一张截图被写进
两份历史文件。接线是下一步（切换）的事，届时这条断言应被**改写**而不是删除。"
  (let ((src (eimg-capture-test--source "eimg.el")))
    (should src)
    (dolist (library eimg-capture-test--migrated-modules)
      (should-not (string-match-p (regexp-quote library) src)))))

(ert-deftest eimg-capture-test-defgroup-defined-once ()
  "`(defgroup eimg' 全包只在 `eimg-core.el' 定义一次。

分布定义会让 `:prefix' / `:group tools' 的父子关系随加载顺序漂移；`eimg-core'
是唯一被所有模块（含 `eimg-ocr'）require 的底层，放这里能保证任何模块求值
`defcustom' 时组已存在。"
  (let ((libraries (append eimg-capture-test--migrated-modules
                           '("eimg-core" "eimg-ocr" "eimg-transient" "eimg")))
        (total 0)
        (core-count 0))
    (dolist (library libraries)
      (let ((n (eimg-capture-test--count
                "(defgroup eimg"
                (eimg-capture-test--code-text
                 (eimg-capture-test--source library)))))
        (setq total (+ total n))
        (when (equal library "eimg-core")
          (setq core-count n))))
    (should (equal total 1))
    (should (equal core-count 1))))

(provide 'eimg-capture-test)

;;; eimg-capture-test.el ends here
