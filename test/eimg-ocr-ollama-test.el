;;; eimg-ocr-ollama-test.el --- ollama 后端 CLI stub 端到端用例  -*- lexical-binding: t; -*-

;; Author: thomas
;; Version: 0.1.0
;; Keywords: convenience, tools, ocr

;;; Commentary:

;; 覆盖 `bin/eimg-ocr' 的 ollama 分支（计划 T11）：真起 `test/fixtures/ollama-stub.py'
;; 这个本地 HTTP stub（python 标准库 `http.server'，端口由内核分配），再用
;; `call-process' 跑**真 CLI**，断言退出码与 stdout / stderr 文案。
;;
;; 与 `eimg-ocr-test.el' 的分工：那边用 shell stub 打桩 `eimg-ocr--start' 来验证
;; elisp 侧的 argv 拼装与回调；本文件不碰 elisp 侧，只验证「CLI + HTTP 协议」这两层——
;; 探测分支（vision / novision / missing）、`/api/chat` 的请求形态、逐行成块、
;; 扩展名白名单、以及模型未配置时的短路。
;;
;; 四条硬约束：
;;   1. **不碰真实 ollama 服务、不下载模型**：所有请求都指向 stub 在 127.0.0.1 上
;;      监听的临时端口；测试阶段禁止 `ollama pull`。
;;   2. **端口靠 stub 回读**（stdout 首行 `PORT <n>'），有界等待 ≤5 秒；不用固定端口
;;      ——本机 mirrored 网络模式下端口空间与 Windows 共享，固定端口可能撞
;;      EADDRINUSE 且 WSL 内 `ss` 看不到占用者。
;;   3. **不读真实配置**：每个用例把 `XDG_DATA_HOME' 指向临时空目录。否则本机将来在
;;      `~/.local/share/eimg/config.json' 写了 `ollama_model'，会让「未配置模型」
;;      用例假红（CLI 会从配置文件读到模型名）。
;;   4. **不留进程与临时文件**：stub 进程、临时目录、stderr 文件全部在
;;      `unwind-protect' 里清理；末尾还有一条专门断言「跑完没有 ollama-stub 进程」。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)

;;;; ── 测试辅助 ──────────────────────────────────────────────────────────

(defvar eimg-ocr-ollama-test--file
  (or load-file-name buffer-file-name)
  "本文件的路径（加载期取值）。
运行期 `load-file-name' 不再绑定，故必须在加载时就抓住它，供「推导仓库根」兜底。")

