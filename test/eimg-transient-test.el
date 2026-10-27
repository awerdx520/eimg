;;; eimg-transient-test.el --- eimg-transient 的 ERT 用例  -*- lexical-binding: t; -*-

;; Author: thomas
;; Version: 0.1.0
;; Keywords: convenience, tools, ocr

;;; Commentary:

;; 覆盖 `eimg-menu' 的结构（三组十项 + 三 infix）、infix 取值到配置 plist 的解析、
;; 「菜单取值经包装命令落到 argv」的完整链路、四个软依赖桥接命令的缺失路径，以及
;; 安装指引「只展示不执行」这条硬约束。
;;
;; 四条硬约束：
;;   1. **绝不运行真实 `bin/eimg-ocr'**：所有会起进程的路径都用 `cl-letf' 把
;;      `eimg-ocr--start' 换成记录参数的空实现。
;;   2. **不依赖 GUI**：`eimg-ocr-region' 有 `display-graphic-p' 守卫，本文件只测
;;      「包装是否把 ARGS 传下去」，用 `cl-letf' 替换 `eimg-ocr-region' 本体。
;;   3. **不改用户的 defcustom**：`eimg-ocr-images-dir' 等一律用 `let' 动态绑定，
;;      用例结束自动还原。
;;   4. **`(require 'eimg)' 不加载 transient** 必须用**子进程**验证：本文件自身
;;      `(require 'eimg-transient)'，在当前进程里 `(featurep 'transient)' 恒为 t，
;;      进程内断言等于自欺。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'eimg)
(require 'eimg-transient)

;;;; ── 测试辅助 ──────────────────────────────────────────────────────────

(defun eimg-transient-test--root ()
  "返回 eimg 仓库根目录（`eimg.el' 所在目录）。"
  (file-name-directory (file-truename (locate-library "eimg"))))

