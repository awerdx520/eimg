# 技术债清理：清单重整 + 四项低风险修复

## 当前状态

- 阶段：Phase 4（Review & Document）· 已完成
- 已确认：方案 ✅（用户 2026-10-28 确认）、计划 ✅（用户 2026-10-28 确认）
- 下一步：无（计划已归档至 `openspec/completed/`）

## 目标

1. `openspec/tech-debt.md` 从 18 条失真清单变为可决策清单：待办 **9 条**（每条带 P 级 + 成本 + 验证方式）+「已关闭（索引）」4 行 +「已转入 README（非债）」5 行。
2. 关闭 4 项低风险真债：rerun 旧页图残留、SVG 前缀缓存只有一条、ollama 探测超时非硬上限、tessdata 下载无内容哈希。
3. 补齐 README 两处缺口（CA 问题的影响面、探测类命令的使用禁忌），并同步「开发与验证」里的 ERT 条数（README 现记 146，实测已漂移到 206，以实测为准）。

## 设计

### A 文档层（tech-debt.md 重构）

- **A1 销项 4 条**：截图能力迁移（D10）、`+thomas/screenshot` 契约（D10）、交互命令 autoload（D11 + `test/eimg-autoload-test.el` 7 条用例）、sentinel event 文案（D7 + commit d128464）。移入文末 `## 已关闭（索引）`，每条一行：标题 + 关闭日期 + 证据指针。不保留整段旧正文。
- **A2 移出 5 条**到文末 `## 已转入 README（非债）`，每条一行指向 README 章节：tesseract 显式安装（`** 后端准备`）、rapidocr 依赖（`** 后端矩阵`）、解释器 CA 配置（`** 后端准备` 的 CA 段）、ollama 端点无身份校验（`** ollama 后端的安全边界`）、`--check`/`--list-backends` 会发本地 HTTP（`** 后端矩阵` 末段）。同时补 README 两处缺口：① CA 段补一句「同一台机器上不经本脚本的其它 Python 下载仍会撞同一问题」；② 后端矩阵末段补一句「不要把这二者放进 shell 补全 / init / hook 等启动路径」。
- **A3 剩余真债重排**为统一字段：`## <标题>（P1/P2/P3 · 成本 S/M/L）`，正文固定四段（散文即可，不强制加粗标签）：现状 / 影响 / 验证方式 / 改进方向。分级定义：P1 = 修法明确且低风险；P2 = 需业务决策或中件；P3 = 需新能力或环境限制（「无改进方向」的条目必须显式写「无（能力边界，非缺陷）」）。
- **A4 P1 九子项拆分**：`SVG 前缀缓存`、`rerun 残留`、`CLI 输出快照回归`、`缩放逻辑去重` 拆为独立条目（可单独认领/销项）；剩余 5 项（底图未降采样、内嵌上限按字节、`create-image` 全量重解析、ollama 无 box、`--posn-entry` 真实点击未端到端验证）合并为一条 `联动视图遗留（P2/P3）` 分组，组内逐项标注级别。
- **A5 文件头加「本文件约定」**：① 只记工程侧债务，用户可见的契约与边界记入 README 并在本文件留指针；② 关闭条目必须给出日期与可验证证据（决策编号 / commit / 测试文件）；③ 每条必须有「验证方式」。
- **A6 数量清点（确定性）**：原始 18 项 → A1 销 4、A2 移 5、B3 删 1、B4 删 1 后余 7 项；P1 九子项按 A4 拆分，其中「SVG 前缀缓存」「rerun 残留」随 B1/B2 一并删除，余「CLI 输出快照回归」「缩放逻辑去重」2 条独立 + `联动视图遗留（P2/P3）` 1 条分组 → 待办合计 6 + 3 = **9 条**。最终 `grep -c '^## '` 预期 = 9（待办）+ 3（`## 已关闭（索引）`、`## 已转入 README（非债）`、`## 本文件约定`）= **12**。
- 本轮 B1–B4 修掉的 4 条在 A 中直接删除（不进入「已关闭」索引，因为它们从未发布为「已知边界」，且属本轮改动的一部分，其证据由 CHANGELOG 与本计划承载）。

### B 代码修复

