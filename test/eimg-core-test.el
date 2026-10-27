;;; eimg-core-test.el --- eimg-core 的 ERT 用例  -*- lexical-binding: t; -*-

;; Author: thomas
;; Version: 0.1.0
;; Keywords: convenience, tools, ocr

;;; Commentary:

;; 覆盖 `eimg-core' 的每个公开函数，正常分支与错误分支都要有：
;; 退出码映射、参数拼装（含页图目录选项）、JSON 校验（含 `image' 字段保留）、
;; 块坐标框、图片尺寸换算、org / text 渲染、临时文件命名，以及
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
  "ollama 的两个键都排在 `:tessdata-dir' 之后，且只允许更晚的键追加到它们后面。
顺序即 argv 生成顺序：既有键的相对顺序一旦变动，所有既有调用方的 argv 日志 diff
都会失真，而功能上又看不出来。注意此用例原本断言「ollama 两键是最后两项」，在
`:page-images-dir' 按约定追加到末尾后该断言必然失效——故改成断言**不变量本身**
（新键只能往后加、老键相对顺序不变），而不是钉死「谁是最后一项」。"
  (let* ((keys (mapcar #'car eimg-core-option-args))
         (pos-tessdata (cl-position :tessdata-dir keys))
         (pos-model (cl-position :ollama-model keys))
         (pos-url (cl-position :ollama-url keys))
         (pos-page-images (cl-position :page-images-dir keys)))
    (should pos-tessdata)
    (should pos-model)
    (should pos-url)
    (should (< pos-tessdata pos-model))
    (should (< pos-model pos-url))
    ;; 更新的键只允许追加在 ollama 之后（`last' 取末尾，即「最新追加的」）。
    (when pos-page-images
      (should (< pos-url pos-page-images)))
    (should (equal :page-images-dir (car (last keys))))
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

;;;; ── 2c. 页图输出选项（--page-images-dir） ─────────────────────────────

;; 这一节只覆盖 `:page-images-dir'：CLI 收到它时会在**每页**多写一个 `image' 键
;; （该页对应图片的绝对路径），联动视图靠它定位原图；不传时 json 的字段集合与
;; 旧版完全一致。本层只管「怎么拼进 argv」，选项语义属于 CLI。

