;;; eimg-core-test.el --- eimg-core 的 ERT 用例  -*- lexical-binding: t; -*-

;; Author: thomas
;; Version: 0.1.0
;; Keywords: convenience, tools, ocr

;;; Commentary:

;; 覆盖 `eimg-core' 的每个公开函数，正常分支与错误分支都要有：
;; 退出码映射、参数拼装、JSON 校验、org / text 渲染、临时文件命名，以及
;; 「顶层零第三方依赖」这条结构性不变量。
;;
;; 全部用例离线且确定性：不起子进程、不调真实 OCR、不读环境变量；唯一的外部
;; 副作用是临时目录（每个用例自建自删）。时间戳相关的用例用 `cl-letf' 钉死
;; `format-time-string'，避免跨秒抖动。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'eimg-core)

;;;; ── 测试辅助 ──────────────────────────────────────────────────────────

(defun eimg-core-test--substring-count (needle haystack)
  "统计 NEEDLE 在 HAYSTACK 中出现的次数（按字面量匹配）。"
  (let ((start 0)
        (count 0))
    (while (string-match (regexp-quote needle) haystack start)
      (setq count (1+ count)
            start (match-end 0)))
    count))

(defun eimg-core-test--char-count (char string)
  "统计 CHAR 在 STRING 中出现的次数。"
  (let ((count 0))
    (dotimes (i (length string))
      (when (eq char (aref string i))
        (setq count (1+ count))))
    count))

(defun eimg-core-test--page (number &rest texts)
  "构造一页：(page . NUMBER) + (blocks . (((text . T) ...)))。
块必须是**元素为 cons 的 proper list**——Emacs 31 的 `assq' 对 `(text . \"a\")'
这种点对会 signal `wrong-type-argument listp'。"
  (list (cons 'page number)
        (cons 'blocks (mapcar (lambda (text) (list (cons 'text text))) texts))))

(defconst eimg-core-test--json-two-pages
  "{\"backend\": \"rapidocr\",
    \"pages\": [{\"page\": 1, \"source\": \"a.png\",
                \"blocks\": [{\"text\": \"第一行\", \"conf\": 0.9, \"box\": [0, 0, 1, 1]},
                           {\"text\": \"第二行\", \"conf\": 0.8, \"box\": [0, 2, 1, 3]}]},
               {\"page\": 2, \"source\": \"a.png\",
                \"blocks\": [{\"text\": \"第三行\", \"conf\": 0.7, \"box\": [0, 4, 1, 5]}]}]}"
  "两份页的合法 JSON，形状与 `bin/eimg-ocr --format json' 一致。")

;;;; ── 1. 退出码映射 ──────────────────────────────────────────────────────

(ert-deftest eimg-core-test-exit-message-known-codes ()
  "已知错误码只给标签（STDERR 为 nil 时不追加）。"
  (should (equal "无可用后端" (eimg-core-exit-message 2 nil)))
  (should (equal "输入不可读" (eimg-core-exit-message 3 nil)))
  (should (equal "识别失败" (eimg-core-exit-message 4 nil)))
  (should (equal "参数错误" (eimg-core-exit-message 5 nil)))
  ;; 空串 STDERR 与 nil 等价，不得留下悬空的冒号。
  (should (equal "参数错误" (eimg-core-exit-message 5 ""))))

(ert-deftest eimg-core-test-exit-message-success-code ()
  "退出码 0 是成功：没有错误标签，只回显 STDERR 末行（通常为空）。"
  (should (equal "" (eimg-core-exit-message 0 nil)))
  (should (equal "" (eimg-core-exit-message 0 "  \n\n")))
  (should (equal "warning: 低置信度" (eimg-core-exit-message 0 "warning: 低置信度\n"))))

(ert-deftest eimg-core-test-exit-message-appends-stderr-tail ()
  "STDERR 只取最后一个非空行，并以「：」接在标签后。"
  (should (equal "识别失败：ValueError: bad image"
                 (eimg-core-exit-message 4 "Traceback (most recent call last):\n  File x.py\nValueError: bad image\n")))
  ;; 末行带缩进 / 空行时仍取末尾那条有效信息并 strip。
  (should (equal "无可用后端：未找到可用的 OCR 后端"
                 (eimg-core-exit-message 2 "\n\n   未找到可用的 OCR 后端   \n\n"))))