(defun eimg-ocr-ollama-test--root ()
  "返回 eimg 仓库根目录（`test/' 的上一级）。
优先用 `locate-library'（`make test' 带 `-L .'，能找到仓库根的 `eimg.el'）；
它可能返回相对路径，故统一 `expand-file-name' + `file-truename'。"
  (let ((library (locate-library "eimg")))
    (if library
        (file-name-directory (file-truename (expand-file-name library)))
      ;; 兜底：本文件在 `<root>/test/' 下，往上两级即仓库根。
      (file-name-directory
       (directory-file-name
        (file-name-directory (expand-file-name eimg-ocr-ollama-test--file)))))))

(defun eimg-ocr-ollama-test--stub-path ()
  "stub 夹具的绝对路径。"
  (expand-file-name "test/fixtures/ollama-stub.py" (eimg-ocr-ollama-test--root)))

(defun eimg-ocr-ollama-test--cli-path ()
  "`bin/eimg-ocr' 的绝对路径（要跑的是真 CLI，不是打桩）。"
  (expand-file-name "bin/eimg-ocr" (eimg-ocr-ollama-test--root)))

(defun eimg-ocr-ollama-test--python ()
  "可用的 python 解释器（优先 python3）；没有时返回 nil。"
  (or (executable-find "python3") (executable-find "python")))

(defun eimg-ocr-ollama-test--ready-p ()
  "本机具备跑端到端用例的三件前提：python、真 CLI（可执行）、stub 脚本。
缺任何一件就 `skip-unless' 跳过——没装 python 的机器应跳过而不是变红。"
  (let ((python (eimg-ocr-ollama-test--python))
        (cli (eimg-ocr-ollama-test--cli-path)))
    (and python
         (file-executable-p cli)
         (file-exists-p (eimg-ocr-ollama-test--stub-path)))))

(defun eimg-ocr-ollama-test--stub-processes ()
  "返回进程名含 `ollama-stub' 的进程列表（收尾断言用）。"
  (seq-filter (lambda (proc) (string-match-p "ollama-stub" (process-name proc)))
              (process-list)))

(defun eimg-ocr-ollama-test--start-stub (mode)
  "以 MODE（vision / novision / missing）起 stub，返回 `(进程 . 端口)'。
端口从 stdout 首行 `PORT <n>' 回读，有界等待 5 秒；超时或 stub 提前退出时杀掉
进程并 `ert-fail'（**不做无界循环**：`make test' 不能被一个没起来的 stub 挂住）。"
  (let* ((output "")
         (proc (let ((process-environment
                      (cons (format "OLLAMA_STUB_MODE=%s" mode) process-environment)))
                 (make-process
                  :name "ollama-stub"
                  :command (list (eimg-ocr-ollama-test--python)
                                 "-u"
                                 (eimg-ocr-ollama-test--stub-path))
                  :buffer nil
                  :coding 'utf-8-unix
                  :connection-type 'pipe
                  :noquery t
                  :filter (lambda (_proc chunk) (setq output (concat output chunk))))))
         port)
    (let ((deadline (+ (float-time) 5.0)))
      (while (and (null port) (process-live-p proc) (< (float-time) deadline))
        (when (string-match "PORT \\([0-9]+\\)" output)
          (setq port (string-to-number (match-string 1 output))))
        (unless port
          (accept-process-output proc 0.05))))
    (if port
        (cons proc port)
      (ignore-errors (delete-process proc))
      (ert-fail (format "ollama-stub（mode=%s）没能报出 PORT：%S" mode output)))))

(defun eimg-ocr-ollama-test--stop-stub (proc)
  "关掉 PROC；已退出 / 已删时静默（`unwind-protect' 的收尾路径必须幂等）。"
  (ignore-errors (delete-process proc)))

(defun eimg-ocr-ollama-test--url (stub)
  "由 STUB（`(进程 . 端口)'）拼出 ollama 服务地址。"
  (format "http://127.0.0.1:%d" (cdr stub)))

(defun eimg-ocr-ollama-test--port-open-p (port)
  "PORT 上能建立 TCP 连接时返回 t。
用 `open-network-stream'（不是 `url-retrieve'）：本机 `http_proxy' 已设置而
`no_proxy' 未设置，走 url 层探活会被代理接管返回假 503；裸 socket 不受影响。"
  (let ((proc (condition-case nil
                  (open-network-stream "eimg-ollama-probe" nil "127.0.0.1" port)
                (error nil))))
    (when proc
      (prog1 (eq 'open (process-status proc))
        (ignore-errors (delete-process proc))))))

(defun eimg-ocr-ollama-test--wait-port (port)
  "有界轮询 PORT 可连：最多 10 次 × 0.2 秒；成功返回 t。"
  (let ((tries 0)
        open)
    (while (and (not open) (< tries 10))
      (setq open (eimg-ocr-ollama-test--port-open-p port)
            tries (1+ tries))
      (unless open (sleep-for 0.2)))
    open))

(defun eimg-ocr-ollama-test--run-cli (args data-dir)
  "在仓库根用 `call-process' 跑真 CLI（参数列表 ARGS），返回 `(退出码 STDOUT STDERR)'。
DATA-DIR 挂成 `XDG_DATA_HOME'（隔离 config.json）并复用为 `TMPDIR'：不污染用户的
`~/.local/share/eimg'，也不把临时文件撒到仓库外。
编码全部钉成 utf-8：中文断言不能受 locale 影响（`PYTHONIOENCODING' 顺带兜住
Python 侧 stdout 编码）。stderr 单独收进临时文件——混进 stdout 会让「退出码 2 +
stderr 文案」这类断言拿不到东西。"
  (let* ((out (generate-new-buffer " *eimg-ollama-stdout*"))
         (err-file (make-temp-file "eimg-ollama-stderr-" nil ".log"))
         (process-environment
          (append (list (format "XDG_DATA_HOME=%s" data-dir)
                        (format "TMPDIR=%s" data-dir)
                        "PYTHONIOENCODING=utf-8")
                  process-environment))
         (coding-system-for-read 'utf-8-unix)
         (coding-system-for-write 'utf-8-unix)
         (default-directory (eimg-ocr-ollama-test--root)))
    (unwind-protect
        (let ((code (apply #'call-process (eimg-ocr-ollama-test--cli-path)
                           nil (list out err-file) nil args)))
          (list code
                (with-current-buffer out (buffer-string))
                (with-temp-buffer
                  (insert-file-contents err-file)
                  (buffer-string))))
      (kill-buffer out)
      (ignore-errors (delete-file err-file)))))

(defmacro eimg-ocr-ollama-test--with-data-dir (variable &rest body)
  "在 BODY 期间把 VARIABLE 绑到临时空目录（挂 `XDG_DATA_HOME' 用），结束后删掉。"
  (declare (indent 1))
  `(let ((,variable (make-temp-file "eimg-ollama-test-data-" t)))
     (unwind-protect
         (progn ,@body)
       (ignore-errors (delete-directory ,variable t)))))

(defmacro eimg-ocr-ollama-test--with-stub (stub mode &rest body)
  "以 MODE 起 stub 绑定到 STUB（`(进程 . 端口)'），确认端口可连后跑 BODY。
无论 BODY 正常结束还是失败，都会关掉 stub 进程。"
  (declare (indent 2))
  `(let ((,stub (eimg-ocr-ollama-test--start-stub ,mode)))
     (unwind-protect
         (progn
           (should (eimg-ocr-ollama-test--wait-port (cdr ,stub)))
           ,@body)
       (eimg-ocr-ollama-test--stop-stub (car ,stub)))))

;;;; ── A. vision：端到端成功路径 ────────────────────────────────────────

(ert-deftest eimg-ocr-ollama-test-vision-end-to-end ()
  "vision 模式：退出码 0，stdout 同时含请求形态回显与两行中文。
回显首行把 `/api/chat' 的关键字段都带出来（`model' / `stream' / `options.temperature'
/ `messages[0].images' 的个数 / `keep_alive'），因此这一条同时钉住「请求体形态」
与「多行文本逐行成块」两件事。"
  (skip-unless (eimg-ocr-ollama-test--ready-p))
  (eimg-ocr-ollama-test--with-data-dir data-dir
    (eimg-ocr-ollama-test--with-stub stub "vision"
      (let* ((result (eimg-ocr-ollama-test--run-cli
                      (list "--backend" "ollama"
                            "--ollama-model" "stub-model"
                            "--ollama-url" (eimg-ocr-ollama-test--url stub)
                            "test/fixtures/hello.png")
                      data-dir))
             (stdout (nth 1 result)))
        (should (equal 0 (nth 0 result)))
        (should (string-match-p "\\[stub\\] model=stub-model" stdout))
        (should (string-match-p "stream=False" stdout))
        (should (string-match-p "temperature=0" stdout))
        ;; images=1 证明图片确实以 base64 进了 `messages[0].images'（不是空数组）。
        (should (string-match-p "images=1" stdout))
        (should (string-match-p "keep_alive=5m" stdout))
        ;; 两行固定文本都在：VLM 的多行输出被逐行成块，而不是只留最后一行 / 揉成一行。
        (should (string-match-p "第一行文字" stdout))
        (should (string-match-p "第二行文字" stdout))))))

;;;; ── B. novision：模型不支持视觉 ──────────────────────────────────────

(ert-deftest eimg-ocr-ollama-test-novision-backend-unavailable ()
  "novision 模式：`capabilities' 不含 `vision' → 退出码 2，stderr 含「不支持视觉」。
显式指定 `--backend ollama' 时后端不可用属「无可用后端」，不是识别失败（4）。"
  (skip-unless (eimg-ocr-ollama-test--ready-p))
  (eimg-ocr-ollama-test--with-data-dir data-dir
    (eimg-ocr-ollama-test--with-stub stub "novision"
      (let ((result (eimg-ocr-ollama-test--run-cli
                     (list "--backend" "ollama"
                           "--ollama-model" "text-only-model"
                           "--ollama-url" (eimg-ocr-ollama-test--url stub)
                           "test/fixtures/hello.png")
                     data-dir)))
        (should (equal 2 (nth 0 result)))
        (should (string-match-p "不支持视觉" (nth 2 result)))))))

;;;; ── C. missing：模型未安装 ────────────────────────────────────────────

(ert-deftest eimg-ocr-ollama-test-missing-model-lists-installed ()
  "missing 模式（`/api/show` → 404 + error）：退出码 2，stderr 含「未安装」与「已装」。
「已装」那一半证明失败分支确实走了一次 `GET /api/tags'——只断言「未安装」的话，
「完全不查已装列表」的实现也能通过。"
  (skip-unless (eimg-ocr-ollama-test--ready-p))
  (eimg-ocr-ollama-test--with-data-dir data-dir
    (eimg-ocr-ollama-test--with-stub stub "missing"
      (let ((result (eimg-ocr-ollama-test--run-cli
                     (list "--backend" "ollama"
                           "--ollama-model" "no-such-model-xyz"
                           "--ollama-url" (eimg-ocr-ollama-test--url stub)
                           "test/fixtures/hello.png")
                     data-dir)))
        (should (equal 2 (nth 0 result)))
        (should (string-match-p "未安装" (nth 2 result)))
        (should (string-match-p "已装" (nth 2 result)))
        ;; 已装列表来自 `/api/tags` 的固定应答；名字出现即证明那次请求发生了。
        (should (string-match-p "stub-model" (nth 2 result)))))))

;;;; ── D. 未配置模型：不发网络请求就短路 ────────────────────────────────

(ert-deftest eimg-ocr-ollama-test-unconfigured-model ()
  "不给 `--ollama-model'（且 `XDG_DATA_HOME' 指向空目录）→ 退出码 2，stderr 含
「未配置 ollama 模型」。
这条**刻意不起 stub**：CLI 的「未配置模型」分支不应发任何网络请求，故没有服务
也必须是同一句文案（若它先去连服务，这里会变成「服务不可达」而变红）。"
  (skip-unless (eimg-ocr-ollama-test--ready-p))
  (eimg-ocr-ollama-test--with-data-dir data-dir
    (let ((result (eimg-ocr-ollama-test--run-cli
                   (list "--backend" "ollama" "test/fixtures/hello.png")
                   data-dir)))
      (should (equal 2 (nth 0 result)))
      (should (string-match-p "未配置 ollama 模型" (nth 2 result))))))

;;;; ── E. 扩展名白名单：非 png/jpg/jpeg 一律拒 ───────────────────────────

(ert-deftest eimg-ocr-ollama-test-rejects-unsupported-suffix ()
  "`.webp' 输入 → 退出码 3，stderr 含「只支持 png/jpg/jpeg」。
`.webp' 在 CLI 的 `SUPPORTED_SUFFIXES' 里（故能通过输入校验），是 ollama 分支自己的
白名单把它拦下——这正是要钉的那一层：没有 PIL 无法转码，明确拒绝优于静默失败。"
  (skip-unless (eimg-ocr-ollama-test--ready-p))
  (let ((image (make-temp-file "eimg-ollama-test-" nil ".webp")))
    (unwind-protect
        (eimg-ocr-ollama-test--with-data-dir data-dir
          (eimg-ocr-ollama-test--with-stub stub "vision"
            ;; 先让探测走通（vision 模式），确保拦下的是扩展名而不是「后端不可用」。
            (let ((result (eimg-ocr-ollama-test--run-cli
                           (list "--backend" "ollama"
                                 "--ollama-model" "stub-model"
                                 "--ollama-url" (eimg-ocr-ollama-test--url stub)
                                 image)
                           data-dir)))
              (should (equal 3 (nth 0 result)))
              (should (string-match-p "只支持 png/jpg/jpeg" (nth 2 result))))))
      (ignore-errors (delete-file image)))))

;;;; ── G. 围栏剥离：VLM 把答案塞进 ``` 块 ────────────────────────────

(ert-deftest eimg-ocr-ollama-test-fenced-content-stripped ()
  "`fenced` 模式（content 被 ``` 围栏包裹）→ 退出码 0，stdout 不含围栏、含两行中文。
真实 VLM 即使被提示词明令禁止也常加围栏，`_strip_code_fence' 必须真的生效：
只断言「有这两行」的话，把围栏当正文输出也能过。"
  (skip-unless (eimg-ocr-ollama-test--ready-p))
  (eimg-ocr-ollama-test--with-data-dir data-dir
    (eimg-ocr-ollama-test--with-stub stub "fenced"
      (let* ((result (eimg-ocr-ollama-test--run-cli
                      (list "--backend" "ollama"
                            "--ollama-model" "stub-model"
                            "--ollama-url" (eimg-ocr-ollama-test--url stub)
                            "test/fixtures/hello.png")
                      data-dir))
             (stdout (nth 1 result)))
        (should (equal 0 (nth 0 result)))
        (should-not (string-match-p "```" stdout))
        (should (string-match-p "第一行文字" stdout))
        (should (string-match-p "第二行文字" stdout))))))

;;;; ── H. 重定向与响应体上限：一律拒绝 ──────────────────────────────────

(ert-deftest eimg-ocr-ollama-test-redirect-rejected ()
  "`redirect` 模式（`/api/chat` → 302）→ 退出码 4，stderr 含「已拒绝跟随」。
跟随重定向等于把**带整张图片 base64 的请求体**发去 `Location` 指向的任意主机，
所以定向在识别路径上是硬失败（4），不是「换个地址再试」。"
  (skip-unless (eimg-ocr-ollama-test--ready-p))
  (eimg-ocr-ollama-test--with-data-dir data-dir
    (eimg-ocr-ollama-test--with-stub stub "redirect"
      (let ((result (eimg-ocr-ollama-test--run-cli
                     (list "--backend" "ollama"
                           "--ollama-model" "stub-model"
                           "--ollama-url" (eimg-ocr-ollama-test--url stub)
                           "test/fixtures/hello.png")
                     data-dir)))
        (should (equal 4 (nth 0 result)))
        (should (string-match-p "已拒绝跟随" (nth 2 result)))))))

(ert-deftest eimg-ocr-ollama-test-oversized-response-rejected ()
  "`huge` 模式（`Content-Length` 声明 32 MB、body 十几字节）→ 退出码 4，含「响应体过大」。
stub 只声明不真传：实现必须先按 header 拒绝，才谈得上「不把 32 MB 读进内存」——
若实现改成「先读完再判大小」，这条用例的耗时也会暴露它。"
  (skip-unless (eimg-ocr-ollama-test--ready-p))
  (eimg-ocr-ollama-test--with-data-dir data-dir
    (eimg-ocr-ollama-test--with-stub stub "huge"
      (let ((result (eimg-ocr-ollama-test--run-cli
                     (list "--backend" "ollama"
                           "--ollama-model" "stub-model"
                           "--ollama-url" (eimg-ocr-ollama-test--url stub)
                           "test/fixtures/hello.png")
                     data-dir)))
        (should (equal 4 (nth 0 result)))
        (should (string-match-p "响应体过大" (nth 2 result)))))))

;;;; ── I. URL 入口校验 + 脱敏 ──────────────────────────────────────────

(ert-deftest eimg-ocr-ollama-test-rejects-non-http-url ()
  "`--ollama-url ftp://…` → 退出码 5（参数错误），stderr 含「只支持 http/https」。
只收 http/https 是安全边界：别的 scheme 交给 `urllib` 会开完全不同的行为（读本地
文件 / 走 FTP 驱动）。这条也钉住「不是退出码 2」——参数错与后端不可用必须可区分。"
  (skip-unless (eimg-ocr-ollama-test--ready-p))
  (eimg-ocr-ollama-test--with-data-dir data-dir
    (let ((result (eimg-ocr-ollama-test--run-cli
                   (list "--backend" "ollama"
                         "--ollama-url" "ftp://127.0.0.1:1"
                         "--ollama-model" "stub-model"
                         "test/fixtures/hello.png")
                   data-dir)))
      (should (equal 5 (nth 0 result)))
      (should (string-match-p "只支持 http/https" (nth 2 result))))))

(ert-deftest eimg-ocr-ollama-test-rejects-url-with-credentials ()
  "`--ollama-url http://user:secret@…` → 退出码 5，且 stderr **不含** `secret'。
命令以 `user:pass@` 形式带凭据时，那个地址会原样进 stderr / `*eimg-ocr-backends*`
buffer 与用户贴出的排障日志——所以入口直接拒，而不是「能用但悄悄脱敏」。
断言「不含 secret」是这条用例的重点：只断言退出码，把密码进日志的实现也能通过。"
  (skip-unless (eimg-ocr-ollama-test--ready-p))
  (eimg-ocr-ollama-test--with-data-dir data-dir
    (let* ((result (eimg-ocr-ollama-test--run-cli
                    (list "--backend" "ollama"
                          "--ollama-url" "http://user:secret@127.0.0.1:1"
                          "--ollama-model" "stub-model"
                          "test/fixtures/hello.png")
                    data-dir))
           (stderr (nth 2 result)))
      (should (equal 5 (nth 0 result)))
      (should (string-match-p "不支持 user:pass@" stderr))
      (should-not (string-match-p "secret" stderr)))))

(ert-deftest eimg-ocr-ollama-test-config-url-credentials-not-leaked ()
  "config.json 里的地址带 `user:pass@` 时，输出里也绝不能出现密码。
这条走**绕过 `--ollama-url` 入口校验**的路径：config.json 来源的坏地址不抛退出码 5，
而是折成「ollama 不可用」（`probe_backends` 里那段 catch）。也就是说 `_mask_url'
是这条路径上唯一的防线——它不是「校验已拦住所以不需要」的冗余，而是兜底。
同理，config.json 也可能是 `bin/eimg-ocr-setup` 之外的人手工写的。"
  (skip-unless (eimg-ocr-ollama-test--ready-p))
  (eimg-ocr-ollama-test--with-data-dir data-dir
    (let ((config-dir (expand-file-name "eimg" data-dir))
          (config (expand-file-name "eimg/config.json" data-dir)))
      (make-directory config-dir t)
      (with-temp-file config
        ;; 手写 JSON 而不 `json-encode'：`json.el' 不是本文件的依赖，测试夹具为这个
        ;; 引一个 require 不值得。
        (insert "{\"ollama_model\": \"stub-model\","
                " \"ollama_url\": \"http://user:secret@127.0.0.1:1\"}"))
      (let ((result (eimg-ocr-ollama-test--run-cli
                     (list "--list-backends")
                     data-dir)))
        (should (equal 0 (nth 0 result)))
        (should-not (string-match-p "secret" (nth 1 result)))
        (should-not (string-match-p "secret" (nth 2 result)))))))

