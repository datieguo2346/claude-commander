# claude-commander

Claude Code 插件：让 Claude Code 当技术主管（规划、拆解、派发、审查），Codex 等 AI 当工人（在独立 git worktree 里写代码）。

## 包含什么

| 组件 | 说明 |
| --- | --- |
| skill `commander` | 指挥官工作流：拆分→确认→并行派发→读 summary→审查→返工→合并→清理 |
| agent `commander:reviewer` | 只读审查工人的改动并运行测试 |
| `scripts/dispatch.sh` | 派发任务：`dispatch.sh <codex\|deepseek\|local\|mock> <task_id> "<指令>" [--worktree \| --reuse <原id>]` |
| `scripts/status.sh` | 查看任务；`status.sh wait <id>` 等待完成 |
| `scripts/worktree.sh` | `create\|path\|merge\|remove <id> [--force]`，remove 默认拒绝丢弃未提交/未合并的改动 |
| 命令 `/commander-tasks` | 打开只读任务面板（状态、耗时、模型、summary） |

任务数据写在目标项目根目录的 `.tasks/`（自动加入 `.git/info/exclude`，不会修改项目的 `.gitignore`），worktree 位于 `../wt-<task_id>`。

## 安装

在终端会话的提示符中：

```
/plugin install commander --marketplace datieguo2346/claude-commander
```

依次回答 `y`（添加 marketplace），再选择安装范围（推荐 user）。

从 shell：

```bash
claude plugin install commander --marketplace datieguo2346/claude-commander
```

在桌面 app 中（不支持 `/plugin`）：点提示框旁的 +，选 Plugins → Add marketplace，填 `datieguo2346/claude-commander`，再 Add plugin。

私有仓库只有能在 GitHub 上读取它、且本机已配置 github.com 的 git 凭据（SSH key，或 `gh auth login` 后 `gh auth setup-git`）的人才能安装。

## 每台设备的前置条件

- `git`、`jq`；macOS 上 `timeout` 来自 `brew install coreutils`（没有则不限时运行）
- 用 Codex 当工人：安装并登录 `codex` CLI，确认 `~/.codex/config.toml` 里的模型当前账号可用
- 首次使用时 skill 会先跑一次 mock 自检

## 安全默认

- Codex 在 `workspace-write` 沙箱中运行，**默认不联网**；需要安装依赖的任务在派发命令前加 `DISPATCH_NETWORK=1`
- 面板只读，不提供合并/删除按钮；合并必须经过审查和测试
- 不要把生产配置、密钥、`.env` 内容写进给工人的指令

## 开发

```bash
bash tests/scripts_test.sh     # 脚本测试
claude plugin validate .       # 校验插件
claude plugin test .           # 面板测试
```
