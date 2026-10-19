#!/usr/bin/env bash
# 管理并行任务用的 git worktree
# 用法:
#   worktree.sh create <task_id>   → 创建 ../wt-<task_id> 并输出路径
#   worktree.sh path   <task_id>   → 输出已有 worktree 的路径（返工复用）
#   worktree.sh merge  <task_id>   → 把分支 task/<task_id> 合并到当前分支
#   worktree.sh remove <task_id>   → 删除 worktree 和对应分支
set -euo pipefail
CMD=${1:?create|path|merge|remove}; ID=${2:?task_id}
ROOT=$(git rev-parse --show-toplevel)
WT="$(dirname "$ROOT")/wt-$ID"; BR="task/$ID"

case "$CMD" in
  create)
    if [[ ! -d "$WT" ]]; then
      git -C "$ROOT" worktree add -q "$WT" -b "$BR" >&2
    fi
    echo "$WT" ;;
  path)
    # 返工时复用已有 worktree，不存在则报错
    [[ -d "$WT" ]] || { echo "worktree 不存在: $WT" >&2; exit 1; }
    echo "$WT" ;;
  merge)
    # 工人经常改完不提交，这里先帮它提交
    git -C "$WT" add -A
    git -C "$WT" diff --cached --quiet || git -C "$WT" commit -qm "task $ID"
    git -C "$ROOT" merge --no-ff -m "merge task $ID" "$BR" ;;
  remove)
    git -C "$ROOT" worktree remove --force "$WT"
    git -C "$ROOT" branch -D "$BR"
    # dispatch.sh 为每个任务在 TMPDIR 建的 uv 虚拟环境，随 worktree 一起清理
    rm -rf "${TMPDIR:-/tmp}/venv-$ID" ;;
  *) echo "未知命令: $CMD" >&2; exit 2 ;;
esac
