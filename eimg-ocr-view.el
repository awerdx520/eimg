;;; eimg-ocr-view.el --- eimg 联动视图：页图坐标框 + 文本列表双向联动  -*- lexical-binding: t; byte-compile-warnings: (not unresolved noruntime) -*-

;; Author: thomas
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, tools, ocr
;; URL: https://github.com/awerdx520/eimg

;;; Commentary:

;; 本文件把 `eimg-ocr' 结果 buffer 里的**结构化**识别结果（`eimg-ocr--result-data'
;; 的 `:pages'）变成一个人能对照的视图：上半部分是「原图（PDF 则是 CLI 栅格化后的
;; 页图）+ 每块文字的坐标框」，下半部分是该页的文本列表。文本行 ↔ 图上框双向联动。
;;
;; 三条硬约束（改动时不要打破）：
;;   1. **顶层零第三方依赖**：只 require 内置库（`cl-lib' / `subr-x'）与同包的
;;      `eimg-core' / `eimg-ocr'。本文件会被 `emacs -Q --batch -L .' 直接加载来验证
;;      「顶层零第三方依赖」，任何顶层 require 第三个包都会让那条验证失败。画 SVG
;;      也**不需要** `(require 'svg)'：SVG 在这里只是一段字符串，交给 `create-image'
;;      （`:type' 传 `svg'）即可；`svg' 库是「用 elisp 构造 DOM 再序列化」的另一条
;;      路，本文件不走那条路（少一层依赖，且字符串能被离线断言）。
;;   2. **依赖方向单向**：`eimg-ocr-view' → `eimg-ocr' → `eimg-core'。`eimg-ocr' 只在
;;      键位表里绑了 `eimg-ocr-view' 这个符号、**不** require 本文件（见该文件
;;      `eimg-ocr-mode-map' 上方的注释），本文件再 require 回去就成了顶层循环依赖。
;;   3. **只读 buffer**：视图 buffer 由 `special-mode' 派生（只读），一切写操作都在
;;      `(let ((inhibit-read-only t)) ...)' 里做，改完 `set-buffer-modified-p' 置 nil。
;;
;; 绘制与坐标（踩过的坑，别改回去）：
;;   - SVG 用 `viewBox="0 0 W H"'（W/H = 原图像素），底图 `<image>' 按 W×H 铺满，且
;;     **必须**带 `preserveAspectRatio="none"'——漏写时 librsvg 会等比居中，底图与框
;;     整体错位（T1 实测）。
;;   - `<rect>' 一律用**原图坐标**：缩放交给 `viewBox' 与 `create-image' 的
;;     `:width' / `:height'，代码里不出现第二套换算（两套换算迟早对不上）。
;;   - 元素顺序 `<image>' → `<rect>'（后续加 `<text>' 也必须排在标注之后）。
;;   - 一切 `create-image' / `image-size' 调用都包在 `(let ((max-image-size nil)) ...)'
;;     里：默认上限是 frame 的 10 倍，大图会被拒并返回 `(30 . 30)' 占位。
;;
;; 两种渲染路径（性能关键）：
;;   - `eimg-ocr-view--render'  重建文本 + 图片（换页、`g' 重取数据时用）
;;   - `eimg-ocr-view--refresh' 只重插图区（光标移动导致高亮变化时用）
;; 光标每动一格就重建整个 buffer，会让光标位置、窗口滚动、命令循环都跟着抖一下，
;; 所以轻量路径用两个 marker 卡住图区，只 `delete-region' + `insert-image'。
;;
;; 降级：没有识别结果时 `user-error'（并说明怎么恢复）；后端不给坐标（ollama）时只
;; 显示文本；找不到页图 / 读不出尺寸 / 读不出内容时同样只显示文本，并在图区写一行
;; 能读懂的原因——绝不静默显示空白图。
;;
;; 语义调整（RET）：计划原文写「跳到原图位置」，但原图是一整张 `image'，Emacs 无法
;; 在其中滚动定位（图片是不可分割的显示对象，没有「图片内位置」这个概念），故改为
;; 「复制当前块文本到 `kill-ring''——同一位置最有用的动作就是拿走那段文字。

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'eimg-core)
(require 'eimg-ocr)

;;;; ── 0. 自定义项、常量与 buffer 局部状态 ────────────────────────────────

(defcustom eimg-ocr-view-max-embed-bytes (* 8 1024 1024)
  "单页底图允许内嵌进 SVG 的原始字节上限（默认 8 MB）。
超过时不内嵌底图，改为只显示文本列表 + 可行动提示。
为什么用上限而不是降采样：Emacs 内置无法把图片缩放后导出字节（`create-image' 的
`:width' 只影响显示），真正降采样需要额外的图像后端；宁可明确降级，也不把几十 MB
的字符串塞进 SVG。"
  :type 'integer
  :group 'eimg)

(defconst eimg-ocr-view-buffer-name "*eimg-ocr-view*"
  "联动视图 buffer 的名字。
与结果 buffer（`eimg-ocr-buffer-name'）分开：视图是派生物，关掉它不该影响识别结果；
反过来 `g' 重取数据也要能从固定名字找回来，故用固定名而不是 `generate-new-buffer'。")

