;;; eimg-core.el --- eimg 纯逻辑层：退出码、参数拼装、输出解析与渲染  -*- lexical-binding: t; byte-compile-warnings: (not unresolved noruntime) -*-

;; Author: thomas
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, tools, ocr
;; URL: https://github.com/awerdx520/eimg

;;; Commentary:

;; 本文件承载 eimg 的**纯逻辑**：只做「数据结构 → 字符串 / 参数列表」的转换，
;; 不启动子进程、不碰 buffer、不读环境变量，因此可以完全离线地用 ERT 覆盖。
;;
;; 职责边界（与 `bin/eimg-ocr' 的 CLI 契约一一对应）：
;;   - 退出码 → 用户可读文案 + 排障提示（`eimg-core-exit-message' / `eimg-core-exit-hint'）
;;   - plist → CLI 参数列表（`eimg-core-build-args'）
;;   - CLI 的 json 输出 → 页 / 块结构（`eimg-core-parse-json'）
;;   - 页 / 块结构 → org 或纯文本（`eimg-core-render-org' / `eimg-core-render-text'）
;;   - 块坐标框与图片尺寸换算（`eimg-core-block-box' / `eimg-core-fit-size'）
;;   - 临时文件命名（`eimg-core-temp-image-path'）
;;
;; 两条设计约束，改动时不要打破：
;;   1. **顶层零第三方依赖**：只 require 内置库。本文件会被 headless 的 `emacs -Q'
;;      测试进程加载，顶层 require 任何第三方 UI 包（补全 / 预览 / 菜单 / 弹窗
;;      四类）都会让 `make test' 直接失败——它们不在 `emacs -Q' 的 load-path 上。
;;   2. **不引用任何宿主配置的常量**（如宿主 Emacs 配置仓库的 `init-const'）：目录、
;;      版本一类的东西由调用方（`eimg-ocr.el' / `eimg-capture.el'）传参或自行 setq。

;;; Code:

