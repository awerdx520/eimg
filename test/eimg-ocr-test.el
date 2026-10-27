;;; eimg-ocr-test.el --- eimg-ocr 的 ERT 用例  -*- lexical-binding: t; -*-

;; Author: thomas
;; Version: 0.1.0
;; Keywords: convenience, tools, ocr

;;; Commentary:

;; 覆盖进程层的四态收尾（finished / failed / cancelled / 超时）、状态清理、
;; CLI 路径推导（`-L .' 与 build 目录软链两种加载方式）与进度文本。
;;
;; 三条硬约束：
;;   1. **绝不调用真实 `bin/eimg-ocr'**：它依赖 rapidocr / tesseract 与 Python
;;      环境，在不具备这些依赖的机器上会让 `make test' 变红。所有用例都用
;;      `make-temp-file' 现写一个 shell stub，再用 `eimg-ocr-cli-path' 注入。
;;   2. **绝不死等**：纯异步收尾靠 `eimg-ocr-test--wait' 轮询（上限 10 秒），
;;      到点返回 nil，让 `should' 打出可读的失败信息。
;;   3. 每个用例先 `eimg-ocr-test--reset'：模块状态是全局单槽，上一个用例残留
;;      的活动进程 / 定时器会让下一个用例假绿。

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
  "清掉上一个用例可能残留的进程、定时器与进度。"
  (when (eimg-ocr-busy-p)
    (ignore-errors (delete-process eimg-ocr--process)))
  (when (timerp eimg-ocr--timeout-timer)
    (ignore-errors (cancel-timer eimg-ocr--timeout-timer)))
  (setq eimg-ocr--process nil
        eimg-ocr--started-at nil
        eimg-ocr--timeout-timer nil
        eimg-ocr--progress nil))

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

(provide 'eimg-ocr-test)

;;; eimg-ocr-test.el ends here
