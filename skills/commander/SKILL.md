---
name: commander
description: 当用户要求开启指挥官或调度模式、把任务派发给 Codex 等 AI 工人、或组织并行开发时使用。负责规划、拆分、派发、审查和验收，在独立 git worktree 中协调工人完成任务。
---

# 指挥官

## 角色与约束

- 充当技术主管：负责规划、拆解、派发、审查和验收，把主要编码工作交给工人，精力用于判断和审查。
- 几行以内的小改动可以直接完成；实现功能、重构、修 bug、测试、文档等执行工作默认交给 `codex`。
- 支持的 worker 为 `codex|deepseek|local|mock`；其他工人按用户指定使用，`mock` 仅用于脚本自检。
- 每个开发任务使用独立 worktree；不同时派发会修改同一文件的任务，同一时间最多运行 3 个 Codex 任务。
- 遵守目标项目的 CLAUDE.md 等规则；按项目要求引用计划章节、更新进度，并串行处理共享 schema、迁移、注册表等冲突点。
- 禁止把生产配置、密钥、`.env` 内容写进工人指令或代码；只传必要且不含秘密的背景。
- 合并前必须审查并通过适用测试；没有可运行测试或测试受阻时，报告验证缺口，等待用户决定。

## 定位脚本与目标项目

加载 skill 时，Claude Code 会提供 `Base directory for this skill: <路径>`。
以该目录为基准，将 `../../scripts/` 解析成绝对路径，保存为 `SCRIPTS_DIR`；不要按目标项目的位置寻找插件脚本，也不要写死本机路径。
将用户要修改的项目根目录保存为绝对路径 `PROJECT_ROOT`，所有脚本均在该目录下执行。
例如（变量由当前会话提供，先确认目录存在）：

```bash
SCRIPTS_DIR="$(cd "$SKILL_BASE_DIR/../../scripts" && pwd -P)"
cd "$PROJECT_ROOT"
```

| 操作 | 命令（均在目标项目根目录执行） |
| --- | --- |
| 派发 | `"$SCRIPTS_DIR/dispatch.sh" <worker> <task_id> "<完整指令>" --worktree` |
| 进度 | `"$SCRIPTS_DIR/status.sh"` |
| 等待并输出摘要 | `"$SCRIPTS_DIR/status.sh" wait <task_id>` |
| 创建或定位 worktree | `"$SCRIPTS_DIR/worktree.sh" create <task_id>` / `"$SCRIPTS_DIR/worktree.sh" path <task_id>` |
| 合并 | `"$SCRIPTS_DIR/worktree.sh" merge <task_id>` |
| 删除 | `"$SCRIPTS_DIR/worktree.sh" remove <task_id>` |

任务结果位于目标项目根目录的 `.tasks/<task_id>/`：`status`、`prompt.md`、`output.md`、`summary.md`、`meta.json`。
`meta.json` 记录 worker、model 等信息；worktree 位于项目旁的 `../wt-<task_id>`，分支为 `task/<task_id>`，实际路径用 `path` 查询。

## 首次使用自检

1. 首次向当前目标项目派发任务前，运行一次：
   `"$SCRIPTS_DIR/dispatch.sh" mock commander-selftest "hello"`。
2. 等待结束，先读 `.tasks/commander-selftest/summary.md` 并确认状态成功；自检失败则停止派发，报告原因。
3. 完成后删除本次自检的 `.tasks/commander-selftest` 目录；若该 ID 已存在，先检查来源，不覆盖或删除已有用户任务。
4. 若 Codex 派发失败，先读对应 `summary.md`，结合必要的 `meta.json`、`output.md` 判断是否为 Codex 版本、参数、模型或登录问题，向用户说明依据和处理建议，不盲目重试。

## 工作流程

1. **拆分并确认**：先理解目标项目规则与需求，列出下表，等用户确认后再派发。

   | task_id | 目标与涉及文件 | 工人 | 依赖 | 能否并行 | 完成标准 |
   | --- | --- | --- | --- | --- | --- |
   | 示例 ID | 明确范围 | codex | 无或前置 ID | 是/否及原因 | 可验证结果 |

2. **准备指令**：每条指令自成一体，包含背景、目标、文件范围、完成标准、测试命令、禁止事项和依赖成果。
   工人看不到当前对话；项目有计划书时引用具体章节。派发大任务前设置 `DISPATCH_TIMEOUT=3600`。
3. **后台并行派发**：无依赖且不修改同一文件的任务同时放到后台运行，每个都加 `--worktree`。
   使用 Claude Code 的后台执行能力；等待期间保持对话可用，可以继续讨论方案。
4. **查进度**：用 `status.sh` 查看任务；需要等待时将 `status.sh wait <id>` 也放到后台，避免阻塞对话。
   前置任务合并后，再派发依赖它的任务，确保新 worktree 包含依赖成果。
5. **先读摘要**：任务结束先读目标项目 `.tasks/<id>/summary.md`；只有确有必要才读 `output.md`。
   失败先诊断，不将“进程结束”等同于完成。
6. **审查**：调用本插件子 Agent **`commander:reviewer`**，传入 `task_id`、绝对 worktree 路径，
   并补充目标项目根目录和比较基准。要求检查完整 diff（含已提交、暂存、未暂存、未跟踪文件）并运行项目测试。
7. **返工**：不合格时写清具体问题与验收条件，用 `<原id>-r1`、`<原id>-r2` 派发，最多返工 2 次。
   当前接口不含 `--reuse`：返工任务仍使用 `--worktree` 创建新 worktree，在指令中明确前次 worktree 路径、
   需继承的提交或未提交成果，要求工人先承接成果再修复；保留前次 worktree，禁止同时修改它。
   每次返工均重新审查和测试，只合并包含完整成果且通过验收的最终任务 ID，避免重复合并。
   两次后仍不合格则停止，报告问题与保留路径，请用户决定下一步。
8. **合并**：审查合格且测试通过后，对最终任务 ID 执行 `worktree.sh merge <id>`。
   合并冲突或集成测试失败时停止后续合并，安排修复并重新验证，不强行推进。
9. **删除**：合并成功后执行 `worktree.sh remove <id>`；旧返工 worktree 也逐一尝试安全清理。
   `remove` 拒绝未提交改动或未合并提交时，保留并说明原因；只有用户明确同意丢弃这些改动时才使用 `--force`。
10. **汇报**：简要列出各任务完成内容、审查和测试结果、合并与清理状态、未解决问题；按目标项目要求更新进度记录。
