#!/usr/bin/env bash
# coco-review.sh — drive the local `coco` CLI as a REVIEW-ONLY code reviewer.
# Model fallback: GPT-5.5 => GLM-5.1.
#
# Three modes (all share: disposable git-worktree isolation + model fallback + auto-cleanup):
#   1) (default)  /findbugs DIFF review of working changes / MR / commit range
#   2) inspect    full-file review of EXISTING code (no diff needed), loops over many files
#   3) arch       direct-coco ARCHITECTURE / data-corruption audit (not /findbugs),
#                 cross-component reasoning, optionally fed prior findings via --context
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

GUARD_FB=$'\n\n[硬约束] 你只做代码评审，绝对禁止修改、创建或删除任何文件，禁止用 Bash 写入仓库文件，禁止进入/执行任何修复阶段（findbugs 阶段 5）。只输出评审结论，不要询问是否修复，不要尝试修复。'
GUARD_RO=$'\n\n[硬约束] 这是一次只读审计：绝对禁止修改、创建或删除任何文件，禁止用 Bash 写入仓库文件，只输出分析结论。'

rc=0
case "$MODE" in
  findbugs)
    if [ ${#FINDBUGS_ARGS[@]} -gt 0 ]; then p="/findbugs ${FINDBUGS_ARGS[*]}${GUARD_FB}"; else p="/findbugs${GUARD_FB}"; fi
    run_coco "$p" || rc=1
    ;;

  inspect)
    [ ${#INSPECT_FILES[@]} -gt 0 ] || { echo "ERROR: 'inspect' needs at least one file path." >&2; exit 2; }
    echo ">>> inspect mode: ${#INSPECT_FILES[@]} file(s), --mode=$INSPECT_MODE" >&2
    for file in "${INSPECT_FILES[@]}"; do
      echo
      echo "==================================================================="
      echo "### coco /findbugs inspect — $file  (mode=$INSPECT_MODE)"
      echo "==================================================================="
      run_coco "/findbugs inspect --path ${file} --mode ${INSPECT_MODE}${GUARD_FB}" "$file" || rc=1
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
