;;; eimg-ocr-test.el --- eimg-ocr 的 ERT 用例  -*- lexical-binding: t; -*-

;; Author: thomas
;; Version: 0.1.0
;; Keywords: convenience, tools, ocr

;;; Commentary:

;; 覆盖进程层的四态收尾（finished / failed / cancelled / 超时）、状态清理、
;; CLI 路径推导（`-L .' 与 build 目录软链两种加载方式）、进度文本，以及结果
;; buffer 的渲染 / 正文提取 / 六条键位。
;;
;; 三条硬约束：
;;   1. **绝不调用真实 `bin/eimg-ocr'**：它依赖 rapidocr / tesseract 与 Python
;;      环境，在不具备这些依赖的机器上会让 `make test' 变红。所有用例都用
;;      `make-temp-file' 现写一个 shell stub，再用 `eimg-ocr-cli-path' 注入。
;;   2. **绝不死等**：纯异步收尾靠 `eimg-ocr-test--wait' 轮询（上限 10 秒），
;;      到点返回 nil，让 `should' 打出可读的失败信息。
;;   3. 每个用例先 `eimg-ocr-test--reset'：模块状态是全局单槽，上一个用例残留
;;      的活动进程 / 定时器 / 结果状态会让下一个用例假绿。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'eimg-ocr)

;;;; ── 测试辅助 ──────────────────────────────────────────────────────────

(defun eimg-ocr-test--stub (body)
  "把 BODY 写成一个 `#!/bin/sh' 脚本并返回其路径（已设可执行位）。
BODY 可含多行；用 `make-temp-file' 保证多次调用互不覆盖。"
  (let ((file (make-temp-file "eimg-ocr-stub-" nil ".sh")))
    (with-temp-file file
      (insert "#!/bin/sh\n" body "\n"))
    (set-file-modes file #o755)
    file))

(defun eimg-ocr-test--wait (pred &optional timeout)
  "轮询 PRED 直到非 nil；超过 TIMEOUT 秒（默认 10）后放弃并返回 nil。"
  (let ((deadline (+ (float-time) (or timeout 10))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (sleep-for 0.02))
    (funcall pred)))

(defun eimg-ocr-test--reset ()
  "清掉上一个用例可能残留的进程、定时器、进度与结果状态。
结果 buffer 也一并关掉：它是固定名字的单例，留着会让「本次渲染到底写了什么」
变得不可区分（上一个用例的内容可能被误当成这次的结果）。"
  (when (eimg-ocr-busy-p)
    (ignore-errors (delete-process eimg-ocr--process)))
  (when (timerp eimg-ocr--timeout-timer)
    (ignore-errors (cancel-timer eimg-ocr--timeout-timer)))
  (when (get-buffer eimg-ocr-buffer-name)
    (ignore-errors (kill-buffer (get-buffer eimg-ocr-buffer-name))))
  ;; 原始输出与后端列表 buffer 同样是固定名单例：不关掉的话，「这次失败到底有没有
  ;; 写原始输出 / 这次查询到底有没有出结果」会被上一个用例的内容假绿。
  (dolist (name (list eimg-ocr-raw-buffer-name eimg-ocr-backends-buffer-name))
    (when (get-buffer name)
      (ignore-errors (kill-buffer (get-buffer name)))))
  (setq eimg-ocr--process nil
        eimg-ocr--started-at nil
        eimg-ocr--timeout-timer nil
        eimg-ocr--progress nil
        eimg-ocr--last-args nil
        eimg-ocr--last-origin nil
        eimg-ocr--last-meta nil
        eimg-ocr--last-summary nil
        eimg-ocr--last-capture nil))

(defmacro eimg-ocr-test--with-stub (file body &rest forms)
  "在 FORMS 执行期间把 BODY 写成 stub 脚本并绑定到 FILE；结束后删脚本。"
  (declare (indent 2))
  `(let ((,file (eimg-ocr-test--stub ,body)))
     (unwind-protect
         (progn ,@forms)
       (ignore-errors (delete-file ,file)))))

;;;; ── 1. 四态收尾 ──────────────────────────────────────────────────────