(require 'subr-x)
(require 'json)

(define-error 'eimg-core-parse-error "eimg JSON 解析错误")

;;;; ── 0. 自定义组（全包唯一） ─────────────────────────────────────────────

;; 全包的 `defgroup' 只在这里定义一次，其它模块一律 `:group 'eimg'`。
;; 为什么不让各模块各写一份：`defgroup' 带 `:prefix` 与 `:group 'tools'`，
;; 重复定义会让 `customize-group` 的父子关系随加载顺序漂移；而且 `eimg-core'
;; 是唯一被所有模块（含 `eimg-ocr'）require 的底层，放在这里能保证任何模块
;; 求值 `defcustom' 时组已存在。
(defgroup eimg nil
  "截图与 OCR 一体化工具包。"
  :group 'tools
  :prefix "eimg-")

;;;; ── 1. 退出码映射（单一事实来源） ──────────────────────────────────────

;; 这张表是退出码语义的**唯一**来源：CLI 侧的常量（bin/eimg-ocr 的 EXIT_*）、
;; 交互层的错误提示、README 的退出码表都应与此处保持一致。值 nil 表示该码不是
;; 错误（0 = 成功），不属于「缺失」。
(defconst eimg-core-exit-codes
  '((0 . nil)
    (2 . "无可用后端")
    (3 . "输入不可读")
    (4 . "识别失败")
    (5 . "参数错误"))
  "退出码到文案标签的映射，与 `bin/eimg-ocr' 的退出码契约一致。")

(defconst eimg-core-exit-hints
  '((2 . "没有可用的 OCR 后端：跑 bin/eimg-ocr-setup --rapidocr 装 Python 后端，或跑 bin/eimg-ocr-setup --tessdata 补齐 tesseract 语言数据（先跑 bin/eimg-ocr-setup --check 可看缺什么）；或配置 ollama 视觉模型（--ollama-model / config.json 的 ollama_model）后走 ollama 后端")
    (3 . "输入不可读：检查路径与支持的扩展名（png/jpg/jpeg/webp/bmp/tif/tiff/gif/pdf）")
    (4 . "识别失败：可尝试 --backend 切换或重试（换后端 / 提高 --dpi）")
    (5 . "参数错误：查看 --help 确认取值与语法"))
  "退出码到排障提示的映射；未列出的码没有提示。")

(defun eimg-core--last-line (text)
  "取 TEXT 中最后一个非空行（去掉首尾空白）。
TEXT 为 nil 或全是空白时返回 nil。为什么取末行：CLI 与后端都把最具体的错误
放在 stderr 末尾，首行往往只是「Traceback (most recent call last):」。"
  (when (stringp text)
    (let (result)
      (dolist (line (split-string text "\n"))
        (let ((trimmed (string-trim line)))
          (unless (string-empty-p trimmed)
            (setq result trimmed))))
      result)))

(defun eimg-core-exit-message (code stderr)
  "由退出码 CODE 与 STDERR 拼出给用户看的完整错误文案。
已知码取 `eimg-core-exit-codes' 的标签，未知码给出「未知错误（退出码 N）」；
能取到 STDERR 末行时以「：」续接。CODE 为 0（成功，标签为 nil）时只返回
STDERR 末行（没有则空串）——成功路径不应显示「成功」这种噪音。"
  (let* ((known (assq code eimg-core-exit-codes))
         (base (cond ((null known) (format "未知错误（退出码 %s）" code))
                     (t (or (cdr known) ""))))
         (tail (eimg-core--last-line stderr)))
    (cond ((string-empty-p base) (or tail ""))
          (tail (concat base "：" tail))
          (t base))))

(defun eimg-core-exit-hint (code)
  "返回针对退出码 CODE 的排障提示；没有对应提示时返回 nil。"
  (cdr (assq code eimg-core-exit-hints)))

;;;; ── 2. CLI 参数拼装 ────────────────────────────────────────────────────

;; 选项顺序是**固定**的（plist 的书写顺序不参与决定）：先所有选项、后文件路径。
;; 顺序固定的理由是可预测——ERT 能逐项断言，日志里两次调用也能直接 diff。
(defconst eimg-core-option-args
  '((:backend      . "--backend")
    (:lang         . "--lang")
    (:format       . "--format")
    (:pdf-pages    . "--pdf-pages")
    (:dpi          . "--dpi")
    (:python       . "--python")
    (:tessdata-dir . "--tessdata-dir")
    (:ollama-model . "--ollama-model")
    (:ollama-url   . "--ollama-url")
    (:page-images-dir . "--page-images-dir"))
  "plist 关键字到 CLI 选项名的映射；顺序即参数生成顺序。")

(defun eimg-core--arg-value (value)
  "把配置值 VALUE 转成 argv 里的单个字符串。
字符串原样、数字转十进制、符号取名字；列表用「+」连接（tesseract 多语言语法
`chi_sim+eng'）。`:pdf-pages' 请直接传字符串（如 \"1-5\"），CLI 只认这一种语法。"
  (cond ((stringp value) value)
        ((numberp value) (number-to-string value))
        ((symbolp value) (symbol-name value))
        ((listp value) (mapconcat #'eimg-core--arg-value value "+"))
        (t (format "%s" value))))

(defun eimg-core--as-list (value)
  "把 VALUE 归一成列表（字符串视为单元素）；nil 归一为 nil。"
  (cond ((null value) nil)
        ((listp value) value)
        (t (list value))))

(defun eimg-core-build-args (plist)
  "把配置 PLIST 转成传给 `bin/eimg-ocr' 的参数列表。
只输出非 nil 的选项——nil 表示「用 CLI 的默认值」，此时绝不能把选项写进
argv（CLI 的默认值随版本演进，本层不该替它决定）。文件路径（`:file' 与
`:files'，可多个）恒排在所有选项之后。"
  (let (args)
    (dolist (entry eimg-core-option-args)
      (let ((value (plist-get plist (car entry))))
        (when value
          (setq args (append args (list (cdr entry) (eimg-core--arg-value value)))))))
    (append args
            (eimg-core--as-list (plist-get plist :file))
            (eimg-core--as-list (plist-get plist :files)))))

;;;; ── 3. JSON 输出解析 ───────────────────────────────────────────────────

(defun eimg-core--parse-error (format-string &rest args)
  "以 `eimg-core-parse-error' 抛出格式化后的说明。
为什么不用「返回 nil 让调用方判断」：nil 会被上层当成「没有识别结果」而与
「CLI 输出损坏」混为一谈，用户看到的会是「空结果」而不是「解析失败」。"
  (signal 'eimg-core-parse-error (list (apply #'format format-string args))))

(defun eimg-core--normalize-page (index page)
  "校验并归一化第 INDEX（0-based）页 PAGE，返回新的 alist。
归一化的含义：只保留 `page' / `source' / `blocks' 等原有键，`blocks' 换成
「校验后、剔除缺 text 项」的列表；每个块是**完整的 alist**（`text' 之外的字
段如 conf / box 原样保留，供将来的框选 / 高亮使用）。
注意块必须是元素为 cons 的 proper list（`((text . \"a\") (conf . 0.9))'），
不能是 `(text . \"a\")' 这样的点对：Emacs 31 的 `assq'/`alist-get' 对非
proper list 会 signal `wrong-type-argument listp'。"
  (unless (and (listp page) (consp page))
    (eimg-core--parse-error "第 %d 个 page 不是对象" (1+ index)))
  (let ((number (alist-get 'page page))
        (blocks (assq 'blocks page)))
    (unless (numberp number)
      (eimg-core--parse-error "第 %d 个 page 缺少数字型 page 字段" (1+ index)))
    (unless blocks
      (eimg-core--parse-error "第 %d 个 page 缺少 blocks 字段" (1+ index)))
    (unless (listp (cdr blocks))
      (eimg-core--parse-error "第 %d 个 page 的 blocks 不是数组" (1+ index)))
    (let (kept)
      (dolist (block (cdr blocks))
        (cond
         ((not (and (listp block) (consp block)))
          (eimg-core--parse-error "第 %d 页存在非对象的 block" number))
         ((not (assq 'text block))
          ;; 缺 text 的块没有可渲染内容：丢弃而不是整份报错（CLI 未来可能加
          ;; 纯图形块），丢弃是向前兼容的最小代价。
          nil)
         (t
          (let* ((text (alist-get 'text block))
                 (text (if (stringp text) text (eimg-core--arg-value text))))
            (push (cons (cons 'text text) (assq-delete-all 'text block)) kept)))))
      (append (list (cons 'blocks (nreverse kept)))
              (assq-delete-all 'blocks page)))))

(defun eimg-core-parse-json (string)
  "解析 `bin/eimg-ocr --format json' 的输出 STRING，返回页列表。
每页形如 ((page . 1) (source . \"a.png\") (blocks . (((text . \"...\")) ...)))。
空串 / 非 JSON / 结构非法一律 `signal' `eimg-core-parse-error'（带说明），
不返回 nil；`{\"pages\": []}' 属合法输入，返回空列表。"
  (unless (stringp string)
    (eimg-core--parse-error "输出不是字符串（%S）" string))
  (when (string-empty-p (string-trim string))
    (eimg-core--parse-error "输出为空"))
  (let ((data (condition-case err
                  (json-parse-string string :object-type 'alist :array-type 'list)
                (error
                 (eimg-core--parse-error "不是合法 JSON：%s"
                                         (error-message-string err))))))
    (unless (and (listp data) (consp data))
      (eimg-core--parse-error "JSON 顶层不是对象"))
    (let ((cells (assq 'pages data)))
      (unless cells
        (eimg-core--parse-error "JSON 缺少 pages 字段"))
      (unless (listp (cdr cells))
        (eimg-core--parse-error "pages 不是数组"))
      (let ((index 0))
        (mapcar (lambda (page)
                  (prog1 (eimg-core--normalize-page index page)
                    (setq index (1+ index))))
                (cdr cells))))))

;;;; ── 3b. 结构工具：块的坐标框与图片尺寸换算 ────────────────────────────

;; 这两个函数都不产生渲染结果，只把「结构 → 可直接用的数值」这一步收敛到一处，
;; 让预览（`eimg-preview'）与联动高亮（`eimg-ocr'）共享同一套换算与容错。
;; 为什么必须放在纯逻辑层：它们只做算术与取值，不需要 frame / buffer / 子进程，
;; 因而能被离线 ERT 直接覆盖——联动视图最易出错的正是这些边界值。

(defun eimg-core-block-box (block)
  "取 BLOCK 的坐标框，返回 \(X0 Y0 X1 Y1\) 四数列表；取不到可用坐标时返回 nil。
BLOCK 是 `eimg-core-parse-json' 归一化后的块 alist（如
\(\(text . \"a\") (conf . 0.9) (box . \(1 2 3 4\))\)\)。判定条件是 `box' 为长度
≥ 4 的 proper list 且前四个元素都是数（rapidocr 与 tesseract 都可能给浮点，
坐标可能是像素也可能是归一化比例——本层不解释单位，只保证是四个数），此时
返回前四个数的列表；超长列表截断到前四个。

**任何异常输入都返回 nil，绝不 signal**：box 缺失、box 为 nil、box 是字符串、
元素不足四个、含 nil 或字符串等。理由：坐标来自第三方 OCR 输出，损坏的坐标
只该让「这一个块没有框」，不该让整页渲染失败——整页失败会让用户连文本都看不到，
代价远大于少画一个框。"
  (when (consp block)
    (let* ((box (alist-get 'box block))
           (len (proper-list-p box)))
      (when (and len
                 (>= len 4)
                 (numberp (nth 0 box))
                 (numberp (nth 1 box))
                 (numberp (nth 2 box))
                 (numberp (nth 3 box)))
        (list (nth 0 box) (nth 1 box) (nth 2 box) (nth 3 box))))))

(defun eimg-core-fit-size (width height max-width max-height)
  "把图片像素尺寸 WIDTH × HEIGHT 按显示上限 MAX-WIDTH / MAX-HEIGHT 换算缩放比。
返回 plist \(:scale S :px-w W :px-h H\)；WIDTH 或 HEIGHT 不是正整数时返回 nil。
MAX-WIDTH / MAX-HEIGHT 为 nil 或非正整数表示该方向不限制（只给一个上限即可只
限制一个方向，两个都给 nil 时 S 恒为 1.0）。
用途：联动视图要把图片缩到窗口内显示、预览要把大图缩到帧里，两处需要同一套
「上限 → 缩放比 + 目标像素尺寸」的换算，故收敛在这里复用。

约束与取舍：
  - 只做像素算术，**不读 frame 的字符宽度或窗口宽度**：字符单位到像素的换算
    依赖当前 frame 与本 buffer 的字体，属于调用方环境；本层保持纯逻辑，才能被
    `emacs -Q' 的离线用例覆盖。
  - WIDTH / HEIGHT 非法时返回 nil 而不报错：调用方拿 nil 就走「不缩放 / 无图」
    降级，一张尺寸未知的图片不该让整条流程失败。
  - S 恒 ≤ 1.0（不放大：放大会糊）且夹在 0.01 以上（避免 0 作为除数）。
  - 夹取后 S 可能与 `:px-w' / `:px-h' 不自洽（例如 1000×1000 压到 1×1 时
    S=0.001 被夹到 0.01，而 px 由 `round' 得出至少 1）。**调用方应以
    `:px-w' / `:px-h' 为准显示，S 只供日志与「是否发生过缩放」的判断参考**。"
  (when (and (integerp width) (> width 0)
             (integerp height) (> height 0))
    (let ((scale 1.0)
          (w-limit (and (integerp max-width) (> max-width 0)))
          (h-limit (and (integerp max-height) (> max-height 0))))
      (when w-limit
        (setq scale (min scale (/ (float max-width) width))))
      (when h-limit
        (setq scale (min scale (/ (float max-height) height))))
      (setq scale (max scale 0.01))
      (list :scale scale
            :px-w (max 1 (round (* width scale)))
            :px-h (max 1 (round (* height scale)))))))

;;;; ── 4. 渲染 ────────────────────────────────────────────────────────────

(defun eimg-core--block-texts (page)
  "取 PAGE 的块文本列表，逐块 strip 首尾空白并剔除 strip 后为空的块。
剔除空块的理由：空文本块渲染成空行只会让 org 结构出现无意义空行。"
  (let (texts)
    (dolist (block (alist-get 'blocks page))
      (let ((text (string-trim (or (alist-get 'text block) ""))))
        (unless (string-empty-p text)
          (push text texts))))
    (nreverse texts)))

(defun eimg-core-render-org (pages &optional title)
  "把 PAGES 渲染成 org 文本。
TITLE 非 nil 时先输出一级标题 `* TITLE'，每页是二级标题 `** 第 N 页'，
页内每块一行。单页也照样输出页标题（不给单页做特例），这样下游按标题切页的
逻辑对所有输入一致。空 PAGES 返回空串；末尾不留多余空行。"
  (let (lines)
    (when title
      (push (concat "* " title) lines))
    (dolist (page pages)
      (push (format "** 第 %s 页" (alist-get 'page page)) lines)
      (dolist (text (eimg-core--block-texts page))
        (push text lines)))
    (mapconcat #'identity (nreverse lines) "\n")))

(defun eimg-core-render-text (pages)
  "把 PAGES 渲染成与 CLI `--format text' 完全一致的纯文本。
每页内块之间换行、页尾一个换行；页间用 `\\f' 分隔，`\\f' 落在下一页行首
（与 pdftotext 的习惯一致，按行处理的下游才不会把两页当成一页）；整串末尾
不带多余换行。"
  (let ((body (mapconcat (lambda (page)
                           (concat (mapconcat #'identity
                                              (eimg-core--block-texts page)
                                              "\n")
                                   "\n"))
                         pages
                         "\f")))
    (string-remove-suffix "\n" body)))

;;;; ── 5. 临时文件命名 ────────────────────────────────────────────────────

(defun eimg-core-temp-image-path (dir prefix)
  "在 DIR 下生成 `PREFIX-YYYYMMDD-HHMMSS.png' 形式的新路径并返回（不创建文件）。
同名文件已存在时依次追加 `-2' `-3' …，保证同一秒内多次调用拿到不同路径，
绝不覆盖已有文件。时间戳只用本地日期时间：文件名里的可读时间比唯一性更
有用，唯一性由后缀兜住。"
  (let* ((dir (file-name-as-directory (expand-file-name dir)))
         (stem (concat prefix "-" (format-time-string "%Y%m%d-%H%M%S")))
         (path (expand-file-name (concat stem ".png") dir))
         (counter 1))
    (while (file-exists-p path)
      (setq counter (1+ counter)
            path (expand-file-name (format "%s-%d.png" stem counter) dir)))
    path))

(provide 'eimg-core)

;;; eimg-core.el ends here
