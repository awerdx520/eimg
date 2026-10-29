;;; eimg-ocr-pdf-test.el --- CLI 级 PDF 页码越界用例  -*- lexical-binding: t; -*-

;; Author: thomas
;; Version: 0.1.0
;; Keywords: convenience, tools, ocr

;;; Commentary:

;; 覆盖 `bin/eimg-ocr' 的 `--pdf-pages' 越界判定（计划 D4 / 技术债 #1）：用
;; `call-process' 跑**真 CLI**，断言用户实际看到的退出码与 stderr 文案。
;;
;; 核心手法：用「假 pdfinfo」模拟**未安装 pdfinfo** 的机器——临时目录里放一个
;; 内容为 `#!/bin/sh' + `exit 1' 的可执行脚本 `pdfinfo'，再把该目录 prepend 到
;; PATH。依据是 `pdf_page_count'（`bin/eimg-ocr:2030' 起）在 `shutil.which' 命中
;; 但 `returncode != 0' 时返回 None，与「pdfinfo 缺失」等价，且不牵连
;; `pdftoppm' / `python3'（它们仍在真 PATH 上）。
;;
;; 四条硬约束：
;;   1. **不碰 elisp 侧**：本文件不 require `eimg-ocr'，只跑 CLI 子进程；elisp
;;      侧 argv 拼装由 `eimg-ocr-test.el' 负责。
;;   2. **不覆盖 `XDG_DATA_HOME'**：ollama 用例覆盖它是为了隔离 config.json，这里
;;      若覆盖会让 `resolve_tessdata_dir' 找不到 `~/.local/share/eimg/tessdata'，
;;      tesseract 直接 rc=4，四条用例全红。也不覆盖 `TMPDIR'（`make test' 已把它
;;      钉到仓库内 `.tmp-test'）。
;;   3. **PATH 必须 cons 到最前并移除旧 `PATH=' 条目**：`process-environment' 靠前
;;      优先；假 pdfinfo 脚本必须 `#o755'，否则 `shutil.which' 找不到它，用例会
;;      悄悄退回「有 pdfinfo」路径而假绿。
;;   4. **就绪判据只探测一次**（缓存到 `eimg-ocr-pdf-test--ready'）：每条用例都跑
;;      一次 `--list-backends' 会白等好几秒。
;;
;; 本文件在 TDD 的「红」阶段写就：用例 1（`partial-overflow-without-pdfinfo'）
;; 锁定的是尚未实现的判据，故在实现（T2）落地前它应当失败；用例 2 / 3 / 4 锁定
;; 既有行为，任何时候都必须通过。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'json)

;;;; ── 测试辅助 ──────────────────────────────────────────────────────────

(defvar eimg-ocr-pdf-test--file
  (or load-file-name buffer-file-name)
  "本文件的路径（加载期取值）。
运行期 `load-file-name' 不再绑定，故必须在加载时就抓住它，供「推导仓库根」兜底。")

