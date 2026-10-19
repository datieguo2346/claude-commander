#!/usr/bin/env bash
# 向工人派发任务的统一接口
# 用法: dispatch.sh <worker> <task_id> "<任务描述>" [--worktree | --reuse <原 task_id>]
#   worker: codex | deepseek | local | mock
#   --worktree: 在 ../wt-<task_id> 创建独立的 git worktree 供工人工作
#   --reuse:    返工时在原任务的 ../wt-<原 task_id> 里继续工作（保留上次的改动），
#               之后用原 task_id 执行 worktree.sh merge / remove
# codex 在沙箱内可访问网络；pnpm / uv 缓存放在 $TMPDIR（沙箱可写目录）
# 结果: .tasks/<task_id>/ 下的 status / output.md / summary.md / meta.json
set -uo pipefail

WORKER=${1:?请指定 worker}
TASK_ID=${2:?请指定 task_id}
PROMPT=${3:?请指定任务描述}
USE_WT=${4:-}
REUSE_ID=${5:-}

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
DIR="$ROOT/.tasks/$TASK_ID"
TIMEOUT=${DISPATCH_TIMEOUT:-1800}   # 秒，默认 30 分钟
LOCAL_MODEL=${LOCAL_MODEL:-qwen2.5-coder:14b}
mkdir -p "$DIR"

WORKDIR="$ROOT"
if [[ "$USE_WT" == "--worktree" ]]; then
  WORKDIR=$("$ROOT/scripts/worktree.sh" create "$TASK_ID") || {
    echo "failed" > "$DIR/status"; echo "创建 worktree 失败" > "$DIR/summary.md"; exit 1; }
elif [[ "$USE_WT" == "--reuse" ]]; then
  [[ -n "$REUSE_ID" ]] || { echo "--reuse 需要指定原 task_id" >&2; exit 2; }
  WORKDIR=$("$ROOT/scripts/worktree.sh" path "$REUSE_ID") || {
    echo "failed" > "$DIR/status"; echo "找不到原任务 $REUSE_ID 的 worktree" > "$DIR/summary.md"; exit 1; }
fi

# 依赖缓存放到沙箱可写的临时目录
CACHE_ROOT=${TMPDIR:-/tmp}
export npm_config_store_dir="$CACHE_ROOT/pnpm-store"
export UV_CACHE_DIR="$CACHE_ROOT/uv-cache"
# 仓库在 exFAT 盘上，uv 在盘内建虚拟环境会因 ._* 附属文件而损坏，放到临时目录
export UV_PROJECT_ENVIRONMENT="$CACHE_ROOT/venv-${REUSE_ID:-$TASK_ID}"

printf '%s\n' "$PROMPT" > "$DIR/prompt.md"
echo "running" > "$DIR/status"
jq -n --arg w "$WORKER" --arg d "$WORKDIR" --arg t "$(date -Iseconds)" --arg r "$REUSE_ID" \
  '{worker:$w, workdir:$d, started:$t} + (if $r != "" then {reuse_of:$r} else {} end)' > "$DIR/meta.json"

run_worker() {
  case "$WORKER" in
    codex)
      (cd "$WORKDIR" && codex exec --sandbox workspace-write \
        -c sandbox_workspace_write.network_access=true "$PROMPT" < /dev/null) ;;
    deepseek)
      : "${DEEPSEEK_API_KEY:?未设置 DEEPSEEK_API_KEY}"
      curl -sS --fail https://api.deepseek.com/chat/completions \
        -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg p "$PROMPT" \
          '{model:"deepseek-chat", messages:[{role:"user", content:$p}]}')" \
        | jq -r '.choices[0].message.content' ;;
    local)
      ollama run "$LOCAL_MODEL" "$PROMPT" ;;
    mock)   # 用于测试脚本是否跑通
      sleep 2; echo "mock 完成: $PROMPT" ;;
    *)
      echo "未知的 worker: $WORKER"; return 2 ;;
  esac
}

export WORKER WORKDIR PROMPT LOCAL_MODEL
export -f run_worker
timeout "$TIMEOUT" bash -c run_worker > "$DIR/output.md" 2>&1
CODE=$?

# 生成摘要：让 Opus 不必阅读冗长的完整输出
{
  echo "# $TASK_ID ($WORKER) exit=$CODE"
  if [[ "$WORKDIR" != "$ROOT" ]]; then
    echo "## 变更文件"; (cd "$WORKDIR" && git status --short && git diff --stat) 2>/dev/null
  fi
  echo "## 输出末尾（完整内容见 output.md，共 $(wc -l < "$DIR/output.md") 行）"
  tail -n 40 "$DIR/output.md"
} > "$DIR/summary.md"

case $CODE in
  0)   echo "done"    > "$DIR/status" ;;
  124) echo "timeout" > "$DIR/status" ;;
  *)   echo "failed"  > "$DIR/status" ;;
esac
jq --arg t "$(date -Iseconds)" --argjson c "$CODE" '. + {finished:$t, exit:$c}' \
  "$DIR/meta.json" > "$DIR/meta.tmp" && mv "$DIR/meta.tmp" "$DIR/meta.json"
exit $CODE
