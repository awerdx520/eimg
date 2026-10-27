;;; eimg-ocr.el --- eimg 进程层与编排层：CLI 调用、四态收尾、进度状态与入口命令  -*- lexical-binding: t; byte-compile-warnings: (not unresolved noruntime) -*-

;; Author: thomas
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, tools, ocr
;; URL: https://github.com/awerdx520/eimg

;;; Commentary:

;; 本文件分三层：
;;   - 第 1–6 节是**进程层**：把 `eimg-core-build-args' 拼出来的参数交给
;;     `bin/eimg-ocr'，异步收尾，并把「进行中 / 已完成 / 失败 / 被取消 / 超时」
;;     这些状态交给调用方。
;;   - 第 7 节是**呈现层**：`eimg-ocr-mode' 结果 buffer、buffer 局部模式行与六条
;;     键位。它只消费进程层与 `eimg-core' 的输出，自己不启动进程。
;;   - 第 8 节是**编排层**：`eimg-ocr--run' 把「拼参数 → 起进程 → 四态收尾」收成
;;     一份，三个入口命令（region / file / history）、后端查询与结果 buffer 的 `g'
;;     全部复用它。
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
;; 同仓库的纯逻辑层：渲染结果 buffer 要用它的 `eimg-core-render-org' 与 JSON 解析。
;; 它零第三方依赖，加载代价可忽略（`eimg.el' 本来也会加载它）。
(require 'eimg-core)

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

(defcustom eimg-ocr-capture-function nil
  "截图函数；nil 表示按 `eimg-ocr--capture-function' 自动探测。
截图能力本轮尚未迁移进 eimg，故运行期按 `eimg-capture' → `+thomas/screenshot'
的顺序探测；迁移完成后把本值指向新函数（或让新函数占用 `eimg-capture' 这个名字），
OCR 侧零改动。被指定的值必须是**交互命令**（`commandp`）：调用方走
`call-interactively'，与用户手工按键执行的路径逐字一致——返回值契约是「命令执行
完毕后的返回值即截图文件的绝对路径」，返回 nil / 非字符串 / 不可读路径都算失败。"
  :type '(choice (const :tag "自动探测" nil) function)
  :group 'eimg)

(defcustom eimg-ocr-images-dir nil
  "历史截图的目录；nil 表示按 `eimg-ocr--history-directory' 自动推导。
`eimg-ocr-file' 的默认目录与 `eimg-ocr-history' 的扫描目录都用它。"
  :type '(choice (const :tag "自动推导" nil) directory)
  :group 'eimg)

(defcustom eimg-ocr-history-size 10
  "`eimg-ocr-history' 最多列出多少个最近的图片文件（按修改时间降序）。"
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

(defvar eimg-ocr--last-args nil
  "最近一次渲染结果所用的 CLI 参数列表；nil 表示本会话还没出过结果。
`eimg-ocr-rerun' 只重跑，不猜参数——参数从哪来属于上层交互命令的职责。")

(defvar eimg-ocr--last-origin nil
  "最近一次结果对应的来源 buffer；`eimg-ocr-insert' 的插入目标。
用 buffer 对象而不是 buffer 名：同名 buffer 可以被重新创建，旧对象一眼就能用
`buffer-live-p' 判定「来源已消失」，不必猜。")

(defvar eimg-ocr--last-meta nil
  "最近一次结果的元信息 plist：`:backend' `:elapsed' `:source'。
供 `eimg-ocr-write-file' 推默认文件名、`eimg-ocr-rerun' 沿用后端。")

(defvar eimg-ocr--last-summary nil
  "最近一次完成的摘要文本（如 \" 完成（2 页，1.30s） \"）；空闲时 nil。
它由 `eimg-ocr--set-progress' 清空、由渲染入口写入，供模式行在任务结束后
继续显示结果概要（进度清空后模式行不该变成一片空白）。")

(defvar eimg-ocr--last-capture nil
  "最近一次截图函数返回的文件路径；nil 表示本会话还没截过图。
`eimg-ocr--history-directory' 在 `eimg-ocr-images-dir' 为 nil 时用它反推目录——
用户刚截了一张图，接着想看历史时最想知道的就是「刚才那些图在哪」。")

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
归属判据是 `process-status' / `process-exit-status'，**不是** EVENT 的文案：
EVENT 对「因信号死亡」的描述取自 `strsignal'，会经 gettext 翻译——本机 zh_CN
下实测 `delete-process' 给出的是 \"已杀死\\n\"、SIGINT 给出 \"中断\\n\"，按
\"killed\" 字面匹配永远不命中，取消与超时两条路径会整个哑掉（`make test' 里
对应用例只能等到超时才报错）。`process-status' 与文案无关，稳定可取：
  `exit' + 退出码 0          → `finished'
  `exit' + 非零退出码        → `failed'（EXIT-CODE = 退出码）
  `signal'（SIGKILL / SIGINT）→ `cancelled'；带 `eimg-timeout' 标记时是 `failed' + 124
其余状态（`run' / `stop' / `open' / `closed' 等）不调回调。
保留 \"finished\" / \"exited\" 的文案兜底：这两条文案不翻译（实测），万一
`process-status' 取不到（nil）时仍能收尾，不至于让回调永久悬空。
超时走的也是 `signal'：`eimg-ocr--on-timeout' 先打 `eimg-timeout' 标记再
`delete-process'，本函数据标记把它归到 `failed' + 124，而不是「用户取消」。"
  (unless (process-get proc 'eimg-done)
    (let ((code (process-exit-status proc))
          (status (process-status proc)))
      (cond
       ((eq status 'exit)
        (if (and (integerp code) (zerop code))
            (eimg-ocr--finish proc 'finished callback 0)
          (eimg-ocr--finish proc 'failed callback code)))
       ((eq status 'signal)
        (if (process-get proc 'eimg-timeout)
            (eimg-ocr--finish proc 'failed callback eimg-ocr--timeout-exit-code
                              (format "OCR 超时（超过 %s 秒）\n" eimg-ocr-timeout))
          (eimg-ocr--finish proc 'cancelled callback nil)))
       ((string-prefix-p "finished" event)
        (eimg-ocr--finish proc 'finished callback 0))
       ((string-match-p "exited" event)
        (if (and (integerp code) (zerop code))
            (eimg-ocr--finish proc 'finished callback 0)
          (eimg-ocr--finish proc 'failed callback code)))
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
两者只对多页输入有意义，单图传 nil。
同时清空上一次的完成摘要：新一轮已经开始，模式行上留着旧摘要会让人以为
旧结果就是新结果。"
  (setq eimg-ocr--progress (list :stage stage :pages pages :current current)
        eimg-ocr--last-summary nil)
  (force-mode-line-update t)
  eimg-ocr--progress)

(defun eimg-ocr--clear-progress ()
  "复位进度并刷新模式行。"
  (setq eimg-ocr--progress nil)
  (force-mode-line-update t)
  nil)

(defun eimg-ocr-mode-line-string ()
  "返回当前应显示在模式行上的文本，供调用方放进 buffer 局部的模式行。
三种形态：进行中 → 进度（如 \" 识别中 2/3 页 \"）；刚完成 → 摘要
（如 \" 完成（2 页，1.30s） \"）；两者都没有 → 空串。
为什么不把 `:eval' 片段塞进全局 `mode-line-format'：那会让 \"识别中 2/3\" 出现
在**所有** buffer（包括完全无关的编程 buffer），而只有结果 buffer 该显示它。
故本层只导出文本，安装留给 `eimg-ocr-mode' 决定。"
  (let ((stage (plist-get eimg-ocr--progress :stage))
        (pages (plist-get eimg-ocr--progress :pages))
        (current (plist-get eimg-ocr--progress :current)))
    (cond
     ((null eimg-ocr--progress) (or eimg-ocr--last-summary ""))
     ((and (numberp pages) (numberp current))
      (format " %s %d/%d " stage current pages))
     ((numberp pages)
      (format " %s 共 %d 页 " stage pages))
     (t (format " %s " stage)))))

;;;; ── 7. 结果 buffer 与键位 ────────────────────────────────────────────

;; 职责：把 `eimg-core-render-org' 的正文装进一个专用 buffer，配上**只属于这个
;; buffer** 的模式行，并用六个键位覆盖「复制 / 回插 / 存盘 / 重跑 / 关闭 / 取消」。
;; 这一节不启动进程（`g' 例外：它只是把已有参数再交给进程层），也不决定「识别
;; 什么」——那是上层交互命令的职责。

(defconst eimg-ocr-buffer-name "*eimg-ocr*"
  "OCR 结果 buffer 的名字。
用固定名字而不是 `generate-new-buffer'：`g' 重跑与后续多次识别都要求写回同一个
buffer，否则每跑一次就漏一个 buffer，而且 `q' 关掉之后还能重开。")

(defconst eimg-ocr--header-prefix "# eimg-ocr: "
  "结果 buffer 首行的前缀。
用 `#' 开头而不是 org 标题：它是给人（以及 `eimg-ocr--collect-body'）看的元信息，
不该进 org 大纲，复制 / 导出 / 折叠时都会被当成注释行跳过。")

(defun eimg-ocr--summary-string (pages elapsed)
  "返回完成摘要的模式行文本。PAGES 是页数，ELAPSED 是耗时秒数（可为 nil）。"
  (format " 完成（%d 页，%.2fs） " (or pages 0) (or elapsed 0)))

(defun eimg-ocr--header-line (source backend pages elapsed)
  "拼出结果 buffer 的说明头行：`# eimg-ocr: 来源（backend=…，N 页，X.XXs）'。
四个参数都容忍 nil：来源 / 后端未知时显示「未知来源」「未知后端」，宁可在头行上
暴露「不知道」也不要让渲染整个失败——识别结果本身仍然是有用的。"
  (format "%s%s（backend=%s，%d 页，%.2fs）"
          eimg-ocr--header-prefix
          (or source "未知来源")
          (or backend "未知后端")
          (or pages 0)
          (or elapsed 0)))

(defun eimg-ocr--collect-body (&optional buffer)
  "返回 BUFFER（默认当前 buffer）中**去掉说明头行**的正文。
`y' / `w' / `i' 三个命令共用：头行是元信息，复制、存盘、回插都不该带上它。
首行不以 `eimg-ocr--header-prefix' 开头时原样返回，这样手工编辑过的 buffer
（或用户自己把结果 buffer 改了）也不会被吞掉第一行。
返回值不含末尾换行：写进其他 buffer 与 kill-ring 时由调用方按需补。"
  (with-current-buffer (or buffer (current-buffer))
    (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
           (body (if (string-prefix-p eimg-ocr--header-prefix text)
                     (let ((newline (string-search "\n" text)))
                       (if newline (substring text (1+ newline)) ""))
                   text)))
      (string-remove-suffix "\n" body))))

(defun eimg-ocr--show-result (pages args meta)
  "把 PAGES 渲染进 `eimg-ocr-buffer-name' 并返回该 buffer。
ARGS 是产出这批结果的 CLI 参数（供 `eimg-ocr-rerun' 原样重跑），META 是 plist
`:backend' / `:elapsed' / `:source'。调用时的**当前 buffer 即来源 buffer**，
它被记进 `eimg-ocr--last-origin'，供 `eimg-ocr-insert' 回插。
batch 环境（`noninteractive'）只填 buffer 不显示窗口：`make test' 走的就是这条路，
而 `display-buffer' 在没有窗口系统的批处理里没有意义、也不该成为失败点。"
  (let* ((source (plist-get meta :source))
         (backend (plist-get meta :backend))
         (elapsed (plist-get meta :elapsed))
         (origin (current-buffer))
         (page-count (length pages))
         (body (eimg-core-render-org pages))
         (buffer (get-buffer-create eimg-ocr-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (eimg-ocr--header-line source backend page-count elapsed) "\n")
        (insert body)
        (insert "\n")
        ;; 先写完文本再开 mode：`special-mode' 会把 buffer 置为只读，反序会 write error。
        (eimg-ocr-mode)
        (goto-char (point-min))
        (set-buffer-modified-p nil)))
    (setq eimg-ocr--last-args args
          eimg-ocr--last-origin origin
          eimg-ocr--last-meta meta
          eimg-ocr--last-summary (eimg-ocr--summary-string page-count elapsed))
    ;; 进度已由进程层收尾时清空，这里只补上摘要，让模式行在任务结束后仍有信息。
    (force-mode-line-update t)
    (unless noninteractive
      (display-buffer buffer '(display-buffer-pop-up-window)))
    buffer))

(define-derived-mode eimg-ocr-mode special-mode "eimg-OCR"
  "OCR 结果 buffer 的主模式。
只设**两份** buffer 局部值：`truncate-lines'（OCR 段落常是超长单行，折行会把
一页的文字搅成视觉上无法对照的碎片）与 `mode-line-format'（进度与摘要只该出现
在这个 buffer，绝不能改全局值——否则所有无关 buffer 的模式行都会被塞进
\"识别中 2/3\"）。"
  (setq-local truncate-lines t)
  (setq-local mode-line-format
              '("%e" mode-line-buffer-identification " " mode-line-modified
                (:eval (eimg-ocr-mode-line-string)))))

;; 键位一律绑在 `eimg-ocr-mode-map'（`define-derived-mode' 已经建好、父表是
;; `special-mode-map'），不用 evil / general——本文件必须保持顶层零第三方依赖。
;; 不复用 `C-c xxx' 前缀：`C-c' 后跟单个字母是**用户保留**的键位空间。
(keymap-set eimg-ocr-mode-map "y" #'eimg-ocr-copy)
(keymap-set eimg-ocr-mode-map "i" #'eimg-ocr-insert)
(keymap-set eimg-ocr-mode-map "w" #'eimg-ocr-write-file)
(keymap-set eimg-ocr-mode-map "g" #'eimg-ocr-rerun)
(keymap-set eimg-ocr-mode-map "q" #'quit-window)
(keymap-set eimg-ocr-mode-map "k" #'eimg-ocr-cancel)

(defun eimg-ocr-copy ()
  "把结果正文（不含说明头行）放入 `kill-ring'。
行数按换行切分统计：OCR 结果的「多少行」就是「多少段文本」，比字符数更有用。"
  (interactive)
  (let ((body (eimg-ocr--collect-body)))
    (when (string-empty-p body)
      (user-error "没有可复制的 OCR 正文"))
    (kill-new body)
    (message "eimg：已复制 %d 行 / %d 字符"
             (length (split-string body "\n"))
             (length body))))

(defun eimg-ocr-insert ()
  "把结果正文插入到 `eimg-ocr--last-origin' 的光标处。
来源 buffer 已被 kill 时 `user-error' 而不是随便挑个 buffer 插入：静默落到别处
的结果比报错更难发现。"
  (interactive)
  (let ((origin eimg-ocr--last-origin)
        (body (eimg-ocr--collect-body)))
    (unless (buffer-live-p origin)
      (user-error "来源 buffer 已不存在，无法插入"))
    (when (string-empty-p body)
      (user-error "没有可插入的 OCR 正文"))
    (with-current-buffer origin
      (insert body)
      ;; 正文自身没有末尾换行；补一个，避免插进正文中间时把后文粘上来。
      (unless (string-suffix-p "\n" body)
        (insert "\n")))
    (message "eimg：已插入 %d 字符到 %s" (length body) (buffer-name origin))))

(defun eimg-ocr--default-file-name ()
  "由 `eimg-ocr--last-meta' 的 `:source' 推出默认文件名（`<source 主干名>.org'）。
取不到来源时退回 `ocr.org'：默认值的价值是「回车就能用」，不是精确。"
  (let* ((source (plist-get eimg-ocr--last-meta :source))
         (stem (if (and (stringp source) (not (string-empty-p source)))
                   (file-name-base source)
                 "ocr")))
    (expand-file-name (concat stem ".org"))))

(defun eimg-ocr-write-file (file)
  "把结果正文写入 FILE；已存在时先 `y-or-n-p' 确认。交互式默认 `.org' 后缀。
`read-file-name' 的 MUSTMATCH 刻意传 nil：传 t 会把「还不存在的文件名」判为
不匹配，而写文件恰恰最需要新名字——覆盖确认交给 `y-or-n-p' 单独做。"
  (interactive
   (list (read-file-name "写入 org 文件：" nil nil nil
                         (eimg-ocr--default-file-name))))
  (let ((body (eimg-ocr--collect-body)))
    (when (string-empty-p body)
      (user-error "没有可写入的 OCR 正文"))
    (when (and (file-exists-p file)
               (not (y-or-n-p (format "文件已存在，覆盖 %s？" file))))
      (user-error "已取消写入"))
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region (concat body "\n") nil file nil 'silent))
    (message "eimg：已写入 %s" file)))

(defun eimg-ocr-rerun ()
  "用最近一次的配置重跑 OCR，结果仍写回本 buffer。
没有历史配置时 `user-error'：本命令只负责「重跑」，不负责猜参数（画哪块、用哪个
后端都属于上层交互命令的职责）。
收尾复用 `eimg-ocr--run'：四态语义、解析失败留原始输出、失败不覆盖已有结果，
这些都与首次识别**同一份代码**——两份相似的收尾最容易长歪成「一处提示一处静默」。
重跑要的是**配置 plist** 而不是 argv（argv 由 `eimg-ocr--run' 现拼），配置存在
`eimg-ocr--last-meta' 的 `:config' 项里，由 `eimg-ocr--run' 写入。"
  (interactive)
  (let ((config (plist-get eimg-ocr--last-meta :config))
        (origin eimg-ocr--last-origin))
    (unless config
      (user-error "本 buffer 还没有 OCR 结果：先跑一次识别再重跑"))
    ;; 回到来源 buffer 里启动：`eimg-ocr--run' 把「当前 buffer」记为回插目标，
    ;; 重跑时当前 buffer 是结果 buffer 自己，直接调用会让 `i' 指向错误的目标。
    (with-current-buffer (if (buffer-live-p origin) origin (current-buffer))
      (eimg-ocr--run config))))

;;;; ── 8. 统一编排与三个入口命令 ────────────────────────────────────────

;; 三个入口命令（`eimg-ocr-region' / `eimg-ocr-file' / `eimg-ocr-history'）与结果
;; buffer 里的 `g'（`eimg-ocr-rerun'）走**同一条**路径：拼参数 → 起进程 → 四态
;; 收尾。收尾代码只留一份，避免长出「一处失败给提示、另一处失败静默」的分裂。
;;
;; 两条约束贯穿本节：
;;   1. **命令立即返回**：`eimg-ocr--run' 只启动进程就返回，识别十几秒也不阻塞
;;      主线程；一切后续动作都在 sentinel 里做。
;;   2. **截图是软依赖**：截图能力本轮尚未迁移进 eimg，故一个截图函数都没有时
;;      明确 `user-error' 并把用户指回 thomas-emacs，而不是抛「void-function」。

(defconst eimg-ocr-raw-buffer-name "*eimg-ocr-raw*"
  "解析失败时保存 CLI 原始 stdout 的 buffer 名。
解析失败意味着「输出与约定不符」，此时唯一有用的证据就是原文——不落盘就只剩
一句「无法解析」，连是 CLI 版本不对还是后端吐了半截都判不出来。")

(defconst eimg-ocr--raw-limit 500
  "`eimg-ocr-raw-buffer-name' 里保存原始输出的字符上限。
只留前 500 字符：足够看出输出形态（是空、是日志、还是被截断的 JSON），又不至于
把整份日志塞进 batch 环境的 *Messages*。")

(defconst eimg-ocr-backends-buffer-name "*eimg-ocr-backends*"
  "`eimg-ocr-list-backends' 的输出 buffer 名。
与结果 buffer 分开：后端列表没有「页」「正文」，混进 `*eimg-ocr*' 会让 `y' / `w'
这些针对识别结果的键位对着一份列表工作。")

(defconst eimg-ocr--capture-missing-message
  "未找到截图函数：截图能力尚未迁移到 eimg，暂时依赖 thomas-emacs 的 +thomas/screenshot"
  "一个截图函数都没有时的统一文案。
写成常量而不是两处各写一遍：探测函数（`eimg-ocr--capture-function'）与命令入口
（`eimg-ocr-region'，当探测被替换成返回 nil 时）都要给出同一句提示。")

(defconst eimg-ocr--image-extensions
  '("png" "jpg" "jpeg" "webp" "bmp" "tif" "tiff" "gif" "pdf")
  "`eimg-ocr-file' 与 `eimg-ocr-history' 认可的输入扩展名（小写，无点）。
与 `bin/eimg-ocr' 支持的输入格式保持一致；PDF 也在内，因为 CLI 会自己渲染分页。")

(defun eimg-ocr--capture-function ()
  "返回当前可用的截图函数符号；一个都没有时 `user-error'。
探测顺序：`eimg-ocr-capture-function'（显式指定）→ `eimg-capture' →
`+thomas/screenshot'。后两者用 `fboundp' 判，不 require 任何宿主包——本文件必须
能在 `emacs -Q' 里加载，把宿主配置的文件名写进 require 会直接断掉 `make test'。
临时把本函数替换成返回 nil 是测试用的注入点（`eimg-ocr-region' 会因此失败）。"
  (let ((function (or eimg-ocr-capture-function
                      (and (fboundp 'eimg-capture) 'eimg-capture)
                      (and (fboundp '+thomas/screenshot) '+thomas/screenshot))))
    (unless function
      (user-error "%s" eimg-ocr--capture-missing-message))
    function))

(defun eimg-ocr--capture (function)
  "调用截图命令 FUNCTION，返回它产出的截图文件绝对路径。
用 `call-interactively' 而不是 `funcall'：截图函数是**交互命令**，其对外契约是
「命令执行完毕后的返回值就是文件路径」。实测（emacs -Q --batch，打桩
`call-process' 与历史写入后 `(call-interactively '+thomas/screenshot)'）返回
`string'、绝对路径、存在、与命令内部生成的路径逐字相同；成功分支的最后一个
表达式就是 `file'。走 `call-interactively' 与用户手工执行是同一条路径，不会像
`funcall' 那样漏掉 `(interactive ...)' 里做的参数准备。

四类结果分三态报错，文案必须可区分（否则用户看不出是「命令没返回」还是
「返回了但文件不在」）：
  - 字符串且是**普通文件** → 原样返回
  - 非字符串（含 nil）→ 「截图函数没有返回文件路径」
  - 字符串但 `file-regular-p' 为 nil → 「截图函数返回的路径不可读: PATH」
  - FUNCTION 自身 signal（含它主动报的 `user-error'，如用户按了取消、外部工具
    没装）→ 包成「截图失败：<原始 message>」再抛 `user-error'：前缀统一让用户
    一眼看出「是截图这一步挂了」，原文保留让原因（取消 / 未安装 / 权限）不被吞掉。"
  (let ((path (condition-case err
                  (call-interactively function)
                (error (user-error "截图失败：%s" (error-message-string err))))))
    (cond
     ((not (stringp path))
      (user-error "截图函数没有返回文件路径（返回 %s）" (type-of path)))
     ((not (file-regular-p path))
      (user-error "截图函数返回的路径不可读: %s" path))
     (t path))))

(defun eimg-ocr--supported-file-p (file)
  "FILE 的扩展名是否在 `eimg-ocr--image-extensions' 里。
只比扩展名、不碰文件系统：调用方（选择 / 列举）已经拿到了候选路径，再问一次
`file-exists-p' 只会让「选了个尚不存在但格式正确的名字」被误判。"
  (and (stringp file)
       (member (downcase (or (file-name-extension file) ""))
               eimg-ocr--image-extensions)))

(defun eimg-ocr--config-with (config key value)
  "返回把 KEY 设为 VALUE 的 CONFIG 副本（不改动原 plist）。
不用 `plist-put'：它会就地改调用方传进来的列表，而调用方的 plist 常常是 defcustom
默认值的 `list' 字面量或调用者复用的变量，就地改等于悄悄改了别人。"
  (let (result)
    (while config
      (unless (eq (car config) key)
        (setq result (append result (list (car config) (cadr config)))))
      (setq config (cddr config)))
    (append result (list key value))))

(defun eimg-ocr--merge-config (defaults overrides)
  "把 OVERRIDES 合进 DEFAULTS（同名键以 OVERRIDES 为准），返回新 plist。
只做一层合并：ARGS 来自 transient infix（T5d），它要「只覆盖我关心的那几个项」，
深层合并对 plist 没有意义。"
  (let ((result defaults))
    (while overrides
      (setq result (eimg-ocr--config-with result (car overrides) (cadr overrides))
            overrides (cddr overrides)))
    result))

(defun eimg-ocr--config-source (config)
  "从配置 CONFIG 里取第一个输入文件路径；没有时返回 nil。
`--run' 用它填结果头行的「来源」——头行写的是人看的来源，不是 argv 里的位置。"
  (or (plist-get config :file)
      (car (eimg-core--as-list (plist-get config :files)))))

(defun eimg-ocr--failure-text (code stderr)
  "把退出码 CODE 与 STDERR 拼成「文案 + 排障提示」的完整错误文本。
提示单独一行：文案说「是什么」，提示说「怎么办」，挤在一行里读起来像重复。
未登记的码没有提示，此时只给文案（`eimg-core-exit-message' 已含 stderr 末行）。"
  (let ((text (eimg-core-exit-message code stderr))
        (hint (eimg-core-exit-hint code)))
    (if hint (format "%s\n%s" text hint) text)))

(defun eimg-ocr--safe-call (function &rest args)
  "在 sentinel 上下文里调用 FUNCTION（可空），错误只 `message'，不上抛。
sentinel 里 signal 会被 Emacs 打成 \"error in process sentinel\" 塞进 *Messages*，
既不可读，也会让排在同一批次后面的收尾动作被跳过。"
  (when function
    (condition-case err
        (apply function args)
      (error
       (message "eimg-ocr：回调失败：%s" (error-message-string err))))))

(defun eimg-ocr--remember-raw (text)
  "把 TEXT 的前 `eimg-ocr--raw-limit' 个字符写进 `eimg-ocr-raw-buffer-name'。
先 `erase-buffer' 再写：保留「最近一次」失败现场比累积多份更有用（旧的那份已经
被上一条错误信息引用过了）。"
  (let* ((raw (cond ((not (stringp text)) "")
                    ((> (length text) eimg-ocr--raw-limit)
                     (substring text 0 eimg-ocr--raw-limit))
                    (t text)))
         (buffer (get-buffer-create eimg-ocr-raw-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert raw)
        (goto-char (point-min))
        (set-buffer-modified-p nil)))
    buffer))

(defun eimg-ocr--run (args &optional on-success on-failure)
  "用配置 ARGS 跑一次 OCR 并统一四态收尾；**立即返回**（纯异步）。
ARGS 是**配置 plist**（`eimg-core-build-args' 的输入），不是 argv——argv 由本函数
现拼，调用方不必关心选项顺序，也不必重复一遍「哪些 nil 项要跳过」的规则。

ON-SUCCESS 在结果 buffer 渲染完成后、于**来源 buffer 的上下文里**以 PAGES 调用
一次（来源 buffer 已死时退化为当前 buffer）。
ON-FAILURE 仅在失败态以拼好的错误文案调用一次（超时也算失败）。
两者都在 sentinel 里执行，异常只 `message' 不上抛——见 `eimg-ocr--safe-call'。

四态：
  finished  → `eimg-core-parse-json' → `eimg-ocr--show-result'（写结果 buffer）
  failed    → `eimg-core-exit-message' + `eimg-core-exit-hint' 拼成可读文案，一律
              `message'。为什么不是 `user-error'：本函数在 sentinel 里跑，signal
              会被 Emacs 吞成 \"error in process sentinel\"，用户看不到；但绝不静默
              ——退出码 2/3/4/5 与超时都有文案与排障提示。
  cancelled → 静默收尾，只 `message' \"已取消\"（用户自己按的取消，不该报错）
  解析失败  → `message' 说明「输出无法解析」，并把原始 stdout 前 500 字符存进
              `eimg-ocr-raw-buffer-name'；**不覆盖**已有结果 buffer。
"
  (let* ((argv (eimg-core-build-args args))
         (source (eimg-ocr--config-source args))
         (origin (current-buffer))
         (started (current-time)))
    (eimg-ocr--start
     argv
     (lambda (status stdout stderr &optional code)
       (pcase status
         ('finished
          (condition-case err
              (let ((pages (eimg-core-parse-json stdout)))
                (with-current-buffer (if (buffer-live-p origin)
                                         origin
                                       (current-buffer))
                  (eimg-ocr--show-result
                   pages argv
                   (list :backend (plist-get args :backend)
                         :source source
                         ;; 配置本身也记下来：`eimg-ocr-rerun' 要重跑就得有配置，
                         ;; argv 是从它推出来的，反过来推不回去（选项顺序固定，但
                         ;; 无法区分「未指定」与「指定成默认值」）。
                         :config args
                         :elapsed (float-time (time-subtract (current-time) started))))
                  (eimg-ocr--safe-call on-success pages)))
            (eimg-core-parse-error
             (eimg-ocr--clear-progress)
             (eimg-ocr--remember-raw stdout)
             (message "eimg-ocr 输出无法解析：%s（原始输出前 %d 字符已存入 %s）"
                      (error-message-string err)
                      eimg-ocr--raw-limit
                      eimg-ocr-raw-buffer-name))))
         ('failed
          (eimg-ocr--clear-progress)
          (let ((text (eimg-ocr--failure-text code stderr)))
            (eimg-ocr--safe-call on-failure text)
            (message "eimg-ocr：%s" text)))
         ('cancelled
          (eimg-ocr--clear-progress)
          (message "eimg-ocr：已取消")))))
    (eimg-ocr--set-progress "识别中")))

(defun eimg-ocr--deliver-body (origin insert)
  "把最近一次识别结果的正文放进 `kill-ring'；INSERT 非 nil 时同时插入 ORIGIN。
正文取自已渲染的结果 buffer（`eimg-ocr--collect-body' 去头行）：这样复制 / 插入
与用户在结果 buffer 里按 `y' / `i' 得到的内容**逐字相同**，不会因为两套渲染路径
而在「有没有 `** 第 N 页'」这种细节上分叉。"
  (let ((body (eimg-ocr--collect-body (get-buffer eimg-ocr-buffer-name))))
    (when (string-empty-p body)
      (user-error "识别结果为空"))
    (kill-new body)
    (when insert
      (with-current-buffer origin
        (insert body)
        ;; 正文自身无末尾换行；补一个，避免插在正文中间时把后文粘上来。
        (unless (string-suffix-p "\n" body)
          (insert "\n"))))
    (message "eimg：已复制 %d 字符%s"
             (length body)
             (if insert (format "并插入 %s" (buffer-name origin)) ""))))

(defun eimg-ocr-region (&optional args)
  "框选屏幕区域并识别，正文进 `kill-ring'；`C-u' 时同时插入当前 buffer。
ARGS 是覆盖默认配置的 plist（供 T5d 的 transient infix 用，ARGS 优先），默认只强制
`:format \"json\"'——结果 buffer 需要结构化输出才能分页渲染。

无图形环境直接 `user-error'：框选依赖屏幕坐标与图形化的选择器，在终端 / 批处理里
不可能工作，硬跑到截图函数只会得到一句底层的、更难懂的报错。"
  (interactive)
  (unless (display-graphic-p)
    (user-error "eimg-ocr-region 需要图形环境：当前环境没有可框选的屏幕"))
  (let* ((insert-p (and current-prefix-arg t))
         (origin (current-buffer))
         (capture (or (eimg-ocr--capture-function)
                      (user-error "%s" eimg-ocr--capture-missing-message)))
         ;; 取返回值、判可读、区分失败文案都在 `eimg-ocr--capture' 里：本命令只
         ;; 负责「要一张图」这件事，截图函数长什么样与它无关。
         (path (eimg-ocr--capture capture)))
    (setq eimg-ocr--last-capture path)
    (eimg-ocr--run
     (eimg-ocr--config-with
      (eimg-ocr--merge-config (list :format "json") args)
      :file path)
     (lambda (_pages) (eimg-ocr--deliver-body origin insert-p)))))

(defun eimg-ocr-file (&optional args)
  "选一个图片或 PDF 文件做 OCR，结果进 `eimg-ocr-buffer-name'。
ARGS 同 `eimg-ocr-region'（plist 覆盖，ARGS 优先）。
默认目录取 `eimg-ocr-images-dir'，未配置时用 `default-directory'。
选择器用 `read-file-name' 而不是 `read-file-name' 之外的补全框架：本文件必须保持
顶层零第三方依赖，且 shell 与 Dired 里 `default-directory' 天然就是用户期望的起点。"
  (interactive)
  (let* ((directory (or eimg-ocr-images-dir default-directory))
         (file (read-file-name
                "选择图片或 PDF: " directory nil t nil
                (lambda (name)
                  (or (file-directory-p name)
                      (eimg-ocr--supported-file-p name))))))
    (unless (eimg-ocr--supported-file-p file)
      (user-error "不支持的输入文件：%s（只支持 %s）"
                  file (string-join eimg-ocr--image-extensions "/")))
    (eimg-ocr--run
     (eimg-ocr--config-with
      (eimg-ocr--merge-config (list :format "json") args)
      :file file))))

(defun eimg-ocr--history-directory ()
  "返回历史截图的扫描目录；目录不存在时 `user-error'。
优先级：`eimg-ocr-images-dir' → 最近一次截图所在目录 → `default-directory'。
第二级不是可有可无的兜底：截图目录配置留空时，用户刚截的图所在目录就是他能想到
的「历史」；退到 `default-directory' 只在本次会话还没截过图时发生。"
  (let ((captured eimg-ocr--last-capture))
    (let ((directory (or eimg-ocr-images-dir
                         (and (stringp captured) (file-name-directory captured))
                         default-directory)))
      (unless (and (stringp directory) (file-directory-p directory))
        (user-error "历史截图目录不存在：%s" directory))
      directory)))

(defun eimg-ocr--recent-images (directory limit)
  "返回 DIRECTORY 下最近的 LIMIT 个图片文件（绝对路径，按修改时间降序）。
只认 `eimg-ocr--image-extensions' 里的扩展名：历史目录里常混着 `.json' / `.txt'
的旁路文件，把它们列进候选只会让用户选到一个必然失败的输入。"
  (let (files)
    (dolist (name (ignore-errors (directory-files directory t "\\`[^.]" t)))
      (when (and (file-regular-p name)
                 (eimg-ocr--supported-file-p name))
        (push name files)))
    (setq files (sort files
                      (lambda (a b)
                        (time-less-p
                         (file-attribute-modification-time (file-attributes b))
                         (file-attribute-modification-time (file-attributes a))))))
    (cl-subseq files 0 (min limit (length files)))))

(defun eimg-ocr-history (&optional args)
  "从最近的截图里挑一张做 OCR，结果进 `eimg-ocr-buffer-name'。
ARGS 同 `eimg-ocr-region'（plist 覆盖，ARGS 优先）。
没有候选时 `user-error' 而不是 `completing-read' 一个空表：空表在部分补全框架下
会静默返回空串，然后调用方拿着空文件名去起进程，报错点就飘到 CLI 那一侧了。"
  (interactive)
  (let* ((directory (eimg-ocr--history-directory))
         (files (eimg-ocr--recent-images directory eimg-ocr-history-size)))
    (unless files
      (user-error "没有可用的历史截图：%s 下没有图片文件" directory))
    (let ((file (completing-read "历史截图: " files nil t)))
      (eimg-ocr--run
       (eimg-ocr--config-with
        (eimg-ocr--merge-config (list :format "json") args)
        :file file)
       nil))))

(define-derived-mode eimg-ocr-backends-mode special-mode "eimg-OCR 后端"
  "后端列表 buffer 的主模式（只读，`q' 关闭）。
`truncate-lines' 与结果 buffer 同理：后端探测输出里可能有很长的路径 / 版本串。"
  (setq-local truncate-lines t))

(defun eimg-ocr--show-backends (text)
  "把 CLI `--list-backends' 的输出 TEXT 写进后端 buffer，并 `message' 一行摘要。
输出原样保存（不做表格化）：CLI 的这份输出是给人扫一眼的，二次排版只会引入
「哪个字段是后端名」的猜测。"
  (eimg-ocr--clear-progress)
  (let ((buffer (get-buffer-create eimg-ocr-backends-buffer-name))
        (lines 0))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (if (string-empty-p (string-trim text)) "(空输出)\n" text))
        (unless (string-suffix-p "\n" (buffer-string))
          (insert "\n"))
        ;; 先写完文本再开 mode：`special-mode' 会把 buffer 置只读，反序会 write error。
        (eimg-ocr-backends-mode)
        (goto-char (point-min))
        (set-buffer-modified-p nil)
        (setq lines (count-lines (point-min) (point-max)))))
    (message "eimg：后端列表已写入 %s（%d 行）"
             eimg-ocr-backends-buffer-name lines)
    buffer))

(defun eimg-ocr-list-backends ()
  "列出 OCR 后端及可用状态，输出写入 `eimg-ocr-backends-buffer-name'。
用与 OCR **同一套**异步进程层，而不是 `call-process'：`call-process' 阻塞到子进程
退出、期间 Emacs 不跑 timer，`eimg-ocr-timeout' 对它完全无效——后端探测一旦卡住
（Python 侧 import torch 之类）就会锁死用户主线程。异步路径的超时由
`eimg-ocr--on-timeout' 兜住，失败文案与 OCR 失败共用 `eimg-ocr--failure-text'。
唯一保留的**同步**错误是「CLI 定位失败」这类前置检查：此时进程还没起，`user-error'
能让调用者（含 transient 菜单）直接拿到可读报错。"
  (interactive)
  (eimg-ocr--start
   (list "--list-backends")
   (lambda (status stdout stderr &optional code)
     (pcase status
       ('finished (eimg-ocr--show-backends stdout))
       ('failed
        (eimg-ocr--clear-progress)
        (message "eimg-ocr：查询后端失败：%s" (eimg-ocr--failure-text code stderr)))
       ('cancelled
        (eimg-ocr--clear-progress)
        (message "eimg-ocr：已取消")))))
  (eimg-ocr--set-progress "查询后端中"))

(provide 'eimg-ocr)

;;; eimg-ocr.el ends here
