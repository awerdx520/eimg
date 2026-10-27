;;; eimg-insert-test.el --- eimg-insert 的 ERT 用例  -*- lexical-binding: t; -*-

;; Author: ThomasDon
;; Version: 0.1.0
;; Keywords: convenience, tools, images

;;; Commentary:

;; 覆盖 `eimg-insert' 的三块纯逻辑与两条命令：
;;   - `eimg-insert--format-link' 的四种模式与**判序**（裸路径必须最优先）；
;;   - `eimg-insert--path-from-string' 的九类输入形态；
;;   - `eimg-insert--region-image-path' / `--delete-captured-region' 的边界语义；
;;   - 两条命令的选区替换与「显式 PATH 不碰选区」语义。
;;
;; 全部用例离线且确定性：不起子进程、不进选择界面、不依赖图形能力，唯一外部
;; 副作用是临时文件（每个用例自建自删）。本文件自带 require，不依赖加载顺序。

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'eimg-insert)

;;;; ── 1. 链接格式化 ──────────────────────────────────────────────────────

(ert-deftest eimg-insert-test-format-link-by-mode ()
  "`--format-link' 按 major-mode 分派（`derived-mode-p'，三态用 setq 造）。"
  (let ((path (expand-file-name "x.png" "~")))
    (with-temp-buffer
      (setq major-mode 'org-mode)
      (should (equal (eimg-insert--format-link path) "[[file:~/x.png]]"))
      (setq major-mode 'markdown-mode)
      (should (equal (eimg-insert--format-link path)
                     "![](file:~/x.png)"))
      (setq major-mode 'fundamental-mode)
      (should (equal (eimg-insert--format-link path) "~/x.png")))))

(ert-deftest eimg-insert-test-format-link-plain-path ()
  "裸路径家族（会话类 mode）分支最优先；列表置 nil 时 markdown 分支行为不变。

`eca-chat-mode' 派生自 `markdown-mode'（两跳：eca-chat → gfm → markdown），
所以裸路径判断必须排在 markdown 之前。`-Q' 下 eca 未加载，`setq major-mode'
造家族身份即可（`derived-mode-p' 按符号比较，与是否加载无关）——**不得**用
`put 'derived-mode-parent'` 造派生：Emacs 31.1 对 parent 有内部缓存，先查询过
就再也 `put' 不进去，断言会稳定失败。"
  ;; 默认值必须含 eca-chat-mode，否则该特性默认不生效
  (should (memq 'eca-chat-mode eimg-insert-plain-path-modes))
  (let ((path (expand-file-name "x.png" "~")))
    (with-temp-buffer
      (setq major-mode 'eca-chat-mode)
      (should (equal (eimg-insert--format-link path)
                     (abbreviate-file-name path))))
    ;; 分支顺序反证：把 markdown-mode 也列进裸路径家族，markdown 分支必须让位。
    ;; 若顺序写反（plain 排在 markdown 之后），这条会红。
    (let ((eimg-insert-plain-path-modes '(markdown-mode)))
      (with-temp-buffer
        (setq major-mode 'markdown-mode)
        (should (equal (eimg-insert--format-link path)
                       (abbreviate-file-name path)))))
    ;; 家族置 nil：回落原分派，org / markdown 分支未被改动
    (let ((eimg-insert-plain-path-modes nil))
      (with-temp-buffer
        (setq major-mode 'markdown-mode)
        (should (equal (eimg-insert--format-link path)
                       "![](file:~/x.png)"))
        (setq major-mode 'org-mode)
        (should (equal (eimg-insert--format-link path)
                       "[[file:~/x.png]]"))))))

(ert-deftest eimg-insert-test-format-link-order ()
  "四模式判序的结构锚点：裸路径分支文本上必须早于 org 与 markdown 分支。

行为断言（上两条）已经覆盖了结果，这里再锁一次**源码顺序**：行为断言依赖
`derived-mode-p' 的家族关系，将来若有人为了让某条行为断言变绿而调换分支，
顺序 bug 会在「既是 org 又属裸路径家族」这类组合下复活。"
  (let* ((src (with-temp-buffer
                (insert-file-contents (or (locate-library "eimg-insert")
                                          (symbol-file 'eimg-insert--format-link
                                                       'defun)))
                (buffer-string)))
         (plain (string-match-p
                 (regexp-quote "eimg-insert--plain-path-p) short") src))
         (org (string-match-p (regexp-quote "(derived-mode-p 'org-mode)") src))
         (markdown (string-match-p (regexp-quote "(derived-mode-p 'markdown-mode)")
                                   src)))
    (should plain)
    (should org)
    (should markdown)
    (should (< plain org))
    (should (< org markdown))))

;;;; ── 2. 选区文本当路径 ──────────────────────────────────────────────────

(ert-deftest eimg-insert-test-path-from-string ()
  "`--path-from-string'：剥包装 / 展开相对路径 / 各类非法输入返回 nil。

选区文本来源不确定（链接、裸路径、带 `file:' 前缀），故逐形态覆盖。空 `.png'
即可——`image-supported-file-p' 只看扩展名，不校验内容。"
  (let* ((png (make-temp-file "eimg-insert-parse-" nil ".png"))
         (txt (make-temp-file "eimg-insert-parse-" nil ".txt"))
         (subdir (make-temp-file "eimg-insert-parse-dir-" t))
         (dir (file-name-directory png)))
    (unwind-protect
        (progn
          ;; 有效形态：绝对路径 / file: 前缀 / 四种包装 / 首尾空白（含制表符）
          (dolist (form (list png
                              (concat "file:" png)
                              (format "[[file:%s]]" png)
                              (format "![alt](file:%s)" png)
                              (format "[[%s]]" png)
                              (format "![alt](%s)" png)
                              (format "  %s  " png)
                              (format "\t%s\n" png)))
            (should (equal (eimg-insert--path-from-string form) png)))
          ;; 相对路径按 default-directory 展开成绝对路径
          (let ((default-directory dir))
            (should (equal (eimg-insert--path-from-string
                            (file-name-nondirectory png))
                           png)))
          ;; 非法形态一律 nil：空串 / 纯空白 / 多行 / 非图片 / 不存在 / 非字符串
          (dolist (form (list ""
                              "   "
                              (format "%s\n%s" png png)
                              txt
                              (concat png ".不存在")
                              nil
                              42))
            (should-not (eimg-insert--path-from-string form)))
          ;; 目录不是图片文件（`file-regular-p' 为假）
          (should-not (eimg-insert--path-from-string subdir))
          (should-not (eimg-insert--path-from-string
                       (directory-file-name subdir))))
      (when (file-exists-p png) (delete-file png))
      (when (file-exists-p txt) (delete-file txt))
      (when (file-directory-p subdir) (delete-directory subdir)))))

(ert-deftest eimg-insert-test-region-helpers ()
  "`--region-image-path' / `--delete-captured-region'：无选区、有效、无效与坏边界。"
  (let* ((png (make-temp-file "eimg-insert-region-" nil ".png"))
         (transient-mark-mode t))
    (unwind-protect
        (progn
          ;; 无活动选区 → nil
          (with-temp-buffer
            (setq mark-active nil)
            (should-not (region-active-p))
            (should-not (eimg-insert--region-image-path)))
          ;; 有效路径 → plist：:path 绝对路径，:beg / :end 为整数
          (with-temp-buffer
            (insert png)
            (push-mark (point-min) t t)
            (activate-mark)
            (let ((info (eimg-insert--region-image-path)))
              (should info)
              (should (equal (plist-get info :path) png))
              (should (integerp (plist-get info :beg)))
              (should (integerp (plist-get info :end)))))
          ;; 无效文本 → :path 为 nil，但边界仍被捕获（调用方要靠它删选区）
          (with-temp-buffer
            (insert "不是图片路径的普通文本")
            (push-mark (point-min) t t)
            (activate-mark)
            (let ((info (eimg-insert--region-image-path)))
              (should info)
              (should-not (plist-get info :path))
              (should (integerp (plist-get info :beg)))
              (should (integerp (plist-get info :end)))))
          ;; 坏边界不得 signal：删不掉选区只是少个便利，报错会毁掉整次插入
          (with-temp-buffer
            (insert "abcdef")
            (should-not (eimg-insert--delete-captured-region nil nil))
            (should-not (eimg-insert--delete-captured-region "a" "b"))
            (should-not (eimg-insert--delete-captured-region 1 nil))
            ;; 两参皆整数但**越界**（point-max 远小于 999999）：`delete-region'
            ;; 会 `args-out-of-range'，实现须静默返回 nil 而不是让插入整体失败。
            (should-not (eimg-insert--delete-captured-region 1 999999))
            (should (equal (buffer-string) "abcdef"))
            ;; 正向对照：合法边界确实删除（防「一律不删」的过度修复）。
            ;; 边界按 Emacs 约定 1-based 且 END 独占：删 2..4 即去掉 "bc"。
            (eimg-insert--delete-captured-region 2 4)
            (should (equal (buffer-string) "adef"))))
      (when (file-exists-p png) (delete-file png)))))

;;;; ── 3. 插入命令 ────────────────────────────────────────────────────────

(ert-deftest eimg-insert-test-insert-region-replaces ()
  "选区是有效图片路径时 `eimg-insert-path' 直接替换选区，不进选择界面。

`transient-mark-mode' 用 let 绑定而非 `(transient-mark-mode 1)'：效果等价
（`region-active-p' 查的就是该变量）但不污染全局测试状态。

**不断言 `(region-active-p)' 为 nil**：实测 `delete-region' 之后 mark 仍
active，该判断照旧返回 t——以 buffer 文本为唯一判据。"
  (let* ((png (make-temp-file "eimg-insert-" nil ".png"))
         (abbrev (abbreviate-file-name png))
         (transient-mark-mode t))
    (unwind-protect
        (dolist (pair '((markdown-mode . "![](file:%s)")
                        (fundamental-mode . "%s")))
          (with-temp-buffer
            (setq major-mode (car pair))
            (insert png)
            (push-mark (point-min) t t)
            (activate-mark)
            (should (region-active-p))
            ;; 有效路径 → 不弹选择界面（-Q 下也没有 consult 可用）
            (eimg-insert-path)
            (should (equal (buffer-string)
                           (format (cdr pair) abbrev)))))
      (when (file-exists-p png) (delete-file png)))))

(ert-deftest eimg-insert-test-display-explicit-path-keeps-region ()
  "显式 PATH 不触发 region 逻辑，`C-u' 桥接把选区替换为内联结果。

覆盖两处审查盲区：
- M1：`eimg-insert-display' 收到显式 PATH 时必须**完全不**碰选区（embark 批量
  动作走同一条路径，误删用户选区是灾难）——选区文本取有效图片路径（否则
  region 解析恒 nil，替换分支进不去），判据是 buffer 变长且恰为「原选区 +
  一份插入结果」，即「追加」而非「替换」。
- M2：`eimg-insert-path' 带前缀参数时走 `(eimg-insert-display region-path)'
  桥接，此时 path 非 nil 却又必须完成选区替换。region 文本故意带首尾空白：
  替换后空白消失，可与「追加」区分开。

**不断言 `(region-active-p)' 为 nil**：`delete-region' 之后 mark 仍 active。"
  (let* ((png (make-temp-file "eimg-insert-" nil ".png"))
         (short (abbreviate-file-name png))
         (transient-mark-mode t))
    (unwind-protect
        (progn
          ;; A（M1）：显式 path 的 display 调用不得删除选区
          ;;
          ;; 选区文本必须是**有效图片路径本身**：若误走 region 分支，
          ;; `--region-image-path' 会给出非 nil 的 :path，插入结果随之顶替选区
          ;; （buffer 只剩一份）；用非路径文本（如 "keep me"）时 :path 恒 nil，
          ;; 「显式 path 仍触发 region 替换」这一 mutation 根本进不到替换分支，
          ;; 断言就失效了。
          (with-temp-buffer
            (setq major-mode 'fundamental-mode)
            (insert png)
            (push-mark (point-min) t t)
            (activate-mark)
            (should (region-active-p))
            (eimg-insert-display png)
            ;; 判据用**长度**而非 `string-prefix-p'：`/tmp' 下
            ;; `abbreviate-file-name' 不缩写，插入结果与选区文本前缀相同，
            ;; 前缀判断区分不了「追加」与「替换」。
            (should (> (buffer-size) (length png)))
            (should (equal (buffer-string) (concat png short))))
          ;; B（M2）：C-u 桥接 → display 收到显式 path，但选区照样被替换
          (with-temp-buffer
            (setq major-mode 'fundamental-mode)
            (let ((raw (concat "  " png "  ")))
              (insert raw)
              (push-mark (point-min) t t)
              (activate-mark)
              (should (region-active-p))
              ;; 未进选择界面：-Q / 批处理下 `completing-read' 无交互输入会报错，
              ;; 故「不报错」本身就是「没进选择界面」的证据。
              (eimg-insert-path '(4))
              (should-not (string-match-p (regexp-quote raw) (buffer-string)))
              ;; 图形能力下是图片对象（`display' 属性），批处理下退化为裸路径文本
              (should (or (get-text-property (point-min) 'display)
                          (equal (buffer-string) short))))))
      (when (file-exists-p png) (delete-file png)))))

(provide 'eimg-insert-test)

;;; eimg-insert-test.el ends here
