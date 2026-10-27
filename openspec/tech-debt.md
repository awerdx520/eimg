# 技术债

## 截图能力尚未迁移
截图采集、选择预览、插入、embark 集成仍在 thomas-emacs 的 `site-lisp/thomas-screenshot.el`；
eimg 侧通过软依赖调用，计划迁移后删除原文件。

## tesseract 语言数据需手工补齐
系统 tesseract 5.5.3 默认只有 afr/osd；中英文需 `bin/eimg-ocr-setup --tessdata` 补 chi_sim+eng。

## rapidocr 依赖 Python 环境
rapidocr 需 onnxruntime + numpy + pillow，首轮依赖用户已有 venv 或 `--rapidocr` 新建。
