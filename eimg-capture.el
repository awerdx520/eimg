;;; eimg-capture.el --- 截图采集：外部工具调用、目标文件命名与历史记录  -*- lexical-binding: t; byte-compile-warnings: (not unresolved noruntime) -*-

;; Author: ThomasDon
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, tools, images
;; URL: https://github.com/awerdx520/eimg

;;; Commentary:

;; 本文件是 eimg 采集链的最上游：调用外部截图工具 → 落盘到配置目录 →
;; 写入历史（供选择界面与「历史截图 OCR」复用）。它不负责挑选、预览与插入，
;; 那三层分别在 `eimg-select.el' 与 `eimg-insert.el'。
;;
;; 三条设计约束，改动时不要打破：
;;   1. **顶层零第三方依赖**：只 require 内置库（`cl-lib'）与同仓库的
;;      `eimg-core'。本文件会被 headless 的 `emacs -Q' 测试进程加载，顶层
;;      require 任何补全 / 预览 / 菜单 / 弹窗类第三方包都会让 `make test' 直接
;;      失败——它们不在 `emacs -Q' 的 load-path 上。
;;   2. **配置项默认全部 nil / 字面量**：`defcustom' 的默认值在 `load-file'
;;      时即求值，引用外部常量会让单文件加载与单测 `void-variable'。目录与
;;      历史文件由调用方（用户配置 / `eimg-transient' 的目录入口）赋值。
;;   3. **历史读盘只 `read' 不 `eval'，且 `condition-case' 包裹**：历史文件是
;;      数据而不是程序，损坏时只能降级为「空历史」，不能执行其中代码，更不能
;;      让截图命令整体失败。

;;; Code:

(require 'cl-lib)
(require 'eimg-core)

;;;; ── 1. 配置项 ──────────────────────────────────────────────────────────

(defcustom eimg-capture-directory nil
  "截图存储目录（绝对路径，建议带尾部 /）。

默认 nil：本文件不引用外部的路径常量（见 Commentary 约束 2）。未配置时
`eimg-capture' 与其内部取值函数都以 `user-error' 明确报错，绝不静默写到
某个猜出来的目录。"
  :type '(choice (const :tag "未配置" nil) directory)
  :group 'eimg)

(defcustom eimg-capture-command "flameshot.exe"
  "执行截图的程序名（在 `exec-path' 中查找）。

换工具时同步改 `eimg-capture-command-args'：参数列表原样传给该命令，目标
文件路径由 `eimg-capture' 追加在末尾。"
  :type 'string
  :group 'eimg)

(defcustom eimg-capture-command-args '("gui" "--path")
  "传给 `eimg-capture-command' 的参数列表（目标文件路径追加在末尾）。"
  :type '(repeat string)
  :group 'eimg)

(defcustom eimg-capture-history-size 200
  "截图历史的最大条目数（超出时丢弃最旧的条目）。"
  :type 'integer
  :group 'eimg)

(defcustom eimg-capture-history-file nil
  "截图历史文件的绝对路径（写入前会自动创建父目录）。

默认 nil：不引用外部的路径常量（见 Commentary 约束 2）。未配置时写入会
`user-error'——丢记录是必须可见的失败，不能静默。"
  :type '(choice (const :tag "未配置" nil) file)
  :group 'eimg)

(defun eimg-capture--directory ()
  "返回截图存储目录的绝对路径；未配置时报用户错误。"
  (if eimg-capture-directory
      (expand-file-name eimg-capture-directory)
    (user-error "未配置 eimg-capture-directory（见 eimg 的 README 与 M-x customize-group RET eimg）")))

(defun eimg-capture--history-file ()
  "返回历史文件的绝对路径；未配置时报用户错误。"
  (if eimg-capture-history-file
      (expand-file-name eimg-capture-history-file)
    (user-error "未配置 eimg-capture-history-file（见 eimg 的 README 与 M-x customize-group RET eimg）")))

;;;; ── 2. 历史（纯逻辑，可单测） ─────────────────────────────────────────

(defvar eimg-capture-history nil
  "截图历史列表，元素为 plist `(:path <绝对路径> :time <时间字符串>)'。

最新条目在列表头部；磁盘副本由 `eimg-capture--history-save' 在每次 push 后
立即写入，避免 daemon 崩溃丢失记录。")

(defun eimg-capture--history-entry-p (x)
  "判断 X 是否为一条合法的历史条目。

合法 = 列表形态的 plist，且 `:path' 是字符串。只做结构校验、不校验文件是否
仍存在：历史允许保留已删除的路径，由 `eimg-capture--history-paths' 在取用时
过滤。"
  (and (listp x) (stringp (plist-get x :path))))

(defun eimg-capture--history-load ()
  "从 `eimg-capture-history-file' 读取历史，失败返回 nil。

只用 `read'（不 `eval'）：历史文件是数据，读入不得执行其中的代码。文件不
存在、父目录缺失或内容损坏时一律降级为空历史——历史丢失只带来不便，不能让
截图命令本身失败。

`read' 不抛错也不等于内容合法：手工编辑、旧版本残留都可能留下 `(\"a\" \"b\")'
或顶层单个 plist 之类形态。故逐条做结构校验（见 `--history-entry-p'）——
否则这些条目会被 `--history-push' / `--history-paths' 当 plist 取值，表现为
`wrong-type-argument' 之类难以定位的错误。"
  (let ((file (ignore-errors (eimg-capture--history-file))))
    (cond
     ((null file) nil)
     ((not (file-exists-p file)) nil)
     (t
      (condition-case err
          (with-temp-buffer
            (insert-file-contents file)
            (goto-char (point-min))
            (let ((data (read (current-buffer))))
              (if (and (listp data)
                       (cl-every #'eimg-capture--history-entry-p data))
                  data
                (message "截图历史格式非法，已忽略：%s" file)
                nil)))
        (error
         (message "读取截图历史失败（%s）：%s" file (error-message-string err))
         nil))))))

(defun eimg-capture--history-save ()
  "把 `eimg-capture-history' 写入 `eimg-capture-history-file'。

固定 `utf-8-unix' 编码，跨机器复制历史文件不出现行尾差异。未配置历史文件时
报用户错误（写入是必须可见的失败，不能静默丢记录）。"
  (let* ((file (eimg-capture--history-file))
         (dir (file-name-directory file))
         (coding-system-for-write 'utf-8-unix))
    (when dir (make-directory dir t))
    (with-temp-buffer
      (let ((print-length nil)
            (print-level nil))
        (prin1 eimg-capture-history (current-buffer)))
      (write-region (point-min) (point-max) file nil 'quiet))
    file))

(defun eimg-capture--history-ensure ()
  "内存历史为空时尝试从磁盘加载一次，返回当前历史列表。"
  (when (null eimg-capture-history)
    (setq eimg-capture-history (eimg-capture--history-load)))
  eimg-capture-history)

(defun eimg-capture--history-push (path)
  "把 PATH 作为最新一条写入历史并立即落盘，返回新历史列表。

处理顺序固定：去重（同一路径只保留最新一条，避免反复截图同一位置时历史被
同一文件刷满）→ 头插 `(:path :time)' → 按 `eimg-capture-history-size' 从尾部
截断 → 落盘。"
  (let* ((abs (expand-file-name path))
         (size (max 1 (or eimg-capture-history-size 200)))
         (entry (list :path abs
                      :time (format-time-string "%Y-%m-%d %H:%M:%S")))
         (rest (cl-remove-if (lambda (item)
                               (and (listp item)
                                    (equal (plist-get item :path) abs)))
                             (eimg-capture--history-ensure))))
    (setq eimg-capture-history
          (cons entry (cl-subseq rest 0 (min (length rest) (1- size)))))
    (eimg-capture--history-save)
    eimg-capture-history))

(defun eimg-capture--history-paths ()
  "返回历史中仍然存在的绝对路径，保持历史顺序（最新在前）。

已删除的文件被过滤：历史是「曾经截过的图」的记录，而候选列表只应包含此刻
仍可插入的图片。"
  (delq nil
        (mapcar (lambda (item)
                  (let ((path (and (listp item) (plist-get item :path))))
                    (and (stringp path) (file-exists-p path) path)))
                (eimg-capture--history-ensure))))

;;;; ── 3. 采集 ────────────────────────────────────────────────────────────

(defun eimg-capture--target-file ()
  "生成一个尚未被占用的截图目标路径。

文件名 `shot-<YYYYMMDD-HHMMSS>.png'；同一秒内重复调用（快速连拍或测试）时
追加 `-2'、`-3'……，绝不覆盖已有文件。"
  (let* ((dir (eimg-capture--directory))
         (stem (concat "shot-" (format-time-string "%Y%m%d-%H%M%S")))
         (candidate (expand-file-name (concat stem ".png") dir))
         (suffix 1))
    (while (file-exists-p candidate)
      (setq suffix (1+ suffix)
            candidate (expand-file-name (format "%s-%d.png" stem suffix) dir)))
    candidate))

(defun eimg-capture ()
  "调用外部工具截屏，存到截图目录并写入历史。

成功判据是**双条件**：退出码为 0 **且**目标文件确实存在。只看退出码会被
「工具返回 0 但没落盘」骗过；只看文件存在则无法区分「本次截图」与「旧文件」。
失败时删除可能残留的半成品并 `user-error'（命令名 + 退出码），不写历史、
不静默。

成功后只记录与提示，不自动插入图片——插图是独立命令 `eimg-insert-path'
（采集与插入分离：采集是「拿到一张图」，插入是「把它放进当前文档」）。"
  (interactive)
  (let* ((dir (eimg-capture--directory))
         file
         status)
    (make-directory dir t)
    (setq file (eimg-capture--target-file))
    (setq status (condition-case err
                     (apply #'call-process
                            eimg-capture-command nil nil nil
                            (append eimg-capture-command-args
                                    (list file)))
                   (error
                    (message "启动截图命令失败（%s）：%s"
                             eimg-capture-command
                             (error-message-string err))
                    nil)))
    (if (and (eq status 0) (file-exists-p file))
        (progn
          (eimg-capture--history-push file)
          (message "已保存截图：%s（M-x eimg-insert-path 插入）"
                   (abbreviate-file-name file))
          file)
      (let ((leftover (file-exists-p file)))
        (when leftover (ignore-errors (delete-file file)))
        (user-error "截图失败（命令 %s，退出码 %s）%s"
                    eimg-capture-command
                    (if (numberp status) status "未启动")
                    (if leftover "；已删除残留文件" ""))))))

(defun eimg-capture-open-directory ()
  "用 dired 打开截图存储目录。"
  (interactive)
  (dired (eimg-capture--directory)))

(provide 'eimg-capture)

;;; eimg-capture.el ends here