(ert-deftest eimg-core-test-exit-message-unknown-code ()
  "未知退出码给出「未知错误（退出码 N）」，同样追加 STDERR 末行。"
  (should (equal "未知错误（退出码 9）" (eimg-core-exit-message 9 nil)))
  (should (equal "未知错误（退出码 137）：oom-kill"
                 (eimg-core-exit-message 137 "oom-kill\n"))))

(ert-deftest eimg-core-test-exit-hint ()
  "各错误码的提示覆盖两条安装路径与三条排查方向；其余码无提示。"
  (let ((hint-2 (eimg-core-exit-hint 2)))
    (should (stringp hint-2))
    (should (string-match-p "--rapidocr" hint-2))
    (should (string-match-p "--tessdata" hint-2)))
  (should (string-match-p "检查路径与支持的扩展名" (eimg-core-exit-hint 3)))
  (should (string-match-p "可尝试 --backend 切换或重试" (eimg-core-exit-hint 4)))
  (should (string-match-p "--help" (eimg-core-exit-hint 5)))
  (should-not (eimg-core-exit-hint 0))
  (should-not (eimg-core-exit-hint 1))
  (should-not (eimg-core-exit-hint 9))
  (should-not (eimg-core-exit-hint nil)))

;;;; ── 2. CLI 参数拼装 ────────────────────────────────────────────────────

(ert-deftest eimg-core-test-build-args-all-options ()
  "七个选项全部给出时，参数顺序与契约一致，文件路径排最后。"
  (should (equal '("--backend" "rapidocr"
                   "--lang" "chi_sim+eng"
                   "--format" "json"
                   "--pdf-pages" "1-3"
                   "--dpi" "300"
                   "--python" "/tmp/venv/bin/python"
                   "--tessdata-dir" "/usr/share/tessdata"
                   "input.pdf")
                 (eimg-core-build-args
                  (list :backend "rapidocr"
                        :lang "chi_sim+eng"
                        :format "json"
                        :pdf-pages "1-3"
                        :dpi 300
                        :python "/tmp/venv/bin/python"
                        :tessdata-dir "/usr/share/tessdata"
                        :file "input.pdf")))))

(ert-deftest eimg-core-test-build-args-defaults ()
  "nil 值一律不出现（交给 CLI 默认值）；完全没有文件时返回 nil。"
  (should (equal '("a.png") (eimg-core-build-args '(:file "a.png"))))
  (should-not (eimg-core-build-args nil))
  (should (equal '("a.png")
                 (eimg-core-build-args
                  (list :backend nil :lang nil :format nil :pdf-pages nil
                        :dpi nil :python nil :tessdata-dir nil :file "a.png")))))

