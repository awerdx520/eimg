;;; eimg-autoload-test.el --- autoload cookie 与延迟加载链路的 ERT 用例  -*- lexical-binding: t; -*-

;; Author: thomas
;; Version: 0.1.0
;; Keywords: convenience, tools, ocr

;;; Commentary:

;; 宿主把 `use-package eimg' 改成 `:defer t' 后，启动时 eimg 一个文件都不加载，
;; 所有「按键可用性」都压到 straight 生成的 autoloads 上。本文件锁住这条链路：
;;
;;   1. 每个**面向用户**的交互命令都有 `;;;###autoload' cookie（源码文本断言）；
;;   2. `eimg-embark' 的延迟加载补偿形态正确（不是 `(require 'eimg-embark)'，
;;      那条会 `Recursive require'，见该文件注释）；
;;   3. 真正跑一遍 `loaddefs-generate'，逐条核对「命令 → 文件名」映射；
;;   4. 仅加载 autoloads（不加载 `eimg.el'）时命令的 `fboundp' / `autoloadp' 语义；
;;   5. embark 加载后补偿真的把 keymap 注册进去（stub embark，无第三方依赖）。
;;
;; 三条硬约束：
;;   - **不用 `use-package :commands'**（它假设「文件名 = 符号名」，`eimg-ocr-region'
;;     定义在 `eimg-ocr.el' 里是对的，但 `eimg-ocr-show-result-buffer' 在
;;     `eimg-transient.el' 里就会指向不存在的文件）—— 文件名只能由
;;     `loaddefs-generate' 按实际定义位置填。
;;   - **生成 autoloads 的输出文件必须落在仓库根**：`loaddefs-generate' 记录的是
;;     相对输出目录的路径，输出到 `/tmp' 会得到 `../eimg-capture' 这种从
;;     `default-directory' 解析不到的路径（`file-missing'）。
;;   - **stub embark 绝不用真包**：`emacs -Q' 里没有 embark，本文件只用最小
;;     `defvar' stub 验证「after-load 钩子 → autoload 函数 → 注册」这条链路。

;;; Code:

