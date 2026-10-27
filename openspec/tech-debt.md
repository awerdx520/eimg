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

## 阅读顺序排序只还原单栏横排，多栏与竖排会失效
`sort_blocks_reading_order` 只做「按 y 中心聚行 + 行内按 x0 从左到右」这一维还原，
前提是页面为单栏横排。具体失效场景：
- **多栏排版**（双栏论文 / 报纸 / 并排代码）：左右栏处在同一水平带时会被聚成同一行，
  输出变成「左栏第 1 行 → 右栏第 1 行 → 左栏第 2 行 …」的左右交错，而不是读完左栏
  再读右栏；栏间距越窄、栏内行距越大，串行越严重。
- **竖排文字**（中日文竖排、旋转 90° 的表头）：字块 x0 相同、y 递增，被排成一字一行，
  行内只剩单块，还原不出「从右到左、从上到下」的列序；与横排正文混排时两者还会被
  交错插入同一顺序。
- **跨行块**（整段贴图、跨行大标题）：块的 cy 落在它所跨的多行之间，整块会被插到
  中间位置，版式越复杂偏差越大。
- 容差取自「所有块高度的中位数的一半」，同一页混排超大块（整幅截图）与正文时中位数
  仍稳健，但整页都是超大块时容差会大到把相邻行并成一行。

留作后续：要真正还原需做栏检测（按 x 投影切栏）与书写方向判定（竖排需按 y 优先、
x 递减）；当前实现刻意只做最保守的一维聚类，宁可排错也不猜版面。

## sentinel 状态判定不得依赖 event 文案（0b75ecc 引入、d128464 修复）
`make-process` 的 sentinel 事件串对「因信号死亡」的描述取自 `strsignal`，会经 gettext
翻译：本机 zh_CN 下 `delete-process` 给出的是「已杀死」、SIGINT 给出「中断」，按
`"killed"` / `"interrupt"` 字面匹配永远不命中——取消与超时两条路径整个哑掉（回调不执行、
状态不复位、`eimg-ocr--process` 一直停在被删的进程对象上，后续每次识别都报「已有任务」）。
判据必须换成与文案无关的 `process-status`（`exit` / `signal`）+ `process-exit-status`
（退出码），超时与用户取消再靠进程属性 `eimg-timeout` 区分。

**风险形态是假绿**：英文 locale 下 `strsignal` 返回 "killed" / "interrupted"，同一份代码
全绿；只有中文环境才暴露。因此这类缺陷不能靠「本地 `make test` 通过」证明不存在——
新增任何依赖进程事件串的分支时，必须同时断言在非英文 locale 下的行为（或用
`process-status` 这类语言无关来源）。

## `+thomas/screenshot` 的返回值契约未经跨仓契约测试
`eimg-ocr-region` 通过软依赖调用 thomas-emacs 的 `+thomas/screenshot`，靠它的**返回值**
（成功分支最后一个表达式 `file`）拿截图路径。实测（`emacs -Q --batch` 打桩
`call-process` + 历史写入后 `call-interactively`）确认当前返回绝对路径字符串，但这条契约
只写在对方的 docstring 里，没有任何测试跨仓锁定：上游若把成功分支改成「先 `message`
再返回 nil」或在末尾追加一句 `(force-mode-line-update)` 之类，返回值就变成非路径，而
eimg 侧只会得到「截图函数没有返回文件路径」——功能静默退化，且改的是**另一个仓库**，
本仓库的 ERT 看不见。

迁移到 `eimg-capture` 之后，截图实现与 OCR 同仓，应把这条契约改成同仓 ERT 锁定
（命令返回绝对路径 + 文件确实存在 + 走 `call-interactively` 路径），届时本条债务关闭。

## 交互入口在 daemon / 批处理下会阻塞（异步只覆盖「识别」这一段）

OCR 本身全异步（`eimg-ocr--start` 立即返回，收尾由 sentinel 完成），但**取输入**与
**取确认**这两段仍是同步的：

| 位置 | 同步点 | 无 attached frame / `noninteractive` 时的表现 |
|---|---|---|
| `eimg-ocr-region` / `eimg-ocr-capture-command` | `call-interactively` 调截图命令（外部工具选区域） | 等外部进程；无图形环境时 `eimg-ocr-region` 已先 `user-error`，但 `display-graphic-p` 为真却无可用 frame 时仍会卡在这里 |
| `eimg-ocr-file` | `read-file-name` | 无 minibuffer 可交互 → 阻塞或直接失败 |
| `eimg-ocr-history` | `completing-read` | 同上 |
| `eimg-ocr-write-file` | 覆盖前 `y-or-n-p` | 同上（ERT 用例里靠 `cl-letf` 打桩绕过，未覆盖真实 daemon 路径） |