- **B1 rerun 旧页图残留**（`eimg-ocr.el` + `test/eimg-ocr-test.el`）：新增 `eimg-ocr--owned-pages-dir-p`，判据三条同时成立——非空字符串且 `file-directory-p` 为真、`(file-truename dir)` 位于 `(file-truename (file-name-as-directory temporary-file-directory))` 之下、目录 basename 以 `eimg-ocr-pages-` 开头。`eimg-ocr--run` 里 `explicit` 的取值改为：base 的 `:page-images-dir` 若满足该判据则视为「上一轮自建目录」，**丢弃**（置 nil）并按无 explicit 处理 → 新建 owned 目录。用户真的显式配置的目录不匹配前缀，行为不变。`owned`/`effective` 记账与 `eimg-ocr--delete-pages-dir` 守卫一律不改。
  - **这是一次有意的语义变更**：T10 确立的「rerun 复用上一轮页图目录」正是残留的根因（同一目录里写页数更少的图，旧页图不会被覆盖、也不会被清理）。改为「rerun 新建目录，旧目录随后由 `eimg-ocr--show-result` 的 stale-dir 清理删除」。该变更**推翻** `test/eimg-ocr-test.el` 中 `eimg-ocr-test-run-rerun-keeps-page-images-dir` 锁定的旧语义，该用例必须同步改造（见 T1），并保留 `eimg-ocr-test-run-explicit-pages-dir-not-deleted-on-failure` 原样（其目录前缀为 `eimg-user-pages-`，不匹配判据）。
  - `eimg-ocr--run` 的 docstring 与 1024–1033 行注释块同步更新：原文「调用方显式给了 `:page-images-dir` 就完全不接管」在 B1 后不再准确，须改为「显式目录不被接管；本包自建的页图目录在 rerun 时被视为过期并重建」。
- **B2 SVG 前缀缓存扩容**（`eimg-ocr-view.el` + `test/eimg-ocr-view-test.el`）：`eimg-ocr-view--svg-prefix-cache` 由单条 plist 改为有序 alist（最近使用在前），容量常量 `eimg-ocr-view--svg-prefix-cache-size` = 3；命中即提升到表头；超容淘汰表尾。键的构成（路径 + mtime + size + 画布尺寸 + 显示尺寸）不变。
- **B3 ollama 探测硬 deadline**（`bin/eimg-ocr` + `test/fixtures/ollama-stub.py` + `test/eimg-ocr-ollama-test.el`）：`_ollama_http` 内部改用以 `time.monotonic()` 为基准的整体预算——`deadline = time.monotonic() + timeout`，`remaining = max(0.0, deadline - time.monotonic())`，`opener.open(...)` 的 `timeout` 取 `remaining`；`_read_capped` 逐块 `read(64 * 1024)` 并在每块前检查剩余预算，耗尽抛内部异常。约束如下：
  - 新异常类命名 `_OllamaDeadlineExceeded`，**直接继承 `Exception`**——不得继承 `OSError` / `ValueError` / `URLError`，否则会被既有 `except (URLError, OSError, ValueError, HTTPException)` 吞成「服务不可达」。
  - 捕获顺序：`_probe_ollama` 中置于 `_OllamaRedirect` / `_OllamaResponseTooLarge` 之后、通用分支之前，reason 写「整体超时（上限 N 秒）」；`run_ollama`（识别路径，同样调用 `_ollama_http`）必须显式捕获并转成 `EXIT_OCR_FAILED` 的「识别失败…超时」文案，**禁止**穿透成 traceback（`main` 只 catch `EimgError` / `KeyboardInterrupt` / `SubprocessError`）。
  - `remaining <= 0` 时直接抛内部异常，不调用 `opener.open`（负 timeout 会让 `socket.settimeout` 抛 `ValueError`，进而被当成「不可达」）。
  - `_ollama_http` 的 `HTTPError` 分支里 `_read_capped(exc)` 外层 `except (OSError, ValueError)` 不得吞掉该异常。
  - `_read_capped` 的 `limit` 语义（响应体上限）与 `_OllamaResponseTooLarge` 行为必须保持不变，尤其 `limit + 1` 用来区分「正好等于上限」与「超出」的设计、以及 `huge` 模式靠 `Content-Length` 先拒的路径。
  - stub 新增两个滴流模式（都先发 header 再每 0.5 秒写少量字节、持续 12 秒；写入循环必须 catch `OSError`（含 `BrokenPipeError`）静默退出，保持「stub 的 stderr 零输出」约定）：`trickle` = `/api/show` 与 `/api/chat` 都滴流（用于探测超时）；`chat-trickle` = `/api/show` 正常返回 vision、仅 `/api/chat` 滴流（用于识别路径超时）。
  - 两条 ERT 用例。**为什么识别路径不跑真 CLI**：真 CLI 会先探测，而 `/api/show` 在 `OLLAMA_PROBE_TIMEOUT = 3` 的 budget 下先超时 → ollama 判不可用 → 命令以退出码 2「无可用后端」结束，根本走不到 `/api/chat`；而识别路径的 budget 是 `OLLAMA_TIMEOUT = 300`，滴流 12 秒不足以触发。故识别路径改为模块直调：① 探测超时——真 CLI `--list-backends` + `trickle`，断言在 `OLLAMA_PROBE_TIMEOUT + 1.5s` 内返回且 ollama 的 reason 含「超时」；② 识别路径超时——ERT 起 `chat-trickle` stub 拿端口，用 `call-process python3 -c` 的脚本 `exec_module` 加载 `bin/eimg-ocr`（顶层有 `if __name__ == "__main__"` 保护、导入无副作用），直接调用 `run_ollama(png_path, "m", "http://127.0.0.1:<port>", timeout=3)`（该函数签名已有 `timeout: int = OLLAMA_TIMEOUT` 形参），捕获 `EimgError` 并断言 `code == 4`、message 含「超时」、输出无 `Traceback`。