;;;; ── J. 图片过大：退出码 3（输入不可读） ─────────────────────────────

(ert-deftest eimg-ocr-ollama-test-oversized-image-rejected ()
  "34 MB 的 `.png' → 退出码 3，stderr 含「文件过大」。
用 `truncate -s 34M' 造**稀疏**文件：内容全零、实际不占盘，几毫秒完成；真写 34 MB
会让这条用例变成 IO 基准测试。判的是 `stat().st_size'，与内容无关。
后端必须可用（vision stub），否则会先落「后端不可用」（2）而测不到大小检查。"
  (skip-unless (eimg-ocr-ollama-test--ready-p))
  (skip-unless (executable-find "truncate"))
  (let ((image (make-temp-file "eimg-ollama-test-huge-" nil ".png")))
    (unwind-protect
        (progn
          (should (equal 0 (call-process "truncate" nil nil nil
                                         "-s" "34M" image)))
          (eimg-ocr-ollama-test--with-data-dir data-dir
            (eimg-ocr-ollama-test--with-stub stub "vision"
              (let ((result (eimg-ocr-ollama-test--run-cli
                             (list "--backend" "ollama"
                                   "--ollama-model" "stub-model"
                                   "--ollama-url" (eimg-ocr-ollama-test--url stub)
                                   image)
                             data-dir)))
                (should (equal 3 (nth 0 result)))
                (should (string-match-p "文件过大" (nth 2 result)))))))
      (ignore-errors (delete-file image)))))

