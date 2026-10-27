;;; eimg.el --- 截图与 OCR 一体化工具包  -*- lexical-binding: t; byte-compile-warnings: (not unresolved noruntime) -*-

;; Author: thomas
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, tools, ocr
;; URL: https://github.com/awerdx520/eimg

;;; Commentary:

;; eimg 把「采集图像 → 识别文字 → 产出可用的文本或链接」收成一个包。
;;
;; 首轮（0.1.0）只交付 OCR 能力：
;;   - `bin/eimg-ocr'  CLI 契约（多后端可插拔：rapidocr / tesseract）
;;   - `eimg-core.el'  纯逻辑（参数拼装、退出码映射、输出解析、org 渲染）
;;   - `eimg-ocr.el'   交互层（框选截图 OCR / 图片与 PDF OCR / 结果 buffer）
;;   - `eimg-transient.el'  `eimg-menu' 菜单聚合入口
;;
;; 截图采集与图片插入能力的迁移是后续计划，本轮通过软依赖复用
;; thomas-emacs 侧的 `+thomas/screenshot' 等命令。

;;; Code:

(defconst eimg-version "0.1.0"
  "eimg 当前版本号。")

;; 纯逻辑层与版本常量同批加载：它零第三方依赖，加载代价可忽略，而调用方
;; （eimg-ocr.el / eimg-transient.el）几乎总要用到其中的参数拼装与渲染。
(require 'eimg-core)

(provide 'eimg)

;;; eimg.el ends here
