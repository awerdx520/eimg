;;; eimg-ocr-setup-test.el --- tessdata 下载的内容校验用例  -*- lexical-binding: t; -*-

;; Author: thomas
;; Version: 0.1.0
;; Keywords: convenience, tools, ocr

;;; Commentary:

;; 覆盖 `bin/eimg-ocr-setup' 的 tessdata 下载路径（计划 B4）：`download()' 边写边算
;; sha256 并与 `TESSDATA_SHA256' 比对，`run_tessdata()' 对「已存在且校验通过」的文件
;; 直接跳过、不联网。
;;
;; 做法：`call-process python3' 跑一段内联脚本，脚本自己加载 `bin/eimg-ocr-setup'
;; （无 `.py' 后缀，必须显式造 `SourceFileLoader'——生产文件 `load_cli' 的注释里
;; 讲的就是这个坑），起一个 `ThreadingHTTPServer' 在 127.0.0.1 的**内核分配端口**
;; 上返回固定字节，然后调真正的 `run_tessdata()'。所有断言都在 python 侧完成，
;; 脚本只往 stdout 打印结构化结论（`CASE1 ok ...'），ERT 断言这些行。
;;
;; 三条硬约束：
;;   1. **不联网**：`TESSDATA_URLS' 被覆写成 127.0.0.1 的本地服务（第 3 条用例甚至
;;      指向必然连不上的 127.0.0.1:1——「跳过下载」若失效，用例会因连接失败变红）。
;;      生产常量 `TESSDATA_SHA256' 也按用例覆写，测试夹具的哈希绝不进生产代码。
;;   2. **不写仓库内路径**：临时目录一律 `tempfile.mkdtemp()'（跟随 `make test' 钉的
;;      `TMPDIR'），`try/finally' + `shutil.rmtree' 清理。
;;   3. **绕开代理**：本机 `http_proxy' 已设而 `no_proxy' 未设，本地 `http.server'
;;      的请求会被代理接管拿到假响应（`rules/environment.md'）。`urlopen' 带
;;      `context=' 时会自建 opener、不认 `install_opener'，故只能从环境变量这一层绕，
;;      ERT 侧与脚本侧各设一次。
;;
;; 四条用例共用**同一个** python 进程与同一个 http.server（一次跑完，结果缓存），
;; 于是不需要为了「每条用例一个 server」付四次端口分配与启动开销；ERT 侧四条用例
;; 各自断言自己那行结论，失败归因仍精确到条。

;;; Code:

(require 'ert)

(defvar eimg-ocr-setup-test--file
  (or load-file-name buffer-file-name)
  "本文件的路径（加载期取值）。
运行期 `load-file-name' 不再绑定，故必须在加载时就抓住它，供「推导仓库根」兜底。")

(defconst eimg-ocr-setup-test--script
  "import contextlib
import hashlib
import http.server
import importlib.machinery
import importlib.util
import io
import os
import pathlib
import shutil
import sys
import tempfile
import threading
import types

# 本机 http_proxy 已设而 no_proxy 未设：本地 http.server 的请求会被代理接管。
# urlopen(context=...) 会自建 opener（不认 install_opener），故只能改环境变量。
BYPASS = '127.0.0.1,localhost,::1'
os.environ['no_proxy'] = BYPASS
os.environ['NO_PROXY'] = BYPASS

loader = importlib.machinery.SourceFileLoader('eimg_ocr_setup', sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
setup = importlib.util.module_from_spec(spec)
loader.exec_module(setup)

# 1.0625 MB：超过 MIN_TESSDATA_BYTES（1 MB）但只占几 MB 内存/流量。
PAYLOAD = bytes(1024 * 1024 + 64 * 1024)
SHA = hashlib.sha256(PAYLOAD).hexdigest()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/chi_sim.traineddata':
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Length', str(len(PAYLOAD)))
        self.end_headers()
        self.wfile.write(PAYLOAD)

    def log_message(self, *args):
        # 静音访问日志：它会混进 ERT 用来断言的 stdout。
        pass


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
PORT = server.server_address[1]
GOOD_URL = 'http://127.0.0.1:{}/chi_sim.traineddata'.format(PORT)
# 必然连不上的地址：用它证明「跳过下载」确实没发请求。
DEAD_URL = 'http://127.0.0.1:1/chi_sim.traineddata'

NOTES = []
ORIGINAL_NOTE = setup.note


def capture_note(message):
    NOTES.append(message)


setup.note = capture_note


def args_for(tmp):
    # run_tessdata 只用到这三个属性（tessdata_dir 经 tessdata_dir(args) 读取）。
    return types.SimpleNamespace(tessdata_dir=tmp, dry_run=False, yes=True)


def check(condition, detail):
    if not condition:
        raise AssertionError(detail)


def read_bytes(path):
    with open(path, 'rb') as handle:
        return handle.read()


def case1(tmp):
    # 哈希匹配 -> 成功落盘、无 .part 残留。
    NOTES.clear()
    setup.TESSDATA_URLS = (GOOD_URL,)
    setup.TESSDATA_SHA256 = {'chi_sim.traineddata': SHA}
    code = setup.run_tessdata(args_for(tmp))
    target = os.path.join(tmp, 'chi_sim.traineddata')
    check(code == setup.EXIT_OK, 'run_tessdata 返回 {}'.format(code))
    check(os.path.isfile(target), '目标文件不存在: ' + target)
    check(read_bytes(target) == PAYLOAD, '目标内容与下载字节不一致')
    check(not os.path.exists(target + '.part'), '.part 半成品残留')
    hashed = any(SHA[:12] in note for note in NOTES)
    check(hashed, '成功路径的 note 里没有哈希前 12 位')
    return 'file=ok part=none content=match note_sha={}'.format(hashed)


def case2(tmp):
    # 哈希不匹配 -> SetupError(code=1)，目标文件与 .part 都不留。
    NOTES.clear()
    setup.TESSDATA_URLS = (GOOD_URL,)
    setup.TESSDATA_SHA256 = {'chi_sim.traineddata': '0' * 64}
    code = None
    message = ''
    try:
        setup.run_tessdata(args_for(tmp))
    except setup.SetupError as exc:
        code = exc.code
        message = exc.message
    target = os.path.join(tmp, 'chi_sim.traineddata')
    check(code == setup.EXIT_FAILED, '期望 SetupError.code == 1，实际 {}'.format(code))
    check('内容校验不通过' in message, '文案不含「内容校验不通过」: ' + message)
    check(not os.path.exists(target), '校验失败后目标文件仍存在')
    check(not os.path.exists(target + '.part'), '校验失败后 .part 仍存在')
    return 'code=1 target=none part=none message=ok'


def case3(tmp):
    # 已存在且校验通过 -> 跳过下载（URL 指向必连不上的地址，真去下载就会抛错）。
    target = os.path.join(tmp, 'chi_sim.traineddata')
    with open(target, 'wb') as handle:
        handle.write(PAYLOAD)
    before = os.stat(target)
    NOTES.clear()
    setup.TESSDATA_URLS = (DEAD_URL,)
    setup.TESSDATA_SHA256 = {'chi_sim.traineddata': SHA}
    code = setup.run_tessdata(args_for(tmp))
    after = os.stat(target)
    check(code == setup.EXIT_OK, 'run_tessdata 返回 {}'.format(code))
    check(before.st_mtime_ns == after.st_mtime_ns, '文件被重写（mtime 变了）')
    check(before.st_size == after.st_size, '文件大小变了')
    check(read_bytes(target) == PAYLOAD, '文件内容被改写')
    skipped = any('跳过下载' in note for note in NOTES)
    check(skipped, '没有出现「跳过下载」提示，说明走了下载路径')
    return 'skipped=1 exit=0 mtime_same=1 content=match'


def case4(tmp):
    # 期望哈希表为空（真值待补的降级态）-> 放行，但必须在 stderr 明示「本次未做内容校验」。
    # 断言 up_to_date 为 False 是这条用例的另一半：空表不得把「已经下过的文件」判成
    # 「已是最新」——否则第二次跑 `--tessdata` 会跳过下载，用户永远拿不到校验能力。
    original = setup.TESSDATA_SHA256
    try:
        NOTES.clear()
        setup.TESSDATA_URLS = (GOOD_URL,)
        setup.TESSDATA_SHA256 = {}
        captured = io.StringIO()
        with contextlib.redirect_stderr(captured):
            code = setup.run_tessdata(args_for(tmp))
        stderr = captured.getvalue()
        target = os.path.join(tmp, 'chi_sim.traineddata')
        check(code == setup.EXIT_OK, 'run_tessdata 返回 {}'.format(code))
        check(os.path.isfile(target), '目标文件不存在: ' + target)
        check('未登记' in stderr, 'stderr 里没有「未登记」: ' + stderr)
        check('仅做体积校验' in stderr, 'stderr 里没有「仅做体积校验」: ' + stderr)
        # tessdata_up_to_date 的形参是 Path（内部取 .name），传 str 会 AttributeError。
        check(setup.tessdata_up_to_date(pathlib.Path(target)) is False,
              '空哈希表把已有的合法文件判成「已是最新」')
        return 'unverified_warned=true up_to_date=false'
    finally:
        setup.TESSDATA_SHA256 = original


FAILURES = 0
for NAME, FUNC in (('CASE1', case1), ('CASE2', case2), ('CASE3', case3),
                   ('CASE4', case4)):
    TMP = tempfile.mkdtemp(prefix='eimg-setup-')
    try:
        print('{} ok {}'.format(NAME, FUNC(TMP)))
    except Exception as exc:
        FAILURES += 1
        print('{} fail {}: {}'.format(NAME, type(exc).__name__, exc))
    finally:
        shutil.rmtree(TMP, ignore_errors=True)

setup.note = ORIGINAL_NOTE
server.shutdown()
server.server_close()
print('RUN done failures={}'.format(FAILURES))
sys.exit(0)
"
  "内联 Python 脚本：四个用例共用一个本地 `http.server'。
脚本向 stdout 打印 `CASE<n> ok ...' / `CASE<n> fail ...' 与末行 `RUN done
failures=<n>'，ERT 侧只对这些行做文本断言（断言本身全在 python 里）。")

(defvar eimg-ocr-setup-test--cache nil
  "缓存 `eimg-ocr-setup-test--script-run' 的结果 `(退出码 STDOUT STDERR)'。
四条用例共享一次运行——共用同一个 http.server 的前提就是「一个进程跑完四例」。")

(defun eimg-ocr-setup-test--root ()
  "返回 eimg 仓库根目录（`test/' 的上一级）。
优先用 `locate-library'（`make test' 带 `-L .'，能找到仓库根的 `eimg.el'）；
它可能返回相对路径，故统一 `expand-file-name' + `file-truename'。"
  (let ((library (locate-library "eimg")))
    (if library
        (file-name-directory (file-truename (expand-file-name library)))
      ;; 兜底：本文件在 `<root>/test/' 下，往上两级即仓库根。
      (file-name-directory
       (directory-file-name
        (file-name-directory (expand-file-name eimg-ocr-setup-test--file)))))))

(defun eimg-ocr-setup-test--setup-path ()
  "被测试的安装脚本 `bin/eimg-ocr-setup' 的绝对路径。"
  (expand-file-name "bin/eimg-ocr-setup" (eimg-ocr-setup-test--root)))

(defun eimg-ocr-setup-test--python ()
  "可用的 python 解释器（优先 python3）；没有时返回 nil。"
  (or (executable-find "python3") (executable-find "python")))

(defun eimg-ocr-setup-test--ready-p ()
  "本机具备跑用例的两件前提：python 与被测脚本可读。
缺任何一件就 `skip-unless' 跳过——没装 python 的机器应跳过而不是变红。"
  (and (eimg-ocr-setup-test--python)
       (file-readable-p (eimg-ocr-setup-test--setup-path))))

(defun eimg-ocr-setup-test--script-run ()
  "跑一次内联 python 脚本，返回 `(退出码 STDOUT STDERR)'（结果缓存）。
编码全部钉成 utf-8：中文断言不能受 locale 影响。stderr 单独收进临时文件——
混进 stdout 会让「断言缺行 + 原因」这类判断拿不到东西。"
  (or eimg-ocr-setup-test--cache
      (setq eimg-ocr-setup-test--cache
            (let* ((out (generate-new-buffer " *eimg-setup-stdout*"))
                   (err-file (make-temp-file "eimg-setup-stderr-" nil ".log"))
                   (default-directory (eimg-ocr-setup-test--root))
                   (coding-system-for-read 'utf-8-unix)
                   (coding-system-for-write 'utf-8-unix)
                   (process-environment
                    (append (list
                             ;; 本地 http.server 必须绕开代理（理由见 Commentary 第 3 条）。
                             "no_proxy=127.0.0.1,localhost,::1"
                             "NO_PROXY=127.0.0.1,localhost,::1"
                             "PYTHONIOENCODING=utf-8"
                             ;; 不开 -B：`py_compile' 由 `make py-check' 负责，
                             ;; 这里跑的是源码加载，字节码缓存落在临时目录外也无害。
                             )
                            process-environment)))
              (unwind-protect
                  (let ((code (call-process
                               (eimg-ocr-setup-test--python) nil (list out err-file) nil
                               "-c" eimg-ocr-setup-test--script
                               (eimg-ocr-setup-test--setup-path))))
                    (list code
                          (with-current-buffer out (buffer-string))
                          (with-temp-buffer
                            (insert-file-contents err-file)
                            (buffer-string))))
                (kill-buffer out)
                (ignore-errors (delete-file err-file)))))))

(defun eimg-ocr-setup-test--assert-case (label pattern)
  "断言 python 侧 LABEL 那行结论匹配 PATTERN。
失败时把完整 stdout / stderr 一起塞进 ERT 报告：只说「没匹配上」无法区分是断言
写错了还是 python 侧真的失败。"
  (let* ((result (eimg-ocr-setup-test--script-run))
         (stdout (nth 1 result))
         (stderr (nth 2 result)))
    (should (equal 0 (nth 0 result)))
    (unless (string-match-p pattern stdout)
      (ert-fail (format "%s 的结构化结论缺失（期望 /%s/）\n--- stdout ---\n%s\n--- stderr ---\n%s"
                        label pattern stdout stderr)))))

;;;; ── 1. 哈希匹配：下载成功 ────────────────────────────────────────────

(ert-deftest eimg-ocr-setup-test-hash-match-succeeds ()
  "哈希匹配时 `run_tessdata' 返回 0，目标文件内容与下载字节一致、无 `.part' 残留。
数据来自本地 `http.server'（固定 1.0625 MB，过 `MIN_TESSDATA_BYTES'），期望哈希由
同一份字节算出——这条钉的是「校验通过就放行」，不是「永远拒绝」。"
  (skip-unless (eimg-ocr-setup-test--ready-p))
  (eimg-ocr-setup-test--assert-case
   "CASE1" "^CASE1 ok file=ok part=none content=match note_sha=True"))

;;;; ── 2. 哈希不匹配：失败且不留残留 ───────────────────────────────────

(ert-deftest eimg-ocr-setup-test-hash-mismatch-removes-partial ()
  "期望哈希改成错的 → `SetupError' 且 `code == 1'（`EXIT_FAILED'）；目标文件与
`.part' 都不留。
为什么断言「两个文件都不存在」：只断言退出码的话，把半成品留在盘上的实现也能过，
而那份半成品下一次运行会成为「已存在的文件」——正是本轮要给 `--tessdata' 堵的坑。"
  (skip-unless (eimg-ocr-setup-test--ready-p))
  (eimg-ocr-setup-test--assert-case
   "CASE2" "^CASE2 ok code=1 target=none part=none message=ok"))

;;;; ── 3. 已存在且匹配：跳过下载 ────────────────────────────────────────

(ert-deftest eimg-ocr-setup-test-existing-match-skips-download ()
  "目标目录里已有内容正确的文件时，`TESSDATA_URLS' 指向 `127.0.0.1:1'（必然连不上）
仍返回 0，且文件 mtime/内容未变。
「没变」是关键：若实现真的去下载，连接失败会抛 `SetupError'；即便连上了，重写文件
也会让 mtime 变化——两条都足以让这条用例变红，不需要统计请求数。"
  (skip-unless (eimg-ocr-setup-test--ready-p))
  (eimg-ocr-setup-test--assert-case
   "CASE3" "^CASE3 ok skipped=1 exit=0 mtime_same=1 content=match"))

;;;; ── 4. 期望哈希未登记：放行但必须在 stderr 明示「未做内容校验」 ──────

(ert-deftest eimg-ocr-setup-test-unregistered-hash-warns ()
  "`TESSDATA_SHA256' 为空表（真值待补的降级态）时：下载仍成功（返回 0、目标文件在），
但 stderr 必须含「未登记」与「仅做体积校验」，且 `tessdata_up_to_date' 对该文件返回
`False'。
为什么三条一起断言：只查「返回 0」放过了静默降级（用户以为校验过了）；只查 stderr
文案放过了「空表把文件判成已是最新」——那会让第二次 `--tessdata` 跳过下载，校验
能力永远补不上来。警告走 stderr 而不是 stdout，是为了在 `--check` / 管道场景里也不被
当成正常进度输出吞掉。"
  (skip-unless (eimg-ocr-setup-test--ready-p))
  (eimg-ocr-setup-test--assert-case
   "CASE4" "^CASE4 ok unverified_warned=true up_to_date=false"))

(provide 'eimg-ocr-setup-test)

;;; eimg-ocr-setup-test.el ends here
