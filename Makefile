# eimg 验证入口
#
# 全部目标用 `emacs -Q --batch` 起独立进程：不依赖 emacsclient，也不会碰运行中的
# daemon（主实例被占住会连带卡住验证，独立进程避免这个耦合）。
# 骨架期「无 .el / 无测试文件 / 无 python3」三种情况一律空跑成功，保证 CI 与本地
# `make full-check` 在仓库尚未长出实现时也能拿到退出码 0。

EMACS ?= emacs

# 收集待检查的 elisp 文件：排除 .git（版本库）、.local（straight 本地克隆，第三方源码
# 不该由本项目把关）、*-autoloads*.el（生成物，会和源文件漂移）。
#
# 通配收紧到 `*-autoloads*.el` 而不是只排 `*-autoloads.el`：ERT 的 autoload 用例会把
# `loaddefs-generate' 的输出写到仓库根（`eimg-autoloads-test-<pid>.el'，落在仓库根
# 是因为 loaddefs 记的是相对输出目录的路径，写 /tmp 会得到解析不到的 `../eimg-*'）。
# 那些文件正常跑完即删，Ctrl-C 打断时却会留下，且名字不匹配 `*-autoloads.el'——
# check-parens 会去检查一个生成物，报的错与源码无关。
EL_FILES := $(shell find . -name '*.el' -not -path './.git/*' -not -path './.local/*' -not -name '*-autoloads*.el' 2>/dev/null)

# 测试文件约定为 test/*-test.el；用 sort 保证加载顺序稳定（ERT 按加载顺序注册用例）。
TEST_FILES := $(sort $(wildcard test/*-test.el))

# 测试临时目录：**显式钉在仓库内**，不继承调用者的环境。
#
# 为什么必须显式设：ERT 用例里的 `make-temp-file' 用的是 Emacs 的
# `temporary-file-directory'，而它直接取自环境变量 TMPDIR（未设时才是 /tmp/）。
# 也就是说「测试产物落在哪」由跑测试的那个 shell 决定：一旦 TMPDIR 被指向
# ~/thomas-emacs 这类用户仓库，`eimg-ocr-write-XXXX/out.org`、`eimg-ocr-stub-XXXX.sh`
# 就会生成在别人的版本库里——跨仓污染，而且测试自己看不见（它只关心文件内容）。
# 钉到 $(CURDIR)/.tmp-test 后，产物与仓库同生命周期，跑完（无论成败）即删；
# 中途被 Ctrl-C 打断时留下的残留也在仓库内，`make clean` 一并清掉。
TEST_TMPDIR := $(CURDIR)/.tmp-test

.PHONY: all check-parens test py-check full-check clean

all: full-check

# L1：括号平衡检查，逐文件独立进程。
# 为什么逐文件：一个文件的括号错误不应掩盖其它文件的结果，且失败点定位更直接；
# 任一文件失败立刻退出非零，不做「继续跑完再汇总」。
check-parens:
	@if [ -z "$(EL_FILES)" ]; then \
		echo "no elisp files"; \
	else \
		for f in $(EL_FILES); do \
			echo "check-parens: $$f"; \
			$(EMACS) -Q --batch --eval '(progn (find-file (car command-line-args-left)) (check-parens) (kill-emacs 0))' "$$f" || exit 1; \
		done; \
	fi

# L2：ERT。自动加载 test/ 下全部 *-test.el，交给 ert 自跑。
# 为什么这里不检查 python：OCR 后端（bin/ 下的 Python 脚本）出问题不该让 elisp 测试
# 整体变红，所以 python 检查单独成 py-check 目标，与 test 解耦。
#
# TMPDIR 必须显式指向 $(TEST_TMPDIR)（理由见文件头注释），且在**任何**退出路径上
# 都删掉它：这里用 `rc=$$?' 捕获退出码再 `rm -rf'，等价于 unwind-protect——
# 无论 ERT 全绿、有失败、还是 Emacs 自己崩掉，临时目录都不会残留。
test:
	@if [ -z "$(TEST_FILES)" ]; then \
		echo "no test files"; \
	else \
		echo "test: $(TEST_FILES)"; \
		mkdir -p "$(TEST_TMPDIR)"; \
		TMPDIR="$(TEST_TMPDIR)" $(EMACS) -Q --batch -L . -L test $(addprefix -l ,$(TEST_FILES)) -f ert-run-tests-batch-and-exit; \
		rc=$$?; \
		rm -rf "$(TEST_TMPDIR)"; \
		exit $$rc; \
	fi

# L1 补充：bin/ 下可执行 Python 脚本的语法检查（py_compile）。
# 为什么判「可执行」而不只看扩展名：bin/ 里的入口通常是无扩展名的可执行脚本，
# 只按 *.py 匹配会漏检；同时用 shebang 里的 python 关键字兜住「可执行但不是 Python」
# 的脚本（比如未来的 shell 包装器），避免把它们误送进 py_compile。
# 为什么 python3 缺失时成功退出：本机 / CI 可能没有 Python，elisp 侧的验证不该因此变红。
py-check:
	@if ! command -v python3 >/dev/null 2>&1; then \
		echo "no python3, skip py-check"; \
	else \
		checked=0; \
		for f in bin/*; do \
			[ -f "$$f" ] && [ -x "$$f" ] || continue; \
			case "$$f" in \
				*.py) ;; \
				*) head -n 1 "$$f" | grep -q python || continue ;; \
			esac; \
			echo "py-check: $$f"; \
			python3 -m py_compile "$$f" || exit 1; \
			checked=$$((checked + 1)); \
		done; \
		if [ "$$checked" -eq 0 ]; then echo "no executable python scripts under bin, skip py-check"; fi; \
	fi

# 完整检查只串 L1 + L2：py-check 与 elisp 骨架无因果关系，按需单独跑。
full-check: check-parens test

# 清理可再生产物：.elc / 原生编译缓存 / Python 字节码缓存 / 测试临时目录。
# `.tmp-test' 是 `make test' 的 TMPDIR（见 `TEST_TMPDIR'）：正常跑完会自动删，
# 这里兜住「中途被打断」的残留。
clean:
	rm -rf eln-cache .eln-cache .tmp-test
	find . -name '*.elc' -not -path './.git/*' -delete
	find . -name '__pycache__' -type d -not -path './.git/*' -prune -exec rm -rf {} +
	# autoload 用例的生成物（`eimg-autoloads-test-<pid>.el'）：`unwind-protect' 会删，
	# 但 Ctrl-C 打断时残留；名字与 `*-autoloads.el' 不匹配，故单独清一次。
	find . -name '*-autoloads-test*.el' -not -path './.git/*' -delete
