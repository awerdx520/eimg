;;; eimg-ocr.el --- eimg 异步进程层：CLI 调用、四态收尾与进度状态  -*- lexical-binding: t; byte-compile-warnings: (not unresolved noruntime) -*-

;; Author: thomas
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, tools, ocr
;; URL: https://github.com/awerdx520/eimg

;;; Commentary:

;; 本文件是 eimg 的**进程层**：把 `eimg-core-build-args' 拼出来的参数交给
;; `bin/eimg-ocr'，异步收尾，并把「进行中 / 已完成 / 失败 / 被取消 / 超时」这些
;; 状态交给调用方。它**不做任何呈现**：结果 buffer、buffer 局部模式行、交互命令
;; 都属于上层（`eimg-ocr-mode'）。
;;
;; 三条设计约束，改动时不要打破：
;;   1. **纯异步**：`eimg-ocr--start' 立即返回进程对象，主线程从不为子进程让路；
;;      收尾一律由 sentinel 触发。这样即使用户 Emacs 正在前台交互，一次十几秒的
;;      OCR 也不会让界面停顿。
;;   2. **stdout / stderr 必须是干净原文**：`make-process' 的 `:stderr' 直接传
;;      buffer 时，Emacs 会为它建一个内部 pipe 进程，其**默认 sentinel** 会往该
;;      buffer 追加一行「Process … stderr finished」，污染 stderr 原文（下游按
;;      末行取错误信息会取到这行噪音）。故 stderr 用自建 `make-pipe-process'
;;      且 `:sentinel #'ignore'，再把这个进程传给 `:stderr'。
;;   3. **顶层零第三方依赖**：只 require 内置库。本文件会被 headless 的
;;      `emacs -Q' 测试进程加载，顶层 require 任何补全 / 预览 / 菜单 / 弹窗类
;;      第三方包都会让 `make test' 直接失败。

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;;;; ── 1. 可配置项与模块状态 ────────────────────────────────────────────

(defgroup eimg nil
  "截图与 OCR 一体化工具包。"
  :group 'tools
  :prefix "eimg-")