(defun eimg-ocr-pdf-test--root ()
  "返回 eimg 仓库根目录（`test/' 的上一级）。
优先用 `locate-library'（`make test' 带 `-L .'，能找到仓库根的 `eimg.el'）；
它可能返回相对路径，故统一 `expand-file-name' + `file-truename'。"
  (let ((library (locate-library "eimg")))
    (if library
        (file-name-directory (file-truename (expand-file-name library)))
      ;; 兜底：本文件在 `<root>/test/' 下，往上两级即仓库根。
      (file-name-directory
       (directory-file-name
        (file-name-directory (expand-file-name eimg-ocr-pdf-test--file)))))))

(defun eimg-ocr-pdf-test--cli-path ()
  "`bin/eimg-ocr' 的绝对路径（要跑的是真 CLI，不是打桩）。"
  (expand-file-name "bin/eimg-ocr" (eimg-ocr-pdf-test--root)))

(defun eimg-ocr-pdf-test--fixture ()
  "三页 PDF 夹具的绝对路径（页码越界断言的基准文档）。"
  (expand-file-name "test/fixtures/three-pages.pdf" (eimg-ocr-pdf-test--root)))

(defvar eimg-ocr-pdf-test--ready nil
  "就绪探测结果缓存：nil = 尚未探测；t = 可用；`no' = 不可用。")

(defun eimg-ocr-pdf-test--tesseract-available-p ()
  "`--list-backends' 的 **stdout** 里 tesseract 是否 `available=true'。
单行格式由 `format_backend_line'（`bin/eimg-ocr:1203' 起）决定：
`{name}: available=true|false reason=...'，输出走 stdout（stderr 只有 Python 侧
异常）。"
  (let ((stdout (nth 1 (eimg-ocr-pdf-test--run-cli (list "--list-backends")))))
    (and stdout (string-match-p "^tesseract: available=true" stdout))))

(defun eimg-ocr-pdf-test--probe-ready ()
  "探测本机是否具备跑端到端用例的全部前提（不含 pdfinfo——它正是被模拟的对象）。"
  (and (executable-find "python3")
       (executable-find "pdftoppm")
       (file-executable-p (eimg-ocr-pdf-test--cli-path))
       (file-exists-p (eimg-ocr-pdf-test--fixture))
       (eimg-ocr-pdf-test--tesseract-available-p)))

(defun eimg-ocr-pdf-test--ready-p ()
  "本机是否具备跑端到端用例的前提（结果缓存，只探测一次）。
缺 python3 / pdftoppm / 真 CLI / 夹具 / 可用 tesseract 时跳过而不是变红——
没装 OCR 后端的机器不该因为本文件失败。"
  (unless eimg-ocr-pdf-test--ready
    (setq eimg-ocr-pdf-test--ready
          (if (eimg-ocr-pdf-test--probe-ready) t 'no)))
  (eq t eimg-ocr-pdf-test--ready))

(defun eimg-ocr-pdf-test--make-fake-pdfinfo-dir ()
  "造一个「假 pdfinfo」目录，返回其绝对路径；用完 `delete-directory' 删掉。
脚本内容恰为 `#!/bin/sh' + `exit 1'：`pdf_page_count' 见 `returncode != 0'
就返回 None（等价于「没装 pdfinfo」），而 `shutil.which' 仍能命中它——这正是
我们要模拟的环境。`#o755' 不能省，否则 `which' 找不到、用例退回真 pdfinfo 路径。"
  (let* ((dir (make-temp-file "eimg-pdf-test-bin-" t))
         (script (expand-file-name "pdfinfo" dir)))
    (with-temp-file script
      (insert "#!/bin/sh\nexit 1\n"))
    (set-file-modes script #o755)
    dir))

(defun eimg-ocr-pdf-test--run-cli (args &optional fake-pdfinfo-dir)
  "在仓库根用 `call-process' 跑真 CLI（参数列表 ARGS），返回 `(退出码 STDOUT STDERR)'。
FAKE-PDFINFO-DIR 非 nil 时把它 prepend 到 PATH（模拟「未安装 pdfinfo」）。

PATH 处理：先剔除环境里已有的 `PATH=' 条目，再把目标 PATH 放到列表最前——
`process-environment' 靠前优先，保留两条同名条目虽也能生效，但会让后续排障
误判。**不覆盖 `XDG_DATA_HOME'**（会打断 tessdata 查找，见文件头约束 2），
也不覆盖 `TMPDIR'（`make test' 已钉到仓库内）。

stderr 单独收进临时文件：混进 stdout 会让「退出码 3 + stderr 文案」这类断言拿
不到东西。编码全部钉成 utf-8：中文断言不能受 locale 影响。"
  (let* ((real-path (getenv "PATH"))
         (base (seq-remove (lambda (entry) (string-prefix-p "PATH=" entry))
                           process-environment))
         (path-entry (if fake-pdfinfo-dir
                         (concat "PATH=" fake-pdfinfo-dir ":" real-path)
                       (concat "PATH=" real-path)))
         (out (generate-new-buffer " *eimg-pdf-stdout*"))
         (err-file (make-temp-file "eimg-pdf-stderr-" nil ".log"))
         (process-environment
          (append (list path-entry "PYTHONIOENCODING=utf-8") base))
         (coding-system-for-read 'utf-8-unix)
         (coding-system-for-write 'utf-8-unix)
         (default-directory (eimg-ocr-pdf-test--root)))
    (unwind-protect
        (let ((code (apply #'call-process (eimg-ocr-pdf-test--cli-path)
                           nil (list out err-file) nil args)))
          (list code
                (with-current-buffer out (buffer-string))
                (with-temp-buffer
                  (insert-file-contents err-file)
                  (buffer-string))))
      (kill-buffer out)
      (ignore-errors (delete-file err-file)))))

(defmacro eimg-ocr-pdf-test--with-fake-pdfinfo (variable &rest body)
  "在 BODY 期间把 VARIABLE 绑到假 pdfinfo 目录，结束后连目录带脚本删掉。"
  (declare (indent 1))
  `(let ((,variable (eimg-ocr-pdf-test--make-fake-pdfinfo-dir)))
     (unwind-protect
         (progn ,@body)
       (ignore-errors (delete-directory ,variable t)))))

;;;; ── A. 无 pdfinfo：部分越界必须报错（本文件锁定待实现判据） ────────────

(ert-deftest eimg-ocr-pdf-test-partial-overflow-without-pdfinfo ()
  "无 pdfinfo 时 `--pdf-pages 2-9' 打在 3 页文档上：退出码 3 且文案说清少了哪些页。
锁定 T2 要实现的判据——「请求页数 vs 实际渲染页数」：3 页文档只渲染出第 2、3 页
（2 页），缺第 4 页起，故必须报退出码 3，而不是静默截断成 rc=0 只返回 2 页。

**改动前此用例应为红**：无 pdfinfo 时 `pdf_page_count' 返回 None，前置校验拿不到
总页数、pdftoppm 又不报错（`-f 2 -l 9' 在 3 页文档上只渲染 2 页），于是 rc=0。
stderr 三个子串分别锁：契约子串 `无法读取输入'（README 退出码表按它识别）、
渲染页数 `只渲染出 2 页'、首个越界页 `页码 4'（带「页码」前缀，避免匹配到
`2-9' 或 `2 页' 里的裸数字）。"
  (skip-unless (eimg-ocr-pdf-test--ready-p))
  (eimg-ocr-pdf-test--with-fake-pdfinfo fake-dir
    (let* ((result (eimg-ocr-pdf-test--run-cli
                    (list "--backend" "tesseract"
                          "--pdf-pages" "2-9"
                          "--format" "json"
                          (eimg-ocr-pdf-test--fixture))
                    fake-dir))
           (code (nth 0 result))
           (stderr (nth 2 result)))
      (should (equal 3 code))
      (should (string-match-p "无法读取输入" stderr))
      (should (string-match-p "只渲染出 2 页" stderr))
      (should (string-match-p "页码 4" stderr)))))

(ert-deftest eimg-ocr-pdf-test-partial-overflow-with-pdfinfo ()
  "有 pdfinfo 时同样的 `--pdf-pages 2-9'：退出码 3 且文案含总页数。
锁定「有 pdfinfo 时既有行为不变」——判据仍是 `recognize_pdf' 的总页数前置校验，
文案走 `_pdf_overflow_message' 的 `total' 分支（含 `共 3 页'）。"
  (skip-unless (eimg-ocr-pdf-test--ready-p))
  (skip-unless (executable-find "pdfinfo"))
  (let* ((result (eimg-ocr-pdf-test--run-cli
                  (list "--backend" "tesseract"
                        "--pdf-pages" "2-9"
                        "--format" "json"
                        (eimg-ocr-pdf-test--fixture))))
         (code (nth 0 result))
         (stderr (nth 2 result)))
    (should (equal 3 code))
    (should (string-match-p "无法读取输入" stderr))
    (should (string-match-p "共 3 页" stderr))))

;;;; ── B. 无 pdfinfo：合法区间与单页越界（防误伤） ────────────────────────

(ert-deftest eimg-ocr-pdf-test-valid-range-without-pdfinfo ()
  "无 pdfinfo 时合法区间 `--pdf-pages 2-3'：退出码 0 且 JSON 恰 2 个页对象。
这是**防误伤**用例——新判据（渲染页数 < 请求页数）不得把合法区间判成越界。
断言只以「页数」为准：夹具是纯图 PDF，`blocks' 可能为空，不依赖 OCR 文本。
（本用例真跑 2 页 OCR，本机约 2–4 秒。）"
  (skip-unless (eimg-ocr-pdf-test--ready-p))
  (eimg-ocr-pdf-test--with-fake-pdfinfo fake-dir
    (let* ((result (eimg-ocr-pdf-test--run-cli
                    (list "--backend" "tesseract"
                          "--pdf-pages" "2-3"
                          "--format" "json"
                          (eimg-ocr-pdf-test--fixture))
                    fake-dir))
           (code (nth 0 result))
           (stdout (nth 1 result)))
      (should (equal 0 code))
      (let ((parsed (json-parse-string stdout :object-type 'alist)))
        (should (equal 2 (length (alist-get 'pages parsed))))
        (should (equal '(2 3)
                       (mapcar (lambda (page) (alist-get 'page page))
                               (alist-get 'pages parsed))))))))

(ert-deftest eimg-ocr-pdf-test-single-page-beyond-without-pdfinfo ()
  "无 pdfinfo 时单页越界 `--pdf-pages 9'：退出码 3。
锁定「单页越界兜底不受新判据影响」——pdftoppm 自身报 rc=99（或渲染零输出兜底）
已经把它拦下，文案只断言契约前缀「无法读取输入」，不断言页码措辞（pdftoppm rc=99 与渲染零输出两条兜底路径的措辞不同，钉死会绑住实现细节）。"
  (skip-unless (eimg-ocr-pdf-test--ready-p))
  (eimg-ocr-pdf-test--with-fake-pdfinfo fake-dir
    (let* ((result (eimg-ocr-pdf-test--run-cli
                    (list "--backend" "tesseract"
                          "--pdf-pages" "9"
                          (eimg-ocr-pdf-test--fixture))
                    fake-dir))
           (stderr (nth 2 result)))
      (should (equal 3 (nth 0 result)))
      (should (string-match-p "无法读取输入" stderr)))))

(provide 'eimg-ocr-pdf-test)
;;; eimg-ocr-pdf-test.el ends here