(defconst eimg-ocr-view--image-cache-limit 8
  "页图 base64 缓存的条目上限（超出即整体清空）。
一张 A4 页 200dpi 的 PNG 编码后有几 MB，而一次浏览通常只涉及一两页；给 8 条的上限
是为了兜住「来回翻页浏览整份 PDF」——那时新页不断进来，不设上限就是无界增长。
清空而不是逐条淘汰：`clrhash' 一行就够，而这层缓存丢了只是下一次多读一次盘。")

(defconst eimg-ocr-view--stroke "#00a0ff"
  "普通框的描边颜色（SVG 颜色值）。")

(defconst eimg-ocr-view--stroke-current "#ff3b30"
  "当前（高亮）框的描边颜色；与 `eimg-ocr-view--stroke' 必须不同，这是「光标在哪
一块」在图上的唯一提示。")

(defconst eimg-ocr-view--entry-property 'eimg-ocr-view-entry
  "文本行上标记「这块是 entries 里的第几个」的文本属性名。
取值是**扁平 entries 列表里的下标**（整数，全局唯一，跨页也唯一），于是
`post-command-hook' 只需一次 `get-text-property' 就能知道光标在哪一块。")

(defconst eimg-ocr-view--mime-types
  '(("png" . "image/png")
    ("jpg" . "image/jpeg")
    ("jpeg" . "image/jpeg")
    ("webp" . "image/webp")
    ("bmp" . "image/bmp")
    ("gif" . "image/gif")
    ("tif" . "image/tiff")
    ("tiff" . "image/tiff"))
  "页图扩展名到 data URI 的 MIME 类型（小写，无点）。
为什么按扩展名判而不是固定写 `image/png'：PDF 页图是 PNG，但单图输入的来源可能是
JPEG——把 JPEG 字节塞进 `data:image/png' 会在 librsvg 侧解不出来，表现为「图区一片
空白、框却还在」。未知扩展名按 `image/png' 兜底（CLI 只接受这几种输入格式）。")

(defvar eimg-ocr-view--image-cache (make-hash-table :test #'equal)
  "页图 base64 的缓存，键为 (路径 修改时间 大小)、值为编码后的字符串。
为什么不按路径缓存：同一路径的图可能被覆盖（重新识别写回同一临时目录），按
「路径 + mtime + size」判等能自动让旧缓存失效，不必手写失效逻辑。")

(defvar-local eimg-ocr-view--state nil
  "联动视图的 buffer 局部状态 plist；nil 表示还没渲染过。**每次读它都要容忍 nil**。
记住的键：
  `:origin'      来源结果 buffer 对象（`g' 从这里重取数据；用 buffer 对象而不是
                 名字，`buffer-live-p' 一眼就能判「来源已消失」）
  `:pages'       结果数据里的 PAGES（原样保存，换页时按 `:page-index' 取）
  `:meta'        结果数据里的 META（`:backend' 显示在模式行、`:source' 是单图输入时
                 的页图候选）
  `:entries'     扁平块列表，每个元素 plist `(:page-index I :block-index J :text T
                 :box BOX)'——页与块的两级结构拍平成一维，导航、文本属性、
                 `:current' 三者共用同一套下标
  `:page-index'  当前页在 `:pages' 里的下标（0-based）
  `:current'     当前块在 `:entries' 里的下标（0-based）
  `:geometry'    当前页图区的几何 plist `(:image :width :height :scale :px-w :px-h)'；
                 nil 表示本页画不出图（原因在 `:visual-hint'）
  `:visual-hint' 图区里那行提示文字（降级原因）；nil 表示有图可画
  `:image-start' / `:image-end'
                 图区在 buffer 里的范围（marker）。`--refresh' 只替换这一段，文本
                 列表与光标一概不动。
为什么用 plist 而不是七八个 `defvar-local'：这些字段永远同时被读改（换页时要同时更新
页号、几何、提示），拆成独立变量后「谁负责清几何」会在三处代码里各写一遍；一个 plist
让「换页」只有 `eimg-ocr-view--with-page' 一个入口。")

;;;; ── 1. 数据拍平与页/块取值 ──────────────────────────────────────────

;; 这一节只做「结果结构 → 视图要用的形状」，不碰 buffer，因而能被离线断言。

(defun eimg-ocr-view--entries (pages)
  "把 PAGES 拍平成块列表，每块一个 plist
`(:page-index I :block-index J :text T :box BOX)'。
`:text' 保留原文（含换行），复制（RET）走它；`:box' 取自
`eimg-core-block-box'，取不到可用坐标时为 nil（ollama 后端如此），此时该块只是
「列表里有、图上没有框」，不是错误。"
  (let ((entries nil)
        (page-index 0))
    (dolist (page pages)
      (let ((block-index 0))
        (dolist (block (alist-get 'blocks page))
          (let ((text (alist-get 'text block)))
            (push (list :page-index page-index
                        :block-index block-index
                        :text (if (stringp text) text (format "%s" text))
                        :box (eimg-core-block-box block))
                  entries))
          (setq block-index (1+ block-index))))
      (setq page-index (1+ page-index)))
    (nreverse entries)))

(defun eimg-ocr-view--page-entries (entries page-index)
  "返回 ENTRIES 里属于 PAGE-INDEX 的元素，每项 `(IDX . ENTRY)'；IDX 是全局下标。
为什么返回「全局下标 + entry」的 cons：图上的热区 ID、文本行属性、`:current' 用的
都是全局下标，任何一处再用页内序号就得来回换算，迟早错一位。"
  (let ((idx 0)
        result)
    (dolist (entry entries)
      (when (= (plist-get entry :page-index) page-index)
        (push (cons idx entry) result))
      (setq idx (1+ idx)))
    (nreverse result)))

(defun eimg-ocr-view--page-boxes (entries page-index)
  "返回 ENTRIES 里 PAGE-INDEX 页「有坐标」的块，每项 `(IDX . BOX)'。
该页一块坐标都没有时返回 nil——调用方据此走「只显示文本 + 一行提示」的降级路径。"
  (let ((items (eimg-ocr-view--page-entries entries page-index))
        result)
    (dolist (pair items)
      (let ((box (plist-get (cdr pair) :box)))
        (when box
          (push (cons (car pair) box) result))))
    (nreverse result)))

(defun eimg-ocr-view--display-text (text)
  "把块 TEXT 变成「一行」显示文本：去首尾空白，内部换行 / 制表符折成空格。
为什么必须压成一行：图上一个框对应列表里**一行**，这是「光标在第几行 = 在第几块」
的唯一依据（`post-command-hook' 从行首字符的属性取下标）。原文含换行时若不压，
一个块会占多行，联动就会错位；原文本身在 `:text' 里原样保留，复制不受影响。"
  (string-trim (replace-regexp-in-string "[\n\r\t]+" " " (or text ""))))

(defun eimg-ocr-view--entry-summary (entry limit)
  "把 ENTRY 的文本压成不超过 LIMIT 个字符的单行摘要（给热区 `help-echo' 用）。
为什么截断：tooltip 里塞整段文字会盖住图区，而 `help-echo' 的作用只是「点之前确认
一下是哪一块」。按字符截断对中文同样成立（`substring' 以字符为单位）。"
  (let ((text (eimg-ocr-view--display-text (plist-get entry :text))))
    (if (> (length text) limit)
        (concat (substring text 0 limit) "…")
      text)))

(defun eimg-ocr-view--page-image (page meta)
  "返回 PAGE 对应的页图路径；取不到返回 nil。
两级候选，顺序不能反：
  1. `page' 的 `image' 字段——只有 CLI 收到 `--page-images-dir'（PDF 输入）时才有，
     它是最准的（就是坐标所依据的那张位图）；
  2. META 的 `:source'——单图输入时坐标就来自用户给的那张图。**仅当它是存在的绝对
     路径**时才用：`:source' 可能只是文件名（CLI 收到的是 basename），相对路径无从
     解析，猜 `default-directory' 只会画出「别的目录里同名的另一张图」。"
  (let ((own (alist-get 'image page))
        (source (plist-get meta :source)))
    (cond
     ((and (stringp own) (not (string-empty-p own)) (file-exists-p own))
      (expand-file-name own))
     ((and (stringp source)
           (not (string-empty-p source))
           (file-name-absolute-p source)
           (file-exists-p source)
           (not (string-equal (downcase (or (file-name-extension source) ""))
                              "pdf")))
      (expand-file-name source))
     (t nil))))

;;;; ── 2. 尺寸换算与底图编码 ────────────────────────────────────────────

(defun eimg-ocr-view--display-window ()
  "返回本 buffer 所在窗口；没显示时退化为选中窗口。
退化是必要的：`eimg-ocr-view' 在 `display-buffer' **之前**就要决定图片尺寸，而那时
本 buffer 还没有窗口。用选中窗口的尺寸当代理，随后 `display-buffer' 会让出真实尺寸
（命令里因此把几何换算推迟到显示之后再算一次）。"
  (or (get-buffer-window (current-buffer) t) (selected-window)))

(defun eimg-ocr-view--limits ()
  "返回图区的可用像素上限 `(MAX-W . MAX-H)'。
高度只给窗口一半：视图 buffer 上半部分是图、下半部分是文本列表，图占满整个窗口就
等于把列表挤没了（而列表才是能用键盘操作的那一半）。宽度给满：横向多一像素也不影响
下面的列表。"
  (let* ((window (eimg-ocr-view--display-window))
         (width (max 1 (window-body-width window t)))
         (height (max 1 (window-body-height window t))))
    (cons width (max 1 (round (* 0.5 height))))))

(defun eimg-ocr-view--format-bytes (bytes)
  "把 BYTES 变成人能读的大小（如「12.3 MB」「900 B」）。
按 1024 进位、保留一位小数：提示里的数字只用来让人感觉「超了多少量级」，不需要
精确到字节。"
  (let ((value (float bytes)))
    (cond
     ((>= value (* 1024.0 1024.0 1024.0))
      (format "%.1f GB" (/ value (* 1024.0 1024.0 1024.0))))
     ((>= value (* 1024.0 1024.0))
      (format "%.1f MB" (/ value (* 1024.0 1024.0))))
     ((>= value 1024.0)
      (format "%.1f KB" (/ value 1024.0)))
     (t (format "%d B" bytes)))))

(defun eimg-ocr-view--image-size (path)
  "返回 PATH 的字节数；取不到返回 nil。
**只读元数据、不读内容**（`file-attributes' 走 stat）：高 DPI 扫描件一张几十 MB，
「先读进来再判断大小」会让内嵌上限要防的那笔开销正好发生在判断本身。"
  (let ((size (ignore-errors (file-attribute-size (file-attributes path)))))
    (and (integerp size) size)))

(defun eimg-ocr-view--geometry (path)
  "换算页图 PATH 的显示几何，返回 plist `(:image :width :height :scale :px-w :px-h)'；
读不出尺寸时返回 nil。
`:width' / `:height' 是**原图像素**（SVG 的 `viewBox' 用它们），`:px-w' / `:px-h' 是
显示像素（`create-image' 的 `:width' / `:height' 用它们）；坐标换算一律用
`px-w/width' 与 `px-h/height' 两个比值（正向 `--image-map'、反向 `--posn-entry'），
`:scale' 只是 `eimg-core-fit-size' 的等比缩放，被钳到下限时与两轴实际比值不
自洽，故**不参与坐标换算**（仅保留作「是否发生过缩放」的判断参考）。
所有 `create-image' / `image-size' 都在 `(let ((max-image-size nil)) ...)' 里：
`max-image-size' 的默认值是 frame 的 10 倍，大图会被拒并给出 `(30 . 30)' 占位——
那会让整页框全部错位，比「读不出尺寸」更糟（错位是静默的）。"
  (let* ((spec (let ((max-image-size nil))
                 (ignore-errors (create-image path nil nil :scale 1.0))))
         (size (and spec
                    (let ((max-image-size nil))
                      (ignore-errors (image-size spec t))))))
    (when (and (consp size)
               (numberp (car size)) (> (car size) 0)
               (numberp (cdr size)) (> (cdr size) 0))
      (let* ((width (truncate (car size)))
             (height (truncate (cdr size)))
             (limits (eimg-ocr-view--limits))
             (fit (eimg-core-fit-size width height (car limits) (cdr limits))))
        (when fit
          (list :image path
                :width width
                :height height
                :scale (plist-get fit :scale)
                :px-w (plist-get fit :px-w)
                :px-h (plist-get fit :px-h)))))))

(defun eimg-ocr-view--mime-type (path)
  "返回 PATH 对应的 data URI MIME 类型；未知扩展名按 `image/png' 兜底。"
  (or (cdr (assoc (downcase (or (file-name-extension path) ""))
                  eimg-ocr-view--mime-types))
      "image/png"))

(defun eimg-ocr-view--image-bytes (path)
  "以**二进制**方式读入 PATH 的内容，返回 unibyte 字符串；读不到返回 nil。
为什么必须 `insert-file-contents-literally' + 关掉多字节：`base64-encode-string'
作用在 multibyte 字符串上时会先按当前编码转码，二进制（尤其含 GBK 风格中文路径读进来的
内容）会被改写，编码出来的 base64 就不是原文件字节了，图片于是解不出来。"
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (condition-case nil
        (progn (insert-file-contents-literally path)
               (buffer-string))
      (error nil))))

