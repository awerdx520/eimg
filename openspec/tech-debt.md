# 技术债

## 截图能力尚未迁移 [已解决 2026-10-27，见 decisions D10]
截图采集、选择预览、插入、embark 集成仍在 thomas-emacs 的 `site-lisp/thomas-screenshot.el`；
eimg 侧通过软依赖调用，计划迁移后删除原文件。

> 已解决：四个模块已迁入本仓（`eimg-capture.el` / `eimg-select.el` / `eimg-insert.el` /
> `eimg-embark.el`），跨仓软依赖与两个转调桥接命令一并删除。以上正文保留作为迁移前的
> 现状记录。

## tesseract 语言数据需显式装一次（CLI 已默认使用 eimg 安装目录）
系统 tesseract 5.5.3 默认只有 afr/osd；中英文需 `bin/eimg-ocr-setup --tessdata` 把 chi_sim+eng
补到 `~/.local/share/eimg/tessdata/`。2026-10-27 起 CLI 在**未显式传** `--tessdata-dir` 时会
自动使用该目录（判据：目录存在且含 `*.traineddata`；探测 `reason` 里注明，显式传入仍以显式
为准），elisp 侧也有 `eimg-ocr-tessdata-dir` 可覆盖，因此「装了却不可用」不再需要手工配路径。

剩下的债务只有「必须由用户显式跑一次安装」这一条事实本身：配置、`init` 与任何 hook 都不
下载（不变量），`--check` 只能如实报告 `available=false` 并给指引。

## 解释器自带的 CA 配置可能与系统不一致
本机 `python3` 是 `/opt/miniforge/bin/python3`，其 openssl 编译期 cafile 路径不存在，于是
`ssl.create_default_context()` 拿不到任何根证书——且因为 `SSL_CERT_FILE` 未被使用，表现成
「系统信任库完好（`curl` 200）但 urlopen 报 `unable to get local issuer certificate`」。

`bin/eimg-ocr-setup` 已按候选表自己加载系统 bundle 兜底（`/etc/ssl/cert.pem` →
`/etc/ssl/certs/ca-certificates.crt` → `/etc/pki/tls/certs/ca-bundle.crt` → `certifi`，
全不可用才回退解释器默认），但这是**客户端绕行**：同一台机器上不经本脚本的其它 Python 下载
仍会撞上同一问题。根治方向是给解释器配好 `certifi` / `SSL_CERT_FILE`，或用系统 python3。

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

## `+thomas/screenshot` 的返回值契约未经跨仓契约测试 [已解决 2026-10-27，见 decisions D10]
`eimg-ocr-region` 通过软依赖调用 thomas-emacs 的 `+thomas/screenshot`，靠它的**返回值**
（成功分支最后一个表达式 `file`）拿截图路径。实测（`emacs -Q --batch` 打桩
`call-process` + 历史写入后 `call-interactively`）确认当前返回绝对路径字符串，但这条契约
只写在对方的 docstring 里，没有任何测试跨仓锁定：上游若把成功分支改成「先 `message`
再返回 nil」或在末尾追加一句 `(force-mode-line-update)` 之类，返回值就变成非路径，而
eimg 侧只会得到「截图函数没有返回文件路径」——功能静默退化，且改的是**另一个仓库**，
本仓库的 ERT 看不见。

迁移到 `eimg-capture` 之后，截图实现与 OCR 同仓，应把这条契约改成同仓 ERT 锁定
（命令返回绝对路径 + 文件确实存在 + 走 `call-interactively` 路径），届时本条债务关闭。

> 已解决：契约现在由同仓的 `test/eimg-ocr-test.el` 第 8 节锁定——四态（合法路径 / nil /
> 不可读 / 命令自身 signal）+「`eimg-ocr-capture-function` 为 nil 时探测到
> `eimg-capture`」+「`eimg-ocr.el` 的可执行代码不出现宿主符号」。
> `eimg-capture-test-no-host-symbols` 另行锁定四个模块的源码边界。