(require 'ert)
(require 'cl-lib)

;;;; ── 测试辅助 ──────────────────────────────────────────────────────────

(defun eimg-autoload-test--root ()
  "返回 eimg 仓库根目录（`eimg.el' 所在目录）。
用 `locate-library' 而不是 `load-file-name'：用例运行期 `load-file-name' 已被
Emacs 复位为 nil，`buffer-file-name' 在 batch 下同样为 nil（实测
`Wrong type argument: arrayp, nil'）。`file-truename' 把 straight build 软链
折回开发仓，故两种加载方式都得到同一个根目录。"
  (file-name-directory (file-truename (locate-library "eimg"))))

(defun eimg-autoload-test--read (root name)
  "读取仓库根 ROOT 下 NAME 文件的全文。"
  (with-temp-buffer
    (insert-file-contents (expand-file-name name root))
    (buffer-string)))

(defun eimg-autoload-test--emacs ()
  "返回当前 Emacs 可执行文件路径（子进程用）。"
  (expand-file-name invocation-name invocation-directory))

(defun eimg-autoload-test--run (root args)
  "在 ROOT 下以 batch 模式跑当前 Emacs，参数为 ARGS（字符串列表）。
返回 (RC . OUTPUT)，OUTPUT 是 stdout+stderr 的合并文本。"
  (with-temp-buffer
    (let* ((default-directory root)
           (rc (apply #'call-process (eimg-autoload-test--emacs) nil
                      (current-buffer) t
                      (append (list "-Q" "--batch" "-L" ".") args))))
      (cons rc (buffer-string)))))

(defun eimg-autoload-test--generate (root name)
  "在 ROOT 下把 autoloads 生成到 NAME（相对 ROOT），返回生成文件全文。"
  (let ((result (eimg-autoload-test--run
                 root
                 (list "--eval"
                       (format "(progn (require 'loaddefs) (loaddefs-generate \".\" %S nil))"
                               name)))))
    (unless (zerop (car result))
      (error "loaddefs-generate 失败（rc=%s）：%s" (car result) (cdr result)))
    (eimg-autoload-test--read root name)))

(defun eimg-autoload-test--autoload-pairs (text)
  "从 autoloads 文本 TEXT 提取 (命令 . 文件名) 列表。
只认 `loaddefs-generate' 写出的两种形态：`(autoload 'CMD \"FILE\" ...)'。"
  (let ((pairs nil)
        (pos 0))
    (while (string-match "(autoload '\\([^ \n]+\\) \"\\([^\"]+\\)\"" text pos)
      (push (cons (match-string 1 text) (match-string 2 text)) pairs)
      (setq pos (match-end 0)))
    (nreverse pairs)))

;;;; ── 1. 源码：每个交互命令都有 cookie ───────────────────────────────────

(defconst eimg-autoload-test--defun-commands
  '(("eimg-capture.el" . "eimg-capture")
    ("eimg-capture.el" . "eimg-capture-open-directory")
    ("eimg-insert.el" . "eimg-insert-path")
    ("eimg-insert.el" . "eimg-insert-display")
    ("eimg-ocr.el" . "eimg-ocr-region")
    ("eimg-ocr.el" . "eimg-ocr-file")
    ("eimg-ocr.el" . "eimg-ocr-history")
    ("eimg-ocr.el" . "eimg-ocr-list-backends")
    ;; 这三条与「按功能分文件」的直觉相反：`eimg-ocr-*' 前缀但定义在
    ;; `eimg-transient.el'（它们只服务菜单的「系统」组，且都用 transient 侧的
    ;; buffer 名常量）。宿主键位不受影响——autoload 记录的是**实际定义位置**。
    ("eimg-transient.el" . "eimg-ocr-show-result-buffer")
    ("eimg-transient.el" . "eimg-ocr-open-directory")
    ("eimg-transient.el" . "eimg-ocr-setup-help"))
  "带 `;;;###autoload' cookie 的 defun 清单（文件 . 命令）。")

(defconst eimg-autoload-test--declared-commands
  '(("eimg-transient.el" . "(autoload 'eimg-menu \"eimg-transient\" nil t)")
    ("eimg-embark.el" . "(autoload 'eimg-embark-register \"eimg-embark\")"))
  "用「cookie + 纯数据 autoload 声明」形态的命令清单（文件 . 声明原文）。
`eimg-menu' 是 `transient-define-prefix'（cookie 直挂宏会让 loaddefs 把宏调用
原样抄进 autoloads，启动即加载 transient）；`eimg-embark-register' 在文件里也有
真 defun（声明在前、定义在后，末尾覆盖 autoload 桩，故文件内自加载安全）。")

(ert-deftest eimg-autoload-test-cookies-present ()
  "13 个入口命令的源码都带 autoload cookie，且 cookie 紧贴目标 form。
不带 cookie 的命令在 `:defer t' 下就是 `void-function'。"
  (let ((root (eimg-autoload-test--root)))
    (dolist (entry eimg-autoload-test--defun-commands)
      (let* ((file (car entry))
             (command (cdr entry))
             (text (eimg-autoload-test--read root file))
             (anchor (concat ";;;###autoload\n(defun " command " (")))
        (should (string-match-p (regexp-quote anchor) text))))
    (dolist (entry eimg-autoload-test--declared-commands)
      (let* ((file (car entry))
             (declaration (cdr entry))
             (text (eimg-autoload-test--read root file)))
        (should (string-match-p
                 (regexp-quote (concat ";;;###autoload\n" declaration))
                 text))))))

(ert-deftest eimg-autoload-test-buffer-only-commands-have-no-cookie ()
  "只在 `*eimg-ocr*' buffer 或菜单内使用的命令**不**加 cookie。
它们工作时包必然已加载（结果 buffer 由 `eimg-ocr--show-result' 创建、
菜单由 `eimg-menu' 拉起），加 cookie 只会把「bufffer 内按键」误当成启动入口。
这条用例是反向断言：防止后续「顺手统一加 cookie」把延迟加载面扩大。"
  (let* ((root (eimg-autoload-test--root))
         (text (eimg-autoload-test--read root "eimg-ocr.el")))
    (dolist (command '("eimg-ocr-cancel" "eimg-ocr-copy" "eimg-ocr-insert"
                       "eimg-ocr-write-file" "eimg-ocr-rerun"))
      (should-not (string-match-p
                   (regexp-quote (concat ";;;###autoload\n(defun " command " ("))
                   text)))
    (should (string-match-p (regexp-quote "(provide 'eimg-ocr)") text))))