(defun eimg-transient-test--suffixes ()
  "返回 `eimg-menu' 的全部 suffix 对象（含 infix 与 transient 自带命令）。
用 `transient-suffixes'（公共函数，明确说明「不会显示菜单」）取，而不是自己解析
`transient--layout' 的内部结构：后者是容器/叶子两种形态混排的私有表示，今天能猜对、
升级后不一定还能。判据是每个对象的 `key' / `command' / `argument' 槽。"
  (transient-suffixes 'eimg-menu))

(defun eimg-transient-test--suffix (key)
  "按 KEY 在 `eimg-menu' 里找 suffix 对象；找不到返回 nil。"
  (seq-find (lambda (object) (equal key (oref object key)))
            (eimg-transient-test--suffixes)))

(defmacro eimg-transient-test--without-functions (symbols &rest body)
  "在 BODY 执行期间把 SYMBOLS 视为未定义（其余符号不受影响）。"
  (declare (indent 1))
  `(let ((original (symbol-function 'fboundp)))
     (cl-letf (((symbol-function 'fboundp)
                (lambda (symbol)
                  (unless (memq symbol ,symbols) (funcall original symbol)))))
       ,@body)))

(defun eimg-transient-test--variable-state (symbol)
  "返回 SYMBOL 的状态快照：`unbound'，或 `(bound . 默认值)'。
写成这种形态而不是直接 `(default-value SYMBOL)'：变量尚未定义时 `default-value'
会 signal，而「原本没有这个变量」本身就是要保护的现状之一。"
  (if (boundp symbol)
      (cons 'bound (default-value symbol))
    'unbound))

(defmacro eimg-transient-test--with-menu-value (args &rest body)
  "在 BODY 期间让 `(transient-args 'eimg-menu)' 返回 ARGS。
用 transient 的**已保存取值**机制（`transient-values'）注入，而不是替换
`transient-args' 本体：这条路径与「用户在菜单里按下 `-b' 再选 tesseract」之后
suffix 读到的值走同一段代码（`transient-prefix-value' → `transient-suffixes'），
比打桩函数更接近真实。"
  (declare (indent 1))
  `(let ((transient-values (when ,args (list (cons 'eimg-menu ,args)))))
     ,@body))

(defun eimg-transient-test--capture-argv (thunk)
  "调用 THUNK 并返回它交给 `eimg-ocr--start' 的 argv（不起任何进程）。"
  (let (captured)
    (cl-letf (((symbol-function 'eimg-ocr--start)
               (lambda (argv _callback) (setq captured argv) 'eimg-transient-test-proc)))
      (funcall thunk))
    captured))

;;;; ── 1. 菜单结构与加载时序 ──────────────────────────────────────────────

(ert-deftest eimg-transient-test-menu-is-transient-prefix ()
  "`eimg-menu' 既是命令，也是真正的 transient prefix（不是普通 defun）。
判据：`commandp' 为 t，且 `transient--prefix' symbol property 上挂着
`transient-prefix' 类的对象、该对象的 `command' 槽就是 `eimg-menu'。"
  (should (commandp 'eimg-menu))
  (let ((object (get 'eimg-menu 'transient--prefix)))
    (should object)
    (should (eq 'transient-prefix (eieio-object-class-name object)))
    (should (eq 'eimg-menu (oref object command)))))

(ert-deftest eimg-transient-test-require-eimg-does-not-load-transient ()
  "`(require 'eimg)' 之后 `(featurep 'transient)' 仍为 nil（子进程断言）。
菜单是延迟加载的：只有 autoload 触发的 `M-x eimg-menu' 才会加载 transient，
不按菜单的人不该为它付启动成本。"
  (let* ((root (eimg-transient-test--root))
         (emacs (expand-file-name invocation-name invocation-directory))
         (buffer (generate-new-buffer " *eimg-transient-probe*")))
    (unwind-protect
        (progn
          (should (eq 0 (call-process
                         emacs nil buffer nil
                         "-Q" "--batch" "-L" root
                         "--eval"
                         "(progn (require 'eimg) (princ (if (featurep 'transient) \"t\" \"nil\")))")))
          (should (equal "nil"
                         (string-trim
                          (with-current-buffer buffer (buffer-string))))))
      (kill-buffer buffer))))

(ert-deftest eimg-transient-test-menu-keys-resolve ()
  "十项动作键位全部可解析，且指向预期命令。
`o' / `h' / `f' 指向 `eimg-menu-run-*' 薄包装：transient 用 `call-interactively'
调 suffix，不会把 infix 取值当参数传，必须有一层把 `(eimg-ocr--menu-args)' 显式
作为 ARGS 传进 OCR 命令。"
  (let ((expected '(("s" . eimg-ocr-capture-command)
                    ("o" . eimg-menu-run-region)
                    ("h" . eimg-menu-run-history)
                    ("f" . eimg-menu-run-file)
                    ("p" . eimg-ocr-insert-path)
                    ("b" . eimg-ocr-insert-display)
                    ("?" . eimg-ocr-list-backends)
                    ("r" . eimg-ocr-show-result-buffer)
                    ("d" . eimg-ocr-open-directory)
                    ("S" . eimg-ocr-setup-help))))
    (should (= 10 (length expected)))
    (dolist (entry expected)
      (let ((object (eimg-transient-test--suffix (car entry))))
        (should object)
        (should (eq (cdr entry) (oref object command)))
        ;; 动作项必须是命令，否则 `call-interactively' 会在按键时才炸。
        (should (commandp (oref object command)))))))

(ert-deftest eimg-transient-test-infix-arguments ()
  "三个 infix 存在（`-b' / `-l' / `-D'），且后端候选里含 tesseract。
判据：suffix 对象是 `transient-option'，`argument' 槽为 `--backend='（argv 形态
`--backend=X'，与 `bin/eimg-ocr' 的选项语法同构），`choices' 含 tesseract。"
  (dolist (entry '(("-b" . eimg-menu--backend)
                   ("-l" . eimg-menu--lang)
                   ("-D" . eimg-menu--dpi)))
    (let ((object (eimg-transient-test--suffix (car entry))))
      (should object)
      (should (eq (cdr entry) (oref object command)))
      (should (eq 'transient-option (eieio-object-class-name object)))))
  (dolist (entry '(("-b" . "--backend=")
                   ("-l" . "--lang=")
                   ("-D" . "--dpi=")))
    (should (equal (cdr entry) (oref (eimg-transient-test--suffix (car entry)) argument))))
  (should (member "tesseract"
                  (oref (eimg-transient-test--suffix "-b") choices)))
  (should (member "chi_sim+eng"
                  (oref (eimg-transient-test--suffix "-l") choices))))

;;;; ── 2. infix 取值 → 配置 plist → argv ─────────────────────────────────

(ert-deftest eimg-transient-test-menu-args-nil-when-unset ()
  "菜单里没动任何 infix 时 `eimg-ocr--menu-args' 返回 nil（而不是空 plist）。
nil 与 `()' 对 `plist-get' 等价，但对「用户有没有表达意图」不等价。"
  ;; 直接打桩取值列表，确认「无参数 → nil」不依赖 transient 的当前状态。
  (cl-letf (((symbol-function 'transient-args) (lambda (_prefix) nil)))
    (should-not (eimg-ocr--menu-args)))
  ;; 绑定 `transient-values' 为 nil 也同样返回 nil（真实 transient 读取路径）。
  (eimg-transient-test--with-menu-value nil
    (should-not (eimg-ocr--menu-args))))

(ert-deftest eimg-transient-test-menu-args-parse ()
  "三个 infix 取值解析成 `(:backend … :lang … :dpi …)'，DPI 转成整数。"
  (cl-letf (((symbol-function 'transient-args)
             (lambda (_prefix) '("--backend=tesseract" "--lang=eng" "--dpi=300"))))
    (should (equal '(:backend "tesseract" :lang "eng" :dpi 300)
                   (eimg-ocr--menu-args))))
  ;; 只设一项时其余不出现（不要把「未设置」写成 nil 值塞进 plist）。
  (cl-letf (((symbol-function 'transient-args)
             (lambda (_prefix) '("--lang=chi_sim+eng"))))
    (should (equal '(:lang "chi_sim+eng") (eimg-ocr--menu-args)))))

(ert-deftest eimg-transient-test-menu-args-drive-argv ()
  "菜单里设 `-b tesseract' 后，经包装命令拼出的 CLI argv 含 `--backend tesseract'。
链路：`transient-values'（已保存取值）→ `transient-args' → `eimg-ocr--menu-args'
→ `eimg-ocr-file' 的 ARGS 合并 → `eimg-core-build-args' → `eimg-ocr--start'。
进程层用 `cl-letf' 换成记录参数的空实现，绝不起真实 CLI。"
  (let* ((file (make-temp-file "eimg-transient-test-" nil ".png"))
         argv)
    (unwind-protect
        (progn
          (with-temp-file file (insert "not a real image"))
          (setq argv
                (eimg-transient-test--with-menu-value '("--backend=tesseract")
                  (let ((eimg-ocr-images-dir nil))
                    (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) file)))
                      (eimg-transient-test--capture-argv #'eimg-menu-run-file)))))
          (should argv)
          (should (member "--backend" argv))
          (should (equal "tesseract" (cadr (member "--backend" argv))))
          ;; infix 的其它项未设置时不得凭空出现（未设置 ≠ 空值）。
          (should-not (member "--lang" argv))
          (should-not (member "--dpi" argv)))
      (ignore-errors (delete-file file)))))

(ert-deftest eimg-transient-test-menu-does-not-change-defcustoms ()
  "菜单取值不改任何 defcustom：操作前后变量状态逐项相同。
注意：`eimg-ocr-backend' / `eimg-ocr-lang' / `eimg-ocr-pdf-dpi' 在 T5d 时点
**尚未定义**（属后续配置项任务），故本用例保护的是「现在是什么样，操作后就还是
什么样」——未定义就该仍未定义，已定义就该值不变。"
  (let* ((symbols '(eimg-ocr-backend eimg-ocr-lang eimg-ocr-pdf-dpi))
         (before (mapcar #'eimg-transient-test--variable-state symbols))
         (file (make-temp-file "eimg-transient-test-" nil ".png")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "not a real image"))
          (eimg-transient-test--with-menu-value '("--backend=tesseract" "--dpi=200")
            (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) file)))
              (eimg-transient-test--capture-argv #'eimg-menu-run-file)))
          (should (equal before
                         (mapcar #'eimg-transient-test--variable-state symbols))))
      (ignore-errors (delete-file file)))))

(ert-deftest eimg-transient-test-wrappers-pass-menu-args ()
  "三个包装命令把 `(eimg-ocr--menu-args)' 原样当 ARGS 传给 OCR 命令。"
  (dolist (entry `((eimg-menu-run-region . eimg-ocr-region)
                   (eimg-menu-run-history . eimg-ocr-history)
                   (eimg-menu-run-file . eimg-ocr-file)))
    (let (received)
      (eimg-transient-test--with-menu-value '("--backend=rapidocr")
        (cl-letf (((symbol-function (cdr entry))
                   (lambda (&optional args) (setq received args))))
          (funcall (car entry))))
      (should (equal '(:backend "rapidocr") received)))))

;;;; ── 3. 安装指引：只展示，不执行 ────────────────────────────────────────

(ert-deftest eimg-transient-test-setup-help-runs-no-process ()
  "`eimg-ocr-setup-help' 不启动任何子进程：把所有起进程的入口都打成抛错，
命令仍必须成功返回 buffer。"
  (unwind-protect
      (let ((explode (lambda (&rest _) (error "不允许起进程"))))
        (cl-letf (((symbol-function 'call-process) explode)
                  ((symbol-function 'process-file) explode)
                  ((symbol-function 'make-process) explode)
                  ((symbol-function 'start-process) explode)
                  ((symbol-function 'shell-command) explode))
          (let ((buffer (eimg-ocr-setup-help)))
            (should (buffer-live-p buffer))
            (should (equal eimg-ocr-setup-buffer-name (buffer-name buffer)))
            (with-current-buffer buffer
              (should (> (buffer-size) 0))))))
    (when (get-buffer eimg-ocr-setup-buffer-name)
      (kill-buffer eimg-ocr-setup-buffer-name))))

(ert-deftest eimg-transient-test-setup-help-content ()
  "指引正文含四条命令与「显式」——用户看完必须知道下一步敲什么、为什么菜单不代劳。"
  (unwind-protect
      (let ((buffer (eimg-ocr-setup-help)))
        (with-current-buffer buffer
          (let ((text (buffer-string)))
            (dolist (needle '("--check" "--reuse-pdf-toc-ocr" "--rapidocr" "--tessdata"))
              (should (string-match-p (regexp-quote needle) text)))
            (should (string-match-p "显式" text))
            (should (string-match-p "bin/eimg-ocr-setup" text)))))
    (when (get-buffer eimg-ocr-setup-buffer-name)
      (kill-buffer eimg-ocr-setup-buffer-name))))

;;;; ── 4. 软依赖：缺失时可见、调用时 user-error ──────────────────────────

(ert-deftest eimg-transient-test-insert-path-soft-dependency-missing ()
  "宿主没装 `+thomas/insert-image-path' 时 `eimg-ocr-insert-path' 抛 `user-error'，
文案含「尚未迁移」。"
  (eimg-transient-test--without-functions '(+thomas/insert-image-path)
    (let ((error-data (should-error (eimg-ocr-insert-path) :type 'user-error)))
      (should (string-match-p "尚未迁移" (error-message-string error-data)))
      (should (string-match-p "insert-image-path" (error-message-string error-data))))))

(ert-deftest eimg-transient-test-insert-display-soft-dependency-missing ()
  "同上，`+thomas/insert-image-display' 缺失时同样抛 `user-error'。"
  (eimg-transient-test--without-functions '(+thomas/insert-image-display)
    (let ((error-data (should-error (eimg-ocr-insert-display) :type 'user-error)))
      (should (string-match-p "尚未迁移" (error-message-string error-data)))
      (should (string-match-p "insert-image-display" (error-message-string error-data))))))

(ert-deftest eimg-transient-test-insert-path-delegates ()
  "宿主命令存在时转调它（`call-interactively'），本命令自己不实现插入逻辑。"
  (let (called)
    (unwind-protect
        (progn
          (fset '+thomas/insert-image-path (lambda () (interactive) (setq called t)))
          (eimg-ocr-insert-path)
          (should called))
      (fmakunbound '+thomas/insert-image-path))))

(ert-deftest eimg-transient-test-menu-keeps-items-without-soft-deps ()
  "宿主能力全缺时菜单项仍在 layout 里（可见但调用报错），不被静默隐藏。"
  (eimg-transient-test--without-functions
      '(+thomas/insert-image-path +thomas/insert-image-display eimg-capture +thomas/screenshot)
    (dolist (entry '(("s" . eimg-ocr-capture-command)
                     ("p" . eimg-ocr-insert-path)
                     ("b" . eimg-ocr-insert-display)))
      (let ((object (eimg-transient-test--suffix (car entry))))
        (should object)
        (should (eq (cdr entry) (oref object command)))))))

(ert-deftest eimg-transient-test-capture-command-missing-capture ()
  "一个截图函数都没有时 `eimg-ocr-capture-command' 抛 `user-error'，
文案含「未找到截图函数」。"
  (let ((eimg-ocr-capture-function nil))
    (eimg-transient-test--without-functions '(eimg-capture +thomas/screenshot)
      (let ((error-data (should-error (eimg-ocr-capture-command) :type 'user-error)))
        (should (string-match-p "未找到截图函数" (error-message-string error-data)))))))

;;;; ── 5. 系统组命令 ──────────────────────────────────────────────────────

(ert-deftest eimg-transient-test-show-result-buffer ()
  "没有 `*eimg-ocr*' 时 `user-error'；有时返回该 buffer。"
  (unwind-protect
      (progn
        (when (get-buffer eimg-ocr-buffer-name)
          (kill-buffer eimg-ocr-buffer-name))
        (let ((error-data (should-error (eimg-ocr-show-result-buffer) :type 'user-error)))
          (should (string-match-p "先跑一次识别" (error-message-string error-data))))
        (with-current-buffer (get-buffer-create eimg-ocr-buffer-name)
          (insert "dummy"))
        (should (equal eimg-ocr-buffer-name
                       (buffer-name (eimg-ocr-show-result-buffer)))))
    (when (get-buffer eimg-ocr-buffer-name)
      (kill-buffer eimg-ocr-buffer-name))))

(ert-deftest eimg-transient-test-open-directory ()
  "`eimg-ocr-images-dir' 为 nil / 不存在时 `user-error'；存在时用 Dired 打开它。"
  (let ((eimg-ocr-images-dir nil))
    (should-error (eimg-ocr-open-directory) :type 'user-error))
  (let ((eimg-ocr-images-dir (expand-file-name "eimg-transient-test-missing-dir"
                                                temporary-file-directory)))
    (should-error (eimg-ocr-open-directory) :type 'user-error))
  (let* ((directory (make-temp-file "eimg-transient-test-dir-" t))
         (opened nil))
    (unwind-protect
        (let ((eimg-ocr-images-dir directory))
          (cl-letf (((symbol-function 'dired) (lambda (dir &rest _) (setq opened dir))))
            (eimg-ocr-open-directory))
          (should (equal directory opened)))
      (ignore-errors (delete-directory directory t)))))

;;;; ── 6. 源码锚点：延迟加载链路不能被改掉 ────────────────────────────────

(ert-deftest eimg-transient-test-source-anchors ()
  "锁定延迟加载的两端：`eimg.el' 不 require 本文件、autoload 声明是纯数据形态、
且全文没有对 OCR defcustom 的 `setq'。"
  (let* ((root (eimg-transient-test--root))
         (entry (expand-file-name "eimg.el" root))
         (menu (expand-file-name "eimg-transient.el" root)))
    (with-temp-buffer
      (insert-file-contents entry)
      ;; Commentary 里提到文件名是正常的（地图作用），禁的是真去加载它。
      (should-not (string-match-p "(require 'eimg-transient" (buffer-string))))
    (with-temp-buffer
      (insert-file-contents menu)
      (let ((text (buffer-string)))
        ;; cookie 后面必须是**纯数据**的 autoload 声明：直接挂在宏调用上会让
        ;; `loaddefs-generate' 把 `(transient-define-prefix …)' 原样抄进 autoloads
        ;; 文件（它展开这个宏得先 load 本文件，实测报 file-missing / Recursive
        ;; load），于是启动加载 autoloads 就得先有 transient——延迟加载彻底失效。
        (should (string-match-p
                 ";;;###autoload\n(autoload 'eimg-menu \"eimg-transient\" nil t)"
                 text))
        (should-not (string-match-p ";;;###autoload\n(transient-define-prefix" text))
        (should (string-match-p "\n(transient-define-prefix eimg-menu ()" text))
        ;; infix 只影响本次调用，绝不写回配置。
        (dolist (variable '("eimg-ocr-backend" "eimg-ocr-lang" "eimg-ocr-pdf-dpi"))
          (should-not (string-match-p (concat "setq " variable "\\_>") text)))))))

(provide 'eimg-transient-test)

;;; eimg-transient-test.el ends here