- **B4 tessdata 内容哈希**（`bin/eimg-ocr-setup` + 新增 `test/eimg-ocr-setup-test.el`）：新增模块常量 `TESSDATA_SHA256 = {文件名: 十六进制 sha256}`；`download()` 把 `shutil.copyfileobj` 改为分块循环，边写边 `hashlib.sha256().update()`，写完后与常量比对，不匹配则删 `.part` 并 `raise fail(EXIT_FAILED, ...)`（文案含文件名与实际/期望哈希前 12 位）。`run_tessdata()` 对每个目标先判「文件已存在 + 大小与哈希均匹配」→ 记 `note` 跳过下载（不联网）。体积下限 `MIN_TESSDATA_BYTES` 校验保留作为先决快速失败。
  - **半覆盖必须可见**：`TESSDATA_SHA256` 中缺该文件名时，`download()` 记一条 `note`「未登记期望哈希，仅做体积校验」——不允许「chi_sim 有哈希、eng 没有」这种静默降级。
  - 测试用 `exec_module` 加载脚本，**同时覆写 `TESSDATA_SHA256` 与 `TESSDATA_URLS`**（后者指向本地 `http.server` 的 fixture，否则 `run_tessdata` 仍打到 GitHub），三条用例：哈希匹配成功、哈希不匹配失败且不残留 `.part`、已存在且匹配则跳过（断言未发请求）。

## 任务