;;;; ── 2. embark 补偿形态 ────────────────────────────────────────────────

(ert-deftest eimg-autoload-test-embark-compensation-form ()
  "`eimg-embark.el' 的补偿必须是「autoload 函数 + after-load 调用」。
`(with-eval-after-load 'embark (require 'eimg-embark))' 会 **Recursive require**：
embark 加载完成时钩子触发 require → 本文件顶层同一条钩子立即执行（embark 已
loaded）→ 再 require 正在加载的 feature → 报错，keymap 与注册一起废掉。"
  (let* ((root (eimg-autoload-test--root))
         (text (eimg-autoload-test--read root "eimg-embark.el")))
    (should (string-match-p
             (regexp-quote
              ";;;###autoload\n(with-eval-after-load 'embark (eimg-embark-register))")
             text))
    (should (string-match-p
             (regexp-quote ";;;###autoload\n(autoload 'eimg-embark-register \"eimg-embark\")")
             text))
    (should (string-match-p (regexp-quote "(defun eimg-embark-register ()") text))
    (should-not (string-match-p
                 (regexp-quote "(with-eval-after-load 'embark (require 'eimg-embark))")
                 text))
    ;; 注册与 keymap 定义都在函数体内，注册值必须与定义名逐字一致。
    (should (string-match-p (regexp-quote "(add-to-list 'embark-keymap-alist") text))
    (should (string-match-p (regexp-quote "(defvar-keymap eimg-image-map") text))
    (should (string-match-p (regexp-quote "'(eimg/image eimg-image-map)") text))))

;;;; ── 3. 端到端：生成的 autoloads 文件名映射 ─────────────────────────────

(ert-deftest eimg-autoload-test-generated-file-mapping ()
  "真跑一次 `loaddefs-generate'，逐条核对命令 → 文件名映射（不容错）。
输出文件必须落在仓库根：`loaddefs-generate' 记录的是相对输出目录的路径，
落在 `/tmp' 会生成 `../eimg-capture' 这类 `default-directory' 解析不到的路径。"
  (let* ((root (eimg-autoload-test--root))
         (name (format "eimg-autoloads-test-%d.el" (emacs-pid)))
         (file (expand-file-name name root)))
    (unwind-protect
        (let* ((text (eimg-autoload-test--generate root name))
               (pairs (eimg-autoload-test--autoload-pairs text)))
          (dolist (expect '(("eimg-capture" . "eimg-capture")
                            ("eimg-capture-open-directory" . "eimg-capture")
                            ("eimg-insert-path" . "eimg-insert")
                            ("eimg-insert-display" . "eimg-insert")
                            ("eimg-ocr-region" . "eimg-ocr")
                            ("eimg-ocr-file" . "eimg-ocr")
                            ("eimg-ocr-history" . "eimg-ocr")
                            ("eimg-ocr-list-backends" . "eimg-ocr")
                            ("eimg-ocr-show-result-buffer" . "eimg-transient")
                            ("eimg-ocr-open-directory" . "eimg-transient")
                            ("eimg-ocr-setup-help" . "eimg-transient")
                            ("eimg-menu" . "eimg-transient")
                            ("eimg-embark-register" . "eimg-embark")))
            (should (equal (cdr expect)
                           (cdr (assoc (car expect) pairs)))))
          ;; embark 的 after-load 调用必须被**逐字**抄进 autoloads：抄成别的
          ;; 形态（或被展开掉）就等于补偿消失，`C-.' 静默失效。
          (should (string-match-p
                   (regexp-quote "(with-eval-after-load 'embark (eimg-embark-register))")
                   text))
          ;; 反面：autoloads 里不得出现「加载即 require 整个包」的形态。
          (should-not (string-match-p
                       (regexp-quote "(require 'eimg)")
                       text)))
      (ignore-errors (delete-file file)))))

;;;; ── 4. 仅加载 autoloads 时的符号语义 ───────────────────────────────────

