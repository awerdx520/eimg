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
  (setq eimg-ocr--process nil
        eimg-ocr--started-at nil
        eimg-ocr--timeout-timer nil
        eimg-ocr--progress nil
        eimg-ocr--last-args nil
        eimg-ocr--last-origin nil
        eimg-ocr--last-meta nil
        eimg-ocr--last-summary nil))

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
    (should-not (string-match-p (concat "accept-process" "-output") source))))

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

(provide 'eimg-ocr-test)

;;; eimg-ocr-test.el ends here