- [x] **T1 B1 rerun 旧页图残留（含既有用例改造）**：按设计实现 `eimg-ocr--owned-pages-dir-p` 与 `eimg-ocr--run` 的 explicit 判定，同步更新该函数 docstring 与注释块。验收：`make check-parens` 通过；**改造** `eimg-ocr-test-run-rerun-keeps-page-images-dir`（断言从「复用同一目录」改为「新建目录 + 旧目录被 show-result 清理 + 页数减少后目录内只剩本轮页图」）；新增三条用例——(a) rerun 且页数减少后目录内只剩本轮页数的图；(b) 配置里显式给的 `:page-images-dir`（前缀 `eimg-user-pages-`）不被接管、不被删除；(c) rerun 失败时本轮新建的 owned 目录被删、上一轮目录保留；`eimg-ocr-test-run-explicit-pages-dir-not-deleted-on-failure` 原样通过。（依赖：无）
- [x] **T2 B2 SVG 前缀缓存 LRU**：按设计改为容量 3 的有序 alist。验收：`make check-parens` 通过；在 `eimg-ocr-view-test-svg-prefix-cache` 既有的「命中 / 失效」断言之上**补**第三条「超容淘汰最旧」断言（既有断言不应失效，alist + `assoc` 的 `equal` 比较与之兼容）；其余 view 用例全绿。（依赖：无）
- [x] **T3 B3 ollama 探测整体 deadline**：按设计实现预算传递（含 `run_ollama` 路径与 `remaining` 钳制），stub 增 `trickle` 模式，新增 ERT 用例。验收：`make py-check` 通过；新用例断言 trickle 下 `--list-backends` 在 `timeout + 1.5s` 内返回且 reason 含「超时」；`eimg-ocr-ollama-test-oversized-response-rejected` 等既有 12 条用例仍全绿（尤其 `_read_capped` 的 16 MB 上限语义未变）；追加一条用例：`chat-trickle` stub 下经 `exec_module` 直调 `run_ollama(..., timeout=3)`，断言抛 `EimgError`（`code == 4`、message 含「超时」）且无 `Traceback`（不跑真 CLI，理由见 B3 设计段）。（依赖：无）
- [x] **T4a B4 哈希校验实现**：`download()` 增量哈希 + 不匹配失败 + 缺哈希 `note` 警告 + `run_tessdata()` 的「已存在且匹配则跳过」。验收：`make py-check` 通过；`--dry-run` 输出不被新逻辑改变（既有文案逐字保留）；导入模块无副作用（顶层已具 `__main__` 保护）。（依赖：无）
- [x] **T4b B4 真值获取与测试**：用脚本自身的 `ssl_context`/`download` 从 `TESSDATA_URLS` 取两个文件的真实 SHA256，写入 `TESSDATA_SHA256`；创建 `test/eimg-ocr-setup-test.el` 三条用例（覆写 `TESSDATA_SHA256` + `TESSDATA_URLS`）。验收：新测试文件三条用例通过；`make full-check` 全绿。**若真值获取因网络/代理失败**：保留 `TESSDATA_SHA256` 为空字典 + 在常量处写明「待补真值」，此时 `download()` 必须走「无期望哈希 → 仅体积校验 + note 警告」的兼容分支，并在报告中明确上报该降级，同时在 `tech-debt.md` 保留该条目（标注「框架已就位，真值待补」）——不许用 fixture 哈希冒充生产常量。（依赖：T4a）
- [x] **T5 A 文档重构**：按 A1–A6 重写 `openspec/tech-debt.md`；补 README 两处缺口；更新 README「开发与验证」中的 ERT 条数（以 `make test` 的实际用例数为准；README 现记 146，实测约 206）。验收：T1–T4 修掉的 4 条已不在待办中；`## 已关闭（索引）` 4 行、`## 已转入 README（非债）` 5 行、待办 9 条（每条含 `（P1/P2/P3 · 成本 S/M/L）` 与现状/影响/验证方式/改进方向四段）；`grep -c '^## '` = 13 并在报告给出实际值（原始预期 12；审查新增 1 条「网络对端输入与下载入口的加固缺口」后为 13）；README 两处缺口已补。（依赖：T1、T2、T3、T4b）
- [x] **T6 决策与变更日志**：`openspec/decisions.md` 追加 D15，四个子项——① B1 目录判据取舍（前缀 + 临时目录，替代「识别后删越界页图」）；② **rerun 语义变更**（由「复用上一轮目录」改为「新建目录 + 旧目录清理」，推翻 T10 的行为并为残留问题的根因）；③ B3 deadline 语义从「单次 socket」升级为「整体预算」及其残余（每块 read 之间仍受单次 socket 超时约束）；④ B4 硬编码哈希优于 TOFU 的理由。`CHANGELOG.md` 追加本轮条目（Fixed：4 项；Changed：rerun 页图目录语义、tech-debt/README 文档结构）。验收：D15 编号连续；CHANGELOG 遵循文件既有格式（读末尾 3 条对照）。（依赖：T5）
- [x] **T7 全量验证收尾**：`make full-check` + `make py-check` 全绿；`make clean` 后 `git status --porcelain` 只含预期改动（含本计划文件）。验收：三命令实际输出与退出码记录在报告中；任一项失败按修复循环处理（L1/L2 各最多 3 轮，耗尽则 `git checkout --` 回滚本轮改动并上报）。（依赖：T1–T6）

## 文档清单

| 文档 | 触发原因 | 动作 |
|---|---|---|
| `openspec/tech-debt.md` | 清单重整 | 重写（A1–A6） |
| `README.org` | 补两处缺口 + ERT 条数 | 局部编辑（`** 后端准备` CA 段、`** 后端矩阵` 末段、`* 开发与验证` 表格） |
| `CHANGELOG.md` | 代码与文档变更 | 追加条目（含 rerun 语义变更） |
| `openspec/decisions.md` | B1/B3/B4 + rerun 语义变更 | 追加 D15（四子项） |
| CLI 参数表 / 退出码表 | 本轮未改契约 | 不动（B3/B4 均不改参数与退出码） |

## 验证标准

- **L1**：`make check-parens`（逐文件独立 `emacs -Q --batch`）、`make py-check`（`py_compile`）。
- **L2**：`make test` 改造前后均需全绿。新增/改造 ERT 用例：B1 一条改造 + 三条新增、B2 一条补断言、B3 两条（list-backends 超时 + 识别路径超时）、B4 三条，共 **9 条新增断言组**；「前 / 后总数」一律以 `make test` 实测为准（本轮实测 206 → 215：改前 `grep -c '^\(ert-deftest' test/*-test.el` 合计 206，改后 215；README 记的 146 已漂移，T5 一并修正）。
- **L3**：手工三项——(a) 无 ollama 服务时 `bin/eimg-ocr --list-backends` 仍毫秒级返回；(b) `bin/eimg-ocr-setup --dry-run --tessdata` 文案未被哈希逻辑改变；(c) 重写后的 `tech-debt.md` 可被「只读该文件」的人判断优先级（报告中附 5 行摘要自证）。
- 本仓验证统一走 `make` 目标：`Makefile` 用 `emacs -Q --batch` 起独立进程，不连 emacsclient、不加载用户配置，因此**不需要** elisp MCP 实例分流（这是 README「开发与验证」的既定契约）。

