;;; eimg-ocr-view-test.el --- eimg-ocr-view 的 ERT 用例（全部 batch 可跑）  -*- lexical-binding: t; -*-

;; Author: ThomasDon
;; Version: 0.1.0
;; Keywords: convenience, tools, ocr

;;; Commentary:

;; 覆盖联动视图的**可离线判定**部分：数据拍平、SVG 字符串合成、热区换算、几何
;; 接线（`eimg-core-fit-size'）、降级文案、模式行与键位、入口命令。
;;
;; 为什么这里不测真实渲染（这条是硬约束，不是省事）
;; ----------------------------------------------
;; 真实渲染依赖 `create-image' + `image-size'，而后者在 `emacs -Q --batch' 下必报
;; `Window system frame should be used'（实测：`(image-size (create-image ...) t)'
;; 在 batch 里 signal，无论有没有 DISPLAY）。于是：
;;   - 几何计算的**输入**（`image-size' 的返回值）在用武之地的环境里拿不到；
;;   - 图片能否显示、热区点得中，都要真实 frame 才能判定。
;; 所以本文件的做法是：
;;   1. SVG 是纯字符串 → 直接断言形状、数量、坐标、属性；
;;   2. 几何 → `cl-letf' 打桩 `create-image' / `image-size' / `--limits'，
;;      断言它把这三个输入交给 `eimg-core-fit-size' 并原样取出结果；
;;   3. 渲染路径 → 走降级分支（没有页图 / 读不出尺寸 / 读不出内容），这才是
;;      batch 下能真实走通的那条路，也恰好是用户最常遇到的那条。
;; 真实 GUI 下的肉眼验证不在 ERT 里（依赖 `DISPLAY'，会让 `make test' 在 CI 上变红）。
;;
;; 两条不许违反的约定：
;;   1. **不起进程、不跑 CLI**：本文件只调纯函数与打桩后的渲染。
;;   2. **不写仓库**：临时文件一律 `make-temp-file' + `unwind-protect' 清理。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'eimg-core)
(require 'eimg-ocr)
(require 'eimg-ocr-view)

;;;; ── 测试数据 ──────────────────────────────────────────────────────────

(defconst eimg-ocr-view-test--pages
  (list (list (cons 'page 1)
              (cons 'source "scan.png")
              (cons 'blocks (list (list (cons 'text "第一块 中文")
                                        (cons 'conf 0.98)
                                        (cons 'box (list 100 200 300 260)))
                                  (list (cons 'text "第二块")
                                        (cons 'conf 0.91)
                                        (cons 'box (list 320 200 500 260)))
                                  (list (cons 'text "无坐标块")
                                        (cons 'conf 0.5)
                                        (cons 'box nil)))))
        (list (cons 'page 2)
              (cons 'source "scan.png")
              (cons 'blocks (list (list (cons 'text "第二页唯一块")
                                        (cons 'conf 0.9)
                                        (cons 'box (list 10 10 20 20)))))))
  "假结果页数据，结构与 `eimg-core-parse-json' 的输出一致。
第一页三块里刻意留一块没有 `box'（ollama 后端就是这样），用于断言「无坐标的块
不产生 rect」；第二页只有一块，用于断言跨页的全局下标。")

(defun eimg-ocr-view-test--count (needle haystack)
  "返回 NEEDLE 在 HAYSTACK 里出现的次数（字面匹配，不当正则）。"
  (let ((pos 0)
        (n 0))
    (while (string-match (regexp-quote needle) haystack pos)
      (setq n (1+ n)
            pos (match-end 0)))
    n))

(defun eimg-ocr-view-test--state (pages &optional page-index current meta)
  "构造一个最小 STATE plist（只填断言用得到的键）。"
  (list :pages pages
        :entries (eimg-ocr-view--entries pages)
        :page-index (or page-index 0)
        :current current
        :meta meta))

(defun eimg-ocr-view-test--root ()
  "返回 eimg 仓库根目录（`test/' 的上一级）。
与 `eimg-ocr-ollama-test--root' 同一口径：优先 `locate-library'（`make test' 带
`-L .'），退化到 `default-directory'——测试不该依赖「从哪儿被拉起来」。"
  (let ((library (ignore-errors (locate-library "eimg"))))
    (if library
        (file-name-directory (file-truename (expand-file-name library)))
      (file-name-as-directory (expand-file-name default-directory)))))

(defun eimg-ocr-view-test--fixture-image ()
  "返回仓库里的测试页图绝对路径（`test/fixtures/hello.png'）。
用它当底图而不是临时文件：`--svg' 现在按路径读字节（前缀缓存键含 mtime / size），
「内嵌的字节 == 文件字节」这条断言只有拿真文件才成立。"
  (expand-file-name "test/fixtures/hello.png" (eimg-ocr-view-test--root)))

(defun eimg-ocr-view-test--make-image ()
  "造一张临时「页图」，内容固定为 3 字节 `abc'（base64 恰好是 \"YWJj\"）。
专供需要改 mtime 的用例（前缀缓存失效）：真夹具在仓库里，改它的 mtime 就是改
工作区。"
  (let ((file (make-temp-file "eimg-view-test-" nil ".png")))
    (with-temp-file file
      (set-buffer-multibyte nil)
      (insert "abc"))
    file))

(defun eimg-ocr-view-test--image-bytes-real (path)
  "以二进制方式读出 PATH 的字节（`--image-bytes' 的真实实现，供打桩计数时转调）。"
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (buffer-string)))

;;;; ── 1. 数据拍平 ────────────────────────────────────────────────────────

;; 拍平的结果是后续一切下标（热区 ID、文本行属性、`:current'）的唯一来源；
;; 拍错一位，图上的框和下面的文本行就整体错位。

(ert-deftest eimg-ocr-view-test-entries-flatten ()
  "`--entries' 把多页多块拍平成一条列表，且保留页内 / 全局两级信息。
无 `box' 的块**照样入列**（它是「有文本没框」，不是错误），只是 `:box' 为 nil。"
  (let ((entries (eimg-ocr-view--entries eimg-ocr-view-test--pages)))
    (should (= 4 (length entries)))
    ;; 顺序 = 页序 + 块序（翻页与导航都依赖这个顺序）：前 3 块属第 0 页、第 4 块属第 1 页
    (should (equal '(0 0 0 1) (mapcar (lambda (e) (plist-get e :page-index)) entries)))
    (should (equal '(0 1 2 0) (mapcar (lambda (e) (plist-get e :block-index)) entries)))
    (should (equal "第一块 中文" (plist-get (nth 0 entries) :text)))
    ;; 无 box 的块：入列、box 为 nil
    (should (null (plist-get (nth 2 entries) :box)))
    (should (equal "无坐标块" (plist-get (nth 2 entries) :text)))
    ;; 有 box 的块：四个数的列表（含跨页那一块）
    (should (equal '(320 200 500 260) (plist-get (nth 1 entries) :box)))
    (should (equal '(10 10 20 20) (plist-get (nth 3 entries) :box)))))

(ert-deftest eimg-ocr-view-test-page-entries-and-boxes ()
  "`--page-entries' 保留**全局**下标；`--page-boxes' 只留有坐标的块。
全局下标是刻意的：热区 ID、文本行属性、`:current' 都用它，任何一处改回页内序号
就要来回换算，迟早错一位。"
  (let* ((entries (eimg-ocr-view--entries eimg-ocr-view-test--pages))
         (first (eimg-ocr-view--page-entries entries 0))
         (boxes (eimg-ocr-view--page-boxes entries 0)))
    ;; 第 0 页三块，全局下标 0/1/2
    (should (equal '(0 1 2) (mapcar #'car first)))
    (should (equal "无坐标块" (plist-get (cdr (nth 2 first)) :text)))
    ;; 有坐标的只有两块，全局下标仍是 0/1
    (should (= 2 (length boxes)))
    (should (equal '(0 1) (mapcar #'car boxes)))
    (should (equal '(100 200 300 260) (cdr (nth 0 boxes))))
    ;; 一页一块坐标都没有时返回 nil（调用方据此走降级路径）
    (let ((boxless (list (list (cons 'page 1)
                               (cons 'blocks (list (list (cons 'text "只有文本")
                                                         (cons 'box nil))))))))
      (should-not (eimg-ocr-view--page-boxes
                   (eimg-ocr-view--entries boxless) 0)))))

(ert-deftest eimg-ocr-view-test-display-text-and-summary ()
  "显示文本压成一行（图上「一个框 = 一行」的唯一依据）；摘要按字符截断。
原文含换行时若不压，一个块会占多行，「光标在第几行 = 在第几块」就断了。"
  (should (equal "第一行 第二行 尾巴"
                 (eimg-ocr-view--display-text "  第一行\n第二行\t尾巴  ")))
  (should (equal "" (eimg-ocr-view--display-text nil)))
  (should (equal "单行" (eimg-ocr-view--display-text "单行")))
  ;; 摘要：截到 LIMIT 个字符再接省略号（`substring' 按字符，中文同样成立）
  (should (equal (concat (make-string 10 ?x) "…")
                 (eimg-ocr-view--entry-summary
                  (list :text (make-string 50 ?x)) 10)))
  ;; 不超限时原样返回（不补省略号）
  (should (equal "短文本"
                 (eimg-ocr-view--entry-summary (list :text "短文本") 30)))
  (should (equal "中文摘要"
                 (eimg-ocr-view--entry-summary (list :text "中文摘要") 30))))

;;;; ── 2. SVG 合成 ────────────────────────────────────────────────────────

;; SVG 是纯字符串，故这部分在 batch 下能逐字符断言。三件事必须同时正确才能画
;; 出对得上的图：viewBox 用原图坐标系、底图 `preserveAspectRatio="none"' 铺满、
;; rect 用原图坐标（不在这里乘缩放）。

(ert-deftest eimg-ocr-view-test-svg-structure ()
  "SVG 的骨架：viewBox / 根与底图尺寸 = 原图像素，底图带 `preserveAspectRatio=\"none\"'。
底图缺这个属性时，比例上的微小差异（浮点取整）就会让 SVG 把图等比居中缩小、
四周留白，而框还画在原坐标上——看起来像「框全偏了」，且完全静默。"
  (let* ((image (eimg-ocr-view-test--fixture-image))
         (base64 (eimg-ocr-view--base64 image))
         (boxes (eimg-ocr-view--page-boxes
                 (eimg-ocr-view--entries eimg-ocr-view-test--pages) 0))
         (svg (eimg-ocr-view--svg image 1000 800 500 400 boxes 0)))
    ;; 底图字节必须来自文件本身（不是某段假串）
    (should (stringp base64))
    (should (> (length base64) 0))
    (should svg)
    ;; rect 数量 = 有坐标的块数（3 块只有 2 个框）
    (should (= 2 (eimg-ocr-view-test--count "<rect" svg)))
    ;; 底图有且只有一张
    (should (= 1 (eimg-ocr-view-test--count "<image" svg)))
    (should (= 1 (eimg-ocr-view-test--count "<svg" svg)))
    (should (string-suffix-p "</svg>\n" svg))
    ;; viewBox 与根元素尺寸都用原图像素
    (should (string-match-p "viewBox=\"0 0 1000 800\"" svg))
    (should (string-match-p "<svg[^>]*width=\"1000\" height=\"800\"" svg))
    (should (string-match-p "<image[^>]*width=\"1000\" height=\"800\"" svg))
    ;; 底图铺满：preserveAspectRatio="none"
    (should (string-match-p "<image[^>]*preserveAspectRatio=\"none\"" svg))
    ;; data URI 带 MIME 与**文件字节**的 base64
    (should (string-match-p (concat "data:image/png;base64,"
                                    (regexp-quote base64))
                            svg))
    ;; 元素顺序：底图必须排在所有 rect 之前（后画的在上面，反了框会被图盖住）
    (should (< (string-search "<image" svg) (string-search "<rect" svg)))))

(ert-deftest eimg-ocr-view-test-svg-rect-original-coordinates ()
  "rect 用**原图**坐标、不乘缩放；stroke-width 随原图宽度放大。
缩放由 `viewBox' 与 `create-image' 的 `:width' / `:height' 完成——在这里再乘一次
就会出现两套换算，随缩放变化而彼此错位。"
  (let* ((image (eimg-ocr-view-test--fixture-image))
         (entries (eimg-ocr-view--entries eimg-ocr-view-test--pages))
         (boxes (eimg-ocr-view--page-boxes entries 0))
         (svg (eimg-ocr-view--svg image 1000 800 500 400 boxes nil))
         (wide (eimg-ocr-view--svg image 4000 3000 500 400 boxes nil)))
    ;; 第一块 (100 200 300 260) → x/y/width/height 原样
    (should (string-match-p
             "x=\"100.0\" y=\"200.0\" width=\"200.0\" height=\"60.0\"" svg))
    (should (string-match-p "x=\"320.0\"" svg))
    ;; stroke-width = max(2, round(width/400))：1000px → 2，4000px → 10
    (should (string-match-p "stroke-width=\"2\"" svg))
    (should (string-match-p "stroke-width=\"10\"" wide))
    ;; 上下颠倒的坐标也要画成正矩形（`svg-rect' 取 min/max）
    (should (string-match-p "width=\"200.0\" height=\"60.0\""
                            (eimg-ocr-view--svg image 1000 800 500 400
                                                (list (cons 0 (list 300 260 100 200)))
                                                nil)))))

(ert-deftest eimg-ocr-view-test-svg-highlight-differs ()
  "高亮块（`:current'）与普通块用不同颜色，且高亮块更粗。
高亮是「光标 ↔ 图」的可见反馈：同色就等于没有联动。"
  (let* ((image (eimg-ocr-view-test--fixture-image))
         (boxes (eimg-ocr-view--page-boxes
                 (eimg-ocr-view--entries eimg-ocr-view-test--pages) 0))
         (svg (eimg-ocr-view--svg image 1000 800 500 400 boxes 0))
         (quiet (eimg-ocr-view--svg image 1000 800 500 400 boxes nil)))
    ;; 高亮色出现两次（fill + stroke 各一次），普通描边色一次
    (should (= 2 (eimg-ocr-view-test--count eimg-ocr-view--stroke-current svg)))
    (should (= 1 (eimg-ocr-view-test--count eimg-ocr-view--stroke svg)))
    (should (string-match-p (concat "stroke=\"" eimg-ocr-view--stroke-current "\"") svg))
    (should (string-match-p
             (concat "fill=\"none\" stroke=\"" eimg-ocr-view--stroke "\"") svg))
    ;; 高亮块有半透明填充，普通块没有
    (should (string-match-p "fill-opacity=\"0.15\"" svg))
    (should-not (string-match-p "fill-opacity" quiet))
    ;; 没有 current 时两框同色（不存在高亮）
    (should (= 2 (eimg-ocr-view-test--count eimg-ocr-view--stroke quiet)))
    (should (= 0 (eimg-ocr-view-test--count eimg-ocr-view--stroke-current quiet)))
    ;; 两个颜色必须是**不同**的字面量（否则「异色」无从谈起）
    (should-not (equal eimg-ocr-view--stroke eimg-ocr-view--stroke-current))))

(ert-deftest eimg-ocr-view-test-svg-no-box-no-rect ()
  "无坐标的块既不产生 rect，也不影响其它块的数量。
ollama 后端一个 box 都没有时，这一页的 SVG 只有底图——多出来的框会指向不存在的
坐标，比不画更糟。"
  (let* ((image (eimg-ocr-view-test--fixture-image))
         (entries (eimg-ocr-view--entries eimg-ocr-view-test--pages))
         (boxes (eimg-ocr-view--page-boxes entries 0))
         (svg (eimg-ocr-view--svg image 1000 800 500 400 boxes nil)))
    ;; 3 块里 1 块无 box → rect 恰好 2 个
    (should (= 2 (eimg-ocr-view-test--count "<rect" svg)))
    ;; 完全无坐标的一页：只有底图
    (let ((empty-svg (eimg-ocr-view--svg image 1000 800 500 400 nil nil)))
      (should (= 0 (eimg-ocr-view-test--count "<rect" empty-svg)))
      (should (= 1 (eimg-ocr-view-test--count "<image" empty-svg)))
      (should (string-match-p "viewBox=\"0 0 1000 800\"" empty-svg))
      ;; 读不到底图时返回 **nil**（而不是半条 SVG）：调用方据此走降级分支
      (should-not (eimg-ocr-view--svg
                   (expand-file-name "eimg-view-test-nope.png"
                                     temporary-file-directory)
                   1000 800 500 400 boxes nil)))))

(ert-deftest eimg-ocr-view-test-svg-prefix-cache ()
  "同参数连调两次 `--svg' 只读一次盘，且两次结果**逐字相同**；画布或 mtime 一变就重建。
为什么这条是缓存正确性的关键：前缀里是整张底图的 base64，缓存命中却算错一点，
表现就是「框画在旧页图上」——比不缓存更糟且完全静默。
另外覆盖容量 3 的 LRU：超容淘汰最久未使用的那条——正是为了「多次翻页来回对比」时
不必反复重建前缀，同时也不会让缓存随翻过的页数无限增长。"
  (let ((image (eimg-ocr-view-test--make-image))
        (reads 0))
    (unwind-protect
        (progn
          ;; 全局缓存与 base64 缓存都要先清：别的用例可能已放入同键或他键的条目，
          ;; 留着会让「读了几次盘」这个计数失去意义。
          (setq eimg-ocr-view--svg-prefix-cache nil)
          (clrhash eimg-ocr-view--image-cache)
          (cl-letf (((symbol-function 'eimg-ocr-view--image-bytes)
                     (lambda (path)
                       (setq reads (1+ reads))
                       (eimg-ocr-view-test--image-bytes-real path))))
            (let* ((boxes (eimg-ocr-view--page-boxes
                           (eimg-ocr-view--entries eimg-ocr-view-test--pages) 0))
                   (first (eimg-ocr-view--svg image 1000 800 500 400 boxes 0))
                   (second (eimg-ocr-view--svg image 1000 800 500 400 boxes 0)))
              (should first)
              ;; 1. 命中缓存：两次结果逐字相同（缓存不能改变渲染结果）
              (should (equal first second))
              ;; 2. 第二次没有重新读盘 / 重新编码
              (should (= 1 reads))
              ;; 3. 换画布尺寸 → 前缀重建（viewBox 变了），底图字节仍走 base64 缓存
              (let ((wide (eimg-ocr-view--svg image 2000 800 500 400 boxes 0)))
                (should (string-match-p "viewBox=\"0 0 2000 800\"" wide))
                (should-not (equal wide first))
                (should (= 1 reads)))
              ;; 4. 同路径同尺寸但 mtime 变了（页图被重新识别覆盖）→ 必须重新读
              (set-file-times image (time-add (current-time) 5))
              (eimg-ocr-view--svg image 1000 800 500 400 boxes 0)
              (should (= 2 reads))
              ;; 5. 容量 3 的 LRU：连用 4 个不同画布（键互不相同）→ 淘汰最久未使用的那个
              ;;
              ;; 为什么这里要清 base64 缓存：`reads' 数的是 `--image-bytes'（读盘），
              ;; 而 `--base64' 自己也有缓存——不清的话，无论前缀重不重建，读盘都只发生
              ;; 一次，`reads' 就区分不出「命中」与「重建」。清掉之后判据很干脆：命中
              ;; 前缀根本不会调 `--base64'（读盘 0 次），重建则必然调它（读盘 +1）。
              (cl-flet ((key-of (w h)
                          ;; 按 `--svg-prefix' 的构成重建键（不硬编码 mtime / size，
                          ;; 否则一旦块 4 改过 mtime，这里的键就对不上）
                          (let ((attrs (file-attributes image)))
                            (list image (float-time (nth 5 attrs)) (nth 7 attrs)
                                  w h 500 400))))
                (setq eimg-ocr-view--svg-prefix-cache nil)
                (clrhash eimg-ocr-view--image-cache)
                (setq reads 0)
                (let* ((dims '((1000 800) (1200 800) (1400 800) (1600 800)))
                       (keys (mapcar (lambda (d) (key-of (nth 0 d) (nth 1 d))) dims)))
                  (dolist (d dims)
                    (eimg-ocr-view--svg image (nth 0 d) (nth 1 d) 500 400 boxes 0))
                  ;; 容量上界：用过 4 个键，缓存只留 3 条
                  (should (= 3 (length eimg-ocr-view--svg-prefix-cache)))
                  ;; 第 1 个键（最久未使用）已被淘汰
                  (should-not (assoc (nth 0 keys) eimg-ocr-view--svg-prefix-cache))
                  ;; LRU 顺序：表头是最后用过的，往后依次更旧
                  (should (equal (list (nth 3 keys) (nth 2 keys) (nth 1 keys))
                                 (mapcar #'car eimg-ocr-view--svg-prefix-cache)))
                  ;; 被淘汰的键再请求时必须**重建**而不是命中：清掉 base64 缓存后，
                  ;; 重建必然多读一次盘，命中则一次都不读。
                  (clrhash eimg-ocr-view--image-cache)
                  (let ((before reads))
                    (eimg-ocr-view--svg image 1000 800 500 400 boxes 0)
                    (should (> reads before)))
                  ;; 重建同时把它提到表头，且仍只留 3 条（第 2 个键被挤出）
                  (should (= 3 (length eimg-ocr-view--svg-prefix-cache)))
                  (should (equal (nth 0 keys)
                                 (car (car eimg-ocr-view--svg-prefix-cache))))
                  (should-not (assoc (nth 1 keys)
                                     eimg-ocr-view--svg-prefix-cache))
                  ;; 6. 命中即提升：请求位于表尾的第 3 个键 → 它被提到表头（而不是原地不动）。
                  ;; 同样是清掉 base64 缓存后判「有没有碰 base64」：不动说明这次是**命中**。
                  (clrhash eimg-ocr-view--image-cache)
                  (let ((before reads))
                    (eimg-ocr-view--svg image (nth 0 (nth 2 dims)) (nth 1 (nth 2 dims))
                                        500 400 boxes 0)
                    (should (= before reads)))
                  (should (equal (list (nth 2 keys) (nth 0 keys) (nth 3 keys))
                                 (mapcar #'car eimg-ocr-view--svg-prefix-cache))))))))
      (ignore-errors (delete-file image)))))

(ert-deftest eimg-ocr-view-test-mime-type ()
  "页图 MIME 由扩展名决定，未知扩展名兜底 `image/png'。
MIME 写错时浏览器 / Emacs 都解不出 data URI 里的图，症状是「图区一片空白」。"
  (should (equal "image/png" (eimg-ocr-view--mime-type "/a/b.png")))
  (should (equal "image/jpeg" (eimg-ocr-view--mime-type "/a/b.JPG")))
  (should (equal "image/gif" (eimg-ocr-view--mime-type "/a/b.gif")))
  (should (equal "image/webp" (eimg-ocr-view--mime-type "/a/b.webp")))
  (should (equal "image/png" (eimg-ocr-view--mime-type "/a/b.xyz")))
  (should (equal "image/png" (eimg-ocr-view--mime-type "/a/no-extension"))))

(ert-deftest eimg-ocr-view-test-base64-roundtrip ()
  "`--base64' 编出来的是**原始字节**的 base64（不因多字节编码被改写）。
`base64-encode-string' 作用在 multibyte 字符串上会先转码，图片于是解不出来。"
  (let* ((file (make-temp-file "eimg-view-test-" nil ".png")))
    (unwind-protect
        (progn
          ;; 写入含 0 字节与非 ASCII 字节的「二进制」内容
          (with-temp-file file
            (set-buffer-multibyte nil)
            (insert (unibyte-string 0 1 2 255 254 137 80 78 71)))
          (let ((encoded (eimg-ocr-view--base64 file)))
            (should (stringp encoded))
            (should (equal (unibyte-string 0 1 2 255 254 137 80 78 71)
                           (base64-decode-string encoded))))
          ;; 读不到时返回 nil（调用方据此降级，而不是插一张坏图）
          (should-not (eimg-ocr-view--base64
                       (expand-file-name "eimg-view-test-nope.png"
                                         temporary-file-directory))))
      (ignore-errors (delete-file file)))))

;;;; ── 3. 几何：`eimg-core-fit-size' 的接线 ──────────────────────────────

;; `--geometry' 的输入是 `image-size' 的结果，而它在 batch 下必报
;; `Window system frame should be used'（见文件头）。故这里打桩三个输入，
;; 断言它把「原图尺寸 + 图区上限」原样交给 `eimg-core-fit-size' 并取回结果。

(ert-deftest eimg-ocr-view-test-geometry-uses-fit-size ()
  "`--geometry' 的 `:scale' / `:px-w' / `:px-h' 就是 `eimg-core-fit-size' 的结果。
这条是「视图不自己发明缩放规则」的唯一保证：两处各算一遍，缩放变化时图片与热区
就会错开。"
  (cl-letf (((symbol-function 'create-image)
             (lambda (&rest _) 'eimg-view-test-spec))
            ((symbol-function 'image-size)
             (lambda (&rest _) '(1000 . 800)))
            ((symbol-function 'eimg-ocr-view--limits)
             (lambda () (cons 500 400))))
    (let* ((geometry (eimg-ocr-view--geometry "/tmp/x.png"))
           (fit (eimg-core-fit-size 1000 800 500 400)))
      (should geometry)
      ;; 原图尺寸进 viewBox，显示尺寸与 scale 进 create-image / 热区换算
      (should (equal "/tmp/x.png" (plist-get geometry :image)))
      (should (= 1000 (plist-get geometry :width)))
      (should (= 800 (plist-get geometry :height)))
      (should (equal (plist-get fit :scale) (plist-get geometry :scale)))
      (should (equal (plist-get fit :px-w) (plist-get geometry :px-w)))
      (should (equal (plist-get fit :px-h) (plist-get geometry :px-h)))
      (should (= 0.5 (plist-get geometry :scale)))
      (should (= 500 (plist-get geometry :px-w)))
      (should (= 400 (plist-get geometry :px-h))))))

(ert-deftest eimg-ocr-view-test-geometry-degrades ()
  "读不出尺寸（`create-image' / `image-size' 失败或返回非法值）时返回 nil。
调用方据此走「只显示文本 + 一行原因」，绝不能用占位尺寸继续画——那会把整页框
画到错的位置，而且完全静默。"
  ;; `create-image' 返回 nil（batch 下的真实情形）
  (cl-letf (((symbol-function 'create-image) (lambda (&rest _) nil))
            ((symbol-function 'image-size) (lambda (&rest _) '(1000 . 800))))
    (should-not (eimg-ocr-view--geometry "/tmp/x.png")))
  ;; `image-size' 返回 nil
  (cl-letf (((symbol-function 'create-image)
             (lambda (&rest _) 'eimg-view-test-spec))
            ((symbol-function 'image-size) (lambda (&rest _) nil)))
    (should-not (eimg-ocr-view--geometry "/tmp/x.png")))
  ;; 零尺寸 / 非数值：同样 nil（`eimg-core-fit-size' 的契约前置）
  (cl-letf (((symbol-function 'create-image)
             (lambda (&rest _) 'eimg-view-test-spec))
            ((symbol-function 'image-size) (lambda (&rest _) '(0 . 800))))
    (should-not (eimg-ocr-view--geometry "/tmp/x.png")))
  (cl-letf (((symbol-function 'create-image)
             (lambda (&rest _) 'eimg-view-test-spec))
            ((symbol-function 'image-size) (lambda (&rest _) '("1000" . 800))))
    (should-not (eimg-ocr-view--geometry "/tmp/x.png"))))

;;;; ── 4. 热区（image map） ───────────────────────────────────────────────

;; 热区三条事实来自 (info "(elisp) Image Descriptors")：一条热区是 `(AREA ID PLIST)'；
;; 矩形 AREA 是 `(rect . ((X0 . Y0) . (X1 . Y1)))'（左上 + 右下两个点）；
;; 坐标必须是**显示后**的像素，故要把原图坐标按 `px-w/width' 与 `px-h/height'
;; 各自换算（不用 `:scale'：它被钳到下限时与两轴实际比例最多差 1px）。

(ert-deftest eimg-ocr-view-test-image-map-scale ()
  "热区坐标按几何换算（`px-w/width'、`px-h/height'），形状是左上 / 右下两个点，
ID 与 help-echo 齐备。
坐标系搞错（写成 X0 Y0 WIDTH HEIGHT）时，所有框会整体错位到右下——而 Emacs 不报错。"
  (let ((map (eimg-ocr-view--image-map
              (eimg-ocr-view-test--state eimg-ocr-view-test--pages)
              (list :image "/tmp/x.png" :width 1000 :height 800
                    :scale 0.5 :px-w 500 :px-h 400))))
    (should (= 2 (length map)))
    ;; 形状：`(rect . ((x0 . y0) . (x1 . y1)))'
    (should (eq 'rect (car (nth 0 (car map)))))
    (should (equal '((50 . 100) . (150 . 130)) (cdr (nth 0 (car map)))))
    ;; 第二块 (320 200 500 260) × 0.5 → (160,100)-(250,130)
    (should (equal '((160 . 100) . (250 . 130)) (cdr (nth 0 (nth 1 map)))))
    ;; ID 是块下标，且能从 ID 反解回来
    (should (eq 'eimg-ocr-view-entry-0 (nth 1 (car map))))
    (should (eq 'eimg-ocr-view-entry-1 (nth 1 (nth 1 map))))
    (should (= 1 (eimg-ocr-view--id-index 'eimg-ocr-view-entry-1)))
    (should-not (eimg-ocr-view--id-index 'some-other-symbol))
    ;; 指针与帮助文本（点之前能确认是哪一块）
    (should (equal 'hand (plist-get (nth 2 (car map)) 'pointer)))
    (should (string-match-p "第 1 块" (plist-get (nth 2 (car map)) 'help-echo)))))

(ert-deftest eimg-ocr-view-test-image-map-clamp ()
  "热区被夹进画面内，且每条边至少 1px。
越界的热区永远点不中；零宽 / 零高的热区同理（单像素高的连字符在 OCR 里并不罕见），
所以「至少 1px」是可用性要求而不是美观要求。"
  (let* ((pages (list (list (cons 'page 1)
                            (cons 'blocks (list (list (cons 'text "越界")
                                                      (cons 'box (list 900 700 1200 900)))
                                                (list (cons 'text "零尺寸")
                                                      (cons 'box (list 10 10 10 10))))))))
         (geometry (list :image "/tmp/x.png" :width 500 :height 400
                         :scale 1.0 :px-w 500 :px-h 400))
         (map (eimg-ocr-view--image-map
               (eimg-ocr-view-test--state pages) geometry)))
    ;; 越界块被夹到画面右下角（x ≤ px-w、y ≤ px-h）
    (should (equal '((499 . 399) . (500 . 400)) (cdr (nth 0 (car map)))))
    ;; 零尺寸块退化成 1×1 的热区（否则永远点不中）
    (should (equal '((10 . 10) . (11 . 11)) (cdr (nth 0 (nth 1 map)))))
    ;; 负坐标夹到 0
    (let ((neg (list (list (cons 'page 1)
                           (cons 'blocks (list (list (cons 'text "负")
                                                     (cons 'box (list -50 -50 100 100)))))))))
      (should (equal '((0 . 0) . (100 . 100))
                     (cdr (nth 0 (car (eimg-ocr-view--image-map
                                       (eimg-ocr-view-test--state neg)
                                       geometry)))))))))

(ert-deftest eimg-ocr-view-test-image-map-reverse-box ()
  "左右 / 上下颠倒的 box：热区与 SVG 框用同一份 min/max 归一，两者必须对得上。
只归一处的后果是「框画得对、却点不中」，且不报错——这条用例把两处结果直接对比。"
  (let* ((pages (list (list (cons 'page 1)
                            (cons 'blocks (list (list (cons 'text "颠倒")
                                                      (cons 'box (list 300 200 100 100))))))))
         (geometry (list :image "/tmp/x.png" :width 1000 :height 800
                         :scale 0.5 :px-w 500 :px-h 400))
         (map (eimg-ocr-view--image-map (eimg-ocr-view-test--state pages) geometry))
         (rect (cdr (nth 0 (car map)))))
    ;; box (300 200 100 100) 归一成 (100,100)-(300,200)，× 0.5 → (50,50)-(150,100)
    (should (equal '((50 . 50) . (150 . 100)) rect))
    (should (< (car (car rect)) (car (cdr rect))))
    (should (< (cdr (car rect)) (cdr (cdr rect))))
    ;; 与 `--svg-rect' 画出的框逐项一致：框的 x/y/w/h 换算回显示像素就是热区四角
    (let ((svg-rect (eimg-ocr-view--svg-rect (list 300 200 100 100) 2 nil)))
      (should (string-match-p
               "x=\"100.0\" y=\"100.0\" width=\"200.0\" height=\"100.0\"" svg-rect))
      (should (= (car (car rect)) (round (* 100 0.5))))
      (should (= (cdr (car rect)) (round (* 100 0.5))))
      (should (= (car (cdr rect)) (round (* 300 0.5))))
      (should (= (cdr (cdr rect)) (round (* 200 0.5)))))))

;;;; ── 5. 降级路径 ────────────────────────────────────────────────────────

;; 降级不是「出错」，而是三种正常可见的状态。文案必须说清「为什么没有图」——
;; 静默的空白区会让用户以为识别结果坏了。

(ert-deftest eimg-ocr-view-test-prepare-page-no-boxes ()
  "本页一块坐标都没有（ollama 后端）→ 无几何 + 提示「后端不提供 box」。"
  (let* ((pages (list (list (cons 'page 1)
                            (cons 'source "scan.png")
                            (cons 'blocks (list (list (cons 'text "只有文本")
                                                      (cons 'box nil)))))))
         (prepared (eimg-ocr-view--prepare-page
                    (eimg-ocr-view-test--state pages) 0)))
    (should-not (plist-get prepared :geometry))
    (should (string-match-p "没有坐标数据" (plist-get prepared :visual-hint)))))

(ert-deftest eimg-ocr-view-test-prepare-page-no-image ()
  "有坐标但找不到页图 → 无几何 + 提示用 PDF 输入或重新识别。
`--page-image' 只信两级证据：页的 `image' 字段（CLI 落的图）与**存在的绝对路径**
来源；`:source' 常常只是 basename，猜 `default-directory' 只会画出别的目录里同名
的另一张图。"
  (let* ((state (eimg-ocr-view-test--state eimg-ocr-view-test--pages 0 nil
                                          (list :source "scan.png")))
         (prepared (eimg-ocr-view--prepare-page state 0)))
    (should-not (plist-get prepared :geometry))
    (should (string-match-p "找不到页图" (plist-get prepared :visual-hint)))
    ;; 相对 / 不存在的来源不算页图
    (should-not (eimg-ocr-view--page-image
                 (nth 0 eimg-ocr-view-test--pages) (list :source "scan.png")))
    ;; 绝对路径但不存在 → 也不算
    (should-not (eimg-ocr-view--page-image
                 (nth 0 eimg-ocr-view-test--pages)
                 (list :source (expand-file-name "eimg-view-test-nope.png"
                                                 temporary-file-directory))))))

(ert-deftest eimg-ocr-view-test-page-image-two-candidates ()
  "页图取值两级候选：页的 `image' 字段优先，其次是存在且非 PDF 的绝对路径来源。"
  (let ((image (make-temp-file "eimg-view-test-page-" nil ".png"))
        (source (make-temp-file "eimg-view-test-source-" nil ".jpg"))
        (pdf (make-temp-file "eimg-view-test-source-" nil ".pdf")))
    (unwind-protect
        (progn
          ;; 1. `image' 字段优先（即使 :source 也可用）
          (should (equal image
                         (eimg-ocr-view--page-image
                          (list (cons 'image image)) (list :source source))))
          ;; 2. 没有 image 字段时退到绝对路径来源
          (should (equal source
                         (eimg-ocr-view--page-image
                          nil (list :source source))))
          ;; 3. PDF 来源不算页图（PDF 本身不能当底图画）
          (should-not (eimg-ocr-view--page-image nil (list :source pdf)))
          ;; 4. 空字符串 / 非字符串都不算
          (should-not (eimg-ocr-view--page-image
                       (list (cons 'image "")) (list :source "")))
          (should-not (eimg-ocr-view--page-image nil (list :source 42))))
      (dolist (file (list image source pdf))
        (ignore-errors (delete-file file))))))

(ert-deftest eimg-ocr-view-test-prepare-page-unreadable ()
  "有坐标、页图也在，但读不出尺寸 / 读不出内容 → 两种不同的提示，都要带上路径。
提示里给路径是因为「哪一个文件出了问题」是用户唯一能自己动手修的信息。"
  ;; `image' / `pages' / `state' 都提到同一层 `let*'：这条用例的重点是两条降级
  ;; 文案，嵌套再深一层括号就难以核对。
  (let* ((image (make-temp-file "eimg-view-test-page-" nil ".png"))
         (pages (list (list (cons 'page 1)
                            (cons 'image image)
                            (cons 'blocks (list (list (cons 'text "块")
                                                      (cons 'box (list 1 2 3 4))))))))
         (state (eimg-ocr-view-test--state pages)))
    (unwind-protect
        (progn
          (with-temp-file image
            (insert "not really a png"))
          ;; 读不出尺寸：打桩 `--geometry' 返回 nil
          (cl-letf (((symbol-function 'eimg-ocr-view--geometry)
                     (lambda (&rest _) nil)))
            (let ((prepared (eimg-ocr-view--prepare-page state 0)))
              (should-not (plist-get prepared :geometry))
              (should (string-match-p
                       "无法读取页图尺寸"
                       (plist-get prepared :visual-hint)))
              (should (string-match-p
                       (regexp-quote image)
                       (plist-get prepared :visual-hint)))))
          ;; 读不出内容：geometry 有值但 base64 为 nil
          (cl-letf (((symbol-function 'eimg-ocr-view--geometry)
                     (lambda (&rest _)
                       (list :image image :width 10 :height 10
                             :scale 1.0 :px-w 10 :px-h 10)))
                    ((symbol-function 'eimg-ocr-view--base64)
                     (lambda (&rest _) nil)))
            (let ((prepared (eimg-ocr-view--prepare-page state 0)))
              (should-not (plist-get prepared :geometry))
              (should (string-match-p
                       "无法读取页图内容"
                       (plist-get prepared :visual-hint))))))
      (ignore-errors (delete-file image)))))

(ert-deftest eimg-ocr-view-test-prepare-page-embed-limit ()
  "底图字节数超过 `eimg-ocr-view-max-embed-bytes' 时**明确降级**：不内嵌，只给文本列表
+ 可行动的提示；上限放大到足够时同一条路径照常出几何。
上限防的是「几十 MB 的 base64 串进 SVG 后 `create-image' 解析卡死」——所以判据必须
只看 `stat'（本用例的文件内容不是真 PNG 也能判），且超限时不再去读尺寸 / 读内容。"
  (let* ((image (make-temp-file "eimg-view-test-big-" nil ".png"))
         (pages (list (list (cons 'page 1)
                            (cons 'image image)
                            (cons 'blocks (list (list (cons 'text "块")
                                                      (cons 'box (list 1 2 3 4))))))))
         (state (eimg-ocr-view-test--state pages)))
    (unwind-protect
        (progn
          (with-temp-file image
            (insert (make-string 500 ?x)))
          ;; 上限 100 字节 → 走降级；后续两步（尺寸 / 内容）一律不该发生
          (let ((eimg-ocr-view-max-embed-bytes 100)
                (prepared nil))
            (cl-letf (((symbol-function 'eimg-ocr-view--geometry)
                       (lambda (&rest _) (error "超限时不该再算几何")))
                      ((symbol-function 'eimg-ocr-view--base64)
                       (lambda (&rest _) (error "超限时不该再读底图"))))
              (setq prepared (eimg-ocr-view--prepare-page state 0)))
            (let ((hint (plist-get prepared :visual-hint)))
              (should-not (plist-get prepared :geometry))
              (should hint)
              (should (string-match-p "超出内嵌上限" hint))
              ;; 提示里要带上「实际多大」和「上限多大」，以及可行动的下一步
              (should (string-match-p
                       (regexp-quote (eimg-ocr-view--format-bytes 500)) hint))
              (should (string-match-p
                       (regexp-quote (eimg-ocr-view--format-bytes 100)) hint))
              (should (string-match-p "--dpi" hint))))
          ;; 上限放大到 1 MB → 不再命中降级分支（几何 / 底图打桩成功即可）
          (let ((eimg-ocr-view-max-embed-bytes (* 1024 1024)))
            (cl-letf (((symbol-function 'eimg-ocr-view--geometry)
                       (lambda (&rest _)
                         (list :image image :width 10 :height 10
                               :scale 1.0 :px-w 10 :px-h 10)))
                      ((symbol-function 'eimg-ocr-view--base64)
                       (lambda (&rest _) "YWJj")))
              (let ((prepared (eimg-ocr-view--prepare-page state 0)))
                (should (plist-get prepared :geometry))
                (should-not (plist-get prepared :visual-hint))))))
      (ignore-errors (delete-file image)))))

(ert-deftest eimg-ocr-view-test-prepare-page-no-svg-support ()
  "本机 Emacs 没有 SVG 支持（缺 librsvg）时显式降级，并说清「文本列表仍可用」。
这条判定必须显式：只靠 `create-image' 返 nil 兜底时，图区会写「本页暂无可显示的
页图」——把「这台 Emacs 画不了」错说成「本页没有图」，用户找不到真正原因。"
  (let* ((image (make-temp-file "eimg-view-test-svg-" nil ".png"))
         (pages (list (list (cons 'page 1)
                            (cons 'image image)
                            (cons 'blocks (list (list (cons 'text "块")
                                                      (cons 'box (list 1 2 3 4))))))))
         (state (eimg-ocr-view-test--state pages)))
    (unwind-protect
        (progn
          (with-temp-file image
            (insert "not really a png"))
          (cl-letf (((symbol-function 'image-type-available-p)
                     (lambda (&rest _) nil))
                    ;; 没有 SVG 时「算几何 / 读底图」都是白做：两条都设成一碰就炸，
                    ;; 用来锁住它们在判定链里的位置（排在 SVG 判定之后）。
                    ((symbol-function 'eimg-ocr-view--geometry)
                     (lambda (&rest _) (error "没有 SVG 支持时不该算几何")))
                    ((symbol-function 'eimg-ocr-view--base64)
                     (lambda (&rest _) (error "没有 SVG 支持时不该读底图"))))
            (let ((prepared (eimg-ocr-view--prepare-page state 0)))
              (should-not (plist-get prepared :geometry))
              (should (string-match-p "SVG" (plist-get prepared :visual-hint)))
              (should (string-match-p "文本列表"
                                      (plist-get prepared :visual-hint))))))
      (ignore-errors (delete-file image)))))

;;;; ── 6. 模式行与键位 ────────────────────────────────────────────────────

(ert-deftest eimg-ocr-view-test-mode-line-string ()
  "模式行显示「第 N/M 页 · 第 K/L 块 · 后端 X」，且 `%' 被转义。
模式行里的字符串仍按格式串解释：后端名带一个 `%' 就会让整行显示错乱，
`(:eval ...)' 的返回值也不例外。"
  (with-temp-buffer
    (setq eimg-ocr-view--state
          (eimg-ocr-view-test--state eimg-ocr-view-test--pages 0 1
                                    (list :backend "rapidocr")))
    (let ((line (eimg-ocr-view-mode-line-string)))
      (should (string-match-p "第 1/2 页" line))
      (should (string-match-p "第 2/3 块" line))
      (should (string-match-p "rapidocr" line)))
    ;; 后端缺省时也不能空着（空字符串会让模式行看起来「少了半截」）
    (setq eimg-ocr-view--state
          (eimg-ocr-view-test--state eimg-ocr-view-test--pages 0 0 nil))
    (should (string-match-p "未知后端" (eimg-ocr-view-mode-line-string)))
    ;; `%' 转义
    (setq eimg-ocr-view--state
          (eimg-ocr-view-test--state eimg-ocr-view-test--pages 0 0
                                    (list :backend "100%local")))
    (should (string-match-p "100%%local" (eimg-ocr-view-mode-line-string)))))

(ert-deftest eimg-ocr-view-test-mode-keys ()
  "视图模式八个键位全部绑到预期命令；模式本身派生自 `special-mode'。
`special-mode' 这条不是细节：它给了只读语义与 `q' 的默认行为，缺了它
用户在视图里随手一按就能改坏文本行、进而让联动错位。
（这里查 `derived-mode-parent' 属性而不是调 `derived-mode-p'：后者看的是**当前
buffer** 的模式，而用例跑在 `*ert*' 里。）"
  (should (eq 'special-mode (get 'eimg-ocr-view-mode 'derived-mode-parent)))
  (dolist (entry '(("n" . eimg-ocr-view-next-block)
                   ("p" . eimg-ocr-view-previous-block)
                   ("N" . eimg-ocr-view-next-page)
                   ("P" . eimg-ocr-view-previous-page)
                   ("RET" . eimg-ocr-view-copy-block)
                   ("o" . eimg-ocr-view-open-image)
                   ("g" . eimg-ocr-view-revert)
                   ("q" . quit-window)))
    (should (eq (cdr entry)
                (keymap-lookup eimg-ocr-view-mode-map (car entry))))))

;;;; ── 7. 入口命令 ────────────────────────────────────────────────────────

(ert-deftest eimg-ocr-view-test-command-without-result ()
  "没有识别结果时 `eimg-ocr-view' 报 `user-error' 并说明怎么办。
比静默打开一个空视图好：空视图看不出是「还没识别」还是「视图坏了」。"
  (dolist (name (list eimg-ocr-buffer-name eimg-ocr-view-buffer-name))
    (when (get-buffer name)
      (ignore-errors (kill-buffer (get-buffer name)))))
  (with-temp-buffer
    (let ((err (should-error (eimg-ocr-view) :type 'user-error)))
      (should (string-match-p "识别" (error-message-string err))))))

(ert-deftest eimg-ocr-view-test-command-renders-degraded ()
  "从 `*eimg-ocr*' 打开视图时，batch 下走降级分支也不炸：buffer 建好、模式正确、
文本列表进了 buffer、图区写明「找不到页图」。
这条是「按 `v' 不会把用户的 Emacs 弄坏」的最低保证——真实的图片渲染只能在 GUI
里验证，但「没有图时给出可读原因」必须在这里锁住。"
  (let ((result-buffer (get-buffer-create eimg-ocr-buffer-name))
        (view-buffer nil))
    (unwind-protect
        (progn
          (with-current-buffer result-buffer
            ;; 只放结构，不走渲染：视图只读这份 plist。
            (setq-local eimg-ocr--result-data
                        (list :pages eimg-ocr-view-test--pages
                              :meta (list :backend "rapidocr"
                                          :source "scan.png"))))
          (setq view-buffer (eimg-ocr-view))
          (should (buffer-live-p view-buffer))
          (with-current-buffer view-buffer
            (should (derived-mode-p 'eimg-ocr-view-mode))
            ;; 文本列表：该页三块都在（含无坐标那块）
            (should (string-match-p "第一块 中文" (buffer-string)))
            (should (string-match-p "第二块" (buffer-string)))
            (should (string-match-p "无坐标块" (buffer-string)))
            ;; 图区降级文案（batch 下找不到页图 → 说的是「找不到页图」）
            (should (string-match-p "找不到页图" (buffer-string)))
            ;; 光标落在当前块那一行（`:current' 默认 0）
            (should (equal 0 (eimg-ocr-view--point-entry)))
            ;; 状态里的结构对得上
            (should (= 4 (length (plist-get eimg-ocr-view--state :entries))))))
      (dolist (buffer (list result-buffer view-buffer))
        (when (buffer-live-p buffer)
          (ignore-errors (kill-buffer buffer)))))))

;;;; ── 8. 反向换算：`--posn-entry' 与 `--image-map' 必须同源 ──────────────

;; 正向（`--image-map'）与反向（`--posn-entry'）各写一套换算基准的后果：
;; 热区点得中 A 块，兜底路径（热区 ID 拿不到时）反解出的却是 B 块，且两者都不报错。
;; 故两条路径统一用 `px-w/width' 与 `px-h/height'，`:scale' 不参与坐标换算
;; （它被 `eimg-core-fit-size' 钳到下限时与两轴实际比值不再自洽）。

(defun eimg-ocr-view-test--posn-state (pages geometry)
  "构造带 `:geometry' 的 STATE：`--posn-entry' 的数据入口。"
  (plist-put (eimg-ocr-view-test--state pages) :geometry geometry))

(defun eimg-ocr-view-test--posn-call (state x y)
  "在 STATE 下用显示坐标 (X . Y) 调 `--posn-entry'，返回块下标或 nil。
`event-start' / `posn-object-x-y' 都打桩：batch 下没有真实 frame，也没有真实事件。"
  (let ((eimg-ocr-view--state state))
    (cl-letf (((symbol-function 'event-start)
               (lambda (&rest _) 'eimg-view-test-position))
              ((symbol-function 'posn-object-x-y)
               (lambda (&rest _) (cons x y))))
      (eimg-ocr-view--posn-entry 'eimg-view-test-event))))

(defconst eimg-ocr-view-test--posn-pages
  (list (list (cons 'page 1)
              (cons 'blocks (list (list (cons 'text "左上块")
                                        (cons 'box (list 240 115 260 135)))
                                  (list (cons 'text "右下块")
                                        (cons 'box (list 300 200 400 300)))))))
  "给反向换算专用的两页块数据：两块分居左上与右下，便于区分「换算到哪去了」。")

(ert-deftest eimg-ocr-view-test-posn-entry-px-basis ()
  "显示坐标按 `width/px-w'、`height/px-h' 反解回原图坐标，再按框匹配。
geometry `(:width 1000 :height 500 :px-w 400 :px-h 200)' 下，显示 (100 . 50) 对应
原图 (250 . 125)——落在「左上块」(240,115)-(260,135) 里。"
  (let* ((geometry (list :image "/tmp/x.png" :width 1000 :height 500
                         :scale 0.4 :px-w 400 :px-h 200))
         (state (eimg-ocr-view-test--posn-state
                 eimg-ocr-view-test--posn-pages geometry)))
    ;; (100 . 50) → (250 . 125)：命中第一块
    (should (= 0 (eimg-ocr-view-test--posn-call state 100 50)))
    ;; (140 . 100) → (350 . 250)：命中第二块（说明不是「总是第一块」）
    (should (= 1 (eimg-ocr-view-test--posn-call state 140 100)))
    ;; (10 . 10) → (25 . 25)：不在任何框里
    (should-not (eimg-ocr-view-test--posn-call state 10 10))))

(ert-deftest eimg-ocr-view-test-posn-entry-ignores-clamped-scale ()
  "`scale' 被钳到下限而与两轴比例不自洽时，反解用的是 px 比例而不是 `scale'。
构造 `:scale 0.01' + `px-w/width = 0.4'：按 scale 反解 (100 . 50) 会落到
(10000 . 5000)（画面外，无框可命中），按 px 比例才是 (250 . 125)。返回 0 即证明
走的是 px 比例。"
  (let* ((geometry (list :image "/tmp/x.png" :width 1000 :height 500
                         :scale 0.01 :px-w 400 :px-h 200))
         (state (eimg-ocr-view-test--posn-state
                 eimg-ocr-view-test--posn-pages geometry))
         (scale (plist-get geometry :scale))
         (boxes (mapcar (lambda (block) (alist-get 'box block))
                        (alist-get 'blocks (car eimg-ocr-view-test--posn-pages)))))
    ;; 前置：按 scale 反解出来的点确实不在任何框里（否则这条用例证明不了什么）
    (let ((sx (/ 100.0 scale))
          (sy (/ 50.0 scale)))
      (should-not (cl-some (lambda (box)
                             (and (<= (nth 0 box) sx) (<= sx (nth 2 box))
                                  (<= (nth 1 box) sy) (<= sy (nth 3 box))))
                           boxes)))
    ;; 按 px 比例反解 (100 . 50) → (250 . 125) → 第一块
    (should (= 0 (eimg-ocr-view-test--posn-call state 100 50)))))

(ert-deftest eimg-ocr-view-test-image-map-posn-inverse ()
  "同一 geometry 下 `--image-map'（正向）与 `--posn-entry'（反向）互为逆运算。
取每条热区矩形的中心回代，必须反解出**同一个**块下标——这是「点图与兜底路径
指向同一块」的机器检查。"
  (let* ((geometry (list :image "/tmp/x.png" :width 1000 :height 800
                         :scale 0.5 :px-w 500 :px-h 400))
         (state (eimg-ocr-view-test--posn-state
                 eimg-ocr-view-test--pages geometry))
         (map (eimg-ocr-view--image-map state geometry)))
    (should (= 2 (length map)))
    (dolist (item map)
      (let* ((rect (cdr (nth 0 item)))
             (id (eimg-ocr-view--id-index (nth 1 item)))
             ;; rect 是 `((x0 . y0) . (x1 . y1))'：两点各是一个 cons，
             ;; 不是四个元素的列表，故第二点只能用 `(cdr rect)' 取。
             (p0 (car rect))
             (p1 (cdr rect))
             (cx (/ (+ (car p0) (car p1)) 2.0))
             (cy (/ (+ (cdr p0) (cdr p1)) 2.0)))
        (should (= id (eimg-ocr-view-test--posn-call state cx cy)))))))

(provide 'eimg-ocr-view-test)

;;; eimg-ocr-view-test.el ends here