## 交互入口在 daemon / 批处理下会阻塞（异步只覆盖「识别」这一段）

OCR 本身全异步（`eimg-ocr--start` 立即返回，收尾由 sentinel 完成），但**取输入**与
**取确认**这两段仍是同步的：

| 位置 | 同步点 | 无 attached frame / `noninteractive` 时的表现 |
|---|---|---|
| `eimg-ocr-region` | `call-interactively` 调截图命令（外部工具选区域） | 等外部进程；无图形环境时 `eimg-ocr-region` 已先 `user-error`，但 `display-graphic-p` 为真却无可用 frame 时仍会卡在这里 |
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

## ollama（VLM）后端的四条边界

1. **无 box/conf**：VLM 只回纯文本，blocks 的 `conf` 恒 `0.0`、`box` 恒 `None`，`sort_blocks_reading_order`
   退化为「原样返回」。多栏/竖排/跨行块的版面还原能力与 tesseract 路线不可比；下游若依赖置信度
   做过滤，ollama 结果会被整体当作「低置信」。
2. **多页 PDF 每页一次推理**：模型驻留靠 `keep_alive:"5m"`，但每页仍是一次完整请求，10 页文档可能
   到分钟级；且 elisp 侧整体 `eimg-ocr-timeout`（默认 300s）会先于单页 `OLLAMA_TIMEOUT`（300s）
   触发，多页 PDF 走 ollama 实际表现为「到点被取消」而非「慢慢跑完」。要真正可用需要单进程多用例
   或调大/解耦整体超时。
3. **只支持 png/jpg/jpeg**：CLI 无 PIL 无法转码，tiff/gif/webp 直接退出码 3。`auto` 锁定 ollama 时
   这类输入不会回退 tesseract（有意行为）。
4. **输出格式漂移未充分防御**：只剥了 Markdown 三反引号围栏，编号列表、解释性前缀、空行结构等
   漂移未处理；真实 VLM 识别质量与稳定性**未验证**（本轮禁止下载模型，端到端只用了 stub）。

## ollama 探测的超时上限只覆盖单次 socket 操作

`OLLAMA_PROBE_TIMEOUT = 3` 交给 `urllib` 的 `timeout` 参数，它约束的是**每次 socket 操作**，
不是整个探测：慢速滴流响应用户实测可把一次 `read()` 拖到 19.6 秒，DNS 解析阶段完全不受它约束。
更彻底的做法是读循环里加单调时钟 deadline（或 `signal.alarm`），把语义升级为「整个探测的硬上限」。
当前未做：实现成本与收益不成比例（对端是本地服务，异常场景需要主动构造），已通过响应体上限
（`OLLAMA_MAX_RESPONSE` = 16 MB，`_read_capped` 按 `Content-Length` 先拒、再 `read(limit+1)` 兜底）
与探测超时缓解到「不会吃满内存、不会无限挂起」，但**「3 秒」不是硬保证**。

## ollama 默认端点无身份校验

`http://127.0.0.1:11434` 是约定而非认证：ollama 未运行时同机其它用户可抢先 bind 该端口冒充服务，
从而拿到被 OCR 图片的 base64、并控制注入结果 buffer 的文本。缓解手段只有「别指向不受信任的主机」
与结果 buffer 只做纯文本插入（不 `eval`）。若将来需要，可在探测阶段校验 `/api/version` 响应特征，
但那只是「更难冒充」，不是认证。

## `--list-backends` / `--check` 现在会发一次本地 HTTP 请求

ollama 探测让这两个「应该毫秒级」的只读命令多了一条网络路径：ollama 未运行时是快速
ECONNREFUSED（毫秒级），但端口被防火墙 DROP 或对端不响应时最多等 3 秒（且如上一节所述，
3 秒不是硬上限）。不要在 shell 补全、`init`、hook 或任何启动路径里调用它们。