## 注意事项

1. **禁止并行编辑同一文件**：`eimg-ocr.el`、`test/eimg-ocr-test.el`、`tech-debt.md` 的多次编辑必须串行，每次编辑后回读确认。
2. **不碰**：`eimg-ocr--delete-pages-dir` 的三条守卫、退出码常量（CLI 的 0/2/3/4/5 与 setup 的 0/1/2/5）、`--pdf-pages` 语义、CLI 参数表。
3. **B1 是本轮最高风险项**（T10 曾在此区域出过「重跑误删正在使用的目录」）：`owned` 与 `effective` 的记账必须原样保留，只改 `explicit` 的来源判定；并且必须同时改造锁旧语义的测试，`make test` 才算过。
4. **B3 不得用 `signal.alarm`**：与 `urlopen` 的 EINTR 重试交互未实测，且不可断言。新异常类**不得**继承 `OSError` / `ValueError`；识别路径 `run_ollama` 必须显式捕获。
5. **B4 真值必须是真实哈希**：不得用测试 fixture 的哈希充当生产常量；取不到就降级并上报，不许编造。
6. 修改前记录安全点：`git -C /home/thomas/Workspace/eimg rev-parse HEAD` 与 `git status --porcelain`（要求开工前工作区除本计划文件外干净），写入报告；回滚用 `git checkout -- <file>`。
7. Python 侧行为测试沿用既有范式（ERT `call-process` 跑真 CLI / `exec_module` 加载脚本 + stdlib HTTP stub），**不引入 pytest**。
8. **凡是行为变更，必须同轮更新对应 docstring / 注释**：B1 的 `eimg-ocr--run` docstring 与 1024–1033 注释块是硬要求，不许留「文档说复用、代码已新建」的漂移。

## 完成记录

- **验证**：`make check-parens` / `make py-check` / `make full-check` 均 exit 0；ERT **206 → 215** 全绿（`Ran 215 tests, 215 results as expected, 0 unexpected`）；`make clean` 后无 `.elc` / `__pycache__` / `.tmp-test` / `*-autoloads-test*.el` 残留。
- **计划审查**（plan-reviewer，两轮）：第 1 轮不通过——blocking 为「`eimg-ocr-test-run-rerun-keeps-page-images-dir` 锁定 T10 的复用语义，B1 会推翻它」；另 4 项 should-fix（`run_ollama` 路径未捕获新异常、异常类继承若为 `OSError` 会被吞、`open(timeout=负值)`、待办数量应为 9 而非 8）。第 2 轮不通过——新引入的「识别路径超时」断言双重不可触发（探测先短路 + 识别 budget 300 秒），改为 stub 双模式 + `exec_module` 直调。全部闭环后通过。
- **代码审查**（code-reviewer）：通过但有建议。2 项 should-fix（B4「未登记哈希」分支无测试、probe-deadline 计时断言 4.5 秒过紧）已采纳。
- **安全审查**（security-reviewer）：有需关注项、无 blocking。5 项建议中 2 项（下载总量上限、未登记哈希提示升级到 stderr）已采纳；另 3 项（裸 `urlopen` 的 handler/重定向、`.part` 符号链接、响应体控制字符）当前不可利用，记入 `tech-debt.md` 的「网络对端输入与下载入口的加固缺口」。
- **审查后修复批次**（R1–R8）：补 CASE4 覆盖未登记哈希分支、计时断言放宽到 8 秒、新增 `MAX_TESSDATA_BYTES`（64 MB）、`note` → `warn`、修正 `eimg-ocr--owned-pages-dir-p` docstring 与实际删除路径的偏差、CHANGELOG 补「变更」条、README 补哈希计算方法、tech-debt 新增加固条目。
- **偏离计划的量化差异**：tech-debt 待办 9 → **10 条**（审查新增一条），`grep -c '^## '` 由预期 12 变为 **13**；ERT 数由预期的 214 变为 **215**（多出 CASE4 一条 ERT 用例）。
