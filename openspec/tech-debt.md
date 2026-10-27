# 技术债

## 截图能力尚未迁移
截图采集、选择预览、插入、embark 集成仍在 thomas-emacs 的 `site-lisp/thomas-screenshot.el`；
eimg 侧通过软依赖调用，计划迁移后删除原文件。

## tesseract 语言数据需手工补齐
系统 tesseract 5.5.3 默认只有 afr/osd；中英文需 `bin/eimg-ocr-setup --tessdata` 补 chi_sim+eng。

## rapidocr 依赖 Python 环境
rapidocr 需 onnxruntime + numpy + pillow，首轮依赖用户已有 venv 或 `--rapidocr` 新建。

## 无 pdfinfo 时部分越界会静默截断
`--pdf-pages 2-9` 打在 3 页文档上，若系统没有 `pdfinfo`，`pdftoppm -f 2 -l 9` 返回 rc=0 且
只输出 2、3 两页，CLI 如实返回识别到的页而不报错——没有总页数就没有判据。有 `pdfinfo`
时用总页数做前置校验（当前主路径），越界直接报退出码 3。要让「少了几页」这件事本身
可发现，只能靠下游对 `pages` 的页数自检，或给 `pdfinfo` 补一条硬依赖。

## `--pdf-pages` 对多 PDF 混排重复生效
多个 PDF 输入时页码范围对每个文件都套用：若第二个文件页数不足，会整体以退出码 3 失败，
前面文件已识别出的结果被一并丢弃（一次失败的识别成本是整批栅格化 + OCR）。批量场景
可能需要「逐文件跳过并继续」的语义，与当前「参数错误即整批失败」的契约不同，留作后续
决定；在决定前，多文件混排时不要带 `--pdf-pages`。
