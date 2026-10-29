# 无 pdfinfo 时 `--pdf-pages` 部分越界改为报错（技术债 #1）

## 当前状态

- 阶段：Phase 4（Review & Document）· 已完成
- 已确认：方案 ✅（用户 2026-10-28 确认）、计划 ✅（用户 2026-10-29 确认）
- 计划审查：第 1 轮「有条件通过」→ 已闭环；代码审查：通过（无 blocking / should-fix，采纳 4 项 nit）
- 下一步：无（计划已归档至 `openspec/completed/`）

## 目标

1. 把「页码越界」的退出码 3 判据从「总页数（依赖 `pdfinfo`）」扩展为「请求页数 vs 实际渲染页数」，使**未安装 `pdfinfo`** 时 `--pdf-pages 2-9` 打在 3 页文档上不再静默截断（当前 rc=0 且只识别 2 页）。
2. `pdfinfo` 退化为「文案增强」，**不引入硬依赖**（无 `pdfinfo` 的机器仍能正常识别整本与合法区间）。
3. 消除「行为随环境里装没装 `pdfinfo` 而分裂」：多 PDF 混排 + 部分越界在两种环境下都是退出码 3（整批失败），与既有 `pdfinfo` 路径一致。
4. 保留既有行为：请求页全部合法时不误报；单页越界（`pdftoppm` rc=99）与渲染零输出的文案逐字不变。

## 设计

### D1 判据（唯一改动点：`rasterize_pdf`）

在 `bin/eimg-ocr` 的 `rasterize_pdf` 中，`rasterized` 列表构造完成之后、`return rasterized` 之前，新增一条**仅当 `pages` 非空且 `total is None`** 生效的判据：

```python
if pages and total is None and len(rasterized) < len(pages):
    produced_numbers = {number for number, _ in rasterized}
    first_overflow = next((page for page in pages if page not in produced_numbers), None)
    raise fail(
        EXIT_BAD_INPUT,
        _pdf_overflow_message(path, pages, None, first_overflow, rendered=len(rasterized)),
    )
```

- **为什么放在 `rasterize_pdf`**：只有它在渲染现场持有 `produced` / `rasterized`（`recognize_pdf` 只拿到返回值，判据放那里要重复「请求 vs 实际」的比较），判据与文案在此闭合；`recognize_pdf` 保持「总页数前置校验」职责，两处判据不交叉、不重复。
- **为什么只在 `total is None` 时启用**：`total` 已知时既有前置校验（`recognize_pdf` 里 `overflow = [page for page in requested if page > total]`）已更早拦截；若在 `total` 已知时也判「渲染页数不足」，会把「单页渲染失败但 rc=0」误报成「页码越界」，属新风险。`total is None` 时没有别的判据可用，只能靠「渲染页数不足」这个信号。
- **`first_overflow` 用集合差**：`next((page for page in pages if page not in produced_numbers), None)` 不依赖「pdftoppm 连续输出」的假设；取不到时（理论上不会）传 `None`，`_pdf_overflow_message` 会退回 `min(requested)`。
- **`len(rasterized) < len(pages)` 而不是 `!=`**：渲染多于请求是不可能的；用 `<` 表达「少了页」这一唯一现实形态。

### D2 文案（`_pdf_overflow_message` 增加可选参数）

给 `_pdf_overflow_message` 增加关键字参数 `rendered: int | None = None`，仅在 `total is None and rendered is not None` 时启用新文案：

```
无法读取输入: {path}（页码 {first} 超出范围：请求 {span} 共 {n} 页，实际只渲染出 {m} 页；未安装 pdfinfo，无法给出总页数）
```

其中 `{span}` = 请求区间的原始写法（`requested[0]-requested[-1]`，单页时为单个数），`{n}` = `len(requested)`，`{m}` = `rendered`，`{first}` = `first_overflow`（无则 `min(requested)`）。

