;;; eimg-insert.el --- 图片插入：按 major-mode 格式化链接、选区替换与内联显示  -*- lexical-binding: t; byte-compile-warnings: (not unresolved noruntime) -*-

;; Author: ThomasDon
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, tools, images
;; URL: https://github.com/awerdx520/eimg

;;; Commentary:

;; 本文件负责「把一张已经拿到的图片放进当前文档」：链接格式化（按 major-mode
;; 分派）、选区文本当路径解析、选区替换、内联图片显示。它不采集、不挑选。
;;
;; 两条设计约束，改动时不要打破：
;;   1. **顶层零第三方依赖**：只 require 内置库（`image' / `subr-x'）与同仓库
;;      的 `eimg-core' / `eimg-select'。evil 的 visual state 判断一律
;;      `fboundp' 守卫——`emacs -Q' 测试进程里没有 evil。
;;   2. **路径一律 `abbreviate-file-name'**：图片与文档物理分离，且 `~/Org'
;;      常是符号链接，相对路径的基准随打开方式变化必有一端失效。

;;; Code:

(require 'image)
(require 'subr-x)
(require 'eimg-core)
(require 'eimg-select)

;;;; ── 1. 配置项 ──────────────────────────────────────────────────────────

(defcustom eimg-insert-plain-path-modes '(eca-chat-mode)
  "只插入裸缩写路径（不做 org / markdown 链接包装）的 major-mode 家族。

元素与当前 `major-mode' 按 `derived-mode-p' 家族关系匹配，即列出的模式及其
派生模式都命中。默认值 `(eca-chat-mode)'：与 AI 助手的会话里要把图片交给
模型，路径文本才有意义，展示层的 `![](file:…)' 包装对模型无益（把本变量置
nil 即整体回退，不必改实现）。

**顺序约束**：`eca-chat-mode' 派生自 `markdown-mode'，故此判断必须排在
`eimg-insert--format-link' 的 markdown 分支之前，否则永远命不中。"
  :type '(repeat symbol)
  :group 'eimg)

;;;; ── 2. 链接格式化 ──────────────────────────────────────────────────────

(defun eimg-insert--plain-path-p ()
  "当前 buffer 是否只该插入裸缩写路径（不包装成 org / markdown 链接）。

命中判据是 `eimg-insert-plain-path-modes' 的 `derived-mode-p' 家族匹配：列出
的模式及其派生模式都算。`eca-chat-mode' 派生自 `markdown-mode'，故该判断必须
排在 `eimg-insert--format-link' 的 markdown 分支之前，否则永远命不中。
`eca-chat-mode' 未加载时 `derived-mode-p' 仍按符号父链比较，不会报错。"
  (and eimg-insert-plain-path-modes
       (apply #'derived-mode-p eimg-insert-plain-path-modes)))

(defun eimg-insert--format-link (path)
  "按当前 buffer 的 major-mode 把 PATH 格式化成待插入文本（纯函数）。

- `eimg-insert-plain-path-modes' 家族 → `<缩写路径>'（最优先）
- `org-mode'      → `[[file:<缩写路径>]]'
- `markdown-mode' → `![](file:<缩写路径>)'
- 其他            → `<缩写路径>'

裸路径分支排在最前是硬约束：`eca-chat-mode' 派生自 `markdown-mode'，排在
markdown 之后就永远不会生效。

用 `derived-mode-p' 分派（`-Q' 下 `setq major-mode' 即可多态试算）。路径
一律 `abbreviate-file-name'：图片与文档物理分离，且 `~/Org' 是符号链接，
相对路径的基准随打开方式变化必有一端失效。

已知边界：部分外部 markdown 渲染器不识别 `file:' 方案，需要时手改为绝对
路径（或改用内联图片）。"
  (let ((short (abbreviate-file-name (expand-file-name path))))
    (cond
     ((eimg-insert--plain-path-p) short)
     ((derived-mode-p 'org-mode) (format "[[file:%s]]" short))
     ((derived-mode-p 'markdown-mode) (format "![](file:%s)" short))
     (t short))))

;;;; ── 3. 选区文本当路径 ──────────────────────────────────────────────────

(defun eimg-insert--path-from-string (s)
  "把字符串 S 解析成有效的图片绝对路径（纯函数，失败返回 nil）。

region 文本来源不确定（用户可能选中的是链接、光路径、带 `file:' 前缀的
形态），故逐层容错：

1. 非字符串 / nil / trim 后为空 → nil；
2. trim 后仍含换行 → nil（多行选区不当路径，宁可让调用方退回选择界面）；
3. 整串剥包装（正则两端锚定，避免部分匹配）：`[[file:PATH]]'、
   `![alt](file:PATH)'、`[[PATH]]'、`![alt](PATH)'；
4. 去 `file:' 前缀，再 `expand-file-name'（`~' 与相对路径按
   `default-directory'）；
5. 有效判据：`file-regular-p' 且 `image-supported-file-p' 同时成立。

只做「能不能当图片路径用」的判断，不猜用户意图：解析失败一律 nil，由调用
方决定退化为「弹出选择界面」。"
  (let ((text (and (stringp s) (string-trim s))))
    (when (and (stringp text)
               (not (equal text ""))
               (not (string-match-p "[\r\n]" text)))
      ;; 带 `file:' 的形态先剥，可免去依赖下面 `string-prefix-p' 那一层后置
      ;; 兜底（`[[PATH]]' 规则同样剥得到路径，只是要多走一步剥前缀），语义更
      ;; 直接。字符类写作 `[^][]*'：Emacs 正则的 `\\]' 在字符类里**不**表示
      ;; `]'（实测被当成字面反斜杠而失配），只有紧跟 `^' 的 `]' 才是字符类
      ;; 内的字面 `]'。
      (dolist (re '("\\`\\[\\[file:\\(.+\\)\\]\\]\\'"
                    "\\`!\\[[^][]*\\](file:\\(.+\\))\\'"
                    "\\`\\[\\[\\(.+\\)\\]\\]\\'"
                    "\\`!\\[[^][]*\\](\\(.+\\))\\'"))
        (when (string-match re text)
          (setq text (match-string 1 text))))
      (when (string-prefix-p "file:" text)
        (setq text (substring text (length "file:"))))
      ;; 剥壳后可能又露出首尾空白（如 `[[file: ~/x.png ]]'）。
      (setq text (string-trim text))
      (let ((path (expand-file-name text)))
        (and (file-regular-p path)
             (image-supported-file-p path)
             path)))))

(defun eimg-insert--region-image-path ()
  "捕获活动选区的边界与其文本解析出的图片路径。

`region-active-p' 为假时返回 nil；否则返回 plist
`(:path <绝对路径或 nil> :beg <整数或标记> :end <整数或标记>)'。

边界必须在**这一刻**捕获：`delete-region' 之后 `(region-beginning)' /
`(region-end)' 可能指向新位置，二次取值会删错范围。触发条件是任意活动
选区——不限 evil visual，鼠标选区同样生效。"
  (when (region-active-p)
    (let ((beg (region-beginning))
          (end (region-end)))
      (list :path (eimg-insert--path-from-string
                   (buffer-substring-no-properties beg end))
            :beg beg
            :end end))))

(defun eimg-insert--delete-captured-region (beg end)
  "删除调用方此前捕获的选区边界 BEG..END；边界不合法时静默返回 nil。

只接受整数或标记：`region-active-p' 与边界取值分属两次判断，中间任何一环
失效都不该让插入命令整体报错——删不掉选区只是少了个便利，signal 却会让
用户丢失整次插入。越界边界（超出 buffer 范围，实测 `delete-region' 会
`args-out-of-range'）同样静默返回 nil，与本函数「尽力而为」的语义一致；
倒序边界无需额外判断，`delete-region' 自己按两者之间的范围删除。"
  (when (and (integer-or-marker-p beg) (integer-or-marker-p end))
    (condition-case nil
        (delete-region beg end)
      (args-out-of-range nil))))

;;;; ── 4. 插入命令 ────────────────────────────────────────────────────────

;;;###autoload
(defun eimg-insert-path (&optional arg)
  "插入图片链接；带前缀 ARG 时改为插入内联图片。

活动选区（`region-active-p'，不限 evil visual，鼠标选区同样生效）的文本先
当路径解析（见 `eimg-insert--path-from-string'）：解析成功则把选区替换为
插入结果；失败则删除选区并照常弹出选择界面。

删除只作用于**进入时捕获**的边界：`delete-region' 之后 `(region-beginning)'
可能已指向新位置，二次取值会删错范围。

仅当进入时处于 evil visual state 才在结束时回 normal：normal / insert 下不
切换 state，避免打断输入。"
  (interactive "P")
  (let* ((visual (and (fboundp 'evil-visual-state-p) (evil-visual-state-p)))
         (region (eimg-insert--region-image-path))
         (region-path (plist-get region :path)))
    ;; `unwind-protect'：选择界面被 C-g 取消（`user-error'）时也要回 normal，
    ;; 否则用户停在「选区已删、state 仍是 visual」的半截状态。
    (unwind-protect
        (progn
          (when region
            (eimg-insert--delete-captured-region
             (plist-get region :beg) (plist-get region :end)))
          (if region-path
              (if arg
                  ;; 传显式 path：display 收到参数时不处理 region（选区已删）。
                  (eimg-insert-display region-path)
                (insert (eimg-insert--format-link region-path)))
            (let ((paths (eimg-select--read-paths
                          (eimg-select--read "插入图片"))))
              (unless paths (user-error "未选择图片"))
              (if arg
                  (dolist (p paths) (eimg-insert-display p))
                (dolist (p paths)
                  (insert (eimg-insert--format-link p)))))))
      (when visual
        (and (fboundp 'evil-normal-state) (evil-normal-state))))))

;;;###autoload
(defun eimg-insert-display (&optional path)
  "把图片插入为内联显示；PATH 为 nil 时交互式选择。

PATH 非 nil（embark 批量动作与 `eimg-insert-path' 的桥接调用）时**完全不
触发 region 逻辑**：批量替换多张图时误删用户选区是灾难，且此时选区已由调用
方处理。

插入形态的第一优先退化是 `eimg-insert--plain-path-p'：命中时无论交互还是带
PATH 都只插 `eimg-insert--format-link' 的结果并 `message' 提示（会话里模型
要的是路径文本，不是展示层图片对象）。其余退化保留原行为：无图形能力
（`display-graphic-p' 为 nil）或类型不受支持时插链接 + `message'。

`:max-width' 取 `eimg-select-preview-max-width`（与选择界面预览同口径），
`:max-height' 取当前窗口 body 高度像素的一半——两者夹住尺寸，图片不会撑破
窗口。

交互路径（PATH 为 nil）的选区语义同 `eimg-insert-path'：有效 → 替换选区；
无效 → 删选区 + 选择界面；结尾按捕获的 visual 回 normal。"
  (interactive)
  (let* ((visual (and (not path)
                      (fboundp 'evil-visual-state-p)
                      (evil-visual-state-p)))
         (region (and (not path) (eimg-insert--region-image-path)))
         (region-path (and region (plist-get region :path))))
    (unwind-protect
        (let ((paths
               (cond
                ((and path) (list path))
                (region-path
                 (eimg-insert--delete-captured-region
                  (plist-get region :beg) (plist-get region :end))
                 (list region-path))
                (t
                 (when region
                   (eimg-insert--delete-captured-region
                    (plist-get region :beg) (plist-get region :end)))
                 (eimg-select--read-paths
                  (eimg-select--read "插入内联图片"))))))
          (unless paths (user-error "未选择图片"))
          (dolist (p paths)
            (let ((type (and (display-graphic-p) (image-supported-file-p p))))
              (cond
               ((eimg-insert--plain-path-p)
                (insert (eimg-insert--format-link p))
                (message "已插入纯路径：%s" (abbreviate-file-name p)))
               ((null type)
                (insert (eimg-insert--format-link p))
                (message "无法内联显示，已插入链接：%s" (abbreviate-file-name p)))
               (t
                (let ((max-width eimg-select-preview-max-width)
                      (max-height (max 1 (/ (window-body-height nil t) 2))))
                  (insert-image (create-image p type nil
                                              :max-width max-width
                                              :max-height max-height))))))))
      (when visual
        (and (fboundp 'evil-normal-state) (evil-normal-state))))))

(provide 'eimg-insert)

;;; eimg-insert.el ends here
