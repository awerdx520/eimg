;;; eimg-select.el --- 图片选择与预览：consult 多源候选、posframe 预览与尺寸换算  -*- lexical-binding: t; byte-compile-warnings: (not unresolved noruntime) -*-

;; Author: ThomasDon
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, tools, images
;; URL: https://github.com/awerdx520/eimg

;;; Commentary:

;; 本文件负责「从一堆图片里挑一张」这一层：候选构造（历史 + 递归扫描）、
;; 右侧标注、child frame 预览、以及候选项到真实路径的归一化。它不采集、不插入。
;;
;; 两条设计约束，改动时不要打破：
;;   1. **顶层零第三方依赖**：只 require 内置库（`cl-lib' / `image'）与同仓库的
;;      `eimg-core' / `eimg-capture'。consult / posframe 一律在函数体内
;;      `(require ... nil t)' 加 `fboundp' 守卫——它们在 headless 的
;;      `emacs -Q' 测试进程里不存在，顶层 require 会让 `make test' 直接失败。
;;   2. **预览失败一律降级，不向上抛错**：预览只是锦上添花，没有图形能力、
;;      没有 posframe、图片类型不受支持都只 `message' 或静默关闭，绝不让
;;      「挑图」这件事本身失败。

;;; Code:

(require 'cl-lib)
(require 'image)
(require 'eimg-core)
(require 'eimg-capture)

;;;; ── 1. 配置项 ──────────────────────────────────────────────────────────

(defcustom eimg-select-item-roots nil
  "「全部图片」候选的递归扫描根目录列表。

目录数量与深度直接决定选择界面的打开耗时（每次打开都全量扫描、无缓存）；
图片量增大后应只保留必要的根目录。"
  :type '(repeat directory)
  :group 'eimg)

(defcustom eimg-select-preview-max-width 700
  "预览与内联插入时图片的像素宽上限。

超出父 frame 可用区时会按 `eimg-select--preview-fit' 等比缩小，而不是把图
交给 posframe / 窗口静默裁剪。"
  :type 'integer
  :group 'eimg)

;;;; ── 2. 预览 ────────────────────────────────────────────────────────────

(defconst eimg-select--preview-buffer " *eimg-preview*"
  "预览用隐藏 buffer 名（前缀空格，不进入 buffer 列表）。")

(defun eimg-select--preview-fit
    (raw max-w fw lh cap-w cap-h border margin)
  "把图片原始像素尺寸 RAW 换算成预览所需尺寸（纯函数，无副作用，独立实现）。

RAW 为 `(WIDTH . HEIGHT)' 像素，非 (正整数 . 正整数) 时返回 nil；MAX-W 为图片
像素宽上限（非正整数表示不限制）；FW / LH 为单个字符的像素宽 / 高；CAP-W /
CAP-H 为父 frame 的**字符**宽 / 高；BORDER 为 child frame 单侧内部边框像素
宽；MARGIN 为额外预留的像素余量。

返回 plist：`:scale'（缩放比例，1.0 表示不缩放）、`:px-w' / `:px-h'（图片
目标像素尺寸）、`:chars-w' / `:chars-h'（posframe `:width' / `:height' 的字符
值，向上取整）。

为什么父 frame 的字符尺寸是硬上限：`posframe-show' 会把 `:width' / `:height'
再夹一道 `(min 值 (frame-width))' / `(min 值 (frame-height))'，超出的像素直接
不可见且不报错。故宁可等比缩小图片，也不交给 posframe 静默截断。字符值额外
加边框与余量后再 ceiling：宁可多占 1 字符，也不让图片被取整误差挤出 frame
边界（「最后一行图片像素不可见」的经典成因）。"
  (when (and (consp raw)
             (integerp (car raw)) (> (car raw) 0)
             (integerp (cdr raw)) (> (cdr raw) 0)
             (integerp fw) (> fw 0)
             (integerp lh) (> lh 0))
    (let* ((bw (* 2 (or border 0)))
           (mg (or margin 0))
           (cap-px-w (and (integerp cap-w) (> cap-w 0) (* cap-w fw)))
           (cap-px-h (and (integerp cap-h) (> cap-h 0) (* cap-h lh)))
           (usable-w (if cap-px-w
                         (max fw (- cap-px-w bw mg))
                       most-positive-fixnum))
           (usable-h (if cap-px-h
                         (max lh (- cap-px-h bw mg))
                       most-positive-fixnum))
           (width-cap (if (and (integerp max-w) (> max-w 0))
                          (/ (float max-w) (float (car raw)))
                        1.0))
           (scale (max 0.01
                       (min 1.0
                            width-cap
                            (/ (float usable-w) (float (car raw)))
                            (/ (float usable-h) (float (cdr raw))))))
           (px-w (max 1 (round (* (car raw) scale))))
           (px-h (max 1 (round (* (cdr raw) scale)))))
      (list :scale scale :px-w px-w :px-h px-h
            :chars-w (ceiling (+ px-w bw mg) fw)
            :chars-h (ceiling (+ px-h bw mg) lh)))))