(defun eimg-ocr-view--base64 (path)
  "返回页图 PATH 的 base64 编码；读不到返回 nil。
按 `(路径 修改时间 大小)' 缓存：每次重绘都读盘 + 编码一张几 MB 的 PNG 会明显卡顿，
而重绘在「光标每次移到另一个块」时都会发生（只为了改一个框的颜色）。
`base64-encode-string' 的 NO-LINE-BREAK 传 t：data URI 里插换行虽然多数解析器容错，
但换行位置一旦被 SVG 格式化代码影响就难排查，直接不产生换行最省事。"
  (let* ((attrs (ignore-errors (file-attributes path)))
        (key (and attrs
                  (list path (float-time (nth 5 attrs)) (nth 7 attrs)))))
    (when key
      (or (gethash key eimg-ocr-view--image-cache)
          (let ((encoded (let ((bytes (eimg-ocr-view--image-bytes path)))
                           (and bytes (base64-encode-string bytes t)))))
            (when encoded
              (when (>= (hash-table-count eimg-ocr-view--image-cache)
                        eimg-ocr-view--image-cache-limit)
                (clrhash eimg-ocr-view--image-cache))
              (puthash key encoded eimg-ocr-view--image-cache))
            encoded)))))

;;;; ── 3. SVG 合成 ───────────────────────────────────────────────────────

;; SVG 是纯字符串，不依赖 frame / window，故这部分能被 `emacs -Q --batch' 直接断言
;; （形状、数量、坐标都钉在字符串里）。三件事必须同时正确才能画出对得上的图：
;;   viewBox 用原图坐标系、底图 `preserveAspectRatio="none"' 铺满、rect 用原图坐标。

(defun eimg-ocr-view--normalize-box (box)
  "把 BOX `(X0 Y0 X1 Y1)' 归一成 `(X0 Y0 X1 Y1)' 且保证 X0≤X1、Y0≤Y1。
两个消费者（`--svg-rect' 画框、`--image-map' 造热区）必须共用这一份归一：只归一处
时，上下或左右颠倒的 box 会画出正确的框、却得到一个取反的热区——框看得见、点不中，
而且完全不报错。"
  (list (min (nth 0 box) (nth 2 box))
        (min (nth 1 box) (nth 3 box))
        (max (nth 0 box) (nth 2 box))
        (max (nth 1 box) (nth 3 box))))

(defun eimg-ocr-view--svg-rect (box stroke-width current)
  "把 BOX（`(X0 Y0 X1 Y1)'，原图像素）变成一条 `<rect>' 字符串。
`stroke-width' 由整图宽度按比例算出（见 `eimg-ocr-view--svg'）：固定像素值在缩到
几百像素宽的页上是三像素的粗线、在 4000px 的原图上是一条看不见的细丝。
CURRENT 非 nil 时用高亮样式（描边色 + 半透明填充 + 更粗的线）。
BOX 先经 `--normalize-box'：OCR 后端给出 x0>x1 / y0>y1 的坐标并不罕见，负宽高的
`<rect>' 在 SVG 里是不画（不是反着画），框会整块消失。"
  (let* ((normalized (eimg-ocr-view--normalize-box box))
         (x0 (nth 0 normalized))
         (y0 (nth 1 normalized))
         (width (max 1 (- (nth 2 normalized) x0)))
         (height (max 1 (- (nth 3 normalized) y0))))
    (format (concat "  <rect x=\"%.1f\" y=\"%.1f\" width=\"%.1f\" height=\"%.1f\""
                    " fill=\"%s\"%s stroke=\"%s\" stroke-width=\"%d\"/>\n")
            x0 y0 width height
            (if current eimg-ocr-view--stroke-current "none")
            (if current " fill-opacity=\"0.15\"" "")
            (if current eimg-ocr-view--stroke-current eimg-ocr-view--stroke)
            (if current (round (* 1.5 stroke-width)) stroke-width))))

