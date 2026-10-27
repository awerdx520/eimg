;;; eimg.el --- 截图与 OCR 一体化工具包  -*- lexical-binding: t; byte-compile-warnings: (not unresolved noruntime) -*-

;; Author: thomas
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, tools, ocr
;; URL: https://github.com/awerdx520/eimg

;;; Commentary:

;; eimg 把「采集图像 → 识别文字 → 产出可用的文本或链接」收成一个包。
;;
;; 0.1.0 交付两组能力，都在本包内：
;;
;;   截图链路（采集 / 选择 / 插入 / embark 动作菜单）
;;     - `eimg-capture.el'  调用外部截图工具、目标文件命名与历史记录
;;     - `eimg-select.el'   consult 多源候选、posframe 预览与尺寸换算
;;     - `eimg-insert.el'   按 major-mode 格式化链接、选区替换与内联显示
;;     - `eimg-embark.el'   选择界面里 `C-.' 的图片动作菜单
;;
;;   OCR 链路（采集图像 → 文字）
;;     - `bin/eimg-ocr'  CLI 契约（多后端可插拔：rapidocr / tesseract）
;;     - `eimg-core.el'  纯逻辑（参数拼装、退出码映射、输出解析、org 渲染）
;;     - `eimg-ocr.el'   交互层（框选截图 OCR / 图片与 PDF OCR / 结果 buffer）
;;     - `eimg-ocr-view.el'  联动视图：把结果里的 `box' 坐标画回原图，文本框与
;;       文本列表双向联动（`eimg-ocr-mode' 里按 `v' 进入）
;;     - `eimg-transient.el'  `eimg-menu' 菜单聚合入口
;;
;; 加载策略：截图四模块在本文件顶层 require——它们是常驻命令，用户按键即用，
;; 且顶层零第三方依赖（consult / posframe / embark 都在函数体内懒加载）。
;; `eimg-transient' 例外，靠 autoload 延迟：不按菜单的人不该为 transient 付
;; 启动成本。
;;
;; `eimg-ocr-view' 同理随 `eimg-ocr' 一起加载，不做 autoload：它复用后者的结果
;; buffer buffer-local 结构（`eimg-ocr--result-data'），而 `eimg-ocr-mode-map'
;; 的 `v' 键直接指向它——键位绑定不会触发加载，延迟只会让按 `v' 报
;; `void-function'。依赖是单向的（`eimg-ocr-view' → `eimg-ocr' → `eimg-core'），
;; 反向只留 `declare-function' 声明，故无循环。

;;; Code:

(defconst eimg-version "0.1.0"
  "eimg 当前版本号。")

;; 纯逻辑层与版本常量同批加载：它零第三方依赖，加载代价可忽略，而调用方
;; （eimg-capture.el / eimg-ocr.el / eimg-transient.el）几乎总要用到其中的
;; 参数拼装与渲染。
(require 'eimg-core)

;; 截图链路的四层按依赖方向加载（采集 → 选择 → 插入 → embark）。四条 require
;; 里只有 `eimg-capture' 是真正必要的：`eimg-select' / `eimg-insert' /
;; `eimg-embark' 各自 require 前一层。这里全列出来是为了让「本包对外提供哪些
;; 截图命令」在入口文件一眼可见，避免读代码时误以为某一层缺失。
(require 'eimg-capture)
(require 'eimg-select)
(require 'eimg-insert)
(require 'eimg-embark)

;; 进程层同样零第三方依赖，且它是 eimg 的 OCR 能力入口（`eimg-ocr-cancel'
;; 等交互命令随之可用），故紧随截图链路加载。
(require 'eimg-ocr)

;; 联动视图把 OCR 结果的 `box' 坐标画回原图，直接读 `eimg-ocr' 结果 buffer 的
;; buffer-local 结构，故必须排在它之后。反向没有 require——`eimg-ocr-mode-map'
;; 只绑定符号、`declare-function' 做编译期声明——依赖单向，不会成环。不做
;; autoload：键位绑定不触发加载，延迟只会让 `v' 报 `void-function'。
(require 'eimg-ocr-view)

(provide 'eimg)

;;; eimg.el ends here
