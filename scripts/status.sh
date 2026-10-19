#!/usr/bin/env bash
# 列出所有任务状态（供 Opus 查看进度）
# 用法: status.sh            → 列表
#       status.sh wait <id>  → 等待指定任务完成后输出摘要（相当于回调）
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
T="$ROOT/.tasks"

if [[ "${1:-}" == "wait" ]]; then
  ID=${2:?task_id}
  while [[ "$(cat "$T/$ID/status" 2>/dev/null)" == "running" ]]; do sleep 5; done
  cat "$T/$ID/summary.md"; exit 0
fi

[[ -d "$T" ]] || { echo "暂无任务"; exit 0; }
printf '%-20s %-10s %-9s %s\n' TASK WORKER STATUS STARTED
for d in "$T"/*/; do
  id=$(basename "$d")
  printf '%-20s %-10s %-9s %s\n' "$id" \
    "$(jq -r .worker "$d/meta.json" 2>/dev/null)" \
    "$(cat "$d/status" 2>/dev/null)" \
    "$(jq -r .started "$d/meta.json" 2>/dev/null)"
done