;;;; ── K. `--list-backends` 的行顺序（rapidocr → ollama → tesseract） ──

(ert-deftest eimg-ocr-ollama-test-list-backends-order ()
  "`--list-backends` 三行顺序固定，ollama 行夹在 rapidocr 与 tesseract 之间。
顺序是 `auto' 的优先级契约（rapidocr 中文截图质量最好 → ollama VLM → tesseract
兜底），不是排版偏好：顺序变了 `auto' 选的后端就变了。
只断言行号关系，**不断言 rapidocr / tesseract 的可用性**——那取决于跑测试的机器装了什么。"
  (skip-unless (eimg-ocr-ollama-test--ready-p))
  (eimg-ocr-ollama-test--with-data-dir data-dir
    (eimg-ocr-ollama-test--with-stub stub "vision"
      (let* ((result (eimg-ocr-ollama-test--run-cli
                      (list "--list-backends"
                            "--ollama-model" "stub-model"
                            "--ollama-url" (eimg-ocr-ollama-test--url stub))
                      data-dir))
             (lines (split-string (nth 1 result) "\n" t))
             (rapidocr (cl-position-if (lambda (line) (string-prefix-p "rapidocr:" line))
                                       lines))
             (ollama (cl-position-if (lambda (line) (string-prefix-p "ollama:" line))
                                     lines))
             (tesseract (cl-position-if (lambda (line) (string-prefix-p "tesseract:" line))
                                        lines)))
        (should (equal 0 (nth 0 result)))
        (should rapidocr)
        (should ollama)
        (should tesseract)
        (should (< rapidocr ollama))
        (should (< ollama tesseract))
        ;; stub 是 vision 模式，故 ollama 这一行必须是 available=true——否则上面的
        ;; 行号断言在「探测全挂」的机器上也绿了，测不到顺序之外的东西。
        (should (string-match-p "available=true" (nth ollama lines)))))))