(ert-deftest eimg-ocr-test-finished-callback ()
  "退出码 0：回调收到 `finished' 与完整 stdout，stderr 是**干净**空串。"
  (eimg-ocr-test--reset)
  (eimg-ocr-test--with-stub stub "printf '{\"pages\":[]}\\n'"
    (let ((calls nil)
          (eimg-ocr-cli-path stub))
      (eimg-ocr--start '("--format" "json")
                       (lambda (&rest args) (push args calls)))
      (should (eimg-ocr-test--wait (lambda () calls)))
      (should (equal 1 (length calls)))
      (should (eq 'finished (nth 0 (car calls))))
      (should (string-match-p "pages" (nth 1 (car calls))))
      ;; stderr 必须是空串：若内部 pipe 的默认 sentinel 生效，这里会多出
      ;; 「Process eimg-ocr-stderr stderr finished」。
      (should (equal "" (nth 2 (car calls)))))))

(ert-deftest eimg-ocr-test-failed-callback ()
  "非零退出：回调收到 `failed'、真实退出码与 stderr 原文。"
  (eimg-ocr-test--reset)
  (eimg-ocr-test--with-stub stub "printf 'partial\\n'\nprintf 'ValueError: bad image\\n' >&2\nexit 3"
    (let ((calls nil)
          (eimg-ocr-cli-path stub))
      (eimg-ocr--start nil (lambda (&rest args) (push args calls)))
      (should (eimg-ocr-test--wait (lambda () calls)))
      (should (equal 1 (length calls)))
      (should (eq 'failed (nth 0 (car calls))))
      (should (equal "partial\n" (nth 1 (car calls))))
      (should (string-match-p "ValueError: bad image" (nth 2 (car calls))))
      (should (equal 3 (nth 3 (car calls)))))))

(ert-deftest eimg-ocr-test-cancelled-path ()
  "被取消：回调收到 `cancelled' 且不带输出；除提示外不留错误文案。"
  (eimg-ocr-test--reset)
  (eimg-ocr-test--with-stub stub "sleep 10"
    (let ((calls nil)
          (messages nil)
          (eimg-ocr-cli-path stub))
      (eimg-ocr--start nil (lambda (&rest args) (push args calls)))
      (should (eimg-ocr-busy-p))
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (push (apply #'format format-string args) messages))))
        (eimg-ocr-cancel))
      (should (eimg-ocr-test--wait (lambda () calls)))
      (should (equal 1 (length calls)))
      (should (equal '(cancelled "" "") (car calls)))
      (should (null eimg-ocr--process))
      (should (null eimg-ocr--timeout-timer))
      ;; 「取消不留错误文案」：除取消提示外不得出现错误 / 失败字样。
      (should (equal 1 (length messages)))
      (should (string-match-p "已取消" (car messages)))
      (should-not (string-match-p "错误\\|失败\\|error\\|failed"
                                 (car messages))))))

(ert-deftest eimg-ocr-test-timeout-path ()
  "超时：回调收到 `failed' + 伪退出码 124 + 可读的超时说明。
选 `failed' 而不是 `cancelled' 的理由：超时不是用户主动取消，若按取消静默处理，
界面会什么都不显示，用户无从知道任务已经死掉。"
  (eimg-ocr-test--reset)
  (eimg-ocr-test--with-stub stub "sleep 5"
    (let ((calls nil)
          (eimg-ocr-cli-path stub)
          (eimg-ocr-timeout 1))
      (eimg-ocr--start nil (lambda (&rest args) (push args calls)))
      (should (eimg-ocr-test--wait (lambda () calls) 8))
      (should (equal 1 (length calls)))
      (should (eq 'failed (nth 0 (car calls))))
      (should (equal eimg-ocr--timeout-exit-code (nth 3 (car calls))))
      (should (string-match-p "超时" (nth 2 (car calls))))
      (should (null eimg-ocr--timeout-timer)))))

(ert-deftest eimg-ocr-test-state-cleared-after-finish ()
  "收尾后模块状态全部归零（进程 / 启动时间 / 定时器 / 进度）。"
  (eimg-ocr-test--reset)
  (eimg-ocr-test--with-stub stub "printf 'ok\\n'"
    (let ((calls nil)
          (eimg-ocr-cli-path stub))
      (eimg-ocr--set-progress "识别中" 2 1)
      (eimg-ocr--start nil (lambda (&rest args) (push args calls)))
      (should (processp eimg-ocr--process))
      (should (timerp eimg-ocr--timeout-timer))
      (should (eimg-ocr-test--wait (lambda () calls)))
      (should (null eimg-ocr--process))
      (should (null eimg-ocr--started-at))
      (should (null eimg-ocr--timeout-timer))
      (should (null eimg-ocr--progress))
      (should-not (eimg-ocr-busy-p)))))

(ert-deftest eimg-ocr-test-callback-once-with-chunked-output ()
  "输出分多段到达时仍只收尾一次：stdout 必须是全部分段拼接后的完整内容。"
  (eimg-ocr-test--reset)
  (eimg-ocr-test--with-stub stub "printf 'a\\n'; sleep 0.1; printf 'b\\n'; sleep 0.1; printf 'c\\n'"
    (let ((calls nil)
          (eimg-ocr-cli-path stub))
      (eimg-ocr--start nil (lambda (&rest args) (push args calls)))
      (should (eimg-ocr-test--wait (lambda () calls)))
      (should (string-match-p "a\nb\nc\n" (nth 1 (car calls))))
      ;; 再等一会儿，确认没有迟到的第二次回调。
      (sleep-for 0.3)
      (should (equal 1 (length calls))))))

(ert-deftest eimg-ocr-test-sentinel-reentry-calls-callback-once ()
  "同一进程的 sentinel 被再次触发时不得二次回调（`eimg-done' 守卫）。
Emacs 会为同一进程在不同时机多次调用 sentinel：若没有守卫，`finished' 之后
再来一个 `killed' 会让已完成的任务再走一遍收尾、甚至被改判成取消。"
  (eimg-ocr-test--reset)
  (eimg-ocr-test--with-stub stub "printf 'ok\\n'"
    (let* ((calls nil)
           (callback (lambda (&rest args) (push args calls)))
           (eimg-ocr-cli-path stub)
           (proc (eimg-ocr--start nil callback)))
      (should (eimg-ocr-test--wait (lambda () calls)))
      (should (equal 1 (length calls)))
      (sleep-for 0.2)
      (eimg-ocr--sentinel proc "finished\n" callback)
      (eimg-ocr--sentinel proc "killed\n" callback)
      (should (equal 1 (length calls)))
      (should (eq 'finished (nth 0 (car calls)))))))

;;;; ── 2. 取消与前置检查 ────────────────────────────────────────────────

(ert-deftest eimg-ocr-test-cancel-without-process ()
  "没有活动进程时 `eimg-ocr-cancel' 只提示，不报错也不改状态。"
  (eimg-ocr-test--reset)
  (let ((messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      ;; 直接调用：一旦 signal，ERT 会把这个用例判红。
      (eimg-ocr-cancel))
    (should (equal 1 (length messages)))
    (should (string-match-p "没有正在进行" (car messages)))
    (should (null eimg-ocr--process))))

(ert-deftest eimg-ocr-test-start-user-error-without-cli ()
  "CLI 定位失败时启动给 `user-error'（而不是裸 file-error / 静默失败）。"
  (eimg-ocr-test--reset)
  (let ((eimg-ocr-cli-path "/nonexistent/eimg-ocr-bin"))
    (should-error (eimg-ocr--start nil #'ignore) :type 'user-error)
    (should (null eimg-ocr--process))))

(ert-deftest eimg-ocr-test-start-returns-immediately ()
  "启动不等子进程：stub 睡 3 秒，`eimg-ocr--start' 必须在 0.5 秒内返回。"
  (eimg-ocr-test--reset)
  (eimg-ocr-test--with-stub stub "sleep 3"
    (let* ((eimg-ocr-cli-path stub)
           (started (float-time))
           (proc (eimg-ocr--start nil #'ignore)))
      (unwind-protect
          (progn
            (should (processp proc))
            (should (process-live-p proc))
            (should (< (- (float-time) started) 0.5)))
        (ignore-errors (delete-process proc))))))

;;;; ── 3. CLI 路径推导 ──────────────────────────────────────────────────

(ert-deftest eimg-ocr-test-cli-path-direct-load-path ()
  "`-L .' 场景：推导结果落在 eimg 自身 .el 所在目录的 bin/eimg-ocr 上。"
  (let* ((eimg-ocr-cli-path nil)
         (library (eimg-ocr--library-file))
         (path (eimg-ocr--cli-path)))
    (should (stringp library))
    (should (stringp path))
    (should (string-suffix-p "bin/eimg-ocr" path))
    (should (equal (expand-file-name "bin/eimg-ocr"
                                     (file-name-directory library))
                   path))))

(ert-deftest eimg-ocr-test-cli-path-through-build-symlink ()
  "build 目录只软链 .el：必须经 `file-truename' 反推回源仓库的 bin/eimg-ocr。"
  (let* ((library (or (locate-library "eimg")
                      (symbol-file 'eimg-ocr--cli-path 'defun)))
         (repo-root (file-name-directory (file-truename library)))
         (tmpdir (file-name-as-directory (make-temp-file "eimg-ocr-build-" t))))
    (unwind-protect
        (progn
          (make-symbolic-link (expand-file-name "eimg.el" repo-root)
                              (expand-file-name "eimg.el" tmpdir))
          (let ((load-path (cons tmpdir load-path))
                (eimg-ocr-cli-path nil))
            ;; 先确认 load-path 命中的确实是软链，否则本用例可能因别处命中而假绿。
            (should (equal (expand-file-name "eimg.el" tmpdir)
                           (locate-library "eimg")))
            (should (equal (expand-file-name "bin/eimg-ocr" repo-root)
                           (eimg-ocr--cli-path)))
            (should-not (string-prefix-p tmpdir (eimg-ocr--cli-path)))))
      (delete-directory tmpdir t))))

(ert-deftest eimg-ocr-test-cli-path-missing-returns-nil ()
  "CLI 不存在时返回 nil 而不是 signal：错误文案统一由调用方给。"
  (let ((eimg-ocr-cli-path "/nonexistent/eimg-ocr-bin"))
    (should-not (eimg-ocr--cli-path)))
  (let ((eimg-ocr-cli-path nil))
    (cl-letf (((symbol-function 'eimg-ocr--library-file)
               (lambda () "/nonexistent/eimg-root/eimg.el")))
      (should-not (eimg-ocr--cli-path)))))

;;;; ── 4. 进度文本 ──────────────────────────────────────────────────────

(ert-deftest eimg-ocr-test-progress-and-mode-line-string ()
  "进度 plist 与导出的模式行文本；空闲时是空串（不污染调用方的模式行）。"
  (eimg-ocr-test--reset)
  (should (equal "" (eimg-ocr-mode-line-string)))
  (should (equal " 识别中 2/3 "
                 (progn (eimg-ocr--set-progress "识别中" 3 2)
                        (eimg-ocr-mode-line-string))))
  (should (equal " 识别中 共 3 页 "
                 (progn (eimg-ocr--set-progress "识别中" 3)
                        (eimg-ocr-mode-line-string))))
  (should (equal " 预处理 "
                 (progn (eimg-ocr--set-progress "预处理")
                        (eimg-ocr-mode-line-string))))
  (should (null (eimg-ocr--clear-progress)))
  (should (null eimg-ocr--progress))
  (should (equal "" (eimg-ocr-mode-line-string))))

;;;; ── 5. 结构性不变量 ──────────────────────────────────────────────────

(ert-deftest eimg-ocr-test-no-third-party-and-no-blocking-wait ()
  "顶层零第三方依赖；源码里不出现阻塞式等待进程输出的调用（纯异步）。"
  (let ((source (with-temp-buffer
                  (insert-file-contents (or (symbol-file 'eimg-ocr--start 'defun)
                                            (locate-library "eimg-ocr")))
                  (buffer-string))))
    (dolist (package '("consult" "posframe" "embark" "transient"))
      (should-not (string-match-p (format "(require '%s" package) source)))
    ;; 为什么断言它不存在：`accept-process-output' 会把 Emacs 主线程阻塞到进程
    ;; 真有输出为止，等于把「异步识别」退回同步等待——daemon 下会连带卡住用户
    ;; 输入，取消与超时定时器也都跑不动（定时器要等主线程回到命令循环）。
    ;; 直接写字符串而不是拼 `concat'：拼接只让人以为要绕开某个搜索检查，实则
    ;; 什么都没绕开（断言的对象是 eimg-ocr.el 的源码文本，不是本文件）。
    (should-not (string-match-p "accept-process-output" source))))

;;;; ── 6. 结果 buffer 与键位 ────────────────────────────────────────────

(defun eimg-ocr-test--pages ()
  "固定 fixture：2 页，每页 2 块。
刻意走真实的 `eimg-core-parse-json' 而不是手搓 alist：渲染入口的输入本来就来自
解析层，从 JSON 出发才能连带锁住「解析 → 渲染」这一段契约。"
  (eimg-core-parse-json
   (concat "{\"pages\":["
           "{\"page\":1,\"source\":\"a.pdf\",\"blocks\":"
           "[{\"text\":\"第一页第一块\"},{\"text\":\"第一页第二块\"}]},"
           "{\"page\":2,\"source\":\"a.pdf\",\"blocks\":"
           "[{\"text\":\"第二页第一块\"},{\"text\":\"第二页第二块\"}]}"
           "]}")))

(defun eimg-ocr-test--expected-body ()
  "`eimg-ocr-test--pages' 渲染后的正文，**逐字**基准（刻意手写死值）。
不用 `eimg-core-render-org' 现算：那样渲染层一改，这里跟着变，断言就失去意义。"
  (concat "** 第 1 页\n"
          "第一页第一块\n"
          "第一页第二块\n"
          "** 第 2 页\n"
          "第二页第一块\n"
          "第二页第二块"))

(defun eimg-ocr-test--render (&optional args meta)
  "在当前 buffer（作为来源 buffer）里渲染固定 fixture，返回结果 buffer。"
  (eimg-ocr--show-result (eimg-ocr-test--pages)
                         (or args '("--format" "json" "a.pdf"))
                         (or meta (list :backend "rapidocr"
                                        :elapsed 1.3
                                        :source "a.pdf"))))

(defun eimg-ocr-test--mode-line-references-p (form symbol)
  "FORM 这棵模式行结构里是否出现 SYMBOL。"
  (cond ((eq form symbol) t)
        ((consp form)
         (or (eimg-ocr-test--mode-line-references-p (car form) symbol)
             (eimg-ocr-test--mode-line-references-p (cdr form) symbol)))
        (t nil)))

(ert-deftest eimg-ocr-test-mode-derives-from-special-mode ()
  "`eimg-ocr-mode' 派生自 `special-mode'：只读、`q' 可关、无自插内容。"
  (eimg-ocr-test--reset)
  (with-temp-buffer
    (eimg-ocr-mode)
    (should (derived-mode-p 'special-mode))
    (should (eq 'special-mode (get 'eimg-ocr-mode 'derived-mode-parent)))))

(ert-deftest eimg-ocr-test-mode-sets-truncate-lines ()
  "`truncate-lines' 必须是 buffer 局部的 t（OCR 段落常是超长单行）。"
  (eimg-ocr-test--reset)
  (with-temp-buffer
    (eimg-ocr-mode)
    (should (eq t truncate-lines))
    (should (local-variable-p 'truncate-lines))))

(ert-deftest eimg-ocr-test-keymap-bindings ()
  "六个键位逐一解析到对应命令。"
  (dolist (pair '(("y" . eimg-ocr-copy)
                  ("i" . eimg-ocr-insert)
                  ("w" . eimg-ocr-write-file)
                  ("g" . eimg-ocr-rerun)
                  ("q" . quit-window)
                  ("k" . eimg-ocr-cancel)))
    (should (eq (cdr pair) (keymap-lookup eimg-ocr-mode-map (car pair)))))
  ;; 六个命令都必须是交互命令，否则绑了也用不了（`M-x' 与按键走同一条判定）。
  (dolist (cmd '(eimg-ocr-copy eimg-ocr-insert eimg-ocr-write-file
                 eimg-ocr-rerun))
    (should (commandp cmd))))

(ert-deftest eimg-ocr-test-keymap-has-no-control-c-prefix ()
  "`eimg-ocr-mode-map' 不得占用 `C-c' 前缀：`C-c + 单字母' 是用户保留键位。
判据用单键 `C-c'（前缀是否绑了 keymap）而不是 `C-c y' 这类整串：
`keymap-lookup' 对「前缀未绑定」的多键序列会返回 `1'（实测 Emacs 31.1），
拿它断言会把正确实现判成失败。"
  (should-not (keymap-lookup eimg-ocr-mode-map "C-c"))
  (should-not (lookup-key eimg-ocr-mode-map (kbd "C-c"))))

(ert-deftest eimg-ocr-test-show-result-exact-text ()
  "渲染结果**逐字**等于「说明头行 + org 正文 + 末尾换行」。"
  (eimg-ocr-test--reset)
  (let ((buf (eimg-ocr-test--render)))
    (should (equal (concat "# eimg-ocr: a.pdf（backend=rapidocr，2 页，1.30s）\n"
                           (eimg-ocr-test--expected-body)
                           "\n")
                   (with-current-buffer buf
                     (buffer-substring-no-properties (point-min) (point-max)))))
    ;; 渲染完的三条副作用：point 在开头、buffer 未修改、mode 已就位。
    (with-current-buffer buf
      (should (= (point-min) (point)))
      (should-not (buffer-modified-p))
      (should (eq major-mode 'eimg-ocr-mode)))
    ;; 可重跑状态被记下来
    (should (equal '("--format" "json" "a.pdf") eimg-ocr--last-args))
    (should (equal "a.pdf" (plist-get eimg-ocr--last-meta :source)))))

(ert-deftest eimg-ocr-test-collect-body-strips-header ()
  "正文提取去掉头行、保留 `** 第 N 页'；无头行时原样返回。"
  (eimg-ocr-test--reset)
  (let ((buf (eimg-ocr-test--render)))
    (with-current-buffer buf
      (should (equal (eimg-ocr-test--expected-body) (eimg-ocr--collect-body)))
      (should (string-match-p "\\`\\*\\* 第 1 页" (eimg-ocr--collect-body)))
      (should-not (string-match-p "eimg-ocr: " (eimg-ocr--collect-body)))))
  (with-temp-buffer
    (insert "无头行正文\n第二行\n")
    (should (equal "无头行正文\n第二行" (eimg-ocr--collect-body))))
  (with-temp-buffer
    (insert "# eimg-ocr: 只有头行\n")
    (should (equal "" (eimg-ocr--collect-body)))))

(ert-deftest eimg-ocr-test-copy-puts-body-in-kill-ring ()
  "`y' 把正文放进 kill-ring，且**不含**头行。
`kill-ring' 动态绑定为 nil：`kill-new' 改的是全局变量，不隔离会污染后续用例
（也会被并行跑测试的其他 buffer 影响）。"
  (eimg-ocr-test--reset)
  (let ((buf (eimg-ocr-test--render))
        (messages nil))
    (let ((kill-ring nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (push (apply #'format format-string args) messages))))
        (with-current-buffer buf (call-interactively #'eimg-ocr-copy)))
      (should (equal (eimg-ocr-test--expected-body) (car kill-ring)))
      (should-not (string-match-p "eimg-ocr: " (car kill-ring))))
    (should (string-match-p "6 行" (car messages)))
    (should (string-match-p (number-to-string (length (eimg-ocr-test--expected-body)))
                            (car messages)))))

(ert-deftest eimg-ocr-test-insert-into-origin-at-point ()
  "`i' 把正文插入来源 buffer 的光标处（不是 buffer 末尾、不是别处）。"
  (eimg-ocr-test--reset)
  (let ((origin (generate-new-buffer " *eimg-ocr-origin*")))
    (unwind-protect
        (progn
          (with-current-buffer origin
            (insert "前缀：")
            (eimg-ocr-test--render))
          (should (eq origin eimg-ocr--last-origin))
          (with-current-buffer (get-buffer eimg-ocr-buffer-name)
            (eimg-ocr-insert))
          (should (equal (concat "前缀：" (eimg-ocr-test--expected-body) "\n")
                         (with-current-buffer origin (buffer-string)))))
      (kill-buffer origin))))

(ert-deftest eimg-ocr-test-insert-does-not-double-newline ()
  "正文自身已带末尾换行时不再补一个。
这条用例防的是 `(insert body (unless …))' 写法：条件不成立时第二个实参是 nil，
`(insert \"x\" nil)' 会 signal `wrong-type-argument'——只有当 buffer 正文末尾有
两个换行（用户手工编辑过结果 buffer）时才踩得到，手测极易漏掉。"
  (eimg-ocr-test--reset)
  (let ((origin (generate-new-buffer " *eimg-ocr-origin*")))
    (unwind-protect
        (progn
          (with-current-buffer origin (eimg-ocr-test--render))
          (with-current-buffer (get-buffer eimg-ocr-buffer-name)
            (let ((inhibit-read-only t))
              (goto-char (point-max))
              (insert "\n")))
          (with-current-buffer (get-buffer eimg-ocr-buffer-name)
            (eimg-ocr-insert))
          (should (equal (concat (eimg-ocr-test--expected-body) "\n")
                         (with-current-buffer origin (buffer-string)))))
      (kill-buffer origin))))

(ert-deftest eimg-ocr-test-insert-dead-origin-errors ()
  "来源 buffer 已 kill 时 `i' 必须 `user-error'，不能静默插到别处。"
  (eimg-ocr-test--reset)
  (let ((origin (generate-new-buffer " *eimg-ocr-origin*")))
    (with-current-buffer origin (eimg-ocr-test--render))
    (kill-buffer origin)
    (should-not (buffer-live-p origin))
    (with-current-buffer (get-buffer eimg-ocr-buffer-name)
      (should-error (eimg-ocr-insert) :type 'user-error))))

(ert-deftest eimg-ocr-test-rerun-without-args-errors ()
  "没有历史参数时 `g' 必须 `user-error'（不猜参数、也不起进程）。"
  (eimg-ocr-test--reset)
  (should-not eimg-ocr--last-args)
  (with-temp-buffer
    (should-error (eimg-ocr-rerun) :type 'user-error))
  (should-not (eimg-ocr-busy-p)))

(ert-deftest eimg-ocr-test-write-file-writes-body-and-confirms-overwrite ()
  "`w' 写入的是去头行正文 + 末尾换行；文件已存在且拒绝覆盖时 `user-error'。
（batch 下 `read-file-name' 不可用，所以直接测试带参函数体。）"
  (eimg-ocr-test--reset)
  (let* ((dir (make-temp-file "eimg-ocr-write-" t))
         (file (expand-file-name "out.org" dir))
         (buf (eimg-ocr-test--render)))
    (unwind-protect
        (progn
          (with-current-buffer buf (eimg-ocr-write-file file))
          (should (equal (concat (eimg-ocr-test--expected-body) "\n")
                         (with-temp-buffer
                           (insert-file-contents file)
                           (buffer-string))))
          ;; 已存在 + 用户拒绝覆盖 → user-error，且文件内容不变
          (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
            (with-current-buffer buf
              (should-error (eimg-ocr-write-file file) :type 'user-error))))
      (delete-directory dir t))))

(ert-deftest eimg-ocr-test-mode-line-format-is-buffer-local ()
  "模式行是 buffer 局部值，且结构里含 `eimg-ocr-mode-line-string'。
为什么用结构断言而不是 `format-mode-line'：batch 环境（`make test'）没有窗口，
`format-mode-line' 对任何格式都返回空串，按文本断言会把「没生效」判成通过。"
  (eimg-ocr-test--reset)
  (let ((buf (eimg-ocr-test--render)))
    (with-current-buffer buf
      (should (local-variable-p 'mode-line-format))
      (let ((format (buffer-local-value 'mode-line-format buf)))
        (should format)
        (should (eimg-ocr-test--mode-line-references-p
                 format 'eimg-ocr-mode-line-string))
        ;; `:eval' 包裹形态也要在：裸符号 `eimg-ocr-mode-line-string' 会被当成
        ;; 字面量插进模式行，什么都不会显示。
        (should (member '(:eval (eimg-ocr-mode-line-string)) format))))))

(ert-deftest eimg-ocr-test-mode-line-shows-summary-and-progress ()
  "模式行文本的三种形态：完成摘要 → 进度（清掉摘要）→ 清空后空串。"
  (eimg-ocr-test--reset)
  (let ((buf (eimg-ocr-test--render)))
    (with-current-buffer buf
      (should (equal " 完成（2 页，1.30s） " (eimg-ocr-mode-line-string)))
      ;; 新一轮开始：进度顶掉摘要
      (eimg-ocr--set-progress "识别中" 3 2)
      (should (equal " 识别中 2/3 " (eimg-ocr-mode-line-string)))
      (eimg-ocr--clear-progress)
      (should (equal "" (eimg-ocr-mode-line-string))))))

(ert-deftest eimg-ocr-test-global-mode-line-format-unchanged ()
  "加载与渲染都不得改全局 `mode-line-format'（否则所有 buffer 的模式行都被污染）。"
  (eimg-ocr-test--reset)
  (let ((before (default-value 'mode-line-format)))
    (eimg-ocr-test--render)
    (with-current-buffer (get-buffer eimg-ocr-buffer-name)
      (should (local-variable-p 'mode-line-format)))
    (should (equal before (default-value 'mode-line-format)))
    ;; 结果 buffer 之外的 buffer 连 buffer 局部值都不该有
    (with-temp-buffer
      (should-not (local-variable-p 'mode-line-format)))))

;;;; ── 7. 统一编排与三个入口命令 ────────────────────────────────────────

(defconst eimg-ocr-test--json-payload
  "{\"pages\":[{\"page\":1,\"source\":\"shot.png\",\"blocks\":[{\"text\":\"第一行\"},{\"text\":\"第二行\"}]}]}"
  "stub CLI 输出的固定 JSON：单页两块。
单页即可验证「正文带 `** 第 1 页' 头、说明头行不在正文里」这两条断言。")

(defun eimg-ocr-test--json-command (&optional prefix)
  "返回一段 sh 脚本片段：先执行 PREFIX（可空），再输出固定 JSON。
用 heredoc 而不是 `printf '%s'`：JSON 里全是双引号，heredoc 不需要任何转义，
也不会被 shell 当成格式串处理。"
  (concat (or prefix "")
          "cat <<'EIMGJSON'\n" eimg-ocr-test--json-payload "\nEIMGJSON\n"))

(defmacro eimg-ocr-test--with-graphic (&rest forms)
  "在 FORMS 执行期间让 `display-graphic-p' 恒返回 t。
`eimg-ocr-region' 的前置检查在 batch 下必然失败，注入图形能力才能测到后续路径。"
  (declare (indent 0))
  `(cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _frame) t)))
     ,@forms))

(defmacro eimg-ocr-test--with-capture (captured &rest forms)
  "在 FORMS 执行期间把截图探测替换成「返回 CAPTURED 路径的**交互命令**」。
被替换的是 `eimg-ocr--capture-function'（探测层），而不是 `eimg-ocr-region' 里
的调用点——探测层的返回约定（返回函数）才是 `eimg-ocr-region' 真正依赖的东西。
返回的函数必须带 `(interactive)'：`eimg-ocr--capture' 走 `call-interactively'，
普通 lambda 会 `Not a command' 直接失败（不是用例想要的失败方式）。"
  (declare (indent 1))
  `(cl-letf (((symbol-function 'eimg-ocr--capture-function)
              (lambda () (lambda () (interactive) ,captured))))
     ,@forms))

(defvar eimg-ocr-test--messages nil
  "`eimg-ocr-test--collect-messages' 在动态作用域内收集到的 `message' 文本。
必须是 `defvar'：只有被声明为 special 的变量才会在 let 内动态绑定，否则 lambda
闭包里读到的仍是全局值（恒 nil），等待条件会永远不成立。")

(defmacro eimg-ocr-test--collect-messages (&rest forms)
  "在 FORMS 执行期间收集 `message' 文本（按调用顺序），返回字符串列表。
FORMS 内部可以直接读 `eimg-ocr-test--messages' 判「消息到了没」——异步收尾靠它
轮询，不必为了拿结果而把 `sleep-for' 固定住。"
  (declare (indent 0))
  `(let ((eimg-ocr-test--messages nil))
     (cl-letf (((symbol-function 'message)
                (lambda (format-string &rest args)
                  (push (apply #'format format-string args)
                        eimg-ocr-test--messages))))
       ,@forms)
     (nreverse eimg-ocr-test--messages)))

(ert-deftest eimg-ocr-test-entry-commands-are-commands ()
  "三个入口命令与后端查询都是交互命令，且都只接受 0–1 个可选参数。
`ARGS' 可选参数是为 T5d 的 transient infix 预留的：命令必须能在**不带**参数时
被 `M-x' / 键位直接调用，否则菜单之外就没有入口了。"
  (dolist (command '(eimg-ocr-region eimg-ocr-file eimg-ocr-history))
    (should (commandp command))
    (should (equal '(0 . 1) (func-arity command))))
  (should (commandp 'eimg-ocr-list-backends))
  (should (equal '(0 . 0) (func-arity 'eimg-ocr-list-backends))))

(ert-deftest eimg-ocr-test-region-requires-graphic ()
  "无图形环境时 `eimg-ocr-region' 立刻 `user-error'，文案指明图形环境。
batch 环境本身就是「无图形」的真实场景，这里再显式绑一次 `noninteractive' 只是
把意图写在用例里，不依赖 `make test' 恰好在 batch 下跑。"
  (eimg-ocr-test--reset)
  (let ((noninteractive t))
    (should-error (eimg-ocr-region) :type 'user-error)
    (should (string-match-p
             "图形环境"
             (condition-case err
                 (eimg-ocr-region)
               (user-error (error-message-string err))))))
  ;; 前置检查失败时不得留下活动进程。
  (should-not (eimg-ocr-busy-p)))

(ert-deftest eimg-ocr-test-region-without-capture-errors ()
  "一个截图函数都没有时 `eimg-ocr-region' `user-error'，文案指向正确的补救路径。
替换探测函数使其返回 nil（模拟「`eimg-capture' 未加载且未显式配置」），命令自身
必须兜住，而不是 `funcall nil' 抛出难懂的 void-function。文案要给**本包的**两个
出口（require 加载 / 自定义变量），不提任何外部仓库。"
  (eimg-ocr-test--reset)
  (cl-letf (((symbol-function 'eimg-ocr--capture-function) (lambda () nil)))
    (eimg-ocr-test--with-graphic
      (should-error (eimg-ocr-region) :type 'user-error)
      (let ((text (condition-case err
                      (eimg-ocr-region)
                    (user-error (error-message-string err)))))
        (should (string-match-p "未找到截图函数" text))
        (should (string-match-p "eimg-ocr-capture-function" text)))))
  (should-not (eimg-ocr-busy-p)))

(ert-deftest eimg-ocr-test-region-copies-body-to-kill-ring ()
  "region 成功后正文进 `kill-ring'：带 `** 第 1 页'、不带说明头行。
`kill-ring' 动态绑定为 nil：`kill-new' 改的是全局变量，不隔离会污染后续用例。"
  (eimg-ocr-test--reset)
  (eimg-ocr-test--with-stub stub (eimg-ocr-test--json-command)
    (let ((captured (make-temp-file "eimg-capture-" nil ".png"))
          (kill-ring nil)
          (eimg-ocr-cli-path stub))
      (unwind-protect
          (progn
            (eimg-ocr-test--with-graphic
              (eimg-ocr-test--with-capture captured
                (with-temp-buffer
                  (eimg-ocr-region)
                  (should (eimg-ocr-test--wait (lambda () kill-ring))))))
            (should (string-match-p "\\`\\*\\* 第 1 页" (car kill-ring)))
            (should (string-match-p "第一行" (car kill-ring)))
            (should-not (string-match-p "# eimg-ocr:" (car kill-ring)))
            ;; 截图路径要记下来：`eimg-ocr-history' 靠它反推默认目录。
            (should (equal captured eimg-ocr--last-capture)))
        (ignore-errors (delete-file captured))))))

(ert-deftest eimg-ocr-test-region-with-prefix-inserts ()
  "`C-u' 变体：除复制外还插入当前 buffer。
`current-prefix-arg' 在这里**必须**显式绑：`C-u' 的语义由它承载，直接函数调用
拿不到前缀参数。"
  (eimg-ocr-test--reset)
  (eimg-ocr-test--with-stub stub (eimg-ocr-test--json-command)
    (let ((captured (make-temp-file "eimg-capture-" nil ".png"))
          (kill-ring nil)
          (eimg-ocr-cli-path stub))
      (unwind-protect
          (progn
            (eimg-ocr-test--with-graphic
              (eimg-ocr-test--with-capture captured
                (with-temp-buffer
                  (let ((current-prefix-arg '(4)))
                    (eimg-ocr-region))
                  (should (eimg-ocr-test--wait
                           (lambda () (string-match-p "第 1 页" (buffer-string)))))
                  (should (string-match-p "\\*\\* 第 1 页" (buffer-string)))
                  (should (string-match-p "第二行" (buffer-string)))
                  ;; 插入的正文同样不含说明头行。
                  (should-not (string-match-p "# eimg-ocr:" (buffer-string))))))
            (should (string-match-p "第 1 页" (car kill-ring))))
        (ignore-errors (delete-file captured))))))

(ert-deftest eimg-ocr-test-file-renders-result ()
  "`eimg-ocr-file' 选到图片后走统一编排，结果进结果 buffer。"
  (eimg-ocr-test--reset)
  (eimg-ocr-test--with-stub stub (eimg-ocr-test--json-command)
    (let ((image (make-temp-file "eimg-file-" nil ".png"))
          (eimg-ocr-cli-path stub))
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) image)))
              (eimg-ocr-file))
            (should (eimg-ocr-test--wait
                     (lambda ()
                       (and (get-buffer eimg-ocr-buffer-name)
                            (with-current-buffer (get-buffer eimg-ocr-buffer-name)
                              (string-match-p "\\*\\* 第 1 页" (buffer-string)))))))
            (should (equal image (plist-get eimg-ocr--last-meta :source))))
        (ignore-errors (delete-file image))))))

(ert-deftest eimg-ocr-test-file-rejects-unsupported-extension ()
  "选中非图片 / 非 PDF 扩展名时 `user-error'，且不起进程。"
  (eimg-ocr-test--reset)
  (let ((text (make-temp-file "eimg-file-" nil ".txt")))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) text)))
            (should-error (eimg-ocr-file) :type 'user-error)
            (should (string-match-p
                     "不支持的输入文件"
                     (condition-case err
                         (eimg-ocr-file)
                       (user-error (error-message-string err))))))
          (should-not (eimg-ocr-busy-p)))
      (ignore-errors (delete-file text)))))

(ert-deftest eimg-ocr-test-history-empty-directory-errors ()
  "目录存在但没有图片时 `user-error'，不静默返回空候选。"
  (eimg-ocr-test--reset)
  (let ((directory (make-temp-file "eimg-history-" t)))
    (unwind-protect
        (let ((eimg-ocr-images-dir directory))
          (should-error (eimg-ocr-history) :type 'user-error)
          (should (string-match-p
                   "没有可用的历史截图"
                   (condition-case err
                       (eimg-ocr-history)
                     (user-error (error-message-string err))))))
      (delete-directory directory t))))

(ert-deftest eimg-ocr-test-history-picks-recent-file ()
  "历史候选按修改时间降序，选中后走通并出结果。
`completing-read' 打桩为「取候选表首项」：既验证排序（首项必须是最新的那张），
又避免在 batch 下真的去读 minibuffer。"
  (eimg-ocr-test--reset)
  (eimg-ocr-test--with-stub stub (eimg-ocr-test--json-command)
    (let* ((directory (make-temp-file "eimg-history-" t))
           (older (expand-file-name "old.png" directory))
           (newer (expand-file-name "new.png" directory))
           ;; 目录里混一个非图片文件：它不该出现在候选里。
           (decoy (expand-file-name "note.txt" directory))
           (picked nil)
           (eimg-ocr-cli-path stub))
      (unwind-protect
          (progn
            (dolist (file (list older newer decoy))
              (with-temp-file file (insert "x")))
            (set-file-times older (time-subtract (current-time) 100))
            (set-file-times newer (time-subtract (current-time) 10))
            (set-file-times decoy (current-time))
            (should (equal (list newer older)
                           (eimg-ocr--recent-images directory 10)))
            (let ((eimg-ocr-images-dir directory))
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (_prompt collection &rest _)
                           (setq picked (car collection))
                           picked)))
                (eimg-ocr-history)))
            (should (equal newer picked))
            (should (eimg-ocr-test--wait
                     (lambda ()
                       (and (get-buffer eimg-ocr-buffer-name)
                            (with-current-buffer (get-buffer eimg-ocr-buffer-name)
                              (string-match-p "第 1 页" (buffer-string)))))))
            (should (equal newer (plist-get eimg-ocr--last-meta :source))))
        (delete-directory directory t)))))

(ert-deftest eimg-ocr-test-run-failure-shows-message-and-hint ()
  "退出码 3：`message' 文案含「输入不可读」与排障提示，且**不**写结果 buffer。
失败走 `message' 而不是 `user-error'——本函数在 sentinel 里跑，signal 会被 Emacs
吞成 \"error in process sentinel\"，用户看不到任何可读信息。"
  (eimg-ocr-test--reset)
  (eimg-ocr-test--with-stub stub "printf 'ValueError: cannot read image\\n' >&2\nexit 3"
    ;; 必须用 `let*'：`messages' 的初始化表达式里就要跑命令，而 `let' 是并行绑定，
    ;; 那样命令看到的 `eimg-ocr-cli-path' 仍是全局 nil → 直接去调真实 CLI。
    (let* ((eimg-ocr-cli-path stub)
           (messages (eimg-ocr-test--collect-messages
                       (eimg-ocr--run (list :format "json" :file "/tmp/eimg-a.png"))
                       (should (eimg-ocr-test--wait
                                (lambda () eimg-ocr-test--messages))))))
      (let ((text (mapconcat #'identity messages "\n")))
        (should (string-match-p "输入不可读" text))
        ;; 提示（`eimg-core-exit-hint'）必须在，不能只给标签不给出路。
        (should (string-match-p "检查路径" text))
        (should (string-match-p "cannot read image" text)))
      (should-not (get-buffer eimg-ocr-buffer-name))
      (should (null eimg-ocr--progress)))))

(ert-deftest eimg-ocr-test-run-unparsable-json-keeps-raw ()
  "输出不是合法 JSON 时：`message' 说明无法解析，原始输出进 `*eimg-ocr-raw*'。
没有原始输出就只剩一句「无法解析」，看不出是 CLI 版本不对、后端吐了半截、还是
输出里混进了日志。"
  (eimg-ocr-test--reset)
  (eimg-ocr-test--with-stub stub "printf 'Traceback: not json at all\\n'"
    ;; 必须用 `let*'：`messages' 的初始化表达式里就要跑命令，而 `let' 是并行绑定，
    ;; 那样命令看到的 `eimg-ocr-cli-path' 仍是全局 nil → 直接去调真实 CLI。
    (let* ((eimg-ocr-cli-path stub)
           (messages (eimg-ocr-test--collect-messages
                       (eimg-ocr--run (list :format "json" :file "/tmp/eimg-a.png"))
                       (should (eimg-ocr-test--wait
                                (lambda () eimg-ocr-test--messages))))))
      (should (string-match-p "无法解析" (mapconcat #'identity messages "\n")))
      (let ((raw (get-buffer eimg-ocr-raw-buffer-name)))
        (should raw)
        (with-current-buffer raw
          (should (string-match-p "not json at all" (buffer-string)))))
      ;; 解析失败不得写出半份结果，也不得留下进度。
      (should-not (get-buffer eimg-ocr-buffer-name))
      (should (null eimg-ocr--progress)))))

(ert-deftest eimg-ocr-test-rerun-reuses-run ()
  "`g' 复用 `eimg-ocr--run'：重跑真的又起一次 CLI，结果仍写回同一个 buffer。
用 stub 往计数文件追加行来判「跑了几次」——只看结果 buffer 无法区分「重跑成功」与
「上次的内容还在」。"
  (eimg-ocr-test--reset)
  (let* ((counter (make-temp-file "eimg-rerun-counter-"))
         (origin (generate-new-buffer " *eimg-rerun-origin*")))
    (unwind-protect
        (eimg-ocr-test--with-stub
            stub (eimg-ocr-test--json-command
                  (format "echo x >> '%s'\n" counter))
          (let ((eimg-ocr-cli-path stub))
            (with-current-buffer origin
              (eimg-ocr--run (list :format "json" :file "first.png"))
              (should (eimg-ocr-test--wait
                       (lambda ()
                         (and (get-buffer eimg-ocr-buffer-name)
                              (with-current-buffer (get-buffer eimg-ocr-buffer-name)
                                (string-match-p "第 1 页" (buffer-string))))))))
            ;; 配置必须被记下来，否则重跑无从下手。
            (should (equal "first.png" (plist-get eimg-ocr--last-meta :source)))
            (should (plist-get eimg-ocr--last-meta :config))
            (with-current-buffer (get-buffer eimg-ocr-buffer-name)
              (eimg-ocr-rerun))
            (should (eimg-ocr-test--wait
                     (lambda ()
                       (>= (with-temp-buffer
                             (insert-file-contents counter)
                             (length (split-string (buffer-string) "\n" t)))
                           2))))
            (with-current-buffer (get-buffer eimg-ocr-buffer-name)
              (should (string-match-p "\\*\\* 第 1 页" (buffer-string))))
            ;; 重跑后回插目标仍是来源 buffer（不是结果 buffer 自己）。
            (should (eq origin eimg-ocr--last-origin)))
        (when (buffer-live-p origin) (kill-buffer origin))
        (ignore-errors (delete-file counter))))))

(ert-deftest eimg-ocr-test-list-backends-writes-buffer ()
  "`eimg-ocr-list-backends' 把 CLI 输出原样写进只读的后端 buffer 并提示摘要。"
  (eimg-ocr-test--reset)
  (eimg-ocr-test--with-stub stub "printf 'rapidocr\\tavailable\\ntesseract\\tmissing\\n'"
    ;; 必须用 `let*'：`messages' 的初始化表达式里就要跑命令，而 `let' 是并行绑定，
    ;; 那样命令看到的 `eimg-ocr-cli-path' 仍是全局 nil → 直接去调真实 CLI。
    (let* ((eimg-ocr-cli-path stub)
           (messages (eimg-ocr-test--collect-messages
                       (eimg-ocr-list-backends)
                       (should (eimg-ocr-test--wait
                                (lambda ()
                                  (and (get-buffer eimg-ocr-backends-buffer-name)
                                       (with-current-buffer
                                           (get-buffer eimg-ocr-backends-buffer-name)
                                         (string-match-p "tesseract" (buffer-string))))))))))
      (with-current-buffer (get-buffer eimg-ocr-backends-buffer-name)
        (should (derived-mode-p 'special-mode))
        (should buffer-read-only)
        (should (string-match-p "rapidocr\tavailable" (buffer-string)))
        (should (string-match-p "tesseract\tmissing" (buffer-string))))
      ;; 摘要一行给的是 buffer 名与行数，不是把整份输出塞进回显区。
      (should (string-match-p "后端列表已写入"
                              (car (last messages))))
      (should (null eimg-ocr--progress)))))

;;;; ── 8. 截图函数返回值契约 ────────────────────────────────────────────

;; 这一节锁定 `eimg-ocr--capture' 的**四态**：拿到路径 / 返回非字符串 /
;; 返回不可读路径 / 命令自身 signal。为什么要单独成节：截图与 OCR 现在是同仓的
;; 两个模块，`eimg-ocr--capture' 的契约靠这一节钉住——一旦 `eimg-capture' 成功分支的
;; 最后一个表达式被改掉，识别会静默退化成「什么也没发生」，而那时既没有报错也没有
;; 结果，只能靠人回头翻代码。

(defun eimg-ocr-test--stub-capture (value)
  "构造一个返回 VALUE 的**交互命令** lambda。
用统一构造器而不是每处手写 lambda：`call-interactively' 的调用路径要求
`commandp' 为真，漏写 `(interactive)' 只会得到一句 `Not a command'。"
  (lambda () (interactive) value))

(ert-deftest eimg-ocr-test-capture-uses-command-return-value ()
  "截图命令返回合法路径 → `eimg-ocr--capture' 原样返回该路径。
同时断言走的是 `call-interactively' 那条路径：stub 必须是 `commandp'，
否则「用 `funcall' 也能过」会让本用例失去意义。"
  (let ((file (make-temp-file "eimg-capture-cmd-" nil ".png")))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'eimg-ocr-test--stub-capture)
                     (eimg-ocr-test--stub-capture file)))
            (should (commandp 'eimg-ocr-test--stub-capture))
            (should (equal file (eimg-ocr--capture 'eimg-ocr-test--stub-capture)))))
      (ignore-errors (delete-file file)))))

(ert-deftest eimg-ocr-test-capture-nil-return-errors ()
  "截图命令返回 nil → `user-error'，文案指出「没有返回文件路径」。
这条是上游契约被破坏时最先亮的那盏灯：命令跑完了、什么也没返回，若静默通过，
用户会看到「OCR 正在识别」然后卡在一个不存在的文件上。"
  (cl-letf (((symbol-function 'eimg-ocr-test--stub-capture)
             (eimg-ocr-test--stub-capture nil)))
    (let ((text (condition-case err
                    (eimg-ocr--capture 'eimg-ocr-test--stub-capture)
                  (user-error (error-message-string err)))))
      (should (stringp text))
      (should (string-match-p "没有返回文件路径" text))
      ;; 必须与「路径不可读」区分开：两种失败的排障方向完全不同。
      (should-not (string-match-p "不可读" text)))))

(ert-deftest eimg-ocr-test-capture-unreadable-path-errors ()
  "截图命令返回一个**不存在**的路径 → `user-error' 含「不可读」与该路径。
刻意不建这个文件：`file-regular-p' 对「不存在」与「是目录」都返回 nil，两种都在
本态覆盖范围内。"
  (let ((missing (expand-file-name "eimg-capture-missing.png"
                                   temporary-file-directory)))
    (should-not (file-exists-p missing))
    (cl-letf (((symbol-function 'eimg-ocr-test--stub-capture)
               (eimg-ocr-test--stub-capture missing)))
      (let ((text (condition-case err
                      (eimg-ocr--capture 'eimg-ocr-test--stub-capture)
                    (user-error (error-message-string err)))))
        (should (stringp text))
        (should (string-match-p "不可读" text))
        ;; 报错必须带路径本身：只报「不可读」用户不知道去找哪个文件。
        (should (string-match-p (regexp-quote missing) text))))))

(ert-deftest eimg-ocr-test-capture-command-error-keeps-prefix ()
  "截图命令自身 `user-error' → 外层仍是 `user-error'，文案形如「截图失败：<原文>」。
前缀统一让用户一眼看出失败发生在「截图」这一步；原文必须保留，否则「用户按了
取消」「外部工具没装」这类原因会被吞成一句无从下手的通用报错。"
  (cl-letf (((symbol-function 'eimg-ocr-test--stub-capture)
             (lambda () (interactive) (user-error "用户取消了截图"))))
    (let ((text (condition-case err
                    (eimg-ocr--capture 'eimg-ocr-test--stub-capture)
                  (user-error (error-message-string err)))))
      (should (stringp text))
      (should (string-prefix-p "截图失败：" text))
      (should (string-match-p "用户取消了截图" text)))))

(ert-deftest eimg-ocr-test-capture-function-defaults-to-eimg-capture ()
  "`eimg-ocr-capture-function' 为 nil 时探测链落到 `eimg-capture'。
打桩的是 `eimg-capture' 的 **symbol-function**（而不是只让它 `fboundp'）：这样
一次覆盖「探测到哪个符号」与「调用它真能拿到路径」两件事，避免只测到一半——
只断言返回符号名的话，探测到 `eimg-capture' 但调用路径不通仍会绿。

保存 / 恢复原定义而不是直接用 `cl-letf'：本测试进程只 `(require 'eimg-ocr)'，
`eimg-capture' 通常未定义，`cl-letf' 恢复时会把符号留成「fbound 但函数为 nil」，
后续用例的探测会命中一个空函数而报出与本用例无关的错误。"
  (let ((file (make-temp-file "eimg-capture-default-" nil ".png"))
        (eimg-ocr-capture-function nil)
        (original (and (fboundp 'eimg-capture) (symbol-function 'eimg-capture))))
    (unwind-protect
        (progn
          (fset 'eimg-capture (lambda () (interactive) file))
          (should (eq 'eimg-capture (eimg-ocr--capture-function)))
          (should (equal file
                         (eimg-ocr--capture (eimg-ocr--capture-function)))))
      (if original
          (fset 'eimg-capture original)
        (fmakunbound 'eimg-capture))
      (ignore-errors (delete-file file)))))

(ert-deftest eimg-ocr-test-capture-contract-uses-eimg-capture ()
  "`eimg-ocr.el' 的**可执行代码**只认 `eimg-capture'，不出现宿主仓库符号。
扫描前剔除整行注释（`^[ \\t]*;;'）：作者行与「为什么不再依赖外部实现」这类说明
允许存在，判据只针对会被求值的 form——`fboundp' / `require' / 符号引用，它们
一旦指向不存在的库就是运行期 `void-function'，而 `make test' 只加载本仓库文件，
根本看不到那个错误。

`case-fold-search' 置 nil：与验收用的 `grep -c \"thomas\"' 同语义，避免在大小写
不敏感匹配下把 `Thomas' 这类变体放过。"
  (let* ((file (expand-file-name
                "eimg-ocr.el"
                (file-name-directory
                 (file-truename (locate-library "eimg-ocr")))))
         (raw (with-temp-buffer
                (insert-file-contents file)
                (buffer-string)))
         (code (replace-regexp-in-string "^[ \t]*;;.*$" "" raw)))
    ;; 扫描本身要有效：取不到源码时下面两条断言会「因为没锚点」而失败，
    ;; 但失败信息说不清原因，故先断一次非空。
    (should (> (length code) 1000))
    (should (string-match-p "eimg-capture" code))
    (let ((case-fold-search nil))
      (should-not (string-match-p "thomas" code)))))

;;;; ── 9. 配置项（defcustom）与参数拼装链 ────────────────────────────────

;; 这一节的判据是「**接线**」而不是「有没有定义变量」：五个新 defcustom 单独存在
;; 毫无价值，价值在于 `eimg-ocr--run' 真的把它们垫进 argv、且 ARGS 能覆盖它们。
;; 所有断言都通过 `eimg-ocr--start' 打桩读 argv（绝不起真实 CLI）。

(defun eimg-ocr-test--capture-argv (args)
  "调用 `eimg-ocr--run' 传入 ARGS，返回它交给 `eimg-ocr--start' 的 argv。
`eimg-ocr--start' 换成记录参数的空实现；回调不执行，故不会写结果 buffer、
也不会触发解析。顺带断言「argv 非空」——空 argv 说明接线整段断了。"
  (let (captured)
    (cl-letf (((symbol-function 'eimg-ocr--start)
               (lambda (argv _callback) (setq captured argv) 'eimg-ocr-test-proc)))
      (eimg-ocr--run args))
    captured))

(defun eimg-ocr-test--arg-value (argv option)
  "返回 ARGV 里 OPTION 后面的取值；OPTION 不在时返回 nil。"
  (cadr (member option argv)))

(ert-deftest eimg-ocr-test-config-defcustoms-and-defaults ()
  "五个新 defcustom 均已定义，且默认值与计划一致。
逐个 `should' 而不是循环比对整张表：失败信息里直接指出是哪一项，不必回头数下标。"
  (should (boundp 'eimg-ocr-backend))
  (should (equal "auto" (default-value 'eimg-ocr-backend)))
  (should (boundp 'eimg-ocr-lang))
  (should (equal "chi_sim+eng" (default-value 'eimg-ocr-lang)))
  (should (boundp 'eimg-ocr-pdf-dpi))
  (should (equal 200 (default-value 'eimg-ocr-pdf-dpi)))
  (should (boundp 'eimg-ocr-python))
  (should (null (default-value 'eimg-ocr-python)))
  (should (boundp 'eimg-ocr-tessdata-dir))
  (should (null (default-value 'eimg-ocr-tessdata-dir)))
  (should (boundp 'eimg-ocr-report-style))
  (should (eq 'org (default-value 'eimg-ocr-report-style)))
  ;; 类型也要是计划的形态：report-style 是 choice，否则「用户能不能改」
  ;; 在 Customize 里就无从表达；backend / dpi 同理。
  (should (eq 'choice (car (get 'eimg-ocr-report-style 'custom-type))))
  (should (eq 'choice (car (get 'eimg-ocr-backend 'custom-type))))
  (should (eq 'choice (car (get 'eimg-ocr-pdf-dpi 'custom-type)))))

(ert-deftest eimg-ocr-test-run-takes-defaults-from-defcustoms ()
  "未传 ARGS 时 argv 取 defcustom 默认值：`--backend auto --lang chi_sim+eng
--dpi 200'，`--python' 因 nil 不出现，`--format' 恒 json。
这条把「defcustom 真的接进了拼装链」钉死——只定义变量不接线时它会红。"
  (eimg-ocr-test--reset)
  (let ((argv (eimg-ocr-test--capture-argv '(:file "/tmp/eimg-a.png"))))
    (should (equal "auto" (eimg-ocr-test--arg-value argv "--backend")))
    (should (equal "chi_sim+eng" (eimg-ocr-test--arg-value argv "--lang")))
    (should (equal "200" (eimg-ocr-test--arg-value argv "--dpi")))
    (should (equal "json" (eimg-ocr-test--arg-value argv "--format")))
    ;; nil 的 defcustom 必须**完全不出现在 argv** 里：写成 `--python nil' 会让
    ;; CLI 收到一个叫 "nil" 的路径，比不传更糟。
    (should-not (member "--python" argv))
    ;; 文件路径恒在末尾（`eimg-core-build-args' 的固定顺序）。
    (should (equal "/tmp/eimg-a.png" (car (last argv))))))

(ert-deftest eimg-ocr-test-run-args-override-defcustoms ()
  "ARGS 显式给出的 `:backend' / `:lang' / `:dpi' / `:python' 全部覆盖 defcustom。
优先级链是「ARGS > defcustom > CLI 默认」，这是菜单 infix 能生效的前提。"
  (eimg-ocr-test--reset)
  (let ((argv (eimg-ocr-test--capture-argv
               '(:backend "tesseract" :lang "eng" :dpi 300
                 :python "/x/python" :file "/tmp/eimg-a.png"))))
    (should (equal "tesseract" (eimg-ocr-test--arg-value argv "--backend")))
    (should (equal "eng" (eimg-ocr-test--arg-value argv "--lang")))
    (should (equal "300" (eimg-ocr-test--arg-value argv "--dpi")))
    (should (equal "/x/python" (eimg-ocr-test--arg-value argv "--python")))
    ;; 覆盖之后不得残留被覆盖的默认值（同一选项只出现一次）。
    (should (= 1 (cl-count "--backend" argv :test #'equal)))
    (should-not (member "auto" argv))
    (should-not (member "chi_sim+eng" argv))))

(ert-deftest eimg-ocr-test-run-python-from-defcustom ()
  "`eimg-ocr-python' 非 nil 时 argv 含 `--python <值>'（来自 defcustom 而非 ARGS）。"
  (eimg-ocr-test--reset)
  (let* ((eimg-ocr-python "/usr/bin/python3")
         (argv (eimg-ocr-test--capture-argv '(:file "/tmp/eimg-a.png"))))
    (should (equal "/usr/bin/python3"
                   (eimg-ocr-test--arg-value argv "--python")))))

(ert-deftest eimg-ocr-test-tessdata-dir-defcustom-and-default-argv ()
  "`eimg-ocr-tessdata-dir' 存在、默认为 nil，且 nil 时 argv **不含** `--tessdata-dir'。
nil 的语义是「交给 CLI 自己决定」（先系统默认位置、再 eimg 安装目录），因此绝不能
把 `--tessdata-dir nil' 这类占位写进 argv——那会让 CLI 收到一个叫 \"nil\" 的目录。"
  (should (boundp 'eimg-ocr-tessdata-dir))
  (should (null (default-value 'eimg-ocr-tessdata-dir)))
  (should (eq 'choice (car (get 'eimg-ocr-tessdata-dir 'custom-type))))
  (eimg-ocr-test--reset)
  (let ((argv (eimg-ocr-test--capture-argv '(:file "/tmp/eimg-a.png"))))
    (should-not (member "--tessdata-dir" argv))
    (should-not (member "nil" argv))))

(ert-deftest eimg-ocr-test-run-tessdata-dir-from-defcustom-and-args ()
  "`eimg-ocr-tessdata-dir' 非 nil 时 argv 含 `--tessdata-dir <值>'；ARGS 给值则覆盖它。
两向都钉：只测「不出现」会把「压根没接线」判成通过，只测「出现」又看不出优先级。"
  (eimg-ocr-test--reset)
  (let* ((eimg-ocr-tessdata-dir "/x/tessdata")
         (argv (eimg-ocr-test--capture-argv '(:file "/tmp/eimg-a.png"))))
    (should (equal "/x/tessdata"
                   (eimg-ocr-test--arg-value argv "--tessdata-dir"))))
  (eimg-ocr-test--reset)
  (let* ((eimg-ocr-tessdata-dir "/x/tessdata")
         (argv (eimg-ocr-test--capture-argv
                '(:tessdata-dir "/y/tessdata" :file "/tmp/eimg-a.png"))))
    (should (equal "/y/tessdata"
                   (eimg-ocr-test--arg-value argv "--tessdata-dir")))
    (should-not (member "/x/tessdata" argv))
    (should (= 1 (cl-count "--tessdata-dir" argv :test #'equal)))))

;;;; ── 9b. ollama 的两个 defcustom 与接线 ──────────────────────────────────

;; 判据仍是「接线」而不是「有没有定义变量」：`eimg-ocr-ollama-model' 单独存在毫无
;; 价值，价值在于它真的经 `eimg-ocr--config-defaults' → `eimg-core-build-args' 落成
;; `--ollama-model'，且 nil 时**不**出现（交给 CLI 判「ollama 不可用」）。

(ert-deftest eimg-ocr-test-ollama-defcustoms-and-defaults ()
  "ollama 的两个 defcustom 存在、默认 nil、类型是 choice，且 choice 首项能表达「未配置」。
默认 nil 是契约的一部分：`eimg-ocr-backend' 默认 `auto'，模型未配置时 ollama 必须判
不可用，而不是替用户挑一个模型名（「自动挑模型」是被明确否决的方案）。"
  (should (boundp 'eimg-ocr-ollama-model))
  (should (null (default-value 'eimg-ocr-ollama-model)))
  (should (eq 'choice (car (get 'eimg-ocr-ollama-model 'custom-type))))
  (should (boundp 'eimg-ocr-ollama-url))
  (should (null (default-value 'eimg-ocr-ollama-url)))
  (should (eq 'choice (car (get 'eimg-ocr-ollama-url 'custom-type))))
  ;; 两个 choice 的首项都是「值为 nil 的 const」：Customize 里能表达「不配置」，
  ;; 逼用户填一个字符串就等于取消了「未配置即不可用」这条语义。
  (dolist (symbol '(eimg-ocr-ollama-model eimg-ocr-ollama-url))
    (let ((first-choice (nth 1 (get symbol 'custom-type))))
      (should (eq 'const (car first-choice)))
      (should (null (car (last first-choice)))))))

(ert-deftest eimg-ocr-test-backend-choice-includes-ollama ()
  "`eimg-ocr-backend' 的 choice 里含 ollama，且四个取值一个不少。
按取值扫描而不是比对 `(const :tag …)' 整条：tag 是给人看的文案，允许措辞调整；
取值是契约，`--backend' 的 choices 必须与它一致。"
  (let ((choices (cdr (get 'eimg-ocr-backend 'custom-type))))
    (dolist (value '("auto" "rapidocr" "ollama" "tesseract"))
      (should (cl-some (lambda (item) (equal value (car (last item)))) choices)))))

(ert-deftest eimg-ocr-test-config-defaults-include-ollama ()
  "`eimg-ocr--config-defaults' 带 `:ollama-model' / `:ollama-url' 两键，默认值 nil。
判据必须用 `plist-member'：两键的默认值本来就是 nil，`plist-get' 取不到与「键压根
不存在」不可区分，正好会放过「定义变量但没接线」。"
  (let ((defaults (eimg-ocr--config-defaults)))
    (should (plist-member defaults :ollama-model))
    (should (plist-member defaults :ollama-url))
    (should (null (plist-get defaults :ollama-model)))
    (should (null (plist-get defaults :ollama-url)))
    ;; 新键只允许追加：既有键一个都不能少。
    (dolist (key '(:backend :lang :format :dpi :python :tessdata-dir))
      (should (plist-member defaults key)))))

(ert-deftest eimg-ocr-test-run-ollama-nil-not-in-argv ()
  "两键为 nil 时 `eimg-ocr--run' 的 argv 不含 `--ollama-model' / `--ollama-url'。
nil 的语义是「交给 CLI」：模型 nil → CLI 判 ollama 不可用并给配置指引；URL nil →
CLI 用它内置的 `http://127.0.0.1:11434'。"
  (eimg-ocr-test--reset)
  (let ((argv (eimg-ocr-test--capture-argv '(:file "/tmp/eimg-a.png"))))
    (should-not (member "--ollama-model" argv))
    (should-not (member "--ollama-url" argv))
    (should-not (member "nil" argv))
    ;; 既有键不受影响（新键为 nil 不该把别的选项挤掉）。
    (should (equal "auto" (eimg-ocr-test--arg-value argv "--backend")))
    (should (equal "/tmp/eimg-a.png" (car (last argv))))))

(ert-deftest eimg-ocr-test-run-ollama-from-defcustom-and-args ()
  "两键非 nil 时进 argv；ARGS 显式给出则覆盖 defcustom（同一选项只出现一次）。
两向都钉：只测「不出现」会把「压根没接线」判成通过，只测「出现」又看不出优先级。"
  (eimg-ocr-test--reset)
  (let* ((eimg-ocr-ollama-model "qwen2.5-vl:7b")
         (eimg-ocr-ollama-url "http://127.0.0.1:11434")
         (argv (eimg-ocr-test--capture-argv '(:file "/tmp/eimg-a.png"))))
    (should (equal "qwen2.5-vl:7b" (eimg-ocr-test--arg-value argv "--ollama-model")))
    (should (equal "http://127.0.0.1:11434"
                   (eimg-ocr-test--arg-value argv "--ollama-url"))))
  (eimg-ocr-test--reset)
  (let* ((eimg-ocr-ollama-model "from-defcustom")
         (argv (eimg-ocr-test--capture-argv
                '(:ollama-model "from-args" :file "/tmp/eimg-a.png"))))
    (should (equal "from-args" (eimg-ocr-test--arg-value argv "--ollama-model")))
    (should-not (member "from-defcustom" argv))
    (should (= 1 (cl-count "--ollama-model" argv :test #'equal)))))

(ert-deftest eimg-ocr-test-run-forces-json-format ()
  "ARGS 里的 `:format' 被忽略，argv 恒为 `--format json'。
理由：结果 buffer 必须按页解析结构化输出；渲染风格是**另一件事**
（`eimg-ocr-report-style'），它绝不能反过来改变请求格式。"
  (eimg-ocr-test--reset)
  (let ((argv (eimg-ocr-test--capture-argv
               '(:format "text" :file "/tmp/eimg-a.png"))))
    (should (equal "json" (eimg-ocr-test--arg-value argv "--format")))
    (should-not (member "text" argv))))

(ert-deftest eimg-ocr-test-run-records-merged-config ()
  "`eimg-ocr--last-meta' 的 `:config' 记的是**合并后**的完整配置。
重跑（`g'）要复现这次的结果，因此配置必须含默认值；只存调用方原始入参的话，
用户改一次 defcustom 再按 `g'，得到的就是另一次识别。"
  (eimg-ocr-test--reset)
  (eimg-ocr-test--with-stub stub (eimg-ocr-test--json-command)
    (let ((eimg-ocr-cli-path stub))
      (with-temp-buffer
        (eimg-ocr--run '(:file "a.png"))
        (should (eimg-ocr-test--wait
                 (lambda () (plist-get eimg-ocr--last-meta :config))))
        (let ((config (plist-get eimg-ocr--last-meta :config)))
          (should (equal "auto" (plist-get config :backend)))
          (should (equal "chi_sim+eng" (plist-get config :lang)))
          (should (equal 200 (plist-get config :dpi)))
          (should (equal "json" (plist-get config :format)))
          (should (equal "a.png" (plist-get config :file))))))))

(ert-deftest eimg-ocr-test-report-style-text-uses-render-text ()
  "`eimg-ocr-report-style' = `text' 时结果 buffer 用 `eimg-core-render-text'：
**不含** `** 第 N 页'，页间用换页符，头行换成 `;; eimg-ocr: ' 前缀。
两种风格都请求 JSON，区别只在渲染阶段——所以这条与上一条 `:format' 断言并存不矛盾。"
  (eimg-ocr-test--reset)
  (let ((eimg-ocr-report-style 'text))
    (with-current-buffer (eimg-ocr-test--render)
      (let ((text (buffer-string)))
        (should-not (string-match-p "\\*\\* 第 " text))
        (should (string-match-p "第一页第一块" text))
        (should (string-match-p "\f" text))
        (should (string-prefix-p ";; eimg-ocr: " text)))))
  ;; 头行换前缀之后，正文提取仍要剥干净（否则复制 / 存盘会带上元信息）。
  (let ((eimg-ocr-report-style 'text))
    (with-current-buffer (eimg-ocr-test--render)
      (should (equal (concat "第一页第一块\n第一页第二块\n\f"
                             "第二页第一块\n第二页第二块")
                     (eimg-ocr--collect-body))))))

(ert-deftest eimg-ocr-test-report-style-org-is-default ()
  "默认（`org'）风格：结果 buffer 含 `** 第 1 页'，头行是 `# eimg-ocr: ' 前缀。
默认值必须保持 org——老用户复制出来的正文形态不该因为加了开关而变。"
  (eimg-ocr-test--reset)
  (should (eq 'org eimg-ocr-report-style))
  (with-current-buffer (eimg-ocr-test--render)
    (let ((text (buffer-string)))
      (should (string-match-p "\\*\\* 第 1 页" text))
      (should (string-match-p "\\*\\* 第 2 页" text))
      (should-not (string-match-p "\f" text))
      (should (string-prefix-p "# eimg-ocr: " text)))))

(ert-deftest eimg-ocr-test-menu-args-do-not-write-defcustoms ()
  "菜单 infix 的取值（等价于 ARGS）只进 argv，不写回 defcustom。
判据：跑完之后 `(default-value 'eimg-ocr-backend)' 仍是 \"auto\"、
`eimg-ocr-lang' / `eimg-ocr-pdf-dpi' 的默认值原样。
「我只在这个菜单里试了下 tesseract」不该变成「配置文件被改了」。"
  (eimg-ocr-test--reset)
  (let* ((backend-before (default-value 'eimg-ocr-backend))
         (lang-before (default-value 'eimg-ocr-lang))
         (dpi-before (default-value 'eimg-ocr-pdf-dpi))
         (argv (eimg-ocr-test--capture-argv
                '(:backend "tesseract" :lang "eng" :dpi 300
                  :file "/tmp/eimg-a.png"))))
    (should (equal "tesseract" (eimg-ocr-test--arg-value argv "--backend")))
    (should (equal backend-before (default-value 'eimg-ocr-backend)))
    (should (equal "auto" (default-value 'eimg-ocr-backend)))
    (should (equal lang-before (default-value 'eimg-ocr-lang)))
    (should (equal dpi-before (default-value 'eimg-ocr-pdf-dpi)))))

(defun eimg-ocr-test--setq-targets (form)
  "返回 FORM 这棵树里被 `setq' / `setq-default' 赋值的符号列表。
用 S 表达式遍历而不是正则：`(setq a 1 b 2)' 里的第二个目标、跨行赋值、
以及注释掉的赋值，正则都要么漏、要么误判；`read' 出来的树没有这些歧义（它天然
跳过注释与字符串内容）。"
  (cond
   ((not (consp form)) nil)
   ((memq (car form) '(setq setq-default))
    (let ((rest (cdr form))
          targets)
      (while (consp rest)
        (push (car rest) targets)
        (setq rest (cdr rest))
        ;; 取值表达式内部可能还嵌着 setq，一并递归。
        (when (consp rest)
          (setq targets (append (eimg-ocr-test--setq-targets (car rest)) targets)
                rest (cdr rest))))
      targets))
   (t
    (let ((rest form)
          targets)
      ;; 用 `while (consp ...)' 而不是 `dolist'：源码里有 `(:k . "v")' 这样的
      ;; 点对字面量，`dolist' 会顺着 cdr 走到字符串上并 `listp' 报错。
      (while (consp rest)
        (setq targets (append (eimg-ocr-test--setq-targets (car rest)) targets)
              rest (cdr rest)))
      targets))))

(ert-deftest eimg-ocr-test-config-defcustoms-have-no-global-setq ()
  "源码里不存在对这八个 defcustom 的全局 `setq' / `setq-default'。
一旦有人用 `setq' 把它们钉死，用户的 Customize 设置会被静默覆盖（且谁赢取决于
加载时机），而代码里看不出任何异常——这类回归只能在文本层锁住。
注释里出现这些名字是允许的（`read' 会跳过注释），故不受影响。"
  (let* ((root (file-name-directory (file-truename (locate-library "eimg"))))
         (files (directory-files root t "\\`eimg.*\\.el\\'"))
         (names '(eimg-ocr-backend eimg-ocr-lang eimg-ocr-pdf-dpi
                  eimg-ocr-python eimg-ocr-tessdata-dir eimg-ocr-report-style
                  eimg-ocr-ollama-model eimg-ocr-ollama-url)))
    (should files)
    (dolist (file files)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (let (targets)
          (condition-case nil
              (while t
                (setq targets
                      (append (eimg-ocr-test--setq-targets (read (current-buffer)))
                              targets)))
            (end-of-file nil))
          (dolist (name names)
            (should-not (memq name targets))))))))

;;;; ── 10. 坐标数据：页图目录 / 结果结构 / 联动视图入口 ────────────────────

;; 这一节锁的是「联动视图能不能拿到图」这条链路上的每一环：CLI 收到
;; `--page-images-dir' 才在每页多写一个 `image'（联动视图据此定位原图），而那个
;; 目录是**临时**资源，生命周期按「交接」走——成功时交给结果 buffer（kill 该 buffer
;; 时删、rerun 覆盖旧结果时删旧的），失败 / 取消 / 解析失败当场删。
;;
;; 两条硬约束沿用本文件的既有做法：
;;   1. **绝不起真实 CLI**（十几秒一次，且会把 `make test' 拖成分钟级）：
;;      `eimg-ocr--start' 一律 `cl-letf' 打桩，回调在用例里手动触发。
;;   2. **不依赖图像渲染**：本节一个字都不碰 `create-image' / `image-size'，
;;      故能在 `emacs -Q --batch' 下跑。

(defun eimg-ocr-test--fake-pages (dir)
  "构造两页假 pages，每页带 `image' 字段指向 DIR 下的页图路径。
结构与 `eimg-core-parse-json' 的输出一致（第二页刻意只有一块、无 `box'）。"
  (list (list (cons 'page 1)
              (cons 'source "p1.png")
              (cons 'image (expand-file-name "page-1.png" dir))
              (cons 'blocks (list (list (cons 'text "第一页")
                                        (cons 'conf 0.97)
                                        (cons 'box (list 10 20 30 40))))))
        (list (cons 'page 2)
              (cons 'source "p2.png")
              (cons 'image (expand-file-name "page-2.png" dir))
              (cons 'blocks (list (list (cons 'text "第二页")))))))

(defun eimg-ocr-test--pages-dirs ()
  "返回当前 `temporary-file-directory' 下的 `eimg-ocr-pages-*' 目录列表。"
  (directory-files temporary-file-directory t "\\`eimg-ocr-pages-" t))

(defun eimg-ocr-test--temp-root ()
  "返回 `temporary-file-directory' 的真实路径（带末尾分隔符）。
`eimg-ocr--delete-pages-dir' 的守卫就是这个前缀，断言里要用同一口径比较。"
  (file-truename (file-name-as-directory temporary-file-directory)))

(defun eimg-ocr-test--run-and-finish (args status stdout stderr &optional code)
  "调 `eimg-ocr--run'（`eimg-ocr--start' 打桩），返回它建的页图目录。
打桩只捕获 argv 与回调；`eimg-ocr--run' 返回后按 STATUS 手动触发回调，模拟进程
收尾（不跑真实 CLI）。来源 buffer 用临时 buffer：回调执行前它的生命周期已结束，
`eimg-ocr--show-result' 于是退化到当前 buffer，两条路径都不炸。
回调刻意留在同一个 `cl-letf' 里触发：失败 / 取消路径以 `message' 收尾，
别把批量输出刷满（不影响断言，但让 `make test' 的输出可读）。"
  (let (captured callback)
    (cl-letf (((symbol-function 'eimg-ocr--start)
               (lambda (argv cb) (setq captured argv callback cb) 'eimg-ocr-test-proc))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (with-temp-buffer
        (eimg-ocr--run args))
      (when callback
        (funcall callback status stdout stderr code)))
    (eimg-ocr-test--arg-value captured "--page-images-dir")))

(ert-deftest eimg-ocr-test-pdf-input-p ()
  "`eimg-ocr--pdf-input-p' 只看扩展名、大小写不敏感，且 `:file' / `:files' 都算。
这一条决定「这次要不要让 CLI 落页图」，判错的两个方向都有代价：漏判 → 联动视图
永远没有页图；误判 → 单图输入也被塞进一个临时目录。"
  ;; :file 是 PDF
  (should (eq t (eimg-ocr--pdf-input-p (list :file "/x/a.pdf"))))
  ;; :files 列表里混着大写扩展名
  (should (eq t (eimg-ocr--pdf-input-p (list :files '("a.png" "b.PDF")))))
  ;; :file 与 :files 同时给，命中其中一个即可
  (should (eq t (eimg-ocr--pdf-input-p (list :file "/x/a.png" :files '("b.pdf")))))
  ;; :files 传单个字符串也要能命中（`eimg-core--as-list' 归一化的边角）
  (should (eq t (eimg-ocr--pdf-input-p (list :files "x.Pdf"))))
  ;; 非 PDF
  (should-not (eimg-ocr--pdf-input-p (list :file "/x/a.png")))
  ;; 无扩展名
  (should-not (eimg-ocr--pdf-input-p (list :file "/x/README")))
  ;; config 为 nil / 空 plist：不能因为「取不到输入」就 signal
  (should-not (eimg-ocr--pdf-input-p nil))
  (should-not (eimg-ocr--pdf-input-p '())))

(ert-deftest eimg-ocr-test-show-result-stores-structure ()
  "`eimg-ocr--show-result' 把原始结构存进 buffer-local 的 `eimg-ocr--result-data'。
渲染后的文本已经丢掉 `box' / 页图路径，联动视图只能吃这份原始 pages——存漏了它
就只剩「能看不能点」的文本。同时锁住 kill-hook 是 **buffer-local** 的：装成全局
钩子会让关掉任何 buffer 都去删这批页图。"
  (eimg-ocr-test--reset)
  (let* ((dir (eimg-ocr--make-pages-dir))
         (pages (eimg-ocr-test--fake-pages dir))
         (meta (list :backend "rapidocr" :source "/x/a.pdf"
                     :pages-dir dir :elapsed 1.5))
         (buffer (eimg-ocr--show-result pages nil meta)))
    (unwind-protect
        (let ((data (buffer-local-value 'eimg-ocr--result-data buffer)))
          (should (file-directory-p dir))
          (should (equal pages (plist-get data :pages)))
          (should (equal meta (plist-get data :meta)))
          ;; `:pages-dir' 藏在第二层，取值走专用函数（写错层级会静默返回 nil）
          (with-current-buffer buffer
            (should (equal dir (eimg-ocr--result-pages-dir))))
          ;; kill-hook 装上且只在本地
          (should (memq #'eimg-ocr--result-buffer-cleanup
                        (buffer-local-value 'kill-buffer-hook buffer)))
          (should-not (memq #'eimg-ocr--result-buffer-cleanup kill-buffer-hook)))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when (file-exists-p dir) (ignore-errors (delete-directory dir t))))))

(ert-deftest eimg-ocr-test-show-result-rerun-deletes-stale-pages-dir ()
  "rerun 渲进同一个 buffer：旧 `:pages-dir' 被删、新目录仍在。
PDF 页图从几 MB 到几十 MB，每重跑一次漏一个目录；而 `eimg-ocr--result-data' 一被
覆盖，旧路径就再没人记得。最后一条断言是反面：同一个目录重复渲染（换风格重渲）时
不得先删掉自己马上要用的图。"
  (eimg-ocr-test--reset)
  (let ((dir-a (eimg-ocr--make-pages-dir))
        (dir-b nil)
        (buffer nil))
    (unwind-protect
        (progn
          (should (file-directory-p dir-a))
          (setq buffer
                (eimg-ocr--show-result
                 (eimg-ocr-test--fake-pages dir-a) nil
                 (list :backend "rapidocr" :source "/x/a.pdf" :pages-dir dir-a)))
          (setq dir-b (eimg-ocr--make-pages-dir))
          (let ((again
                 (eimg-ocr--show-result
                  (eimg-ocr-test--fake-pages dir-b) nil
                  (list :backend "tesseract" :source "/x/b.pdf" :pages-dir dir-b))))
            ;; 同一个 buffer（`eimg-ocr-buffer-name' 是固定名单例）
            (should (eq buffer again))
            (should (file-directory-p dir-b))
            (should-not (file-exists-p dir-a))
            (with-current-buffer again
              (should (equal (eimg-ocr-test--fake-pages dir-b)
                             (plist-get eimg-ocr--result-data :pages))))
            ;; 同目录重渲：不能删掉自己马上要用的页图
            (eimg-ocr--show-result
             (eimg-ocr-test--fake-pages dir-b) nil
             (list :backend "tesseract" :source "/x/b.pdf" :pages-dir dir-b))
            (should (file-directory-p dir-b))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (dolist (dir (list dir-a dir-b))
        (when (and dir (file-exists-p dir)) (ignore-errors (delete-directory dir t)))))))

(ert-deftest eimg-ocr-test-kill-buffer-deletes-pages-dir ()
  "kill 结果 buffer → 页图目录随之删除；清理函数幂等（重复调用不 signal）。
`kill-buffer-hook' 上一旦 signal，「关个 buffer」就变成用户可见的报错，还会打断
后续钩子——所以幂等是硬要求，不是洁癖。"
  (eimg-ocr-test--reset)
  (let* ((dir (eimg-ocr--make-pages-dir))
         (buffer
          (eimg-ocr--show-result
           (eimg-ocr-test--fake-pages dir) nil
           (list :backend "rapidocr" :source "/x/a.pdf" :pages-dir dir))))
    (should (file-directory-p dir))
    (kill-buffer buffer)
    (should-not (file-exists-p dir))
    (should-not (buffer-live-p buffer))
    ;; 幂等：目录已不在、`eimg-ocr--result-data' 已被抹掉，再调两次仍安静返回。
    (with-temp-buffer
      (setq-local eimg-ocr--result-data
                  (list :pages nil :meta (list :pages-dir dir)))
      (eimg-ocr--result-buffer-cleanup)
      (should-not eimg-ocr--result-data)
      (setq-local eimg-ocr--result-data nil)
      (eimg-ocr--result-buffer-cleanup)
      (should-not eimg-ocr--result-data))))

(ert-deftest eimg-ocr-test-delete-pages-dir-guards ()
  "`eimg-ocr--delete-pages-dir' 的三重守卫：只删 `temporary-file-directory' 之下。
DIR 的出处是 plist，任何一段 elisp 都能往里面塞任意路径；「收到什么就删什么」会把
一次三元组的拼写错误变成删用户目录。这里用仓库里的真目录（`test/fixtures'）当
「不该删」的样本。"
  (let* ((root (file-name-directory (file-truename (locate-library "eimg"))))
         (repo-dir (expand-file-name "test/fixtures" root))
         (tmp (eimg-ocr--make-pages-dir)))
    ;; 前置事实：样本确实在临时根之外（否则下面的断言毫无意义，且真删了就危险）
    (should (file-directory-p repo-dir))
    (should-not (string-prefix-p (eimg-ocr-test--temp-root)
                                 (file-truename (file-name-as-directory repo-dir))))
    ;; 1. 不在临时根之下 → 拒绝删除
    (eimg-ocr--delete-pages-dir repo-dir)
    (should (file-directory-p repo-dir))
    ;; 2. nil / 非字符串 / 空串 / 不存在的路径 → 静默返回
    (should-not (eimg-ocr--delete-pages-dir nil))
    (should-not (eimg-ocr--delete-pages-dir 42))
    (should-not (eimg-ocr--delete-pages-dir ""))
    (should-not (eimg-ocr--delete-pages-dir
                 (expand-file-name "eimg-ocr-pages-does-not-exist"
                                   temporary-file-directory)))
    ;; 3. 自己建的临时目录 → 正常删除
    (should (stringp tmp))
    (should (file-directory-p tmp))
    (should (string-prefix-p (eimg-ocr-test--temp-root)
                             (file-truename (file-name-as-directory tmp))))
    (eimg-ocr--delete-pages-dir tmp)
    (should-not (file-exists-p tmp))))

(ert-deftest eimg-ocr-test-mode-map-view-key ()
  "结果 buffer 的 `v' 绑到 `eimg-ocr-view'，既有六个键位一个不变。
`v' 是联动视图的唯一入口：绑错符号（或绑成未定义的别名）会比缺键更糟——按下去
要么静默无反应，要么报一个和用途无关的错。"
  (should (eq 'eimg-ocr-view (keymap-lookup eimg-ocr-mode-map "v")))
  (dolist (entry '(("y" . eimg-ocr-copy)
                   ("i" . eimg-ocr-insert)
                   ("w" . eimg-ocr-write-file)
                   ("g" . eimg-ocr-rerun)
                   ("q" . quit-window)
                   ("k" . eimg-ocr-cancel)))
    ;; 逐条断言而不是比对整张表：失败信息直接指出是哪个键被改了。
    (should (eq (cdr entry) (keymap-lookup eimg-ocr-mode-map (car entry))))))

(ert-deftest eimg-ocr-test-run-injects-page-images-dir-for-pdf ()
  "PDF 输入且调用方没给 `:page-images-dir' 时，argv 里带上本层自己建的临时目录。
这条是「页图真的会被栅格化」的唯一保证：argv 里少了这个选项，json 里就没有
`image' 字段，联动视图退化成没有图可画的一列文本。"
  (eimg-ocr-test--reset)
  (let (captured)
    (cl-letf (((symbol-function 'eimg-ocr--start)
               (lambda (argv _cb) (setq captured argv) 'eimg-ocr-test-proc)))
      (with-temp-buffer
        (eimg-ocr--run (list :file "/x/a.pdf"))))
    (let ((dir (eimg-ocr-test--arg-value captured "--page-images-dir")))
      (unwind-protect
          (progn
            (should (stringp dir))
            (should (file-directory-p dir))
            ;; 建出来的必须是临时目录（否则守卫会拒绝删除 → 每跑一次漏一批页图）
            (should (string-prefix-p (eimg-ocr-test--temp-root)
                                     (file-truename
                                      (file-name-as-directory dir))))
            (should (equal "/x/a.pdf" (car (last captured)))))
        (when (and dir (file-exists-p dir))
          (ignore-errors (delete-directory dir t)))))))

(ert-deftest eimg-ocr-test-run-no-pages-dir-for-image-or-explicit ()
  "非 PDF 输入、或调用方显式给了 `:page-images-dir' 时，本层完全不接管。
显式给的意思就是「目录归我管」：替他删等于删用户自己的页图，替他建则会让他的
输出落到两个地方。"
  (eimg-ocr-test--reset)
  ;; 1. 单图输入：不注入，也不建目录
  (let (captured
        (before (length (eimg-ocr-test--pages-dirs))))
    (cl-letf (((symbol-function 'eimg-ocr--start)
               (lambda (argv _cb) (setq captured argv) 'eimg-ocr-test-proc)))
      (with-temp-buffer
        (eimg-ocr--run (list :file "/x/a.png"))))
    (should-not (member "--page-images-dir" captured))
    (should (= before (length (eimg-ocr-test--pages-dirs)))))
  ;; 2. PDF + 用户自带目录：argv 用用户的路径，不另建临时目录
  (let ((user-dir (make-temp-file "eimg-user-pages-" t))
        captured
        (before (length (eimg-ocr-test--pages-dirs))))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'eimg-ocr--start)
                     (lambda (argv _cb) (setq captured argv) 'eimg-ocr-test-proc)))
            (with-temp-buffer
              (eimg-ocr--run (list :file "/x/a.pdf" :page-images-dir user-dir))))
          (should (equal user-dir
                         (eimg-ocr-test--arg-value captured "--page-images-dir")))
          (should (= before (length (eimg-ocr-test--pages-dirs)))))
      (when (file-directory-p user-dir)
        (ignore-errors (delete-directory user-dir t))))))

(ert-deftest eimg-ocr-test-run-deletes-pages-dir-when-start-signals ()
  "`eimg-ocr--start' **同步**抛错（CLI 没装 / 已有任务在跑）时，刚建的页图目录当场删。
为什么这条必须锁：那时异步回调永远不会执行，四条收尾路径一条都到不了；页图动辄
几十 MB，一次误按就是一份纯泄漏。错误本身还要原样向上传播——`--start' 的同步错误
是给用户看的提示，吞掉只会让「按了没反应」。"
  (eimg-ocr-test--reset)
  (let ((before (length (eimg-ocr-test--pages-dirs)))
        (err nil))
    (cl-letf (((symbol-function 'eimg-ocr--start)
               (lambda (&rest _)
                 (user-error "找不到可执行的 bin/eimg-ocr")))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (with-temp-buffer
        (setq err (should-error (eimg-ocr--run (list :file "/x/a.pdf"))
                                :type 'user-error))))
    ;; 错误照旧往上抛，文案还是 `--start' 那条
    (should (string-match-p "bin/eimg-ocr" (error-message-string err)))
    ;; 目录回到调用前的数量：建出来的那个已经被删掉了
    (should (= before (length (eimg-ocr-test--pages-dirs))))))

(ert-deftest eimg-ocr-test-run-deletes-pages-dir-on-failure-paths ()
  "失败 / 取消 / 解析失败三条路径上目录**当场**删；成功则交给结果 buffer。
判据是三条路上没有任何 buffer 接手这批页图（结果 buffer 只在 finished 分支写），
不删就是纯泄漏；而 finished 分支必须留着——它刚把路径交给 buffer，后面联动视图
要靠它读图。"
  (eimg-ocr-test--reset)
  ;; failed：后端不可用（退出码 2）
  (let ((dir (eimg-ocr-test--run-and-finish
              (list :file "/x/a.pdf") 'failed "" "boom" 2)))
    (should (stringp dir))
    (should-not (file-exists-p dir)))
  ;; cancelled：用户按停
  (let ((dir (eimg-ocr-test--run-and-finish
              (list :file "/x/a.pdf") 'cancelled "" "" nil)))
    (should (stringp dir))
    (should-not (file-exists-p dir)))
  ;; parse-error：输出无法解析
  (let ((dir (eimg-ocr-test--run-and-finish
              (list :file "/x/a.pdf") 'finished "不是 JSON" "" 0)))
    (should (stringp dir))
    (should-not (file-exists-p dir)))
  ;; finished：结果 buffer 接手 → 目录保留，kill buffer 时才删
  (let ((dir (eimg-ocr-test--run-and-finish
              (list :file "/x/a.pdf") 'finished
              "{\"pages\": [{\"page\": 1, \"blocks\": [{\"text\": \"t\"}]}]}" "" 0)))
    (unwind-protect
        (progn
          (should (stringp dir))
          (should (file-directory-p dir))
          (let ((buffer (get-buffer eimg-ocr-buffer-name)))
            (should (buffer-live-p buffer))
            (with-current-buffer buffer
              (should (equal dir (eimg-ocr--result-pages-dir))))
            (kill-buffer buffer)
            (should-not (file-exists-p dir))))
      (when (and dir (file-exists-p dir))
        (ignore-errors (delete-directory dir t))))))

(ert-deftest eimg-ocr-test-run-rerun-keeps-page-images-dir ()
  "rerun 复用上一轮配置（其中带 `:page-images-dir'）时，页图目录必须保留。
**这是 T10 的行为变更**：META 的 `:pages-dir' 记的是**实际生效目录**（effective），
不是「本层是否拥有该目录」（owned）。`g'（`eimg-ocr-rerun'）复用的是上一轮合并后
的配置，本轮不新建目录（`owned' 为 nil），但 CLI 这次仍把页图写进上一轮那个目录；
若 meta 按 owned 记成 nil，`eimg-ocr--show-result' 会把「旧 `:pages-dir' = D」与
「新 `:pages-dir' = nil」判为不同，删掉 D——重跑一次页图全失效，联动视图退化成
「找不到页图」的一列文本。

用例走两遍 `eimg-ocr--run'（`eimg-ocr--start' 打桩，不跑真实 CLI）：第一遍模拟
首次识别（PDF、无显式目录 → 本层自建 D），第二遍拿 `eimg-ocr--last-meta' 的
`:config' 模拟 `g'，并断言本次生效目录仍是 D。"
  (eimg-ocr-test--reset)
  (let* ((json-for
          ;; 单页、带 `image' 绝对路径：联动视图要靠它定位原图。
          (lambda (dir)
            (format (concat "{\"pages\":[{\"page\":1,\"image\":%S,"
                            "\"blocks\":[{\"text\":\"第一页\"}]}]}")
                    (expand-file-name "page-1.png" dir))))
         (run-once
          (lambda (args)
            ;; 打桩只捕获 argv 与回调；返回本次 argv 里生效的页图目录。
            (let (captured callback)
              (cl-letf (((symbol-function 'eimg-ocr--start)
                         (lambda (argv cb)
                           (setq captured argv callback cb)
                           'eimg-ocr-test-proc)))
                (with-temp-buffer
                  (eimg-ocr--run args)))
              (let ((dir (eimg-ocr-test--arg-value captured "--page-images-dir")))
                ;; 模拟 CLI 在**进程运行期间**把页图写进 DIR：必须发生在回调之前，
                ;; 与真实时序一致（CLI 边跑边写，sentinel 收尾时才可能删目录）。
                (when (stringp dir)
                  (with-temp-file (expand-file-name "page-1.png" dir)
                    (insert "PNG")))
                ;; 回调在 `cl-letf' 外触发，模拟进程收尾（含渲染进结果 buffer）。
                (funcall callback 'finished (funcall json-for dir) "" 0)
                dir))))
         (dir-a nil)
         (dir-b nil))
    (unwind-protect
        (progn
          ;; ① 首次识别：本层自建临时目录并注入 `--page-images-dir'
          (setq dir-a (funcall run-once (list :file "/x/a.pdf")))
          (should (stringp dir-a))
          (should (file-directory-p dir-a))
          ;; ② 模拟 `g'：复用上一轮合并后的配置（`eimg-ocr-rerun' 就是这么做的）
          (let ((rerun-config (plist-get eimg-ocr--last-meta :config)))
            (should (equal dir-a (plist-get rerun-config :page-images-dir)))
            (setq dir-b (funcall run-once rerun-config))
            ;; 不另建新目录：本次生效目录仍是上一轮那个
            (should (equal dir-a dir-b)))
          ;; 核心断言：目录与页图都还在（修复前 D 已被 show-result 删掉）
          (should (file-directory-p dir-a))
          (should (file-exists-p (expand-file-name "page-1.png" dir-a)))
          (let ((buffer (get-buffer eimg-ocr-buffer-name)))
            (should (buffer-live-p buffer))
            (with-current-buffer buffer
              ;; meta 记的是实际生效目录，不是所有权
              (should (equal dir-a (eimg-ocr--result-pages-dir)))
              ;; 每页 `image' 指向的文件可读——联动视图有图可画
              (dolist (page (plist-get eimg-ocr--result-data :pages))
                (should (file-readable-p (alist-get 'image page)))))))
      (when (get-buffer eimg-ocr-buffer-name)
        (ignore-errors (kill-buffer (get-buffer eimg-ocr-buffer-name))))
      (dolist (dir (list dir-a dir-b))
        (when (and dir (file-exists-p dir))
          (ignore-errors (delete-directory dir t)))))))

(ert-deftest eimg-ocr-test-run-explicit-pages-dir-not-deleted-on-failure ()
  "调用方显式给的 `:page-images-dir' 在本层失败路径上**不得**被删。
「配置里有这个路径」不等于「这个路径归本层处置」：只有本层 `make-temp-file' 建的
目录（owned）才由本层清理。failed / cancelled 两条路过去按 `pages-dir'（即
`(or owned explicit)'）删，会把用户自己指的目录一起带走；rerun 场景下更会删掉
上一轮正在使用的页图。"
  (eimg-ocr-test--reset)
  (let ((user-dir (make-temp-file "eimg-user-pages-" t))
        (fake-page nil))
    (setq fake-page (expand-file-name "page-1.png" user-dir))
    (with-temp-file fake-page (insert "PNG"))
    (unwind-protect
        (dolist (status '(failed cancelled))
          (let (callback)
            (cl-letf (((symbol-function 'eimg-ocr--start)
                       (lambda (_argv cb)
                         (setq callback cb)
                         'eimg-ocr-test-proc))
                      ;; 失败 / 取消分支以 `message' 收尾，压掉批量输出噪声。
                      ((symbol-function 'message) (lambda (&rest _) nil)))
              (with-temp-buffer
                (eimg-ocr--run (list :file "/x/a.pdf"
                                     :page-images-dir user-dir))))
            (funcall callback status "" "boom" 2)
            ;; owned 为 nil → 无目录可删，用户目录与页图必须原样还在
            (should (file-directory-p user-dir))
            (should (file-exists-p fake-page))))
      (when (file-directory-p user-dir)
        (ignore-errors (delete-directory user-dir t))))))

(provide 'eimg-ocr-test)

;;; eimg-ocr-test.el ends here
