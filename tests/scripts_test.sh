#!/usr/bin/env bash
# 独立于插件位置的回归测试；只运行 mock worker。
set -uo pipefail
SCRIPT_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd) || exit 1
for DEP in git jq; do
  command -v "$DEP" >/dev/null 2>&1 || { echo "FAIL: 缺少 $DEP"; exit 1; }
done
TEMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TEMP"' EXIT
PASS=0
FAIL=0
check() {
  local label=$1
  shift
  if "$@"; then
    printf 'PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s\n' "$label"
    FAIL=$((FAIL + 1))
  fi
}
reject() { if "$@"; then return 1; else return 0; fi; }
reject_logged() {
  local log=$1
  shift
  reject "$@" > "$log" 2>&1
}
status_is() { [[ $(cat "$1/status") == "$2" ]]; }
exclude_once() { [[ $(grep -Fxc '.tasks/' "$1") == 1 ]]; }
absent() { [[ ! -e "$1" ]]; }
branch_absent() { ! git show-ref --verify --quiet "refs/heads/$1"; }

# 复制出一个独立插件安装目录，再经过两层相对符号链接调用。
mkdir -p "$TEMP/plugin/scripts" "$TEMP/bin" "$TEMP/project/sub/dir" "$TEMP/outside"
cp "$SCRIPT_DIR/dispatch.sh" "$SCRIPT_DIR/status.sh" "$SCRIPT_DIR/worktree.sh" "$TEMP/plugin/scripts/"
ln -s ../plugin/scripts/dispatch.sh "$TEMP/bin/dispatch-link"
ln -s dispatch-link "$TEMP/bin/dispatch"
DISPATCH="$TEMP/bin/dispatch"
STATUS="$TEMP/plugin/scripts/status.sh"
WORKTREE="$TEMP/plugin/scripts/worktree.sh"
cd "$TEMP/project" || exit 1
git init -q || exit 1
git config user.name 'Scripts Test'
git config user.email 'scripts-test@example.invalid'
git config commit.gpgsign false
printf 'initial\n' > tracked.txt
git add tracked.txt
git commit -qm initial || exit 1
ROOT=$(git rev-parse --show-toplevel)
COMMON=$(git rev-parse --git-common-dir)
[[ "$COMMON" == /* ]] || COMMON="$ROOT/$COMMON"
EXCLUDE="$COMMON/info/exclude"
# 检验原排除文件没有结尾换行时也能安全追加。
printf 'existing-pattern' > "$EXCLUDE"
cd sub/dir || exit 1
check '从子目录通过插件符号链接派发' bash "$DISPATCH" mock root-task 'test root'
check '任务写到仓库根目录' status_is "$ROOT/.tasks/root-task" done
check '根目录定位正确' jq -e --arg root "$ROOT" '.workdir == $root and .worker == "mock" and has("started") and has("worker_version")' "$ROOT/.tasks/root-task/meta.json"
check '默认不联网' jq -e '.network == false' "$ROOT/.tasks/root-task/meta.json"
check '排除文件包含 .tasks/ 一次' exclude_once "$EXCLUDE"
check '再次派发' bash "$DISPATCH" mock second-task 'test exclude'
check '排除项不重复' exclude_once "$EXCLUDE"
check 'DISPATCH_NETWORK=1 时联网' env DISPATCH_NETWORK=1 bash "$DISPATCH" mock net-task 'test network'
check '联网写入元数据' jq -e '.network == true' "$ROOT/.tasks/net-task/meta.json"
check '.tasks 被 git 忽略' git check-ignore -q "$ROOT/.tasks/root-task/status"
check '没有修改 .gitignore' absent "$ROOT/.gitignore"
LIST=$(bash "$STATUS")
check 'status 列出任务' grep -q root-task <<< "$LIST"
check 'status wait 输出摘要' bash "$STATUS" wait root-task
check '--worktree 派发成功' bash "$DISPATCH" mock wt-task 'test worktree' --worktree
WT=$(bash "$WORKTREE" path wt-task)
check 'worktree 任务完成' status_is "$ROOT/.tasks/wt-task" done
check 'worktree 元数据目录正确' jq -e --arg wt "$WT" '.workdir == $wt' "$ROOT/.tasks/wt-task/meta.json"
printf 'untracked\n' > "$WT/new-file.txt"
printf 'changed\n' >> "$WT/tracked.txt"
check '未提交改动拒绝删除' reject_logged "$TEMP/remove.log" bash "$WORKTREE" remove wt-task
check '拒绝信息列出未跟踪文件' grep -q new-file.txt "$TEMP/remove.log"
check '拒绝信息列出已跟踪改动' grep -q tracked.txt "$TEMP/remove.log"
check '--force 删除成功' bash "$WORKTREE" remove wt-task --force
check 'worktree 目录已删除' absent "$WT"
check 'worktree 分支已删除' branch_absent task/wt-task

# 即使工作区干净，也要保护尚未合并的提交。
WT=$(bash "$WORKTREE" create committed-task) || exit 1
printf 'commit\n' > "$WT/committed.txt"
git -C "$WT" add committed.txt
git -C "$WT" commit -qm 'unmerged-test-commit' || exit 1
check '未合并提交拒绝删除' reject_logged "$TEMP/commit-remove.log" bash "$WORKTREE" remove committed-task
check '拒绝信息列出未合并提交' grep -q unmerged-test-commit "$TEMP/commit-remove.log"
check '强制删除未合并分支' bash "$WORKTREE" remove committed-task --force
WT=$(bash "$WORKTREE" create missing-task) || exit 1
rm -rf "$WT"
check 'worktree 已不存在时清理分支' bash "$WORKTREE" remove missing-task
check '缺失 worktree 的分支已清理' branch_absent task/missing-task
check '重复清理不报错' bash "$WORKTREE" remove missing-task

# 从 linked worktree 派发时，排除规则仍写在公共 git 目录。
WT=$(bash "$WORKTREE" create linked-task) || exit 1
cd "$WT" || exit 1
check '从 linked worktree 派发' bash "$DISPATCH" mock linked-root 'test common dir'
check '公共排除项仍只有一次' exclude_once "$EXCLUDE"
check 'linked worktree 任务被忽略' git check-ignore -q .tasks/linked-root/status
cd "$ROOT" || exit 1
check '清理 linked worktree' bash "$WORKTREE" remove linked-task --force

# 限制 PATH 来覆盖 timeout 回退和依赖缺失，不启动任何真实 worker。
TOOLS="$TEMP/tools"
mkdir -p "$TOOLS"
for DEP in bash dirname readlink git jq mkdir grep date sleep wc tail mv sed head; do
  ln -s "$(command -v "$DEP")" "$TOOLS/$DEP"
done
check '无 timeout 时 mock 仍完成' env PATH="$TOOLS" bash "$DISPATCH" mock no-timeout 'test fallback'
check 'summary 说明不限时' grep -q '不限时' "$ROOT/.tasks/no-timeout/summary.md"
cat > "$TOOLS/gtimeout" <<'TIMEOUT_STUB'
#!/usr/bin/env bash
printf '%s\n' "${0##*/}" > "$TIMEOUT_TRACE"
shift
exec "$@"
TIMEOUT_STUB
chmod +x "$TOOLS/gtimeout"
check '只有 gtimeout 时派发成功' env PATH="$TOOLS" TIMEOUT_TRACE="$TEMP/timeout-trace" bash "$DISPATCH" mock gtimeout-task 'test gtimeout'
check '使用了 gtimeout' grep -qx gtimeout "$TEMP/timeout-trace"
cp "$TOOLS/gtimeout" "$TOOLS/timeout"
check '同时存在 timeout 和 gtimeout 时派发成功' env PATH="$TOOLS" TIMEOUT_TRACE="$TEMP/timeout-trace" bash "$DISPATCH" mock timeout-task 'test timeout'
check '优先使用 timeout' grep -qx timeout "$TEMP/timeout-trace"
rm "$TOOLS/jq"
check '缺少 jq 时派发失败' reject env PATH="$TOOLS" bash "$DISPATCH" mock missing-jq 'must fail'
check '缺少 jq 时写 failed' status_is "$ROOT/.tasks/missing-jq" failed
check '缺少 jq 时说明安装方法' grep -q 'brew install.*jq' "$ROOT/.tasks/missing-jq/summary.md"
rm "$TOOLS/git"
check '缺少 git 时派发失败' reject env PATH="$TOOLS" bash "$DISPATCH" mock missing-git 'must fail'
check '缺少 git 时写 failed' status_is "$ROOT/.tasks/missing-git" failed
check '缺少 git 时说明安装方法' grep -q 'brew install git' "$ROOT/.tasks/missing-git/summary.md"

cd "$TEMP/outside" || exit 1
check '非 git 目录 dispatch 报错' reject bash "$DISPATCH" mock outside 'must fail'
check '非 git 目录 status 报错' reject bash "$STATUS"
check '非 git 目录 worktree 报错' reject bash "$WORKTREE" create outside
check '非 git 目录不生成任务' absent "$TEMP/outside/.tasks"
printf '\nPASS: %d  FAIL: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