(ert-deftest eimg-core-test-build-args-page-images-dir-position ()
  "`--page-images-dir' 落在 `--ollama-url' 之后、文件路径之前，取值原样透传。
位置用下标逐项断言：只断言「存在」会放过「被插到选项区开头」这类回归。"
  (let ((argv (eimg-core-build-args
               (list :ollama-url "http://127.0.0.1:11434"
                     :page-images-dir "/tmp/x"
                     :file "input.pdf"))))
    (should (equal '("--ollama-url" "http://127.0.0.1:11434"
                     "--page-images-dir" "/tmp/x"
                     "input.pdf")
                   argv))
    (should (< (cl-position "--ollama-url" argv :test #'equal)
               (cl-position "--page-images-dir" argv :test #'equal)))
    (should (< (cl-position "--page-images-dir" argv :test #'equal)
               (cl-position "input.pdf" argv :test #'equal)))))

(ert-deftest eimg-core-test-build-args-page-images-dir-nil-absent ()
  "`:page-images-dir' 为 nil 时不进 argv（不传就保持旧版 json 字段集合）。
写成 `--page-images-dir nil' 会让 CLI 拿到一个叫 \"nil\" 的目录名，比不传更糟。"
  (should (equal '("input.png")
                 (eimg-core-build-args
                  '(:page-images-dir nil :file "input.png"))))
  (should-not (member "--page-images-dir"
                      (eimg-core-build-args '(:file "input.png"))))
  ;; 只有选项、没有文件时也照样拼出来（拼接不依赖文件是否存在）。
  (should (equal '("--page-images-dir" "/tmp/x")
                 (eimg-core-build-args '(:page-images-dir "/tmp/x")))))

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

(ert-deftest eimg-core-test-parse-json-keeps-image-field ()
  "`--page-images-dir' 带出的 `image' 字段归一化后仍在，`blocks' 仍在首位。
归一化的实现是「摘掉 blocks 再拼回最前、其余键原样跟随」，所以 `image' 会被保住；
而它是联动视图定位原图的唯一线索——一旦被归一化吃掉，框选就只剩坐标没有图。
这条用例是**回归保护**：将来若把归一化改成正向白名单（只挑 page / source /
blocks），它会立刻变红。"
  (let* ((json "{\"pages\": [{\"page\": 1, \"source\": \"a.png\",
                               \"blocks\": [{\"text\": \"t\"}],
                               \"image\": \"/abs/a.png\"}]}")
         (page (car (eimg-core-parse-json json))))
    (should (equal "/abs/a.png" (alist-get 'image page)))
    ;; 键顺序即实际行为：blocks 在最前（归一化时重新拼上去），其余键保持原序。
    (should (equal '(blocks page source image) (mapcar #'car page)))
    (should (equal 1 (alist-get 'page page)))
    (should (equal "a.png" (alist-get 'source page)))
    (should (equal "t" (alist-get 'text (nth 0 (alist-get 'blocks page)))))
    ;; 不带 image 的输入不得凭空造出该字段（不传选项时字段集合与旧版一致）。
    (should-not (assq 'image (car (eimg-core-parse-json
                                   "{\"pages\": [{\"page\": 1, \"blocks\": []}]}"))))))

;;;; ── 3b. 块坐标框（block-box） ──────────────────────────────────────────

;; 坐标来自第三方 OCR（rapidocr 给像素、tesseract 给像素或比例，diff 都可能带浮点），
;; 脏数据必须降级成「这一个块没有框」，绝不能整页 signal——故这一节的重点是
;; **异常输入一律 nil 且不抛错**。

(ert-deftest eimg-core-test-block-box-valid ()
  "合法 box 返回前四个数：整型、浮点、超长截断、零与负数都接受。"
  (should (equal '(1 2 3 4)
                 (eimg-core-block-box '((text . "a") (box . (1 2 3 4))))))
  ;; 浮点坐标：别用 `integerp' 过滤，否则 tesseract 的比例坐标会被整批丢掉。
  (should (equal '(1.5 2.5 3.5 4.5)
                 (eimg-core-block-box '((text . "a") (box . (1.5 2.5 3.5 4.5))))))
  ;; 多于四个元素（未来可能带角度 / 多边形顶点）：只取前四个，不报错。
  (should (equal '(1 2 3 4)
                 (eimg-core-block-box '((box . (1 2 3 4 5 6))))))
  ;; 归一化后的真实块形状：text / conf 之外仍能取到 box。
  (should (equal '(0 0 1 1)
                 (eimg-core-block-box '((text . "t") (conf . 0.9) (box . (0 0 1 1))))))
  ;; 0 是合法坐标（左上角）；负数出现在旋转 / 裁剪场景，本层不额外过滤。
  (should (equal '(0 -2 10 10)
                 (eimg-core-block-box '((box . (0 -2 10 10)))))))

(ert-deftest eimg-core-test-block-box-invalid ()
  "缺 box / nil / 字符串 / 不足四个 / 含非数字：一律返回 nil，绝不 signal。
`should-not' 本身也覆盖了「不报错」这层——signal 会让用例失败而不是返回 nil。"
  (should-not (eimg-core-block-box '((text . "a"))))
  (should-not (eimg-core-block-box '((text . "a") (box . nil))))
  (should-not (eimg-core-block-box '((box . "1 2 3 4"))))
  (should-not (eimg-core-block-box '((box . (1 2 3)))))
  (should-not (eimg-core-block-box '((box . (1 2 3 nil)))))
  (should-not (eimg-core-block-box '((box . (1 2 3 "4")))))
  (should-not (eimg-core-block-box '((box . (1 2 3 x)))))
  ;; 空 box：空列表是合法 proper list 但长度为 0，同样不属于可用坐标。
  (should-not (eimg-core-block-box '((box . ()))))
  (should-not (eimg-core-block-box nil))
  ;; 点对 box（`(1 . 2)'）不是 proper list：不能走 `length' 而抛
  ;; `wrong-type-argument listp'，必须仍然安静返回 nil。
  (should-not (eimg-core-block-box (list (cons 'box (cons 1 2)))))
  ;; BLOCK 本身不是 alist（字符串 / 数字）时也不炸。
  (should-not (eimg-core-block-box "junk"))
  (should-not (eimg-core-block-box 42)))

;;;; ── 3c. 图片尺寸换算（fit-size） ────────────────────────────────────────

;; 规则：scale = min(1.0, 宽上限/宽, 高上限/高)，再夹到 ≥ 0.01；px 由 `round'
;; 得出并至少 1。字符单位 → 像素的换算与 frame 相关，留在调用方，本层只做像素算术。

(ert-deftest eimg-core-test-fit-size-no-scaling ()
  "上限不小于实际尺寸时不放大：scale 恒 1.0，px 等于原尺寸。"
  (should (equal '(:scale 1.0 :px-w 100 :px-h 50)
                 (eimg-core-fit-size 100 50 200 200)))
  ;; 恰好等于上限同样是 1.0（「刚好装得下」不该被算成一次缩放）。
  (should (equal '(:scale 1.0 :px-w 100 :px-h 50)
                 (eimg-core-fit-size 100 50 100 50))))

(ert-deftest eimg-core-test-fit-size-width-limited ()
  "宽受限时按宽度比缩放，高度等比跟随（纵横比不变）。"
  (should (equal '(:scale 0.5 :px-w 50 :px-h 25)
                 (eimg-core-fit-size 100 50 50 200))))

(ert-deftest eimg-core-test-fit-size-height-limited ()
  "高受限时按高度比缩放；两个方向都算，取更小的那个比值。"
  (should (equal '(:scale 0.5 :px-w 50 :px-h 25)
                 (eimg-core-fit-size 100 50 200 25)))
  ;; 宽度上限极宽松，也不能把吃紧的高度拉回 1.0。
  (should (equal '(:scale 0.25 :px-w 25 :px-h 25)
                 (eimg-core-fit-size 100 100 1000 25))))

(ert-deftest eimg-core-test-fit-size-single-limit ()
  "只给一个上限时另一个方向完全不受限；非正整数上限等同「不限制」。"
  (should (equal '(:scale 0.5 :px-w 50 :px-h 25)
                 (eimg-core-fit-size 100 50 50 nil)))
  (should (equal '(:scale 0.5 :px-w 50 :px-h 25)
                 (eimg-core-fit-size 100 50 nil 25)))
  ;; 0 / 负数 / 字符串不能被当成「缩到 0 像素」或「按字符串比」。
  (should (equal '(:scale 1.0 :px-w 100 :px-h 50)
                 (eimg-core-fit-size 100 50 0 -1)))
  (should (equal '(:scale 1.0 :px-w 100 :px-h 50)
                 (eimg-core-fit-size 100 50 "200" nil))))

(ert-deftest eimg-core-test-fit-size-no-limit ()
  "两个上限都为 nil：scale 1.0、px 等于原尺寸（等价于「不缩放」而非「算不出来」）。"
  (should (equal '(:scale 1.0 :px-w 800 :px-h 600)
                 (eimg-core-fit-size 800 600 nil nil))))

(ert-deftest eimg-core-test-fit-size-invalid-dimensions ()
  "WIDTH / HEIGHT 非正整数时返回 nil（调用方据此降级），且不 signal。
像素尺寸通常来自 `image-size'；拿不到尺寸时应当是「无图 / 不缩放」，不是崩溃。"
  (should-not (eimg-core-fit-size 0 50 10 10))
  (should-not (eimg-core-fit-size 100 0 10 10))
  (should-not (eimg-core-fit-size -1 50 10 10))
  (should-not (eimg-core-fit-size 100 -50 10 10))
  (should-not (eimg-core-fit-size "100" 50 10 10))
  (should-not (eimg-core-fit-size nil 50 10 10))
  (should-not (eimg-core-fit-size 100 nil 10 10))
  ;; 浮点尺寸同样拒绝：整数像素是本函数的输入契约。
  (should-not (eimg-core-fit-size 100.0 50 10 10)))

(ert-deftest eimg-core-test-fit-size-extreme ()
  "极端缩放（1×1 上限）时 scale 不为 0（避免除零），且 px 至少 1 个像素。
scale 被夹到 0.01 后与 px 不再自洽（100 像素按 0.01 应该是 1，而 1000 像素按
0.01 是 10）；docstring 已声明 px 才是显示尺寸的权威值，scale 只表示「缩过」。"
  (let ((fit (eimg-core-fit-size 100 50 1 1)))
    (should fit)
    (should (= 0.01 (plist-get fit :scale)))
    (should (> (plist-get fit :scale) 0))
    (should (>= (plist-get fit :px-w) 1))
    (should (>= (plist-get fit :px-h) 1))
    (should (integerp (plist-get fit :px-w)))
    (should (integerp (plist-get fit :px-h))))
  ;; 更大的图也不会缩成 0 像素：钳位后仍按 0.01 给像素数。
  (let ((fit (eimg-core-fit-size 100000 100000 1 1)))
    (should (= 0.01 (plist-get fit :scale)))
    (should (= 1000 (plist-get fit :px-w)))
    (should (= 1000 (plist-get fit :px-h)))))

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