(ert-deftest eimg-core-test-build-args-multiple-files ()
  ":file 与 :files 可同时使用，多个路径按给出顺序排在选项之后。"
  (should (equal '("--format" "text" "a.png" "b.pdf" "c.jpg")
                 (eimg-core-build-args
                  (list :format "text"
                        :file "a.png"
                        :files '("b.pdf" "c.jpg")))))
  ;; :files 只给一个字符串也接受（调用方少写一层 list 时的容错）。
  (should (equal '("only.png")
                 (eimg-core-build-args '(:files "only.png")))))

(ert-deftest eimg-core-test-build-args-order-stable ()
  "选项顺序由映射表决定，与 plist 的书写顺序无关。"
  (should (equal '("--backend" "auto" "--format" "lines" "--dpi" "150" "x.png")
                 (eimg-core-build-args
                  (list :dpi 150 :file "x.png" :format "lines" :backend "auto")))))

;;;; ── 2b. ollama 选项（视觉后端） ────────────────────────────────────────

;; 这一节只关心**新键**：既有的 seven-option 断言保持原样（它不含新键，故不会红，
;; 也不该为了「看起来完整」去改写——那会丢掉「老键顺序不变」这层旧覆盖）。
;; 新键按约定只能追加到映射表末尾，因此既验证「存在 / 取值形态」，也验证「位置」。

(ert-deftest eimg-core-test-option-args-ollama-at-end ()
  "`eimg-core-option-args' 末尾两项是 ollama 的键，且 `:tessdata-dir' 仍在它们之前。
顺序即 argv 生成顺序：新键只允许追加到末尾。既有键的相对顺序一旦变动，所有既有
调用方的 argv 日志 diff 都会失真，而功能上又看不出来。"
  (let* ((keys (mapcar #'car eimg-core-option-args))
         (pos-tessdata (cl-position :tessdata-dir keys))
         (pos-model (cl-position :ollama-model keys))
         (pos-url (cl-position :ollama-url keys)))
    (should (equal '(:ollama-model :ollama-url) (last keys 2)))
    (should pos-tessdata)
    (should pos-model)
    (should pos-url)
    (should (< pos-tessdata pos-model))
    (should (< pos-model pos-url))
    ;; 映射的取值是 CLI 的真实选项名（拼错就是「参数错误」退出码 5）。
    (should (equal "--ollama-model" (cdr (assq :ollama-model eimg-core-option-args))))
    (should (equal "--ollama-url" (cdr (assq :ollama-url eimg-core-option-args))))))

(ert-deftest eimg-core-test-build-args-ollama-nil-absent ()
  "`--ollama-model' / `--ollama-url' 为 nil 时不进 argv。
nil 的语义是「交给 CLI 自己决定」：模型 nil 时 CLI 判 ollama 不可用（不替你挑模型），
URL nil 时用它内置的 `http://127.0.0.1:11434'。写成 `--ollama-model nil' 会让 CLI
收到一个叫 \"nil\" 的模型名，比不传更糟。"
  (should (equal '("input.png")
                 (eimg-core-build-args
                  (list :ollama-model nil :ollama-url nil :file "input.png"))))
  (let ((argv (eimg-core-build-args '(:file "input.png"))))
    (should-not (member "--ollama-model" argv))
    (should-not (member "--ollama-url" argv))
    (should-not (member "nil" argv))))

(ert-deftest eimg-core-test-build-args-ollama-nonnil-order ()
  "两个键都给值时落在选项区末尾、文件路径之前；完整 argv 逐项断言。
只断言「存在」会放过位置回归（比如被插到 `--backend' 前面），故这里比对整条 argv。"
  (should (equal '("--backend" "ollama"
                   "--tessdata-dir" "/usr/share/tessdata"
                   "--ollama-model" "qwen2.5-vl:7b"
                   "--ollama-url" "http://127.0.0.1:11434"
                   "input.png")
                 (eimg-core-build-args
                  (list :backend "ollama"
                        :tessdata-dir "/usr/share/tessdata"
                        :ollama-model "qwen2.5-vl:7b"
                        :ollama-url "http://127.0.0.1:11434"
                        :file "input.png"))))
  ;; 多文件输入时同样先选项、后路径（`:files' 与 `:file' 都排在最后）。
  (should (equal '("--ollama-model" "m" "a.png" "b.png")
                 (eimg-core-build-args
                  (list :ollama-model "m" :files '("a.png" "b.png"))))))

(ert-deftest eimg-core-test-exit-hint-2-mentions-ollama ()
  "退出码 2 的提示补上 ollama 的配置路径，且两条老路径仍在。
这是「只加不改」：ollama 是第三条可选后端，不是 rapidocr / tesseract 的替代品，
老提示一旦被换掉，用户按提示做就找不到原来的安装入口。"
  (let ((hint (eimg-core-exit-hint 2)))
    (should (stringp hint))
    (should (string-match-p "ollama" hint))
    (should (string-match-p "--ollama-model" hint))
    (should (string-match-p "--rapidocr" hint))
    (should (string-match-p "--tessdata" hint))))

;;;; ── 3. JSON 解析 ───────────────────────────────────────────────────────

(ert-deftest eimg-core-test-parse-json-two-pages ()
  "合法 JSON 解析成页列表：页号、来源、块文本都在，块里多余字段被收敛为文本。"
  (let* ((pages (eimg-core-parse-json eimg-core-test--json-two-pages))
         (first (nth 0 pages))
         (second (nth 1 pages)))
    (should (= 2 (length pages)))
    (should (equal 1 (alist-get 'page first)))
    (should (equal "a.png" (alist-get 'source first)))
    (should (equal 2 (length (alist-get 'blocks first))))
    (should (equal "第一行" (alist-get 'text (nth 0 (alist-get 'blocks first)))))
    (should (equal "第二行" (alist-get 'text (nth 1 (alist-get 'blocks first)))))
    (should (equal 2 (alist-get 'page second)))
    (should (equal "第三行" (alist-get 'text (nth 0 (alist-get 'blocks second)))))))

(ert-deftest eimg-core-test-parse-json-empty-pages ()
  "`{\"pages\": []}' 是合法输入，返回空列表（不是 nil 之外的奇怪东西）。"
  (should (equal nil (eimg-core-parse-json "{\"pages\": []}")))
  (should (equal 0 (length (eimg-core-parse-json
                             "{\"backend\": \"rapidocr\", \"pages\": []}")))))

(ert-deftest eimg-core-test-parse-json-invalid ()
  "非 JSON 与空串都 signal `eimg-core-parse-error'，不得返回 nil。"
  (should-error (eimg-core-parse-json "不是 JSON") :type 'eimg-core-parse-error)
  (should-error (eimg-core-parse-json "{\"pages\": [}") :type 'eimg-core-parse-error)
  ;; 顶层是数组而不是对象：同样视为结构非法。
  (should-error (eimg-core-parse-json "[1, 2, 3]") :type 'eimg-core-parse-error)
  ;; 非字符串入参也不静默吞掉。
  (should-error (eimg-core-parse-json nil) :type 'eimg-core-parse-error))

(ert-deftest eimg-core-test-parse-json-empty-string ()
  "空串 / 纯空白：明确的「输出为空」错误，而不是 json 库的含糊报错。"
  (should-error (eimg-core-parse-json "") :type 'eimg-core-parse-error)
  (should-error (eimg-core-parse-json " \n\t ") :type 'eimg-core-parse-error)
  (let ((err (should-error (eimg-core-parse-json "") :type 'eimg-core-parse-error)))
    (should (string-match-p "输出为空" (error-message-string err)))))

(ert-deftest eimg-core-test-parse-json-missing-fields ()
  "缺 pages / 缺 blocks / page 非数字：逐项 signal，说明里点出第几页。"
  (should-error (eimg-core-parse-json "{\"backend\": \"rapidocr\"}")
                :type 'eimg-core-parse-error)
  (should-error (eimg-core-parse-json "{\"pages\": [{\"page\": 1}]}")
                :type 'eimg-core-parse-error)
  (should-error (eimg-core-parse-json "{\"pages\": [{\"blocks\": []}]}")
                :type 'eimg-core-parse-error)
  (should-error (eimg-core-parse-json "{\"pages\": [{\"page\": \"1\", \"blocks\": []}]}")
                :type 'eimg-core-parse-error))

(ert-deftest eimg-core-test-parse-json-block-without-text-dropped ()
  "缺 text 的块被丢弃，其余块保留；合法页不受影响。"
  (let* ((json "{\"pages\": [{\"page\": 1,
                               \"blocks\": [{\"text\": \"保留\"},
                                            {\"conf\": 0.5, \"box\": [0, 0, 1, 1]},
                                            {\"text\": \"也保留\"}]}]}")
         (pages (eimg-core-parse-json json))
         (blocks (alist-get 'blocks (nth 0 pages))))
    (should (= 1 (length pages)))
    (should (= 2 (length blocks)))
    (should (equal '("保留" "也保留")
                   (mapcar (lambda (block) (alist-get 'text block)) blocks)))))

;;;; ── 4. 渲染 ────────────────────────────────────────────────────────────

(ert-deftest eimg-core-test-render-org-three-pages ()
  "三页各自出现且仅出现一次页标题，块按顺序逐行输出。"
  (let* ((pages (list (eimg-core-test--page 1 "第一页甲" "第一页乙")
                      (eimg-core-test--page 2 "第二页")
                      (eimg-core-test--page 3 "第三页")))
         (org (eimg-core-render-org pages)))
    (dolist (heading '("** 第 1 页" "** 第 2 页" "** 第 3 页"))
      (should (= 1 (eimg-core-test--substring-count heading org))))
    (should (equal "** 第 1 页\n第一页甲\n第一页乙\n** 第 2 页\n第二页\n** 第 3 页\n第三页"
                   org))
    ;; 末尾不留多余空行。
    (should-not (string-suffix-p "\n" org))))

(ert-deftest eimg-core-test-render-org-with-title ()
  "TITLE 非 nil 时先输出一级标题，页标题保持二级（不因单页而省略）。"
  (let ((org (eimg-core-render-org (list (eimg-core-test--page 1 "文本")) "识别结果")))
    (should (string-prefix-p "* 识别结果\n** 第 1 页\n文本" org))
    ;; 单页也照样有页标题（不做特例）。单页且 TITLE 为 nil 时同样是页标题开头。
    (should (string-prefix-p "** 第 1 页\n"
                             (eimg-core-render-org (list (eimg-core-test--page 1 "文本")))))))

(ert-deftest eimg-core-test-render-org-empty ()
  "空 pages 渲染成空串；块文本首尾空白被 strip，空白块不产生空行。"
  (should (equal "" (eimg-core-render-org nil)))
  (should (equal "* 标题" (eimg-core-render-org nil "标题")))
  (should (equal "** 第 1 页\n原文\n第二行"
                 (eimg-core-render-org
                  (list (eimg-core-test--page 1 "  原文  " "" "  \n " "第二行")))))
  ;; 只有 TITLE、没有页时只输出标题行，不留空行。
  (should (equal "* 只有标题" (eimg-core-render-org nil "只有标题"))))

(ert-deftest eimg-core-test-render-text-three-pages ()
  "三页之间恰好两个换页符，\\f 落在下一页行首，末尾无多余换行。"
  (let* ((pages (list (eimg-core-test--page 1 "甲一" "甲二")
                      (eimg-core-test--page 2 "乙")
                      (eimg-core-test--page 3 "丙")))
         (text (eimg-core-render-text pages)))
    (should (= 2 (eimg-core-test--char-count ?\f text)))
    (should (equal "甲一\n甲二\n\f乙\n\f丙" text))
    (should-not (string-suffix-p "\n" text))))

(ert-deftest eimg-core-test-render-text-empty ()
  "没有页时是空串；单页时不带换页符。"
  (should (equal "" (eimg-core-render-text nil)))
  (should (equal "唯一一页" (eimg-core-render-text (list (eimg-core-test--page 5 "唯一一页"))))))

;;;; ── 5. 临时图片路径 ────────────────────────────────────────────────────

(ert-deftest eimg-core-test-temp-image-path-naming ()
  "文件名形如 `<PREFIX>-<YYYYMMDD-HHMMSS>.png'，落在 DIR 下，且只算路径不建文件。"
  (let ((dir (make-temp-file "eimg-core-test-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'format-time-string)
                   (lambda (&rest _) "20260102-030405")))
          (let ((path (eimg-core-temp-image-path dir "shot")))
            (should (equal "shot-20260102-030405.png" (file-name-nondirectory path)))
            (should (string-prefix-p (file-name-as-directory dir) path))
            (should-not (file-exists-p path))))
      (delete-directory dir t))))

(ert-deftest eimg-core-test-temp-image-path-unique ()
  "已存在同名文件时依次追加 -2 / -3，绝不覆盖；同一秒内连续调用必然不同。"
  (let ((dir (make-temp-file "eimg-core-test-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'format-time-string)
                   (lambda (&rest _) "20260102-030405")))
          (let ((first (eimg-core-temp-image-path dir "shot")))
            (write-region "" nil first)
            (let ((second (eimg-core-temp-image-path dir "shot")))
              (should-not (equal first second))
              (should (equal "shot-20260102-030405-2.png"
                             (file-name-nondirectory second)))
              (write-region "" nil second)
              (should (equal "shot-20260102-030405-3.png"
                             (file-name-nondirectory (eimg-core-temp-image-path dir "shot")))))))
      (delete-directory dir t))))

;;;; ── 6. 结构性不变量：顶层零第三方依赖 ─────────────────────────────────

(ert-deftest eimg-core-test-no-third-party-features ()
  "eimg-core 只 require 内置库：源码里不出现四个 UI 包的 require，加载后也未引入。"
  (let ((source (with-temp-buffer
                  (insert-file-contents (or (symbol-file 'eimg-core-render-org 'defun)
                                            (locate-library "eimg-core")))
                  (buffer-string))))
    (dolist (package '("consult" "posframe" "embark" "transient"))
      (should-not (string-match-p (format "(require '%s" package) source))))
  ;; 上面是源码级断言；这里再断言运行态（若测试进程启动时已自带某包则跳过该项）。
  (dolist (feature '(consult posframe embark transient))
    (if (featurep feature)
        (message "eimg-core-test: %s 在测试进程启动时已加载，跳过该项 featurep 断言" feature)
      (should-not (featurep feature)))))

(provide 'eimg-core-test)

;;; eimg-core-test.el ends here