(defun eimg-select--preview-hide ()
  "关闭图片预览 child frame；posframe 未加载时静默返回 nil。"
  (when (fboundp 'posframe-delete)
    (ignore-errors (posframe-delete eimg-select--preview-buffer)))
  nil)

(defun eimg-select--preview-display (path type)
  "在 child frame 中显示 PATH 指向的图片（TYPE 为 `image-supported-file-p' 结果）。"
  (let* ((raw (let ((max-image-size nil))
                (let ((spec (ignore-errors
                              (create-image path type nil :scale 1.0))))
                  (and spec (ignore-errors (image-size spec t))))))
         (fw (max 1 (frame-char-width)))
         (lh (max 1 (frame-char-height)))
         (fit (eimg-select--preview-fit
               raw eimg-select-preview-max-width
               fw lh (frame-width) (frame-height) 1 0))
         (px-w (plist-get fit :px-w))
         (px-h (plist-get fit :px-h))
         (chars-w (or (plist-get fit :chars-w) 1))
         (chars-h (or (plist-get fit :chars-h) 1))
         ;; 显式 `:scale 1.0'：`image-scaling-factor' 为 `auto' 时会在请求尺寸
         ;; 之上再乘一个缩放系数，导致图片比 frame 大、右侧与下沿被裁。
         (img (if fit
                  (create-image path type nil
                                :width px-w :height px-h :scale 1.0)
                (create-image path type nil :scale 1.0)))
         (buf (get-buffer-create eimg-select--preview-buffer))
         (frame nil))
    (with-current-buffer buf
      (erase-buffer)
      (insert-image img))
    (setq frame (posframe-show buf
                               :poshandler #'posframe-poshandler-frame-center
                               :background-color "white"
                               :internal-border-width 1
                               :internal-border-color "gray40"
                               :respect-mode-line nil
                               :left-fringe 0
                               :right-fringe 0
                               :width chars-w
                               :height chars-h))
    ;; `posframe-show' 在部分路径下返回 nil，按 `posframe-buffer' frame 参数反查。
    ;; 必须比对 buffer 名：其他包（consult / corfu / vertico-posframe 等）可能
    ;; 同时存在 posframe frame，只判「参数存在」会把我们的预览尺寸错调到别人
    ;; 的 frame 上（表现为预览位置/大小莫名其妙）。
    (unless (and (framep frame) (frame-live-p frame))
      (setq frame (cl-find-if
                   (lambda (f)
                     (and (framep f)
                          (equal (frame-parameter f 'posframe-buffer)
                                 eimg-select--preview-buffer)))
                   (frame-list))))
    ;; 像素级校正：`:width' / `:height' 是字符单位，取整必然留下几到几十像素
    ;; 误差；`set-frame-size' 带第三参数 t 是像素语义，可让 frame 精确贴合
    ;; 图片，保证不越出父 frame。
    (when (and fit (framep frame) (frame-live-p frame))
      (set-frame-size frame px-w px-h t))
    frame))

(defun eimg-select--preview-show (cand)
  "在 child frame 中预览候选 CAND 指向的图片。

失败一律降级，不向调用方抛错（预览只是锦上添花）：
- 无图形能力 → `message' 输出图片路径；
- posframe 不可用 → 同上；
- 文件不是受支持的图片类型（`image-supported-file-p' 为 nil）→ 关闭预览。
候选可能带 text property，内部一律 `expand-file-name' 还原路径，不依赖
consult 的属性还原行为（属其内部细节）。"
  (let* ((path (and (stringp cand) (expand-file-name cand)))
         (type (and path (image-supported-file-p path))))
    (cond
     ((null path) nil)
     ((null type) (eimg-select--preview-hide))
     ((not (display-graphic-p))
      (message "预览不可用（无图形能力）：%s" (abbreviate-file-name path))
      nil)
     ((not (and (require 'posframe nil t)
                (fboundp 'posframe-workable-p)
                (posframe-workable-p)))
      (message "预览不可用（posframe 不可用）：%s" (abbreviate-file-name path))
      nil)
     (t
      (condition-case err
          (eimg-select--preview-display path type)
        (error
         (message "图片预览失败：%s" (error-message-string err))
         (eimg-select--preview-hide)
         nil))))))

(defun eimg-select--preview-state ()
  "构造 consult 的 `:state' 函数（consult 的 `:state' 语义就是「无参构造函数」）。

返回的函数接收 `(ACTION CAND)'：ACTION 为 `preview' 时按 CAND 显示 / 隐藏
预览，为 `exit' 时关闭预览，其余动作忽略。内部一律 `expand-file-name'。"
  (lambda (action cand)
    (pcase action
      ('preview
       (if (and (stringp cand) (not (equal cand "")))
           (eimg-select--preview-show cand)
         (eimg-select--preview-hide)))
      ('exit (eimg-select--preview-hide))
      (_ nil))))

;;;; ── 3. 候选构造与归一化 ────────────────────────────────────────────────

(defun eimg-select--item-path (item)
  "由候选 ITEM 还原真实绝对路径。

优先取 `eimg/image-path' text property（`eimg-select--history-items' /
`eimg-select--all-image-items' 构造候选时写入），兜底 `expand-file-name'
（consult 会在预览前剥离属性：不依赖属性一定存在）。"
  (cond
   ((not (stringp item)) nil)
   ;; 空串不是路径：`(expand-file-name "")' 会返回 `default-directory'（一个
   ;; 目录），后续 `image-supported-file-p' / `insert' 都以「目录」为输入而
   ;; 失败得很难定位。consult 在输入被清空时可能给出 ""。
   ((equal item "") nil)
   ((get-text-property 0 'eimg/image-path item))
   (t (expand-file-name item))))

(defun eimg-select--mtime (path)
  "返回 PATH 的修改时间；取不到时返回纪元起点。"
  (or (ignore-errors (file-attribute-modification-time (file-attributes path)))
      (seconds-to-time 0)))

(defun eimg-select--annotate (cand)
  "为候选 CAND 生成右侧标注：修改时间 + 文件大小。"
  (let* ((path (eimg-select--item-path cand))
         (attrs (and path (file-exists-p path) (file-attributes path))))
    (when attrs
      (concat "  "
              (format-time-string "%Y-%m-%d %H:%M"
                                  (file-attribute-modification-time attrs))
              "  "
              (if (fboundp 'file-size-human-readable)
                  (file-size-human-readable (file-attribute-size attrs))
                (number-to-string (file-attribute-size attrs)))))))

(defun eimg-select--history-items ()
  "构造「截图」source 的候选列表（最新在前）。

候选用 `abbreviate-file-name' 显示的缩写路径，并带 `eimg/image-path' text
property 供动作还原真实路径；时间与大小交给 `eimg-select--annotate'。"
  (mapcar (lambda (path)
            (propertize (abbreviate-file-name path)
                        'eimg/image-path path))
          (eimg-capture--history-paths)))

(defun eimg-select--all-image-items ()
  "构造「全部图片」source 的候选列表（递归扫描，按修改时间倒序）。

扫描根为 `eimg-select-item-roots'，只保留 `image-supported-file-p' 认得的
文件（非图片扩展名在预览阶段必然失败，不该出现在候选里）。每次打开选择界面
都会全量扫描，无缓存——见 `eimg-select-item-roots' 的性能边界说明。"
  (let ((files nil))
    (dolist (root eimg-select-item-roots)
      (when (and (stringp root) (file-directory-p root))
        (setq files (append (directory-files-recursively root "" nil) files))))
    (setq files (cl-remove-duplicates files :test #'equal))
    (setq files (cl-remove-if-not (lambda (file)
                                    (and (file-regular-p file)
                                         (image-supported-file-p file)))
                                  files))
    (setq files (sort files (lambda (a b)
                              (time-less-p (eimg-select--mtime b)
                                           (eimg-select--mtime a)))))
    (mapcar (lambda (path)
              (propertize (abbreviate-file-name path)
                          'eimg/image-path path))
            files)))

(defun eimg-select--read (prompt)
  "带预览地选择一张图片，返回真实绝对路径；未选中返回 nil。

两个 source（`s' = 截图历史 / `a' = 全部图片，narrow 天然按 source 切换候选
集）：静态 table 下 `:narrow' 不重算候选集，故必须用 `consult--multi' 的
multi-source 形态。`:state' 传构造函数的调用结果（consult 期待 state 函数
本体）。consult 不可用时退化为 `completing-read'（无预览）。"
  (if (not (and (require 'consult nil t)
                (fboundp 'consult--multi)))
      (let* ((items (append (eimg-select--history-items)
                            (eimg-select--all-image-items)))
             (choice (and items (completing-read prompt items nil t))))
        (and choice (not (equal choice ""))
             (eimg-select--item-path choice)))
    (let* ((sources
            (list
             (list :name "截图"
                   :narrow ?s
                   :category 'eimg/image
                   :items #'eimg-select--history-items
                   :state #'eimg-select--preview-state
                   :annotate #'eimg-select--annotate)
             (list :name "全部图片"
                   :narrow ?a
                   :category 'eimg/image
                   :items #'eimg-select--all-image-items
                   :state #'eimg-select--preview-state
                   :annotate #'eimg-select--annotate)))
           (selected (car (consult--multi sources
                                         :prompt prompt
                                         :require-match t))))
      (and selected (eimg-select--item-path selected)))))

(defun eimg-select--paths (x)
  "把 embark target X 归一化成真实绝对路径列表。

只有登记在 `embark-multitarget-actions' 的 action 才会收到列表，普通 action
收到单个字符串，故所有自定义动作先过这里：string → 单元素列表，其余列表
原样，再逐项取真实路径。"
  (let ((items (cond ((stringp x) (list x))
                     ((listp x) x)
                     (t nil))))
    (delq nil (mapcar #'eimg-select--item-path items))))

(defun eimg-select--read-paths (selection)
  "把选择结果 SELECTION 归一化成真实绝对路径列表（string / list / nil）。"
  (eimg-select--paths selection))

(provide 'eimg-select)

;;; eimg-select.el ends here
