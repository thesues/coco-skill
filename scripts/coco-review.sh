#!/usr/bin/env bash
# coco-review.sh — drive the local `coco` CLI as a REVIEW-ONLY code reviewer.
# Model fallback: GPT-5.5 => GLM-5.1.
#
# Three modes (all share: disposable git-worktree isolation + model fallback + auto-cleanup).
# NONE of them call coco's built-in /findbugs skill — every mode drives coco with our own
# prompt embedded in this script:
#   1) (default)  DIFF review of working changes / MR / commit range (custom prompt)
#   2) inspect    full-file review of EXISTING code (no diff needed), loops over many files
#   3) arch       ARCHITECTURE / data-corruption audit, cross-component reasoning,
#                 optionally fed prior findings via --context
#
# HARD GUARANTEE: never modifies your code. coco's tools include Bash, which can write files
#   even when Edit/Write are disallowed — so we run everything inside a throwaway git WORKTREE
#   (or cp -a copy for non-git dirs) that is ALWAYS removed on exit (trap). Defense in depth:
#   write tools are disallowed and the prompt forbids any modification.
#
# Usage:
#   coco-review.sh [--repo PATH] [fast|deep] [--with-lint=false] [--mr URL]      # mode 1
#   coco-review.sh [--repo PATH] inspect [--mode fast|deep] FILE [FILE...]       # mode 2
#   coco-review.sh [--repo PATH] arch [--context FINDINGS_FILE] [free-text focus]# mode 3
#
# Output: stdout = review report(s). stderr = progress + "model_used=<MODEL>".

set -uo pipefail

MODELS=("GPT-5.5" "GLM-5.1")
DISALLOWED=(Edit Write Replace ApplyPatch CreateFile DeleteFile MultiEdit)

REPO="$(pwd)"
MODE="findbugs"
INSPECT_MODE="deep"
INSPECT_FILES=()
ARCH_CONTEXT=""
ARCH_FOCUS=""
FINDBUGS_ARGS=()

# --- pull out global flags (--repo, --context) from anywhere ---
PASS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)      REPO="$2"; shift 2 ;;
    --repo=*)    REPO="${1#--repo=}"; shift ;;
    --context)   ARCH_CONTEXT="$2"; shift 2 ;;
    --context=*) ARCH_CONTEXT="${1#--context=}"; shift ;;
    *)           PASS+=("$1"); shift ;;
  esac
done
set -- "${PASS[@]:-}"

# --- detect mode from the first positional ---
case "${1:-}" in
  inspect)
    MODE="inspect"; shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --mode)   INSPECT_MODE="$2"; shift 2 ;;
        --mode=*) INSPECT_MODE="${1#--mode=}"; shift ;;
        fast|deep) INSPECT_MODE="$1"; shift ;;
        *)        INSPECT_FILES+=("$1"); shift ;;
      esac
    done
    ;;
  arch)
    MODE="arch"; shift
    ARCH_FOCUS="$*"
    ;;
  *)
    FINDBUGS_ARGS=("$@")
    ;;
esac

command -v coco >/dev/null 2>&1 || { echo "ERROR: 'coco' not found on PATH. Install it first." >&2; exit 127; }
[ -d "$REPO" ] || { echo "ERROR: repo path does not exist: $REPO" >&2; exit 2; }
REPO="$(cd "$REPO" && pwd)"

# ---- cleanup state ----
WT=""; COPYDIR=""; IS_GIT=0
cleanup() {
  if [ "$IS_GIT" -eq 1 ] && [ -n "$WT" ]; then
    git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
    git -C "$REPO" worktree prune >/dev/null 2>&1
    echo ">>> cleaned up worktree: $WT" >&2
  elif [ -n "$COPYDIR" ]; then
    rm -rf "$COPYDIR"; echo ">>> cleaned up copy: $COPYDIR" >&2
  fi
}
trap cleanup EXIT INT TERM

