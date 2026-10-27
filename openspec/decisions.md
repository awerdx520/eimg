# 决策日志

格式：日期 + 决策 + 理由。

## 2026-10-27 仓库形态
eimg 采用独立 git 仓库 + thomas-emacs 通过 straight `:local-repo` 接入；
不登记 `versions.lock.el`（`:local-repo` 下 lock 无效，freeze 会把本地 HEAD 误写回 lock）。

## 2026-10-27 OCR 后端契约
OCR 后端通过统一 CLI 契约（`bin/eimg-ocr`）+ 退出码（0/2/3/4/5）解耦，
首轮支持 rapidocr 与 tesseract，`auto` 按可用性探测；elisp 侧不感知后端实现。

## 2026-10-27 安装必须显式
`:config` 与任何 hook 不安装、不下载；首次使用由 `bin/eimg-ocr-setup` 显式执行。

## 2026-10-27 截图能力软依赖
首轮不迁移截图能力：`eimg-ocr-capture-function` 运行时探测 `eimg-capture`
再回落 `+thomas/screenshot`，迁移完成后自动切换，OCR 侧零改动。

## 2026-10-27 transient 菜单分层
`eimg-menu` 聚合采集/文件/系统三组动作，backend/lang/dpi 以 infix 会话内覆盖，
不改 defcustom；transient 延迟 require，保持启动零成本。