- **stderr 关键子串 `无法读取输入` 必须保留**：退出码 3 的契约（`README.org` 退出码表）按该子串识别，`eimg-core-exit-message` / `eimg-core-exit-hint` 不受影响。
- 现有三个调用点（`rasterize_pdf` 的 rc=99 分支、`rasterize_pdf` 的零输出分支、`recognize_pdf` 的前置校验）**不传 `rendered`**，文案逐字不变——这是回归约束，不得顺手「优化」它们。
- 中文全角标点与既有文案风格一致（`（` `）` `；`），数字与英文保持半角。

### D3 docstring / 注释同步（行为变更必须同轮更新）

1. `parse_pdf_pages` docstring（现写「由 `pdf_page_count`（pdfinfo）或 pdftoppm 的越界信号在 `recognize_pdf` 里判定」）→ 补上「或渲染页数少于请求页数（`rasterize_pdf`，无 `pdfinfo` 时的判据）」。
2. `rasterize_pdf` docstring 的「三类失败分开报」→ 扩为四类，新增「请求 n 页但只渲染出 m 页（无 `pdfinfo` 时的部分越界判据）→ 退出码 3」。
3. `recognize_pdf` docstring 的「已知边界：拿不到 pdfinfo（未安装）时无法判断请求区间部分越界…我们照实返回识别到的页，不报错」整段**删除或改写**——该边界已消失。改写后必须说清：无 `pdfinfo` 时判据是「渲染页数少于请求页数」，`pdfinfo` 只用于给出更准确的总页数文案。
4. `_pdf_overflow_message` 自身 docstring（约 `:2067-2072`）补 `rendered` 参数说明与新文案分支（`total is None` 且 `rendered is not None` 时给出「请求 n 页只渲染出 m 页」）。
5. `pdf_page_count` docstring（约 `:2032-2033`）的「由 pdftoppm 的越界信号兜底判定」改为「由 `rasterize_pdf` 的渲染页数判据（及 pdftoppm 的越界信号）兜底判定」。

### D4 测试（新建 `test/eimg-ocr-pdf-test.el`，CLI 级端到端）

沿用本仓既有范式：`call-process` 真跑 `bin/eimg-ocr`（参照 `test/eimg-ocr-ollama-test.el` 的 `--run-cli`），`process-environment` 注入 env；**不引入 pytest、不引入 mock 库**。

**就绪判据（`skip-unless`，结果缓存到 defvar，避免重复探测）**：`python3` 存在 + `bin/eimg-ocr` 可执行 + `pdftoppm` 存在 + `test/fixtures/three-pages.pdf` 存在 + `bin/eimg-ocr --list-backends` 输出里 `tesseract` 为 `available=true`。最后一项的判定格式**必须先读 `bin/eimg-ocr` 的 `--list-backends` 分支（`:2391` 起）、`format_backend_line`（`:1203-1205`）与 `probe_backends`（`:1134` 起）再写断言**（不要凭猜；本文件**没有**名为 `render_backends` 的函数）。

**模拟「无 `pdfinfo`」**：在临时目录写一个可执行脚本 `pdfinfo`，内容 `#!/bin/sh\nexit 1\n`，`set-file-modes` 置 `#o755`，然后**把该目录 prepend 到 PATH**。依据：`pdf_page_count` 在 `shutil.which` 命中但 `returncode != 0` 时返回 `None`（`bin/eimg-ocr:2035-2050`），等价于缺失，且不牵连 `pdftoppm` / `python3`。
- **PATH 注入写法**：`process-environment` 中**靠前的条目优先**，因此必须 `(cons (concat "PATH=" fake-dir ":" (getenv "PATH")) process-environment)`，且**同时移除列表里已有的 `PATH=` 条目**（`(seq-remove (lambda (s) (string-prefix-p "PATH=" s)) process-environment)`）——只 cons 不删也能生效，但保留两条同名条目会让后续排障误判。用例结束（`unwind-protect`）删掉临时目录与脚本。
- 其余 env 参照既有范式：`PYTHONIOENCODING=utf-8`、`TMPDIR`（用 `make-temp-file "eimg-pdf-test-" t` 建目录）、`coding-system-for-read/write` = `utf-8-unix`、`default-directory` = 仓库根。