(defvar eimg-ocr-view--svg-prefix-cache nil
  "最近一次合成的 SVG 前缀缓存，plist `(:key KEY :text TEXT)'；nil 表示还没算过。
为什么要单独缓存「前缀」：前缀里含整张底图的 base64（单页几 MB），而 `--refresh'
每次光标移动都要重拼整条 SVG 串，重拼的代价几乎全在那一段上。命中时只拼 `<rect>'，
「光标动一格」的开销就从「几 MB 的字符串拼接」降到「几十条几百字节的 rect」。
KEY 是 `(路径 修改时间 大小 原图宽 原图高 显示宽 显示高)'，**任一项变化即重建**：
页图被重新识别覆盖（路径相同、mtime / size 变）、换页（路径变）、窗口尺寸变化导致
显示尺寸变化（px-w / px-h 变）都会让旧前缀失效。只留一条（不像 base64 缓存留多条）：
前缀永远只服务「当前页」，翻页后旧前缀再也用不上，留多份只是白占内存。")

(defun eimg-ocr-view--svg-prefix (image-path width height px-w px-h)
  "返回 SVG 从根元素到内嵌底图为止的那一段字符串；读不到底图时返回 nil。
IMAGE-PATH 是页图路径（MIME 类型也由它的扩展名得出），WIDTH / HEIGHT 是原图像素
（`viewBox' 与底图尺寸都用它），PX-W / PX-H 是显示像素——它们当前不写进 SVG，但
「显示尺寸变了」意味着换了画布，保守起见让它们参与缓存失效判断。
缓存与失效条件见 `eimg-ocr-view--svg-prefix-cache'。
底图必须带 `preserveAspectRatio=\"none\"'：viewBox 与显示尺寸的比例一致时两种写法
画出来一样，但一旦比例有微小差异（浮点取整），等比居中就会把整张图缩到中间、四周
留白，而框还在原坐标上——看起来像「框全偏了」。"
  (let* ((attrs (ignore-errors (file-attributes image-path)))
         (key (and attrs
                   (list image-path
                         (float-time (nth 5 attrs))
                         (nth 7 attrs)
                         width height px-w px-h))))
    (if (and (plist-get eimg-ocr-view--svg-prefix-cache :text)
             (equal key (plist-get eimg-ocr-view--svg-prefix-cache :key)))
        (plist-get eimg-ocr-view--svg-prefix-cache :text)
      (let ((base64 (eimg-ocr-view--base64 image-path)))
        (when base64
          (let ((text (concat
                       (format (concat "<svg xmlns=\"http://www.w3.org/2000/svg\""
                                       " viewBox=\"0 0 %d %d\" width=\"%d\" height=\"%d\">\n")
                               width height width height)
                       (format (concat "  <image href=\"data:%s;base64,%s\""
                                       " x=\"0\" y=\"0\" width=\"%d\" height=\"%d\""
                                       " preserveAspectRatio=\"none\"/>\n")
                               (eimg-ocr-view--mime-type image-path)
                               base64 width height))))
            (setq eimg-ocr-view--svg-prefix-cache (list :key key :text text))
            text))))))