这不是可以「顺手修」的缺陷：截图选区域本质上要人操作。留作后续决定——可选方向是给三个
入口命令加一个「非交互参数入口」（直接吃文件路径，不弹选择器），让 daemon / 脚本能复用同一条
OCR 编排路径；在那之前，从 daemon（`emacsclient -e`、定时任务）调这些命令不要指望能返回。

## 多页 PDF 每页独立起进程，rapidocr 模型每页重新加载
`recognize_pdf` 先 `pdftoppm` 栅格化，再**逐页**走 `recognize_image` → `run_rapidocr` /
`run_tesseract`：每页一个子进程，rapidocr 那份内联脚本每页都要重新导入 onnxruntime 并
加载检测/识别模型（实测冷启动 8–10 秒）。10 页文档≈10 次冷启动，真正的 OCR 时间被模型
加载淹没。

超时也只在**单页**粒度上：`RAPIDOCR_TIMEOUT = 180` / `TESSERACT_TIMEOUT = 120` 落在每次
`subprocess.run` 上，CLI 层**没有整体超时**（也没有 `--timeout` 选项）。页数一多，总耗时
可以远超用户对「一次识别」的预期；elisp 侧靠 `eimg-ocr-timeout`（整体定时器 →
`delete-process`）兜住，于是表现为「到点被取消」而不是「慢慢跑完」，且已识别出的页一并
丢弃。

改进方向：**单进程识别多页**——一次 `subprocess.run` 传入多张图，Python 侧循环识别并把
每页 block 合并进同一个结果 JSON，模型只加载一次。代价有两条，需先定取舍：① 错误粒度变粗
（一页失败是丢整份还是跳过该页？）；② 超时语义要从「每页上限」改成「总量上限 + 每页软
上限」，CLI 与 elisp 两侧的退出码 4 / 超时文案都要跟着重做。

## tessdata 下载只校验体积下限，没有 SHA256
`bin/eimg-ocr-setup --tessdata` 从 GitHub 取 `chi_sim.traineddata` / `eng.traineddata`，
校验只有「文件大于 1 MB」一条，没有内容哈希比对：HTTPS 被降级、或环境配了不校验的代理、
或上游同名文件被替换时都会静默通过。后果是 OCR 质量退化而不是报错——只要文件大于 1 MB，
`tesseract --list-langs` 就认为语言可用，`probe_backends` 也判 tesseract 可用。

当前「HTTPS + 体积下限」可接受（公开大文件，篡改动机与收益都低），严格起来应固定每个文件
的 SHA256 并在下载后比对，顺带补一条「已存在且哈希匹配则跳过下载」的路径（现在重复执行
`--tessdata` 会重下）。

## 交互命令没有 `;;;###autoload`，可用性隐式依赖宿主不延迟加载
`eimg-ocr-region` / `eimg-ocr-file` / `eimg-ocr-history` / `eimg-ocr-write-file` 等
交互命令只定义在 `eimg-ocr.el` 里，**没有 `;;;###autoload` cookie**。宿主
（thomas-emacs 的 `lisp/init-tools.el`）在 `use-package-always-defer` 为 nil 的默认值下
于启动期 require 本包，于是这些键位「恰好」可用——这是一条隐式契约，本仓库自己的 ERT
也锁不住（`make test` 用 `-L . -L test -l` 显式加载，永远看不到延迟加载的形态）。

风险：若将来 eimg 改成 `:defer t`（延迟加载省启动时间，是很可能的下一步），`SPC` 系列
键位会静默变成 `void-function`，而 `eimg-menu`（transient 菜单，上游带 autoload）仍能
打开并调用同一批命令——属「部分可用」的隐蔽退化：菜单能跑、直接按键报错，错误信息只说
函数未定义，排查时很难联想到「autoload 没生成」。

修法二选一：① 给全部 `(interactive)` 命令补 `;;;###autoload` cookie（straight 的
autoloads 步骤会收集，宿主即可安全 `:defer`）；② 明确把「本包不做延迟加载」写成契约
（`:demand t` + README 说明），让后来改 `:defer` 的人先看到这句话。