**四条用例**（一律 `--backend tesseract`，因后端探测不可跳过，无可用后端会在 `resolve_backend` 以 rc=2 短路）：

| 用例名 | 构造 | 断言 |
|---|---|---|
| `eimg-ocr-pdf-test-partial-overflow-without-pdfinfo` | 假 `pdfinfo` + `--pdf-pages 2-9` + `--format json` | rc=**3**；stderr 含 `无法读取输入`、`只渲染出 2 页`、`页码 4`（断言「页码 4」而非裸 `4`，避免匹配到「2-9」或「2 页」里的数字） |
| `eimg-ocr-pdf-test-partial-overflow-with-pdfinfo` | 真 `pdfinfo`（不注入假脚本）+ 同上参数 | rc=**3**；stderr 含 `共 3 页`（既有行为不变） |
| `eimg-ocr-pdf-test-valid-range-without-pdfinfo` | 假 `pdfinfo` + `--pdf-pages 2-3` + `--format json` | rc=**0**；JSON 解析后 `pages` 恰 **2** 个（防误伤，真跑 2 页 OCR） |
| `eimg-ocr-pdf-test-single-page-beyond-without-pdfinfo` | 假 `pdfinfo` + `--pdf-pages 9` | rc=**3**（`pdftoppm` rc=99 或零输出兜底，文案不断言） |

- C3 的 JSON 断言：**先读 CLI 的 json 输出结构**（`--format json` 的顶层键与页对象形态）再写断言，不要假设；若 blocks 为空也应产出页对象，断言只以「页数」为准，不依赖 OCR 内容。
- 用例 1/2/4 在栅格化阶段即失败，不跑 OCR；用例 3 真跑 2 页 OCR（本机实测约 2–4 秒）。

### D5 不做的事（明确边界）

- 不改 `--pdf-pages` 的语法解析、不新增参数、不改退出码常量与语义。
- 不改 `recognize_pdf` 的总页数前置校验。
- 不改多 PDF 混排的语义（「逐文件跳过」属技术债 #2，需独立契约决策）。
- 不改 `--page-images-dir`、后端探测、ollama / rapidocr 路径。
- 不给 `pdfinfo` 增加硬依赖，也不引入 `pypdf` 之类的库。

## 任务