(ert-deftest eimg-autoload-test-autoloads-only-semantics ()
  "只加载生成的 autoloads 时：`eimg.el' 未加载、命令可键、`fboundp' 为 t。
`fboundp' 这一条是 OCR 软依赖链的前提：`eimg-ocr--capture-function' 用
`(fboundp 'eimg-capture)' 探测截图能力，autoload 符号同样返回 t，
因此「宿主延迟加载 eimg」不会让 OCR 误判「没有截图能力」。"
  (let* ((root (eimg-autoload-test--root))
         (name (format "eimg-autoloads-test-%d.el" (emacs-pid)))
         (file (expand-file-name name root)))
    (unwind-protect
        (progn
          (eimg-autoload-test--generate root name)
          (let* ((result
                  (eimg-autoload-test--run
                   root
                   (list "-l" name "--eval"
                         (concat
                          "(progn"
                          " (princ (format \"featurep-eimg=%S\\n\" (featurep 'eimg)))"
                          " (princ (format \"featurep-transient=%S\\n\" (featurep 'transient)))"
                          " (dolist (c '(eimg-capture eimg-insert-path eimg-ocr-region"
                          "                eimg-ocr-file eimg-menu))"
                          "   (princ (format \"%s autoloadp=%S file=%S\\n\" c"
                          "                  (autoloadp (symbol-function c))"
                          "                  (and (autoloadp (symbol-function c))"
                          "                       (nth 1 (symbol-function c))))))"
                          " (princ (format \"fboundp-capture=%S commandp-capture=%S\\n\""
                          "                (fboundp 'eimg-capture) (commandp 'eimg-capture))))"))))
                 (output (cdr result)))
            (should (zerop (car result)))
            (should (string-match-p "featurep-eimg=nil" output))
            ;; 延迟加载没有退化：transient 也不该被 autoloads 拽进来。
            (should (string-match-p "featurep-transient=nil" output))
            (should (string-match-p "eimg-capture autoloadp=t file=\"eimg-capture\"" output))
            (should (string-match-p "eimg-insert-path autoloadp=t file=\"eimg-insert\"" output))
            (should (string-match-p "eimg-ocr-region autoloadp=t file=\"eimg-ocr\"" output))
            (should (string-match-p "eimg-ocr-file autoloadp=t file=\"eimg-ocr\"" output))
            (should (string-match-p "eimg-menu autoloadp=t file=\"eimg-transient\"" output))
            (should (string-match-p "fboundp-capture=t commandp-capture=t" output))))
      (ignore-errors (delete-file file)))))

;;;; ── 5. embark 加载后补偿真的生效 ────────────────────────────────────────

(ert-deftest eimg-autoload-test-embark-registration-after-load ()
  "加载 autoloads → 加载（stub）embark → `eimg/image' 注册成功且无递归。
stub 只用 `defvar' 提供 embark 的两个变量，绝不引入真包：本用例验证的是
「after-load 钩子 → autoload 函数 → 加载 `eimg-embark.el' → 注册」这条链路。"
  (let* ((root (eimg-autoload-test--root))
         (name (format "eimg-autoloads-test-%d.el" (emacs-pid)))
         (file (expand-file-name name root))
         (stub (make-temp-file "eimg-autoload-test-embark-" t)))
    (unwind-protect
        (progn
          (eimg-autoload-test--generate root name)
          (with-temp-file (expand-file-name "embark.el" stub)
            (insert ";;; embark.el --- stub  -*- lexical-binding: t; -*-\n"
                    "(defvar embark-general-map (make-sparse-keymap))\n"
                    "(defvar embark-keymap-alist nil)\n"
                    "(provide 'embark)\n"))
          (let* ((result
                  (eimg-autoload-test--run
                   root
                   (list "-L" stub "-l" name "--eval"
                         (concat
                          "(progn"
                          " (princ (format \"before=%S\\n\" (featurep 'eimg-embark)))"
                          " (require 'embark)"
                          " (princ (format \"after=%S alist=%S keymapp=%S action=%S\\n\""
                          "                (featurep 'eimg-embark) embark-keymap-alist"
                          "                (and (boundp 'eimg-image-map)"
                          "                     (keymapp eimg-image-map))"
                          "                (fboundp 'eimg-embark-insert-link))))"))))
                 (output (cdr result)))
            (should (zerop (car result)))
            (should (string-match-p "before=nil" output))
            (should (string-match-p
                     "after=t alist=((eimg/image eimg-image-map)) keymapp=t action=t"
                     output))))
      (ignore-errors (delete-directory stub t))
      (ignore-errors (delete-file file)))))

(provide 'eimg-autoload-test)

;;; eimg-autoload-test.el ends here