;;;; ── F. 收尾不变量：不留 stub 进程 ────────────────────────────────────

(ert-deftest eimg-ocr-ollama-test-no-leftover-processes ()
  "跑完不留 `ollama-stub' 进程：先查当前是否有残留，再自己走一遍「起 → 关」。
自身起一次是必要的——只查「现在没有」，在别的用例恰好没起进程时也会绿；
ERT 的批次顺序不保证本文件内的定义顺序，故这条不能指望「前面用例刚跑过」。"
  (skip-unless (eimg-ocr-ollama-test--ready-p))
  (should-not (eimg-ocr-ollama-test--stub-processes))
  (let ((stub (eimg-ocr-ollama-test--start-stub "vision")))
    (unwind-protect
        (progn
          (should (eimg-ocr-ollama-test--wait-port (cdr stub)))
          (should (= 1 (length (eimg-ocr-ollama-test--stub-processes)))))
      (eimg-ocr-ollama-test--stop-stub (car stub))))
  ;; `delete-process' 已把进程从 `process-list' 摘掉；轮询一次以防实现细节变化。
  (let ((deadline (+ (float-time) 2.0)))
    (while (and (eimg-ocr-ollama-test--stub-processes) (< (float-time) deadline))
      (accept-process-output nil 0.05)))
  (should-not (eimg-ocr-ollama-test--stub-processes)))

(provide 'eimg-ocr-ollama-test)

;;; eimg-ocr-ollama-test.el ends here