- [x] **T1 先写测试（红）**：新建 `test/eimg-ocr-pdf-test.el`，实现 D4 的四条用例与就绪判据。写前先读 `bin/eimg-ocr` 的 `--list-backends` 分支（`:2391` 起）、`format_backend_line`（`:1203-1205`）、`probe_backends`（`:1134` 起）与 json 输出函数（`:1396-1432`），确认断言依据（EE-1；本文件**没有** `render_backends` 这个函数）。验收：写用例前先 `pdfinfo test/fixtures/three-pages.pdf | grep Pages` 实测确认 fixture 为 **3 页**（防 fixture 漂移导致用例 1 假红），实测输出记入报告；`make check-parens` 通过；`make test` 中用例 1 **失败**（红，证明判据缺失）、用例 2/3/4 通过；记录总用例数与失败条数（改前基线 **215**，新增 4 条应为 **219**，红阶段失败 1 条）。（依赖：无）
- [x] **T2 实现判据与文案（绿）**：按 D1 在 `rasterize_pdf` 加判据，按 D2 给 `_pdf_overflow_message` 加 `rendered` 参数与新文案，按 D3 同步三处 docstring/注释。验收：`make py-check` 通过；`make test` **219 条全绿**；`grep -n "_pdf_overflow_message" bin/eimg-ocr` 应为 5 行（1 处 `def` 定义行 + 4 处调用点：3 处不传 `rendered`、1 处传），确认无遗漏调用者。（依赖：T1）
- [x] **T3 文档沉淀**：① `openspec/tech-debt.md` 删除「无 pdfinfo 时部分页码越界会静默截断（P1 · 成本 S）」整条，在 `## 已关闭（索引）` 追加一行（日期 + 证据：commit + 用例名 + D16 指针）；② `README.org` **两处**同步：删除「已知边界」中「*无 =pdfinfo= 时部分页码越界会静默截断*」整条（约 `:456-458`）并检查上下文列表是否连续；**同时改写「前置」节 `:39-40`** 的「缺 =pdfinfo= 时页码越界可能静默截断（见「已知边界」）」为「缺 =pdfinfo= 时页码越界仍报错（退出码 3），只是文案无法给出总页数」，并移除失效的「（见「已知边界」）」交叉引用（该条已删除）；③ `CHANGELOG.md` 的 `### 修复` 追加一条（说明：无 `pdfinfo` 时部分越界不再静默截断；多 PDF 混排 + 部分越界统一为退出码 3）；④ `openspec/decisions.md` 追加 **D16**（三个子项：判据改为「渲染页数 vs 请求页数」、`pdfinfo` 退化为文案增强、新判据仅 `total is None` 时启用以隔离损坏页风险）。验收：`grep -c '^## ' openspec/tech-debt.md` 由 13 变为 **12**；`grep -n "静默截断" README.org` 必须 **0 命中**（README 是用户可见的当前契约，不留历史描述）；`grep -n "静默截断" openspec/tech-debt.md` 的命中只允许出现在「已关闭（索引）」行；`grep -n "见「已知边界」" README.org` 不得残留指向已删除条目的引用；D16 编号与既有 D15 连续。（依赖：T2）
- [x] **T4 全量验证收尾**：`make check-parens`、`make py-check`、`make full-check`；`make clean` 后 `git status --porcelain` 只含预期改动（本计划文件 + `bin/eimg-ocr` + 新建测试 + `tech-debt.md` + `README.org` + `CHANGELOG.md` + `decisions.md`，另允许未跟踪的 `.envrc` 与 `.tmp-test` 不残留）。验收：三命令退出码与关键输出记录进报告；任一失败按修复循环处理（L1/L2 各最多 3 轮，耗尽则 `git checkout --` 回滚本轮改动并上报）。（依赖：T1–T3）

## 文档清单

| 文档 | 触发原因 | 动作 |
|---|---|---|
| `openspec/tech-debt.md` | 技术债销项 | 删条目 + 「已关闭（索引）」加一行 |
| `README.org` | 「已知边界」条目失效 + 「前置」节交叉引用失效 | 删除 `:456-458` 条目；改写 `:39-40`（不再说「可能静默截断」，移除交叉引用） |
| `CHANGELOG.md` | 用户可感知的行为变更 | `### 修复` 追加一条 |
| `openspec/decisions.md` | 判据语义决策 | 追加 D16（三子项） |
| CLI 参数表 / 退出码表 | 无契约变更 | 不动 |
| `test/eimg-ocr-pdf-test.el` | 新增测试 | 新建文件（Makefile `test/*-test.el` 通配自动收集，不改 Makefile） |

## 验证标准

- **L1**：`make check-parens`（逐文件独立 `emacs -Q --batch`）、`make py-check`（`py_compile`）。
- **L2**：`make test` 全绿，用例数 215 → **219**。新增 4 条见 D4；不修改任何既有用例（本次不改既有语义）。
- **L3**（手工，委派 general 执行并记录实际输出）：① 假 `pdfinfo` + `--pdf-pages 2-9` 的真 CLI stderr 原文（确认文案可读、含越界页号与渲染页数）；② 假 `pdfinfo` + 整本（不带 `--pdf-pages`）→ rc=0 且 3 页（确认未误伤整本识别）；③ 真 `pdfinfo` + `--pdf-pages 2-9` → rc=3 且文案仍含「共 3 页」（既有行为不变）。
- 本仓验证统一走 `make` 目标（`emacs -Q --batch` 独立进程，不连 emacsclient、不加载用户配置），因此**不需要** elisp MCP 实例分流——这是 README「开发与验证」的既定契约。