# ---- build the isolated review tree ----
if git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  IS_GIT=1
  REPO="$(git -C "$REPO" rev-parse --show-toplevel)"
  WT="/tmp/coco-review-wt${REPO}"
  echo ">>> Isolating via git worktree (your real working files will NOT be touched)" >&2
  echo ">>>   repo:     $REPO" >&2
  echo ">>>   worktree: $WT" >&2
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
  rm -rf "$WT"
  if ! git -C "$REPO" worktree add --detach --quiet "$WT" HEAD 2>/tmp/coco_wt_err; then
    echo "ERROR: failed to create worktree:" >&2; cat /tmp/coco_wt_err >&2; rm -f /tmp/coco_wt_err; exit 3
  fi
  rm -f /tmp/coco_wt_err
  # replay uncommitted tracked changes (incl. binaries)
  patch="$(mktemp)"; git -C "$REPO" diff HEAD --binary > "$patch" 2>/dev/null
  if [ -s "$patch" ]; then
    git -C "$WT" apply --whitespace=nowarn "$patch" 2>/dev/null \
      && echo ">>>   replayed uncommitted tracked changes" >&2 \
      || echo ">>>   WARNING: could not replay all tracked changes" >&2
  fi
  rm -f "$patch"
  # replay untracked, non-ignored files
  n=0
  while IFS= read -r -d '' f; do
    mkdir -p "$WT/$(dirname "$f")"; cp -a "$REPO/$f" "$WT/$f" 2>/dev/null && n=$((n+1))
  done < <(git -C "$REPO" ls-files --others --exclude-standard -z 2>/dev/null)
  [ "$n" -gt 0 ] && echo ">>>   replayed $n untracked file(s)" >&2
  REVIEW_DIR="$WT"
else
  COPYDIR="/tmp/coco-review-src${REPO}"
  echo ">>> Not a git repo — isolating via disposable copy: $COPYDIR" >&2
  rm -rf "$COPYDIR"; mkdir -p "$COPYDIR"; cp -a "$REPO"/. "$COPYDIR"/ 2>/dev/null
  [ -n "$(ls -A "$COPYDIR" 2>/dev/null)" ] || { echo "ERROR: failed to copy repo to $COPYDIR" >&2; exit 3; }
  REVIEW_DIR="$COPYDIR"
fi

DISALLOW_FLAGS=()
for t in "${DISALLOWED[@]}"; do DISALLOW_FLAGS+=(--disallowed-tool "$t"); done