(defun eimg-ocr-view--svg (image-path width height px-w px-h rects current)
  "合成一页的 SVG 字符串；读不到底图时返回 nil。
IMAGE-PATH 是页图路径（MIME 与底图字节都从它得出）；WIDTH / HEIGHT 是原图像素，
同时充当 `viewBox' 与底图的 `width' / `height'；PX-W / PX-H 是显示像素，只参与
前缀缓存的失效判断；RECTS 是 `(IDX . BOX)' 列表，只含**本页有坐标**的块；
CURRENT 是高亮块的下标（没有则 nil）。

坐标策略：`<rect>' 直接写原图坐标，不乘缩放比。缩放由 `viewBox' 与
`create-image' 的 `:width' / `:height' 完成——一旦在这里再乘一次，两套换算会随
缩放变化而对不齐（T1 实测：底图与框错位到框完全落在文字外）。

前缀（含几 MB 的底图 base64）走缓存，见 `eimg-ocr-view--svg-prefix'：本函数每次
调用都会重新拼，但重拼的只有 `<rect>' 那几十行。"
  (let ((prefix (eimg-ocr-view--svg-prefix image-path width height px-w px-h)))
    (when prefix
      (let ((stroke-width (max 2 (round (/ (float width) 400.0))))
            parts)
        (dolist (item rects)
          (setq parts (cons (eimg-ocr-view--svg-rect
                             (cdr item) stroke-width (eql (car item) current))
                            parts)))
        (concat prefix (mapconcat #'identity (nreverse parts) "") "</svg>\n")))))

;;;; ── 4. 图区：热区、图片 spec 与插入 ──────────────────────────────────

;; 热区（`:map'）的三条事实来自 (info "(elisp) Image Descriptors")，别凭记忆改：
;;   - 一条热区是 `(AREA ID PLIST)'；
;;   - 矩形的 AREA 是 `(rect . ((X0 . Y0) . (X1 . Y1)))'，即**左上角与右下角**两个点
;;     （不是 X0 Y0 WIDTH HEIGHT）；
;;   - 点中热区时事件变成「ID 与鼠标事件拼成的键序列」`[ID mouse-1]'，故 FUNCTION
;;     不是写进 plist 的，而是键位表里 `[ID mouse-1]' 的绑定；
;;   - 坐标必须是**显示后**的像素（缩放 / 旋转之后），所以要把原图坐标按
;;     `px-w/width' 与 `px-h/height' 各自换算（不用 `:scale'，理由见 `--image-map'）。

(defun eimg-ocr-view--entry-id (index)
  "返回块 INDEX 的热区 ID 符号。
ID 里带下标：点中热区时事件序列以它为第一项（`[eimg-ocr-view-entry-3 mouse-1]'），
命令由此知道「点的是哪一块」，不必再去猜坐标。"
  (intern (format "eimg-ocr-view-entry-%d" index)))

(defun eimg-ocr-view--id-index (symbol)
  "从热区 ID SYMBOL 反解块下标；不是本视图的 ID 时返回 nil。"
  (let ((name (and (symbolp symbol) (symbol-name symbol)))
        (prefix "eimg-ocr-view-entry-"))
    (when (and name (string-prefix-p prefix name))
      (string-to-number (substring name (length prefix))))))

(defun eimg-ocr-view--clamp (value low high)
  "把 VALUE 夹在 [LOW, HIGH] 之间。"
  (max low (min high value)))

(defun eimg-ocr-view--image-map (state geometry)
  "构造 `:map' 热区列表；每个有坐标的块一条 `(rect ID PLIST)'。
GEOMETRY 是 `--geometry' 的返回值（提供 `:width' / `:height' / `:px-w' / `:px-h'）：
换算比取 `(/ px-w width)' 与 `(/ px-h height)' **各自**算，而不是用 `:scale'。
为什么不用 `:scale'：它是 `eimg-core-fit-size' 的等比缩放，被钳到下限（0.01）时与
两个轴各自的比例最多能差 1px；而热区与画出来的框必须**逐像素**一致，否则框边缘
的可点区域会缺一条缝（或溢出一像素，点中相邻块）。
BOX 先经 `--normalize-box'（与 `--svg-rect' 同一份归一），越界的部分夹进画面内，
每条边至少 1px：0 宽或 0 高的热区**永远**点不中，而 OCR 的坐标里出现「零高行」
并不罕见（单像素高的连字符、被切掉的横线）。"
  (let* ((width (plist-get geometry :width))
         (height (plist-get geometry :height))
         (px-w (plist-get geometry :px-w))
         (px-h (plist-get geometry :px-h))
         (x-scale (/ (float px-w) (float width)))
         (y-scale (/ (float px-h) (float height)))
         (items (eimg-ocr-view--page-boxes (plist-get state :entries)
                                           (plist-get state :page-index)))
         result)
    (dolist (item items)
      (let* ((index (car item))
             (box (eimg-ocr-view--normalize-box (cdr item)))
             (x0 (eimg-ocr-view--clamp (round (* (nth 0 box) x-scale)) 0 (1- px-w)))
             (y0 (eimg-ocr-view--clamp (round (* (nth 1 box) y-scale)) 0 (1- px-h)))
             (x1 (eimg-ocr-view--clamp (round (* (nth 2 box) x-scale)) (1+ x0) px-w))
             (y1 (eimg-ocr-view--clamp (round (* (nth 3 box) y-scale)) (1+ y0) px-h))
             (entry (nth index (plist-get state :entries))))
        (when (and (> x1 x0) (> y1 y0))
          (push (list (cons 'rect (cons (cons x0 y0) (cons x1 y1)))
                      (eimg-ocr-view--entry-id index)
                      (list 'help-echo
                            (format "第 %d 块：%s"
                                    (1+ index)
                                    (eimg-ocr-view--entry-summary entry 30))
                            'pointer 'hand))
                result))))
    (nreverse result)))

(defun eimg-ocr-view--click-keymap (state)
  "构造图区用的键位表：为当前页每个块绑 `[ID mouse-1]'。
父表用 `(current-local-map)'（模式表）：点完图光标会落在图区那个「空格字符」上，
若这张表是孤立的，落在图区上按 `n' / `q' 就会失效——组合键位表让两张表都生效。"
  (let ((map (make-sparse-keymap)))
    (dolist (item (eimg-ocr-view--page-boxes (plist-get state :entries)
                                             (plist-get state :page-index)))
      (define-key map (vector (eimg-ocr-view--entry-id (car item)) 'mouse-1)
                  #'eimg-ocr-view--mouse-goto))
    (make-composed-keymap map (or (current-local-map) (current-global-map)))))

(defun eimg-ocr-view--make-image (geometry state)
  "由 GEOMETRY 与 STATE 造出可插入的 image spec；失败返回 nil。
`:scale 1.0' 是刻意的：`image-scaling-factor' 为 `auto' 时 Emacs 会在请求尺寸之上再
乘一个系数，导致图片比请求的大、右侧与下沿被窗口裁掉（而热区坐标是按请求尺寸算的，
于是点哪儿都不对）。
SVG 串每次现拼（只有 `<rect>' 那几十行），前缀里的底图 base64 走缓存——见
`eimg-ocr-view--svg-prefix'。`create-image' 仍会重新解析整条串，这是回到 Emacs 的
必经开销，无法缓存（图片 spec 里存的是解析结果，热区一变就得重造）。"
  (let* ((image-path (plist-get geometry :image))
         (svg (eimg-ocr-view--svg image-path
                                  (plist-get geometry :width)
                                  (plist-get geometry :height)
                                  (plist-get geometry :px-w)
                                  (plist-get geometry :px-h)
                                  (eimg-ocr-view--page-boxes
                                   (plist-get state :entries)
                                   (plist-get state :page-index))
                                  (plist-get state :current))))
    (when svg
      (let ((map (eimg-ocr-view--image-map state geometry))
            (max-image-size nil))
        (ignore-errors
          (create-image svg 'svg t
                        :width (plist-get geometry :px-w)
                        :height (plist-get geometry :px-h)
                        :scale 1.0
                        :ascent 'center
                        :map map))))))

(defun eimg-ocr-view--insert-visual ()
  "把图区插到光标处：能画就插图片，否则插一行能读懂的原因，末尾补一个换行。
图区是「一个空格字符 + `display' 属性」，必须换行——否则下半部分的第一行文本会接
在图片右边（图片在 buffer 里只占一个字符宽，视觉上却占整幅）。
图片那一个字符上还要覆盖 `keymap' 文本属性：
`insert-image' 装的是内置 `image-map'，里面没有我们的 `[ID mouse-1]' 绑定。"
  (let* ((state eimg-ocr-view--state)
         (geometry (plist-get state :geometry))
         (image (and geometry (eimg-ocr-view--make-image geometry state))))
    (cond
     (image
      (let ((start (point)))
        (insert-image image)
        (put-text-property start (point)
                           'keymap (eimg-ocr-view--click-keymap state))
        (put-text-property start (point)
                           'help-echo "点框跳到对应文本行")))
     (t
      ;; 降级时也要写清「为什么没有图」，静默的空白区会让用户以为识别结果坏了。
      (insert (propertize (or (plist-get state :visual-hint)
                              "本页暂无可显示的页图")
                          'face 'shadow))))
    (insert "\n")))

;;;; ── 5. 页/块状态与几何准备 ───────────────────────────────────────────

(defun eimg-ocr-view--prepare-page (state page-index)
  "算出 STATE 在 PAGE-INDEX 页的图区信息，返回 plist `(:geometry :visual-hint)'。
七种情形，优先级从上到下（越靠前越先判，因为后面的判断都依赖前面成立）：
  1. 本页一块坐标都没有（ollama 后端）→ 提示「后端不提供 box」；
  2. 当前 Emacs 没有 SVG 支持（缺 librsvg）→ 说明图区不可用、文本列表照常；
  3. 找不到页图 → 说明缺什么（PDF 输入 / 重新识别 / 绝对路径）；
  4. 页图字节数超过 `eimg-ocr-view-max-embed-bytes' → 明确降级（不内嵌底图）；
  5. 读不出尺寸（`create-image' / `image-size' 失败）→ 带上路径；
  6. 读不出内容（base64 为空）→ 带上路径；
  7. 都成功 → `:geometry' 有值、`:visual-hint' 为 nil。
第 2 条排在「找页图」之前：缺 librsvg 时有没有页图都画不出图，先说「这台 Emacs
画不了」比说「找不到页图」更贴近用户能动手的方向。第 4 条排在「读尺寸」之前：
判断只看 `stat'，比 `create-image' 便宜得多，且超限时后续两步全是白做。"
  (let* ((pages (plist-get state :pages))
         (page (nth page-index pages))
         (boxes (eimg-ocr-view--page-boxes (plist-get state :entries) page-index))
         (path (and boxes (eimg-ocr-view--page-image page (plist-get state :meta))))
         (size (and path (eimg-ocr-view--image-size path)))
         (geometry nil)
         (hint nil))
    (cond
     ((null boxes)
      (setq hint "此页没有坐标数据（后端不提供 box），仅显示文本"))
     ((not (image-type-available-p 'svg))
      ;; 这条是显式判定，不是靠后面 `ignore-errors' 兜底撞出来的：`create-image'
      ;; 失败只会得到 nil，用户看到的是「本页暂无可显示的页图」——那句话把原因
      ;; 说成「本页没有图」，而真正的原因是这台 Emacs 没有 SVG 后端。
      (setq hint "当前 Emacs 没有 SVG 支持（librsvg），图区不可用：文本列表仍可正常使用"))
     ((null path)
      (setq hint "找不到页图：请用 PDF 输入或重新识别（单图输入的来源需是绝对路径）"))
     ((and size (> size eimg-ocr-view-max-embed-bytes))
      ;; 明确降级而不是「硬塞」：这个上限防的是「几十 MB 的 base64 串进 SVG 后
      ;; `create-image' 解析卡死」，所以宁可只给文本列表 + 可行动的下一步。
      (setq hint (format "原图较大（%s），超出内嵌上限 %s：可降低 --dpi 重新识别 PDF，或裁剪图片后再识别"
                         (eimg-ocr-view--format-bytes size)
                         (eimg-ocr-view--format-bytes eimg-ocr-view-max-embed-bytes))))
     (t
      (setq geometry (eimg-ocr-view--geometry path))
      (cond
       ((null geometry)
        (setq hint (format "无法读取页图尺寸：%s" path)))
       ((null (eimg-ocr-view--base64 path))
        (setq geometry nil
              hint (format "无法读取页图内容：%s" path))))))
    (list :geometry geometry :visual-hint hint)))

(defun eimg-ocr-view--with-page (state page-index)
  "返回 STATE 的副本：`:page-index' 换成 PAGE-INDEX，并重算几何与提示。
换页是唯一会改动「图区能不能画」的操作，故全部收敛到这里；其它函数只读
`:geometry' / `:visual-hint'，不自己算。"
  (let ((prepared (eimg-ocr-view--prepare-page state page-index)))
    (setq state (plist-put state :page-index page-index))
    (dolist (key '(:geometry :visual-hint))
      (setq state (plist-put state key (plist-get prepared key))))
    state))

;;;; ── 6. 渲染（重建 / 只换图） ─────────────────────────────────────────

(defun eimg-ocr-view--drop-markers (state)
  "把 STATE 里记录的图区 marker 从 buffer 上摘掉（`set-marker' 置 nil）。
不摘就漏：`erase-buffer' 之后旧 marker 仍挂在 buffer 上，每次重渲漏两个，翻几十页
后 buffer 上挂满无用 marker，编辑/显示都会变慢。"
  (dolist (key '(:image-start :image-end))
    (let ((marker (plist-get state key)))
      (when (markerp marker)
        (set-marker marker nil))))
  state)

(defun eimg-ocr-view--entry-position (index)
  "返回块 INDEX 在 buffer 里的行首位置；不在 buffer 里返回 nil。
用 `text-property-search-forward' 而不是自己扫 `next-single-property-change'：
前者就是为「按属性值找区间」写的，且不用手写循环边界。"
  (save-excursion
    (goto-char (point-min))
    (let ((match (text-property-search-forward
                  eimg-ocr-view--entry-property index #'eql)))
      (when match
        (prop-match-beginning match)))))

(defun eimg-ocr-view--recenter ()
  "把当前块所在行滚到**本 buffer 的窗口**中部；本 buffer 没显示时什么也不做。
三个细节都是实测踩出来的：
  1. 不能裸调 `recenter'：它作用于**选中窗口**，而本命令可能从别的窗口触发（点图时
     视图未必是被选中的窗口）。裸调用会滚错窗口，甚至因为两点不一致而报错。
  2. 必须 `with-selected-window' 才是对的那个窗口。
  3. 光选窗还不够：`select-window' 会把 buffer point 同步成该窗口记着的
     `window-point'（可能是个过期的老位置），于是 `recenter' 会去居中**旧行**，
     命令返回后 point 也被改掉——高亮与光标就此错位。故先 `set-window-point' 对齐
     到本次要看的 POSITION，再 recenter，最后用 `save-excursion' 把 point 还回来。"
  (let ((window (get-buffer-window (current-buffer)))
        (position (point)))
    (when window
      (save-excursion
        (with-selected-window window
          (goto-char position)
          (set-window-point window position)
          (recenter))))))

(defun eimg-ocr-view--render ()
  "重建整个视图 buffer：先图区，再文本列表，最后把光标放回当前块。
只有换页、`g' 重取数据这类「文本列表本身变了」的场合才走这里；
见 `eimg-ocr-view--refresh' 的轻量路径。"
  (let ((inhibit-read-only t)
        (state (eimg-ocr-view--drop-markers eimg-ocr-view--state)))
    (erase-buffer)
    (setq eimg-ocr-view--state
          (plist-put (plist-put state :image-start (copy-marker (point-min) nil))
                     :image-end (copy-marker (point-min) nil)))
    (goto-char (point-min))
    (eimg-ocr-view--insert-visual)
    ;; 图区到此为止。两个 marker 的插入类型**都必须**是 nil，且必须在这里显式把 end
    ;; 设到当前点：插入类型 t 的 marker 会被「在它位置上插入的后续内容」推到后面去，
    ;; 而紧接着插入的正是文本列表——end 于是变到 `point-max'，下一次 `--refresh'
    ;; 的 `delete-region' 会把整个文本列表一起删掉（本次实测的真实故障：刷新一次
    ;; 之后列表全没了，光标属性也一并消失）。
    (set-marker (plist-get eimg-ocr-view--state :image-end) (point))
    (let ((items (eimg-ocr-view--page-entries
                  (plist-get eimg-ocr-view--state :entries)
                  (plist-get eimg-ocr-view--state :page-index))))
      (if (null items)
          (insert (propertize "（本页没有识别出文本）" 'face 'shadow) "\n")
        (dolist (pair items)
          (let* ((index (car pair))
                 (text (eimg-ocr-view--display-text
                        (plist-get (cdr pair) :text)))
                 (line (if (string-empty-p text) "（空块）" text)))
            (insert (propertize (concat line "\n")
                                eimg-ocr-view--entry-property index))))))
    (set-buffer-modified-p nil)
    (let ((position (eimg-ocr-view--entry-position
                     (plist-get eimg-ocr-view--state :current))))
      (goto-char (or position (point-min))))))

(defun eimg-ocr-view--refresh ()
  "只重插图区（更新高亮），文本列表与光标一概不动。
为什么值得单独走一条路径：`post-command-hook' 每次光标移动都会调它，而重建整个
buffer 会让「光标位置 / 窗口滚动 / 行号」全部重算一遍，高频调用下主观就是卡顿
（20 块以上的页面尤其明显）。这里只做 `delete-region' + `insert-image'，两次 buffer
修改都是常量级。"
  (let* ((state eimg-ocr-view--state)
         (start (plist-get state :image-start))
         (end (plist-get state :image-end)))
    (when (and (markerp start) (markerp end))
      (let ((inhibit-read-only t))
        (save-excursion
          (delete-region start end)
          (goto-char start)
          (eimg-ocr-view--insert-visual)
          (set-marker end (point)))
        (set-buffer-modified-p nil)))))

;;;; ── 7. 光标 ↔ 高亮联动 ──────────────────────────────────────────────

(defun eimg-ocr-view--point-entry ()
  "返回光标所在文本行的块下标；不在任何块行上时返回 nil。
行尾也算（光标停在换行符上时，`get-text-property' 读到的是同一行那个属性——换行符
一起被 propertize 了），否则光标停在行尾高亮会莫名其妙地保持不动。"
  (or (get-text-property (point) eimg-ocr-view--entry-property)
      (and (> (point) (point-min))
           (get-text-property (1- (point)) eimg-ocr-view--entry-property))))

(defun eimg-ocr-view--sync ()
  "把光标所在块同步成高亮块；下标没变时立即返回。
挂在 buffer-local 的 `post-command-hook' 上，所以第一件事就是「便宜地判断要不要
干活」：一次 `get-text-property' 加一次整数比较，未变直接返回，不触发任何重绘。"
  (when eimg-ocr-view--state
    (let ((index (eimg-ocr-view--point-entry))
          (current (plist-get eimg-ocr-view--state :current)))
      (when (and (integerp index) (not (eql index current)))
        (setq eimg-ocr-view--state
              (plist-put eimg-ocr-view--state :current index))
        (eimg-ocr-view--refresh)
        (force-mode-line-update)))))

(defun eimg-ocr-view--goto-entry (index)
  "把光标移到块 INDEX 对应的文本行，并高亮它。
跨页时先换页重建 buffer（该块的文本行在别的页里，只刷新图区是不够的）。
INDEX 越界时 `user-error'：这条路径的入参来自导航命令与热区 ID，越界一定是内部状态
坏了，静默无反应会让问题藏起来。"
  (let* ((state eimg-ocr-view--state)
         (entry (nth index (plist-get state :entries))))
    (unless (and (integerp index) entry)
      (user-error "没有第 %s 块（共 %d 块）"
                  (if (integerp index) (1+ index) index)
                  (length (plist-get state :entries))))
    (setq eimg-ocr-view--state (plist-put eimg-ocr-view--state :current index))
    (if (/= (plist-get entry :page-index) (plist-get state :page-index))
        (progn
          (setq eimg-ocr-view--state
                (eimg-ocr-view--with-page eimg-ocr-view--state
                                          (plist-get entry :page-index)))
          (eimg-ocr-view--render))
      (let ((position (eimg-ocr-view--entry-position index)))
        (when position
          (goto-char position)))
      (eimg-ocr-view--refresh))
    (eimg-ocr-view--recenter)
    (force-mode-line-update)))

(defun eimg-ocr-view--posn-entry (event)
  "由点击事件 EVENT 的像素位置反解块下标；算不出返回 nil。
这是热区 ID 拿不到时的兜底：`posn-object-x-y' 给的是「相对图片左上角的**显示**像素」，
按 `width/px-w' 与 `height/px-h' 各自换算回原图坐标，再找包含该点的框。
换算基准必须是 `--image-map' 用的那两个比值的**逆**（而不是 `:scale'）：正向用
`px-w/width' 建热区，反向若用 `:scale'，两套基准在 scale 被钳到下限时就会错位，
兜底命中的块会和热区命中的块不一致。"
  (let* ((state eimg-ocr-view--state)
         (geometry (plist-get state :geometry))
         (width (plist-get geometry :width))
         (height (plist-get geometry :height))
         (px-w (plist-get geometry :px-w))
         (px-h (plist-get geometry :px-h))
         (position (ignore-errors (event-start event)))
         (coordinates (and position (ignore-errors (posn-object-x-y position)))))
    (when (and coordinates
               (numberp width) (> width 0)
               (numberp height) (> height 0)
               (numberp px-w) (> px-w 0)
               (numberp px-h) (> px-h 0))
      (let ((x (* (float (car coordinates)) (/ (float width) (float px-w))))
            (y (* (float (cdr coordinates)) (/ (float height) (float px-h))))
            found)
        (dolist (item (eimg-ocr-view--page-boxes (plist-get state :entries)
                                                 (plist-get state :page-index)))
          (let ((box (cdr item)))
            (when (and (<= (min (nth 0 box) (nth 2 box)) x)
                       (<= x (max (nth 0 box) (nth 2 box)))
                       (<= (min (nth 1 box) (nth 3 box)) y)
                       (<= y (max (nth 1 box) (nth 3 box))))
              (setq found (car item)))))
        found))))

(defun eimg-ocr-view--keys-entry (keys)
  "从键序列 KEYS 里取出热区 ID 对应的块下标；没有热区 ID 时返回 nil。
为什么不能只看命令参数：`:map' 的 ID 与鼠标事件拼成键序列 `[ID mouse-1]'，而交互
规格 `e' 只把「第一个列表型事件」交给命令——ID 是符号，不在其中。故先扫
`this-command-keys'，扫不到再退回几何换算（`--posn-entry'）。"
  (let (found)
    (dotimes (i (length keys))
      (let ((index (eimg-ocr-view--id-index (aref keys i))))
        (when index
          (setq found index))))
    found))

(defun eimg-ocr-view--mouse-goto (event)
  "响应图区热区上的鼠标点击 EVENT：跳到对应文本行并高亮。
热区的 FUNCTION 就是这条命令：`:map' 里只写 ID，`[ID mouse-1]' → 本命令的绑定在
`eimg-ocr-view--click-keymap' 里。"
  (interactive "e")
  (let ((index (or (eimg-ocr-view--keys-entry (this-command-keys))
                   (eimg-ocr-view--posn-entry event))))
    (if index
        (eimg-ocr-view--goto-entry index)
      (user-error "这一处没有对应的文本块：点在图上某个框里试试"))))

;;;; ── 8. 导航与动作命令 ────────────────────────────────────────────────

(defun eimg-ocr-view-next-block ()
  "光标移到下一块；跨页自动换页并重渲。已经是最后一块时 `user-error'。"
  (interactive)
  (let* ((state eimg-ocr-view--state)
         (next (1+ (or (plist-get state :current) 0))))
    (if (< next (length (plist-get state :entries)))
        (eimg-ocr-view--goto-entry next)
      (user-error "已经是最后一块（共 %d 块）" (length (plist-get state :entries))))))

(defun eimg-ocr-view-previous-block ()
  "光标移到上一块；跨页自动换页并重渲。已经是第一块时 `user-error'。"
  (interactive)
  (let* ((state eimg-ocr-view--state)
         (previous (1- (or (plist-get state :current) 0))))
    (if (>= previous 0)
        (eimg-ocr-view--goto-entry previous)
      (user-error "已经是第一块"))))

(defun eimg-ocr-view--show-page (page-index)
  "切到第 PAGE-INDEX 页（0-based）并重渲；越界时 `user-error'。
换页后光标落在该页第一块（该页没有块时停在图区）——比「保持原来的块号」可预测：
块号是全局的，跨页保持会指向一个不在本页的数字。"
  (let* ((state eimg-ocr-view--state)
         (total (length (plist-get state :pages))))
    (unless (and (integerp page-index) (>= page-index 0) (< page-index total))
      (user-error "没有这一页（共 %d 页）" total))
    (setq eimg-ocr-view--state (eimg-ocr-view--with-page state page-index))
    (let* ((items (eimg-ocr-view--page-entries
                   (plist-get eimg-ocr-view--state :entries) page-index))
           (target (cond ((null items) 0)
                         ((< page-index (plist-get state :page-index)) (car (car (last items))))
                         (t (car (car items))))))
      (setq eimg-ocr-view--state
            (plist-put eimg-ocr-view--state :current target)))
    (eimg-ocr-view--render)
    (force-mode-line-update)))

(defun eimg-ocr-view-next-page ()
  "切到下一页。"
  (interactive)
  (eimg-ocr-view--show-page (1+ (or (plist-get eimg-ocr-view--state :page-index) 0))))

(defun eimg-ocr-view-previous-page ()
  "切到上一页。"
  (interactive)
  (eimg-ocr-view--show-page (1- (or (plist-get eimg-ocr-view--state :page-index) 0))))

(defun eimg-ocr-view--current-entry ()
  "返回当前块 entry；没有任何块时 `user-error'。"
  (let* ((state eimg-ocr-view--state)
         (entry (nth (or (plist-get state :current) 0) (plist-get state :entries))))
    (unless entry
      (user-error "当前页没有可用的文本块"))
    entry))

(defun eimg-ocr-view-copy-block ()
  "复制当前块文本到 `kill-ring'。
语义调整：原计划此处是「跳到原图位置」，但原图是一整张 `image'——Emacs 的图片是
不可分割的显示对象，没有「图片内位置」的概念，无法在其中滚动定位。同一位置真正有用
的动作是拿走那段文字，故改为复制。复制的是 `:text' 原文（含原有换行），不是列表里
那行压平的显示文本。"
  (interactive)
  (let ((text (plist-get (eimg-ocr-view--current-entry) :text)))
    (when (string-empty-p (or text ""))
      (user-error "这一块没有文本可复制"))
    (kill-new text)
    ;; 文案里不回显文本本身：OCR 文本可能含 `%'，它会破坏 `message' 的格式串。
    (message "eimg：已复制当前块（%d 字符）" (length text))))

(defun eimg-ocr-view-open-image ()
  "打开当前页的位图文件（`find-file'）。
取 `:geometry' 里的路径而不是 `page' 的 `image' 字段：`--prepare-page' 已经做过
「`image' 字段优先、`:source' 兜底」的解析，再用裸字段判断等于把那段逻辑抄一遍。"
  (interactive)
  (let* ((state eimg-ocr-view--state)
         (path (plist-get (plist-get state :geometry) :image)))
    (unless path
      (user-error "当前页没有位图文件：%s"
                  (or (plist-get state :visual-hint)
                      "请用 PDF 输入或重新识别")))
    (find-file path)))

;;;; ── 9. 数据来源、主模式与入口命令 ────────────────────────────────────

(defun eimg-ocr-view--source-data ()
  "返回 `(来源 buffer . 结果 plist)'；没有可用结果时返回 nil。
三个候选按可信度排序：当前 buffer（用户就在结果 buffer 里按 `v'）、状态里记的来源
（`g' 重取时最准）、固定名的结果 buffer（从别处调命令）。空 `:pages' 当作没有结果：
渲染一个空视图什么也说明不了，不如让调用方给出「先去识别」的提示。"
  (let* ((state (and (boundp 'eimg-ocr-view--state) eimg-ocr-view--state))
         (origin (plist-get state :origin))
         (candidates (delq nil (list (and (derived-mode-p 'eimg-ocr-mode)
                                          (current-buffer))
                                     (and (buffer-live-p origin) origin)
                                     (get-buffer eimg-ocr-buffer-name)))))
    (cl-loop for buffer in candidates
             for data = (buffer-local-value 'eimg-ocr--result-data buffer)
             when (and data (plist-get data :pages))
             return (cons buffer data))))

(defun eimg-ocr-view--make-state (origin data previous)
  "由来源 buffer ORIGIN 与结果数据 DATA 造出初始状态 plist。
PREVIOUS 是同一个视图 buffer 上次的状态（可为 nil）：当来源与块文本逐条相同时沿用它的
`:page-index' / `:current'，于是「关掉再打开」「`g' 重取同一批数据」都能回到上次浏览
的位置。比对用块文本而不只比块数：识别重跑过之后块数可能一样而内容完全不同，那时沿用
旧下标会指向另一段文字的框。"
  (let* ((pages (plist-get data :pages))
         (entries (eimg-ocr-view--entries pages))
         (state (list :origin origin
                      :pages pages
                      :meta (plist-get data :meta)
                      :entries entries
                      :page-index 0
                      :current 0
                      :geometry nil
                      :visual-hint nil
                      :image-start nil
                      :image-end nil)))
    (when (and previous
               (eq (plist-get previous :origin) origin)
               (equal (mapcar (lambda (entry) (plist-get entry :text))
                              (plist-get previous :entries))
                      (mapcar (lambda (entry) (plist-get entry :text)) entries)))
      (let ((page-index (or (plist-get previous :page-index) 0))
            (current (or (plist-get previous :current) 0)))
        (setq state (plist-put state :page-index
                               (if (< page-index (length pages)) page-index 0)))
        (setq state (plist-put state :current
                               (if (< current (length entries)) current 0)))))
    state))

(defun eimg-ocr-view-mode-line-string ()
  "返回模式行文本：「第 N/M 页 · 第 K/L 块 · 后端 X」。
`%' 要转义成 `%%'：模式行里的字符串仍按格式串解释，后端名里带一个 `%' 就会让整行
显示错乱（`(:eval ...)' 的返回值不例外）。"
  (let* ((state eimg-ocr-view--state)
         (pages (plist-get state :pages))
         (entries (plist-get state :entries))
         (page-index (or (plist-get state :page-index) 0))
         (current (or (plist-get state :current) 0))
         (items (eimg-ocr-view--page-entries entries page-index))
         (backend (or (plist-get (plist-get state :meta) :backend) "未知后端")))
    (format " 第 %d/%d 页 · 第 %d/%d 块 · %s "
            (1+ page-index) (length pages)
            (cl-count-if (lambda (pair) (<= (car pair) current)) items)
            (length items)
            (replace-regexp-in-string "%" "%%" (format "%s" backend)))))

(define-derived-mode eimg-ocr-view-mode special-mode "eimg-OCR-View"
  "OCR 联动视图的主模式。
只设两份 buffer 局部值：`truncate-lines'（一个块在列表里必须占一行，折行会把「第几行
= 第几块」的对应关系搅碎）与 `mode-line-format'（页 / 块 / 后端只该出现在这个 buffer，
绝不能改全局值）。另外挂一个 buffer-local 的 `post-command-hook' 做光标 → 高亮同步：
装成全局钩子的话，任何 buffer 里移动光标都要先跑一次我们的判断。"
  (setq-local truncate-lines t)
  (setq-local mode-line-format
              '("%e" mode-line-buffer-identification " " mode-line-modified
                (:eval (eimg-ocr-view-mode-line-string))))
  (add-hook 'post-command-hook #'eimg-ocr-view--sync nil t))

(defun eimg-ocr-view-revert ()
  "重新从来源结果 buffer 取数据并重渲（`revert' 语义，绑 `g'）。
先重算 entries 再渲染：识别可能已经重跑过，块的数量与文本都变了。取不到数据时
`user-error' 并说明恢复方式——保留上一次的视图而不是清空它，用户还能继续看旧结果。"
  (interactive)
  (let* ((found (eimg-ocr-view--source-data)))
    (unless found
      (user-error "来源结果 buffer 已没有可用结果：先在 *eimg-ocr* 里跑一次识别"))
    (setq eimg-ocr-view--state
          (eimg-ocr-view--make-state (car found) (cdr found)
                                     eimg-ocr-view--state))
    (setq eimg-ocr-view--state
          (eimg-ocr-view--with-page eimg-ocr-view--state
                                    (plist-get eimg-ocr-view--state :page-index)))
    (eimg-ocr-view--render)
    (force-mode-line-update)
    (message "eimg：已重新载入 %d 块"
             (length (plist-get eimg-ocr-view--state :entries)))))

;; 键位一律单键，不用 `C-c' 前缀：`C-c' 后跟单个字母是**用户保留**的键位空间，
;; 包不该占用。全部绑在本模式表上（`define-derived-mode' 已建好、父表是
;; `special-mode-map'），也不走 evil / general——本文件必须保持顶层零第三方依赖。
;; 绑定写在所有命令定义之后：`keymap-set' 只记符号，但把「定义在绑定之后」的符号
;; 交给字节编译器会得到 "not known to be defined" 噪音，不如按依赖顺序排。
(keymap-set eimg-ocr-view-mode-map "n" #'eimg-ocr-view-next-block)
(keymap-set eimg-ocr-view-mode-map "p" #'eimg-ocr-view-previous-block)
(keymap-set eimg-ocr-view-mode-map "N" #'eimg-ocr-view-next-page)
(keymap-set eimg-ocr-view-mode-map "P" #'eimg-ocr-view-previous-page)
(keymap-set eimg-ocr-view-mode-map "RET" #'eimg-ocr-view-copy-block)
(keymap-set eimg-ocr-view-mode-map "o" #'eimg-ocr-view-open-image)
(keymap-set eimg-ocr-view-mode-map "g" #'eimg-ocr-view-revert)
(keymap-set eimg-ocr-view-mode-map "q" #'quit-window)

;;;###autoload
(defun eimg-ocr-view ()
  "从 `*eimg-ocr*' 结果 buffer 打开联动视图。
上半部分是「原图（PDF 是 CLI 栅格化后的页图）+ 每块文字的坐标框」，下半部分是该页的
文本列表。文本行与图上框双向联动：光标移到某块，图上对应的框变红加粗；点图上的框，
光标跳到对应文本行。

键位（全部单键）：
  \\{eimg-ocr-view-mode-map}

降级路径都能读地提示，不报错：
  - 没有识别结果 → `user-error'，并说明「先在 *eimg-ocr* 里跑一次识别」；
  - 后端不给坐标（ollama）→ 只显示文本列表 + 一行提示；
  - 找不到页图 / 读不出尺寸 / 读不出内容 → 同样只显示文本，并在图区写明原因。

已有视图 buffer 会复用并重渲（不新开第二个）；同一段数据重开时回到上次浏览的块。"
  (interactive)
  (let* ((found (eimg-ocr-view--source-data))
         (buffer (get-buffer-create eimg-ocr-view-buffer-name)))
    (unless found
      (user-error "还没有可用的识别结果：先在 *eimg-ocr* 里跑一次识别"))
    (with-current-buffer buffer
      (unless (derived-mode-p 'eimg-ocr-view-mode)
        (eimg-ocr-view-mode))
      (setq eimg-ocr-view--state
            (eimg-ocr-view--make-state (car found) (cdr found)
                                       eimg-ocr-view--state)))
    ;; 先显示再算几何：图片尺寸按「图区可用像素」算，而本 buffer 在显示之前没有窗口，
    ;; 用选中窗口的尺寸当代理会偏大（`display-buffer' 往往要拆窗，宽度会变小），
    ;; 于是图片右侧被裁掉一截、热区坐标也跟着对不上。
    (unless noninteractive
      (display-buffer buffer '(display-buffer-pop-up-window)))
    (with-current-buffer buffer
      (setq eimg-ocr-view--state
            (eimg-ocr-view--with-page eimg-ocr-view--state
                                      (plist-get eimg-ocr-view--state :page-index)))
      (eimg-ocr-view--render)
      (force-mode-line-update))
    buffer))

(provide 'eimg-ocr-view)

;;; eimg-ocr-view.el ends here