(defcustom eimg-ocr-cli-path nil
  "`bin/eimg-ocr' 的绝对路径；nil 表示按 `eimg-ocr--cli-path' 自动推导。
需要显式设置的场合：CLI 装在别处、或想在测试里注入一个 stub 脚本。
路径不存在时自动推导同样返回 nil（由调用方给 `user-error'，本层不 signal）。"
  :type '(choice (const :tag "自动推导" nil) file)
  :group 'eimg)

(defcustom eimg-ocr-timeout 300
  "单次 OCR 的整体超时秒数（含 PDF 全部分页）。
到点 `delete-process'，收尾状态取 `failed'、退出码取
`eimg-ocr--timeout-exit-code'（124），stderr 末尾附「OCR 超时」说明。"
  :type 'natnum
  :group 'eimg)

(defconst eimg-ocr--timeout-exit-code 124
  "超时使用的伪退出码。
沿用 coreutils `timeout' 的约定值 124：`bin/eimg-ocr' 自身不超时，因此这个码
不会与 CLI 的 0/2/3/4/5 冲突，下游可以据此区分「超时」与「CLI 报错」。")

(defvar eimg-ocr--process nil
  "当前活动的进程对象；nil 表示空闲。")

(defvar eimg-ocr--started-at nil
  "当前任务的启动时间（`current-time' 格式）；nil 表示空闲。")

(defvar eimg-ocr--timeout-timer nil
  "当前任务的超时定时器；nil 表示空闲。")

(defvar eimg-ocr--progress nil
  "当前进度：nil 或 plist `(:stage 阶段 :pages 总页数 :current 当前页)'。
单图（非 PDF）时只有 `:stage' 一项有值。")

;;;; ── 2. CLI 路径定位 ──────────────────────────────────────────────────

;; straight 的 `:files' 只软链 `.el'，`bin/' 不会出现在 build 目录里；因此
;; 「CLI 在哪」只能从「eimg 自己的 .el 在哪」反推。两条实测结论（Emacs 31.1）：
;;   - `-L .' 场景：`locate-library' 返回绝对路径，目录即仓库根；
;;   - build 目录场景：`locate-library' / `symbol-file' 返回的都是**软链路径**，
;;     必须 `file-truename' 解开才能回到源仓库根。
;; 注意拼的是「.el 所在目录 / bin/eimg-ocr」而**不是**父目录：本仓库的 .el 就在
;; 仓库根（`bin/' 是它的子目录），上溯一层会指到 ~/Workspace/ 上。

(defun eimg-ocr--library-file ()
  "返回 eimg 自身 `.el' 文件在磁盘上的真实路径；取不到时返回 nil。
`symbol-file' 的 TYPE 用 `defvar' 而非 `defun'：eimg 的版本号是 defconst
（变量），按 `defun' 查恒为 nil，那样这个兜底分支等于不存在。"
  (let ((file (or (locate-library "eimg")
                  (locate-library "eimg-ocr")
                  (symbol-file 'eimg-ocr-timeout 'defvar)
                  (symbol-file 'eimg-ocr--cli-path 'defun))))
    (when (and (stringp file) (file-exists-p file))
      (file-truename file))))

(defun eimg-ocr--cli-path ()
  "返回可执行的 `bin/eimg-ocr' 路径；找不到时返回 nil（不 signal）。
`eimg-ocr-cli-path' 非 nil 时直接用它（仍要过存在性 / 可执行性检查，让
「自定义路径写错」和「仓库里没装 CLI」走同一条用户可见的错误文案）。"
  (let ((candidate
         (or eimg-ocr-cli-path
             (when-let* ((file (eimg-ocr--library-file)))
               (expand-file-name "bin/eimg-ocr" (file-name-directory file))))))
    (when (and (stringp candidate)
               (file-exists-p candidate)
               (file-executable-p candidate))
      candidate)))

;;;; ── 3. 启动进程 ──────────────────────────────────────────────────────

(defun eimg-ocr-busy-p ()
  "当前是否有活动的 OCR 进程。"
  (and (processp eimg-ocr--process)
       (process-live-p eimg-ocr--process)))

(defun eimg-ocr--start (args callback)
  "以 ARGS 启动 `bin/eimg-ocr'，**立即**返回进程对象（不等待任何输出）。
CALLBACK 在收尾时被调用一次，参数见 `eimg-ocr--sentinel'。
ARGS 由 `eimg-core-build-args' 产出，本层不解释它的语义。
已有活动进程时 `user-error'：模块状态是单槽的，并发启动会让前一个任务的
收尾覆盖后一个的 `eimg-ocr--process'，宁可明确拒绝。"
  (let ((exe (eimg-ocr--cli-path)))
    (unless exe
      (user-error "找不到可执行的 bin/eimg-ocr：跑 bin/eimg-ocr-setup 安装，或自定义 `eimg-ocr-cli-path'"))
    (when (eimg-ocr-busy-p)
      (user-error "已有正在进行的 OCR 任务：先执行 eimg-ocr-cancel 再重试"))
    (let* ((out (generate-new-buffer " *eimg-ocr-out*"))
           (err (generate-new-buffer " *eimg-ocr-err*"))
           ;; stderr 走自建管道进程：直接给 buffer 会让内部 pipe 的默认 sentinel
           ;; 往 buffer 里追加收尾文案（见 Commentary 约束 2）。
           (errproc (make-pipe-process :name "eimg-ocr-stderr"
                                       :buffer err
                                       :noquery t
                                       :sentinel #'ignore
                                       :coding 'utf-8-unix))
           (proc (make-process :name "eimg-ocr"
                               :command (cons exe args)
                               :buffer out
                               :stderr errproc
                               :coding 'utf-8-unix
                               :connection-type 'pipe
                               :noquery t
                               :sentinel (lambda (process event)
                                           (eimg-ocr--sentinel process event callback))))
           (timer (run-with-timer eimg-ocr-timeout nil
                                  #'eimg-ocr--on-timeout proc)))
      ;; 状态全部挂在进程对象上（而不是只放模块全局）：旧进程的 sentinel 若晚到，
      ;; 只会清理它自己那份，不会踩到新任务。
      (process-put proc 'eimg-out-buffer out)
      (process-put proc 'eimg-err-buffer err)
      (process-put proc 'eimg-err-process errproc)
      (process-put proc 'eimg-timeout-timer timer)
      (setq eimg-ocr--process proc
            eimg-ocr--started-at (current-time)
            eimg-ocr--timeout-timer timer)
      proc)))

;;;; ── 4. sentinel：四态收尾 ────────────────────────────────────────────

(defun eimg-ocr--sentinel (proc event callback)
  "处理 PROC 的状态变化：按四态分支收尾，并让 CALLBACK 恰好执行一次。
EVENT 是 Emacs 给出的原文案，实测（Emacs 31.1）只有这几种形态：
  \"finished\\n\"                        退出码 0        → `finished'
  \"exited abnormally with code N\\n\"    非零退出        → `failed'（EXIT-CODE = N）
  \"killed\\n\"                          `delete-process' / SIGKILL → `cancelled'
  \"interrupt\\n\"                       SIGINT          → `cancelled'
其余事件（\"open\\n\" / \"run\" / \"stop\" / \"closed\" 等）不调回调。
超时走的是 `killed'：`eimg-ocr--on-timeout' 先打 `eimg-timeout' 标记再
`delete-process'，本函数据标记把它归到 `failed' + 124，而不是「用户取消」。"
  (unless (process-get proc 'eimg-done)
    (let ((code (process-exit-status proc)))
      (cond
       ((string-prefix-p "finished" event)
        (eimg-ocr--finish proc 'finished callback 0))
       ((string-match-p "exited" event)
        (if (and (integerp code) (zerop code))
            (eimg-ocr--finish proc 'finished callback 0)
          (eimg-ocr--finish proc 'failed callback code)))
       ((or (string-prefix-p "killed" event)
            (string-prefix-p "interrupt" event))
        (if (process-get proc 'eimg-timeout)
            (eimg-ocr--finish proc 'failed callback eimg-ocr--timeout-exit-code
                              (format "OCR 超时（超过 %s 秒）\n" eimg-ocr-timeout))
          (eimg-ocr--finish proc 'cancelled callback nil)))
       (t nil)))))

(defun eimg-ocr--drain-stderr (proc)
  "等 PROC 的 stderr 管道把残留数据读完，最多约 0.2 秒。
为什么需要：主进程的 sentinel 由 SIGCHLD 触发，可能早于 stderr 管道把最后一批
字节读进 buffer（后端往 stderr 写得多的任务有这个窗口）。这不是等待任务完成
——主进程此时已经退出，只是把已产出的字节收干净；`sleep-for' 期间 Emacs 照常
处理进程输出。管道已关闭（常态）时立即返回。"
  (let ((errproc (process-get proc 'eimg-err-process))
        (tries 0))
    (while (and (processp errproc) (process-live-p errproc) (< tries 20))
      (sleep-for 0.01)
      (setq tries (1+ tries)))))

(defun eimg-ocr--buffer-text (proc key)
  "取 PROC 上 KEY 登记的 buffer 全文；buffer 已被销毁时返回空串。"
  (let ((buffer (process-get proc key)))
    (if (buffer-live-p buffer)
        (with-current-buffer buffer
          (buffer-string))
      "")))

(defun eimg-ocr--cleanup (proc)
  "释放 PROC 的定时器、stderr 管道与两个 buffer，并复位模块状态。
调用方用 `ignore-errors' 包住：任何一步失败都不该让回调永不执行。
模块状态只在仍指向 PROC 时才复位——避免旧进程的收尾踩掉新任务的状态。"
  (let ((errproc (process-get proc 'eimg-err-process))
        (timer (process-get proc 'eimg-timeout-timer)))
    (when (timerp timer)
      (cancel-timer timer))
    (when (and (processp errproc) (process-live-p errproc))
      (delete-process errproc))
    (dolist (key '(eimg-out-buffer eimg-err-buffer))
      (let ((buffer (process-get proc key)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))
    (when (eq eimg-ocr--process proc)
      (setq eimg-ocr--process nil
            eimg-ocr--started-at nil
            eimg-ocr--timeout-timer nil)
      (eimg-ocr--clear-progress))))

(defun eimg-ocr--finish (proc status callback exit-code &optional note)
  "收尾 PROC 并按 STATUS 调用 CALLBACK 一次。
NOTE 非 nil 时追加到 STDERR 末尾，用于「不是 CLI 给出的错误」（目前只有超时）。
回调参数：`finished' → (STATUS STDOUT STDERR)；`failed' →
(STATUS STDOUT STDERR EXIT-CODE)；`cancelled' → (STATUS \"\" \")'——取消不交
付半成品输出，也不留任何错误文案。
先在函数入口置 `eimg-done'：`delete-process' 与自然退出都可能各触发一次
sentinel，标记保证回调只跑一次、清理只做一遍。"
  (process-put proc 'eimg-done t)
  (eimg-ocr--drain-stderr proc)
  (let ((stdout (eimg-ocr--buffer-text proc 'eimg-out-buffer))
        (stderr (eimg-ocr--buffer-text proc 'eimg-err-buffer)))
    (when (and note (stringp stderr))
      (setq stderr (concat stderr note)))
    (ignore-errors (eimg-ocr--cleanup proc))
    (apply callback
           (pcase status
             ('finished (list 'finished stdout stderr))
             ('failed (list 'failed stdout stderr exit-code))
             (_ (list 'cancelled "" ""))))))

;;;; ── 5. 取消与超时 ────────────────────────────────────────────────────

(defun eimg-ocr-cancel ()
  "取消正在进行的 OCR 任务；没有任务时只提示，不报错。
取消的收尾仍然由 sentinel 完成（`delete-process' → \"killed\" → `cancelled'），
所以状态清理与「不留错误文案」两条与自然完成一致。"
  (interactive)
  (if (eimg-ocr-busy-p)
      (progn
        (delete-process eimg-ocr--process)
        (message "eimg：已取消当前 OCR 任务"))
    (message "eimg：没有正在进行的 OCR 任务")))

(defun eimg-ocr--on-timeout (proc)
  "PROC 超过 `eimg-ocr-timeout' 秒仍未退出时的定时器回调。
先打 `eimg-timeout' 标记再 `delete-process'：sentinel 只能靠这个标记区分
「用户取消」与「超时」，两者在事件层面都是 \"killed\"。"
  (when (process-live-p proc)
    (process-put proc 'eimg-timeout t)
    (delete-process proc)))

;;;; ── 6. 进度与模式行文本 ──────────────────────────────────────────────

(defun eimg-ocr--set-progress (stage &optional pages current)
  "设置进度并刷新模式行，返回新的进度 plist。
STAGE 是阶段名（如 \"识别中\"）；PAGES 为总页数、CURRENT 为当前页（1-based），
两者只对多页输入有意义，单图传 nil。"
  (setq eimg-ocr--progress (list :stage stage :pages pages :current current))
  (force-mode-line-update t)
  eimg-ocr--progress)

(defun eimg-ocr--clear-progress ()
  "复位进度并刷新模式行。"
  (setq eimg-ocr--progress nil)
  (force-mode-line-update t)
  nil)

(defun eimg-ocr-mode-line-string ()
  "返回当前进度字符串，供调用方放进 buffer 局部的模式行；空闲时返回空串。
为什么不把 `:eval' 片段塞进全局 `mode-line-format'：那会让 \"识别中 2/3\" 出现
在**所有** buffer（包括完全无关的编程 buffer），而只有结果 buffer 该显示它。
故本层只导出文本，安装留给上层决定。"
  (let ((stage (plist-get eimg-ocr--progress :stage))
        (pages (plist-get eimg-ocr--progress :pages))
        (current (plist-get eimg-ocr--progress :current)))
    (cond
     ((null eimg-ocr--progress) "")
     ((and (numberp pages) (numberp current))
      (format " %s %d/%d " stage current pages))
     ((numberp pages)
      (format " %s 共 %d 页 " stage pages))
     (t (format " %s " stage)))))

(provide 'eimg-ocr)

;;; eimg-ocr.el ends here
