#!/usr/bin/env bash
# 向工人派发任务的统一接口
# 用法: dispatch.sh <worker> <task_id> "<任务描述>" [--worktree | --reuse <原 task_id>]
#   worker: codex | deepseek | local | mock
#   --worktree: 在 ../wt-<task_id> 创建独立的 git worktree 供工人工作
#   --reuse:    返工时在原任务的 ../wt-<原 task_id> 里继续工作（保留上次的改动），
#               之后用原 task_id 执行 worktree.sh merge / remove
# 网络: codex 沙箱默认不联网；DISPATCH_NETWORK=1 时本任务的沙箱允许联网（如需安装依赖）
# pnpm / uv 缓存放在 $TMPDIR（沙箱可写目录）
# 结果: .tasks/<task_id>/ 下的 status / output.md / summary.md / meta.json
set -uo pipefail

WORKER=${1:?请指定 worker}
TASK_ID=${2:?请指定 task_id}
PROMPT=${3:?请指定任务描述}
USE_WT=${4:-}
REUSE_ID=${5:-}

# 插件可安装在目标仓库之外，也可能通过符号链接调用。
SOURCE=${BASH_SOURCE[0]}
while [[ -L "$SOURCE" ]]; do
  BASE=$(cd -P "$(dirname "$SOURCE")" && pwd) || exit 1
  SOURCE=$(readlink "$SOURCE") || exit 1
  [[ "$SOURCE" == /* ]] || SOURCE="$BASE/$SOURCE"
done
SCRIPT_DIR=$(cd -P "$(dirname "$SOURCE")" && pwd) || exit 1

if ! command -v git >/dev/null 2>&1; then
  # 没有 git 时只沿父目录寻找仓库标记，以便记录依赖失败。
  ROOT=$(pwd -P)
  while [[ ! -e "$ROOT/.git" && "$ROOT" != / ]]; do ROOT=$(dirname "$ROOT"); done
  if [[ -e "$ROOT/.git" ]]; then
    mkdir -p "$ROOT/.tasks/$TASK_ID"
    echo failed > "$ROOT/.tasks/$TASK_ID/status"
    echo '缺少依赖: git。macOS 安装: brew install git' > "$ROOT/.tasks/$TASK_ID/summary.md"
  fi
  echo '缺少依赖: git。macOS 安装: brew install git' >&2
  exit 1
fi
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "错误: 当前目录不在 git 仓库中" >&2; exit 1;
}
DIR="$ROOT/.tasks/$TASK_ID"
TIMEOUT=${DISPATCH_TIMEOUT:-1800}   # 秒，默认 30 分钟
LOCAL_MODEL=${LOCAL_MODEL:-qwen2.5-coder:14b}
NETWORK=false
[[ "${DISPATCH_NETWORK:-0}" == 1 ]] && NETWORK=true
mkdir -p "$DIR"

fail_task() {
  echo failed > "$DIR/status"
  printf '%s\n' "$1" > "$DIR/summary.md"
  printf '%s\n' "$1" >&2
  exit 1
}

# 即使后续依赖检查失败，也不应把失败任务的数据加入 Git。
COMMON_DIR=$(git -C "$ROOT" rev-parse --git-common-dir) || fail_task '无法定位 git 排除文件'
[[ "$COMMON_DIR" == /* ]] || COMMON_DIR="$ROOT/$COMMON_DIR"
mkdir -p "$COMMON_DIR/info" || fail_task '无法创建 git info 目录'
EXCLUDE="$COMMON_DIR/info/exclude"
if ! grep -Fxq '.tasks/' "$EXCLUDE" 2>/dev/null; then
  # 前置换行兼容原文件最后一行没有换行的情况。
  printf '\n.tasks/\n' >> "$EXCLUDE" || fail_task '无法更新 git 排除文件'
fi

DEPENDENCIES=(git jq)
case "$WORKER" in
  codex) DEPENDENCIES+=(codex) ;;
  local) DEPENDENCIES+=(ollama) ;;
  deepseek) DEPENDENCIES+=(curl) ;;
  mock) ;;
  *) fail_task "未知的 worker: $WORKER" ;;
esac
MISSING=""
INSTALL=""
for DEP in "${DEPENDENCIES[@]}"; do
  if ! command -v "$DEP" >/dev/null 2>&1; then
    MISSING="$MISSING $DEP"
    if [[ "$DEP" == codex ]]; then
      INSTALL="${INSTALL}brew install --cask codex; "
    else
      INSTALL="${INSTALL}brew install $DEP; "
    fi
  fi
done
[[ -z "$MISSING" ]] || fail_task "缺少依赖:${MISSING}。macOS 安装: $INSTALL"

TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD=gtimeout
fi

WORKDIR="$ROOT"
if [[ "$USE_WT" == "--worktree" ]]; then
  WORKDIR=$("$SCRIPT_DIR/worktree.sh" create "$TASK_ID") || {
    echo "failed" > "$DIR/status"; echo "创建 worktree 失败" > "$DIR/summary.md"; exit 1; }
elif [[ "$USE_WT" == "--reuse" ]]; then
  [[ -n "$REUSE_ID" ]] || { echo "--reuse 需要指定原 task_id" >&2; exit 2; }
  WORKDIR=$("$SCRIPT_DIR/worktree.sh" path "$REUSE_ID") || {
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
WORKER_VERSION=""
case "$WORKER" in
  codex) WORKER_VERSION=$(codex --version 2>&1) ;;
  local) WORKER_VERSION=$(ollama --version 2>&1) ;;
  deepseek) WORKER_VERSION=$(curl --version 2>&1) ;;
  mock) WORKER_VERSION=mock ;;
esac
jq -n --arg v "$WORKER_VERSION" --arg w "$WORKER" --arg d "$WORKDIR" --arg t "$(date -Iseconds)" --arg r "$REUSE_ID" --argjson n "$NETWORK" \
  '{worker:$w, workdir:$d, started:$t, worker_version:$v, network:$n} + (if $r != "" then {reuse_of:$r} else {} end)' > "$DIR/meta.json"

run_worker() {
  case "$WORKER" in
    codex)
      (cd "$WORKDIR" && codex exec --sandbox workspace-write \
        -c "sandbox_workspace_write.network_access=$NETWORK" "$PROMPT" < /dev/null) ;;
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

export WORKER WORKDIR PROMPT LOCAL_MODEL NETWORK
export -f run_worker
if [[ -n "$TIMEOUT_CMD" ]]; then
  "$TIMEOUT_CMD" "$TIMEOUT" bash -c run_worker > "$DIR/output.md" 2>&1
else
  bash -c run_worker > "$DIR/output.md" 2>&1
fi
CODE=$?
MODEL=""
if [[ "$WORKER" == codex ]]; then
  MODEL=$(sed -n 's/^[[:space:]]*model:[[:space:]]*//p' "$DIR/output.md" | head -n 1)
  MODEL=${MODEL%$'\r'}
fi

# 生成摘要：让 Opus 不必阅读冗长的完整输出
{
  echo "# $TASK_ID ($WORKER${MODEL:+ / $MODEL}) exit=$CODE"
  [[ "$NETWORK" == true ]] && echo "本任务沙箱允许联网（DISPATCH_NETWORK=1）。"
  if [[ -z "$TIMEOUT_CMD" ]]; then
    echo "未找到 timeout 或 gtimeout，本次不限时运行。macOS 可用 brew install coreutils 安装 gtimeout。"
  fi
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
jq --arg t "$(date -Iseconds)" --argjson c "$CODE" --arg m "$MODEL" \
  '. + {finished:$t, exit:$c} + (if .worker == "codex" then {model:$m} else {} end)' \
  "$DIR/meta.json" > "$DIR/meta.tmp" && mv "$DIR/meta.tmp" "$DIR/meta.json"
exit $CODE