## 注意事项

1. **TDD 顺序不可颠倒**：T1 必须先写测试并记录「用例 1 失败」的红阶段证据，再进 T2。若 T1 时用例 1 意外通过，说明判据已存在或测试构造无效，须先排查（不要直接改代码）。
2. **PATH 注入细节**：`process-environment` 靠前优先；必须 cons 到最前，并建议移除旧 `PATH=` 条目。假 `pdfinfo` 脚本必须 `#o755`，否则 `shutil.which` 找不到 → 用例变成「真 pdfinfo」路径而假绿。
3. **不要动既有三个 `_pdf_overflow_message` 调用点**：它们的文案是回归约束（rc=99 / 零输出 / 前置校验），新增参数必须默认值兼容。
4. **不要给 `pdfinfo` 加硬依赖**：本改动的价值在于「没有 `pdfinfo` 也能发现少识别」，任何「要求安装 pdfinfo」的方案都偏离目标。
5. **`total` 已知时不得启用新判据**：否则「单页渲染失败但 rc=0」会被误报为页码越界（新风险）。
6. **测试必须真跑 CLI**（`call-process bin/eimg-ocr`），不要用 `exec_module` 直调 `rasterize_pdf` 代替——本条的验收对象是「用户看到的退出码与 stderr」，模块直调会把「main 的异常处理路径」测漏。
7. **行为变更同轮更新文档**：D3 的三处 docstring 是硬要求，`recognize_pdf` 的「已知边界」段必须删/改，不许留「文档说会静默截断、代码已报错」的漂移。
8. 修改前记录安全点：`git -C /home/thomas/Workspace/eimg rev-parse HEAD` 与 `git status --porcelain`（开工前工作区除 `.envrc` 与本计划文件外必须干净），写入报告；回滚用 `git checkout -- <file>`。
9. 不要顺手修技术债 #2（多 PDF 混排 `--pdf-pages` 重复生效）——它需要先定契约（逐文件跳过 vs 整批失败），本改动只是让两种环境行为统一为「整批失败」。
10. 中文输出与注释；提交信息若需要，用简体中文并遵循既有 Conventional Commits 风格（本轮不强制提交，由用户决定）。

## 完成记录

- **验证**：`make check-parens` / `make py-check` / `make full-check` 三项退出码与 ERT 汇总行见下（由 T4 报告回填）：`Ran 219 tests, 219 results as expected, 0 unexpected`（改前基线 215）。
- **TDD 红阶段证据**：T1 完成后 `make test` 为 `Ran 219 tests, 218 results as expected, 1 unexpected`，唯一失败是 `eimg-ocr-pdf-test-partial-overflow-without-pdfinfo`（`(equal 3 0)`，实际 rc=0），证明判据缺失；T2 后转绿。
- **行为变更**：无 `pdfinfo` 时 `--pdf-pages` 部分越界由「rc=0 静默截断」改为「rc=3 报错」；多 PDF 混排 + 部分越界在两种环境下统一为整批失败（与有 `pdfinfo` 时一致）。
- **未做**：多 PDF 混排的「逐文件跳过」契约（tech-debt #2）、`total` 已知时的「静默少渲染」检测（未实测形态）。
- **代码审查**（code-reviewer）：通过，无 blocking / should-fix；6 项 nit 中采纳 4 项（`parse_pdf_pages` docstring 归口表述、C3 补页号 `(2 3)` 断言、C4 补契约子串断言、D16「代价」栏补对称残余），未采纳 2 项（新增 `1-3` / 单页合法用例——C3 已覆盖同类；`PYTHONIOENCODING` 重复条目——无实质影响）。
- **审查后验证**：`make check-parens` / `make py-check` / `make test` 均 rc=0，`Ran 219 tests, 219 results as expected, 0 unexpected`。
