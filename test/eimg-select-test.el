;;; eimg-select-test.el --- eimg-select 与 embark 接线的 ERT 用例  -*- lexical-binding: t; -*-

;; Author: ThomasDon
;; Version: 0.1.0
;; Keywords: convenience, tools, images

;;; Commentary:

;; 覆盖 `eimg-select' 的两块纯逻辑与一处**跨文件一致性**：
;;   - `eimg-select--preview-fit' 的尺寸换算（含非法输入）；
;;   - `eimg-select--paths' 的 target 归一化（string / list / nil / 带属性）；
;;   - `eimg-select--read' 的 `:category' 与 `eimg-embark.el' 注册的 keymap
;;     符号必须逐字一致（embark 对它做 `symbol-value'，差一字即 void-variable）。
;;
;; `C-.' 的动作菜单本体在 embark 加载后才定义，`emacs -Q' 下无法运行时断言，
;; 故该部分一律走源码文本断言（先例：`eimg-core-test-no-third-party-features'）。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'eimg-select)

;;;; ── 1. 预览尺寸换算 ────────────────────────────────────────────────────

(ert-deftest eimg-select-test-preview-fit-bounds ()
  "`--preview-fit' 超大输入缩放与非法输入 nil（签名 8 参，含 max-w）。"
  (let ((args '(700 8 16 100 50 1 0)))
    ;; 超大图必须被 max-w 或父 frame 字符上限夹住，且保持宽高比
    (let ((fit (apply #'eimg-select--preview-fit (cons 4000 3000) args)))
      (should (consp fit))
      (should (< (plist-get fit :scale) 1.0))
      (should (<= (plist-get fit :px-w) 700))
      (should (integerp (plist-get fit :chars-w)))
      (should (integerp (plist-get fit :chars-h)))
      (should (< (abs (- (/ (float (plist-get fit :px-w))
                            (float (plist-get fit :px-h)))
                         (/ 4000.0 3000.0)))
                 0.01)))
    ;; 非法输入一律返回 nil：nil / 0 / 浮点 / 缺 cdr / 零宽 / fw=0
    (should-not (apply #'eimg-select--preview-fit nil args))
    (should-not (apply #'eimg-select--preview-fit 0 args))
    (should-not (apply #'eimg-select--preview-fit
                       (cons 800.0 600.0) args))
    (should-not (apply #'eimg-select--preview-fit (cons 800 nil) args))
    (should-not (apply #'eimg-select--preview-fit (cons 0 600) args))
    (should-not (apply #'eimg-select--preview-fit
                       (cons 800 600) '(700 0 16 100 50 1 0)))))

(ert-deftest eimg-select-test-preview-hide-without-posframe ()
  "posframe 未加载时 `--preview-hide' 静默返回 nil（预览失败不向上抛错）。"
  (unless (fboundp 'posframe-delete)
    (should-not (eimg-select--preview-hide))))

;;;; ── 2. target 归一化 ───────────────────────────────────────────────────

(ert-deftest eimg-select-test-paths-normalize ()
  "`--paths' 归一化：string / list / nil / 带 text property 四种输入。"
  (let ((a (expand-file-name "a.png" temporary-file-directory))
        (b (expand-file-name "b.png" temporary-file-directory)))
    (should (equal (eimg-select--paths a) (list a)))
    (should (equal (eimg-select--paths (list a b)) (list a b)))
    (should-not (eimg-select--paths nil))
    ;; 候选带 `eimg/image-path' 属性时以属性为准（缩略显示下的真实路径）
    (should (equal (eimg-select--paths
                    (propertize "~/x.png" 'eimg/image-path "/real/x.png"))
                   '("/real/x.png")))
    ;; 空串不是路径：`expand-file-name' 会返回目录，必须被剔除
    (should-not (eimg-select--paths ""))
    (should-not (eimg-select--paths 42))))

;;;; ── 3. embark 注册与 category 的跨文件一致性 ──────────────────────────

(defun eimg-select-test--source (library)
  "返回同仓库 LIBRARY 的源码文本；取不到时返回空串。"
  (let ((path (locate-library library)))
    (if (not path)
        ""
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-string)))))

(ert-deftest eimg-select-test-embark-registration-source ()
  "embark 注册、keymap 定义与 `:category' 三者逐字一致（源码文本断言）。

`defvar-keymap' 与 `add-to-list' 都在 `with-eval-after-load 'embark' 内，
`emacs -Q' 下永不执行，故只能断言源码锚点：
- 注册值必须是**已定义**的 keymap 符号（embark 对它做 `symbol-value'）；
- 注册的 category 必须与 `eimg-select--read' 里的 `:category' 逐字相同，
  否则按 `C-.'` 时 refine 失配——一个在 `eimg-embark.el'、一个在
  `eimg-select.el'，跨文件不一致没有编译器能发现，只能靠这条用例。"
  (let ((embark (eimg-select-test--source "eimg-embark"))
        (select (eimg-select-test--source "eimg-select")))
    (should embark)
    (should select)
    ;; 注册与 keymap 定义都在延迟加载块内（避免启动期硬依赖 embark）
    (should (string-match-p
             (regexp-quote "(with-eval-after-load 'embark") embark))
    (should (string-match-p (regexp-quote "(add-to-list 'embark-keymap-alist")
                            embark))
    (should (string-match-p (regexp-quote "(defvar-keymap eimg-image-map")
                            embark))
    ;; 注册的两项都必须逐字匹配定义名与 category 名
    (should (string-match-p (regexp-quote "'(eimg/image eimg-image-map)")
                            embark))
    (should-not (string-match-p (regexp-quote "eimg-image-map ") embark))
    ;; 变量名不得写成别的东西（历史遗留的连字符形态）
    (should-not (string-match-p (regexp-quote "eimg--image-map") embark))
    ;; category 必须与 select 侧一致
    (should (string-match-p (regexp-quote ":category 'eimg/image") select))
    ;; 两个 source（截图 / 全部图片）都要带该 category
    (should (equal 2 (let ((start 0) (n 0))
                       (while (string-match ":category 'eimg/image" select start)
                         (setq n (1+ n) start (match-end 0)))
                       n)))
    ;; 顶层不得硬依赖 embark（headless 测试进程没有它）
    (should-not (string-match-p "^(require 'embark"
                                (replace-regexp-in-string "^[ \t]*;;.*$" ""
                                                          embark)))))

(provide 'eimg-select-test)

;;; eimg-select-test.el ends here