# ---- shared: run coco with model fallback ----
# run_coco <prompt> [label]
run_coco() {
  local prompt="$1" label="${2:-}" status out
  for model in "${MODELS[@]}"; do
    echo ">>> coco model=$model${label:+ [$label]}" >&2
    out="$(cd "$REVIEW_DIR" && coco -p -y "${DISALLOW_FLAGS[@]}" -c "model.name=$model" "$prompt" 2>&1)"
    status=$?
    if [ $status -eq 0 ] && [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
      printf '%s\n' "$out"
      echo ">>> model_used=$model${label:+ [$label]}" >&2
      return 0
    fi
    echo ">>> model=$model failed (exit=$status). Falling back." >&2
    [ -n "$out" ] && printf '%s\n' "$out" >&2
  done
  return 1
}

# Read-only hard constraint appended to EVERY prompt (findbugs / inspect / arch).
GUARD_RO=$'\n\n[硬约束] 这是一次只读评审：绝对禁止修改、创建或删除任何文件，禁止用 Bash 写入仓库文件，禁止进入任何修复阶段，不要询问是否修复，只输出评审/分析结论。'

# Shared review dimensions + output spec (used by findbugs + inspect; NO coco /findbugs skill).
REVIEW_DIMS=$'审查维度：\n- 正确性：逻辑错误、算法/状态机错误、错误的条件判断、off-by-one。\n- 并发：数据竞争、死锁、锁顺序、未保护的共享状态、原子性缺失。\n- 资源：未释放的句柄/锁/连接/goroutine、泄漏、重复关闭。\n- 错误处理：被吞掉的错误、未检查的返回值、错误的传播、panic/nil 解引用。\n- 边界：空值/越界/整数溢出/空集合/超大输入。\n- 安全：注入、路径穿越、权限校验缺失、敏感信息泄漏、不安全的反序列化。\n- API 误用与回归风险。'
OUTPUT_SPEC=$'输出要求：按严重度从高到低（P0 最严重 .. P3 最轻）逐条列出，每条包含【严重度 / 文件:行 / 类别 / 问题描述 / 触发或影响场景 / 修复建议】。定位到具体代码，不要泛泛而谈。若确无问题，明确输出“未发现问题”。'

rc=0
case "$MODE" in
  findbugs)
    # Custom diff-review prompt (NOT coco's /findbugs skill). Parse native-style args ourselves.
    DEPTH="deep"; WITH_LINT=1; MR_URL=""; DIFF_TARGET=""
    if [ ${#FINDBUGS_ARGS[@]} -gt 0 ]; then
      i=0
      while [ $i -lt ${#FINDBUGS_ARGS[@]} ]; do
        a="${FINDBUGS_ARGS[$i]}"
        case "$a" in
          fast|deep)                                   DEPTH="$a" ;;
          --with-lint=false|--with-lint=0|--no-lint)   WITH_LINT=0 ;;
          --with-lint|--with-lint=true|--with-lint=1)  WITH_LINT=1 ;;
          --mr)    i=$((i+1)); MR_URL="${FINDBUGS_ARGS[$i]:-}" ;;
          --mr=*)  MR_URL="${a#--mr=}" ;;
          *)       DIFF_TARGET="$a" ;;
        esac
        i=$((i+1))
      done
    fi

    if [ -n "$MR_URL" ]; then
      # 只读拉取：禁止 git fetch（会写入与真实仓库共享的 .git 对象库，破坏只读保证）。
      SRC=$'获取改动：请用【只读】方式拉取以下 MR/PR 的 diff 后评审——优先 `gh pr diff <url>`、`glab mr diff`，或 `curl` 拉取其 .diff/.patch URL。\n严禁使用 `git fetch`/`git pull`（本仓库与真实仓库共享 .git 对象库，fetch 会写入真实仓库）。\nMR/PR：'"$MR_URL"
    elif [ -n "$DIFF_TARGET" ]; then
      SRC=$'获取改动：在仓库根目录运行 `git diff '"$DIFF_TARGET"$'` 取得本次要评审的 diff。若 diff 为空，请直接说明“无改动可评审”。'
    else
      # 默认评工作区改动：先 `git add -A -N`（仅作用于这个一次性隔离 worktree，安全），
      # 这样新增但未跟踪的文件也会出现在 `git diff HEAD` 里，不被漏审。
      SRC=$'获取改动：在仓库根目录先运行 `git add -A -N`（让新增未跟踪文件也纳入），再运行 `git diff HEAD` 取得本次要评审的 diff（含已修改文件与新增文件）。若 diff 为空，请直接说明“无改动可评审”。'
    fi
    case "$DEPTH" in
      fast) DNOTE=$'评审力度：fast —— 快速过一遍，只报高置信度、明显的问题。' ;;
      *)    DNOTE=$'评审力度：deep —— 深入推理，包含跨函数/跨文件的数据流与并发分析。' ;;
    esac
    if [ "$WITH_LINT" -eq 1 ]; then LNOTE=$'可附带次要的代码规范/lint 级问题（标注为 P3）。'; else LNOTE=$'忽略纯风格/lint 问题，只报真正的 bug。'; fi

    FINDBUGS_PROMPT=$'你是一名严格的资深代码评审专家。请对【本次代码改动】做 bug 评审。\n\n'"$SRC"$'\n\n只聚焦【变更的行】及其直接影响，不要泛泛评审未改动的旧代码。\n'"$DNOTE"$'\n'"$LNOTE"$'\n\n'"$REVIEW_DIMS"$'\n\n'"$OUTPUT_SPEC"
    run_coco "${FINDBUGS_PROMPT}${GUARD_RO}" || rc=1
    ;;

  inspect)
    [ ${#INSPECT_FILES[@]} -gt 0 ] || { echo "ERROR: 'inspect' needs at least one file path." >&2; exit 2; }
    echo ">>> inspect mode: ${#INSPECT_FILES[@]} file(s), --mode=$INSPECT_MODE" >&2
    case "$INSPECT_MODE" in
      fast) IDNOTE=$'评审力度：fast —— 只报高置信度、明显的问题。' ;;
      *)    IDNOTE=$'评审力度：deep —— 深入逐行推理，含数据流与并发分析。' ;;
    esac
    for file in "${INSPECT_FILES[@]}"; do
      echo
      echo "==================================================================="
      echo "### coco inspect — $file  (mode=$INSPECT_MODE)"
      echo "==================================================================="
      # Custom full-file review prompt (NOT coco's /findbugs skill).
      INSPECT_PROMPT=$'你是一名严格的资深代码评审专家。请对文件【'"$file"$'】做全量逐行评审（把它当作全新代码全量审，不依赖 diff）。\n\n请先读取该文件完整内容，再逐段审查。\n'"$IDNOTE"$'\n\n'"$REVIEW_DIMS"$'\n\n'"$OUTPUT_SPEC"
      run_coco "${INSPECT_PROMPT}${GUARD_RO}" "$file" || rc=1
    done
    ;;

  arch)
    ctx=""
    if [ -n "$ARCH_CONTEXT" ]; then
      if [ -f "$ARCH_CONTEXT" ]; then
        ctx=$'\n\n## 已有上下文 / 前期发现（请验证、补充、并据此推理，不要照抄）\n\n'"$(cat "$ARCH_CONTEXT")"
        echo ">>> arch: injected context from $ARCH_CONTEXT" >&2
      else
        echo ">>> WARNING: --context file not found: $ARCH_CONTEXT" >&2
      fi
    fi
    focus=""
    [ -n "$ARCH_FOCUS" ] && focus=$'\n\n## 本次重点\n'"$ARCH_FOCUS"
    ARCH_PROMPT=$'你是一名分布式存储/系统架构评审专家。这是一次只读架构审计，核心目标是发现数据损坏（data corruption）风险。\n\n请阅读本仓库相关源码，围绕以下维度审计，并在可能处对照业界系统（WAS / Bigtable / Spanner / Kafka / Raft·Paxos 类共识实现）的常见做法，指出差距：\n1. 崩溃一致性：写入顺序、fsync/fdatasync 时机、WAL/journal 与数据落盘先后、断电/进程崩溃下的可恢复性、torn write。\n2. 提交协议：commit 的原子性边界、多副本/多分片提交的原子性与幂等性、部分提交的可见性。\n3. 锁与 fencing：owner/lease 失效后的写保护、脑裂（split-brain）下的双写、fencing token 是否贯穿到存储层。\n4. CoW / GC / recovery 竞态：copy-on-write 与垃圾回收、快照、恢复流程之间的并发窗口与悬垂引用。\n5. 错误处理：被吞掉的写错误、被忽略的 fsync/IO error、重试导致的重复写或乱序写。\n\n输出要求：按风险点列出【严重度 P0..P3 / 位置(文件:行) / 损坏触发场景 / 与对照系统的差距 / 建议】。只分析，不修改任何文件。'
    run_coco "${ARCH_PROMPT}${focus}${ctx}${GUARD_RO}" "arch" || rc=1
    ;;
esac

if [ $rc -eq 0 ]; then
  echo ">>> done; your real repo at $REPO was never modified" >&2
else
  echo "ERROR: one or more coco runs failed (models tried: ${MODELS[*]})." >&2
fi
exit $rc
