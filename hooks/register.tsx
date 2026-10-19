import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, Timer } from 'claude-code'
import type { CommanderPanel, CommanderTask } from '../types'

const PANE = 'commander-tasks'
// The host tracks render subscriptions to this atom on both surfaces.
const panel = atom({ plugin: 'commander', key: 'panel' } as const, {
  tasks: [], expanded: [], now: 0, message: '暂无任务',
} as CommanderPanel)

function isStatus(value: string): value is CommanderTask['status'] {
  return ['running', 'done', 'failed', 'timeout'].includes(value)
}

function duration(task: CommanderTask, now: number): string {
  if (!Number.isFinite(task.started) || task.started < 0) return '耗时未知'
  const end = task.status === 'running' ? now : task.ended
  if (end === undefined) return '总耗时未知'
  const seconds = Math.max(0, Math.floor((end - task.started) / 1000))
  return `${task.status === 'running' ? '已运行' : '总耗时'} ${seconds}s`
}

let timer: Timer | undefined
let root: string | undefined
let loading: Promise<void> | undefined
let generation = 0
const stop = () => { timer?.cancel(); timer = undefined }
const visible = async ($: EngineInterface) =>
  (await $.ui.panes()).some(p => p.id === PANE && p.isPlaced && p.isShown)

async function scan($: EngineInterface) {
  const epoch = generation
  if (root === undefined) {
    const git = await $.process.run(['git', 'rev-parse', '--show-toplevel'])
      .catch(() => undefined)
    root = git?.exitCode === 0 ? git.stdout.trim() : ''
  }
  const now = await $.clock.now()
  const previous = await read($, panel)
  let message = root ? '' : '当前目录不是 git 仓库'
  let tasks: CommanderTask[] = []
  if (root) {
    const folder = `${root}/.tasks`
    try {
      const entries = await $.fs.list(folder)
      const results = await Promise.all(entries.filter(e => e.kind === 'dir').map(async (entry): Promise<CommanderTask | undefined> => {
        const base = `${folder}/${entry.name}`
        try {
          const [rawStatus, rawMeta] = await Promise.all([
            $.fs.read(`${base}/status`), $.fs.read(`${base}/meta.json`),
          ])
          const status = rawStatus.trim()
          if (!isStatus(status)) return undefined
          const meta: unknown = JSON.parse(rawMeta)
          if (!meta || typeof meta !== 'object') return undefined
          const fields = meta as Record<string, unknown>
          const [stat, summary] = await Promise.all([
            status === 'running' ? undefined : $.fs.stat(`${base}/status`).catch(() => undefined),
            $.fs.read(`${base}/summary.md`).catch(() => ''),
          ])
          const started = typeof fields.started === 'string' ? Date.parse(fields.started) : NaN
          return {
            id: entry.name,
            worker: typeof fields.worker === 'string' ? fields.worker : '未知 worker',
            model: typeof fields.model === 'string' ? fields.model : undefined,
            status,
            started: Number.isFinite(started) ? started : -1,
            ended: stat?.mtimeMs,
            summary: summary.split(/\r?\n/).slice(0, 30).join('\n'),
          } satisfies CommanderTask
        } catch { return undefined } // A task may still be being created.
      }))
      tasks = results.filter((task): task is CommanderTask => task !== undefined)
      tasks.sort((a, b) => Number(b.status === 'running') - Number(a.status === 'running') ||
        (Number.isFinite(b.started) ? b.started : 0) - (Number.isFinite(a.started) ? a.started : 0) ||
        a.id.localeCompare(b.id))
    } catch {
      message = await $.fs.exists(folder).catch(() => true) ? '无法读取任务目录' : '暂无任务'
    }
  }
  if (epoch !== generation) return
  const count = tasks.filter(t => t.status === 'running').length
  $.ui.status(count ? `commander: ${count} 运行中` : undefined)
  for (const task of tasks) {
    if (task.status !== 'running' && previous.tasks.some(t =>
      t.id === task.id && t.started === task.started && t.status === 'running')) {
      $.ui.toast(`${task.id}: ${task.status}`)
    }
  }
  await update($, panel, current => ({
    ...current, tasks, now, message: message || (tasks.length ? '' : '暂无任务'),
  }))
}

function refresh($: EngineInterface) {
  if (!loading) loading = scan($).finally(() => { loading = undefined })
  return loading
}

// There is no pane-visibility event: render/attach restart the timer;
// each tick checks the host's pane record before touching task files.
async function sync($: EngineInterface, immediate = true) {
  if (!await visible($)) { stop(); return }
  if (timer) return
  timer = $.clock.every(3000, async () => {
    if (!await visible($)) { stop(); return }
    await refresh($)
  })
  // Drawing is pure; a render may arrange the next tick but cannot write state.
  if (immediate) await refresh($)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({ name: PANE, description: '打开指挥官任务面板' })
    return next(e)
  })
  on('command.run', { command: PANE }, async $ => {
    root = undefined
    const opened = await $.ui.open({ id: PANE, title: 'Commander 任务' })
    if (opened.isPlaced) {
      await sync($, false)
      await refresh($)
    } else stop()
    return { text: opened.isPlaced ? 'Commander 任务面板已打开' : 'Commander 任务面板等待可用显示区域' }
  })
  on('ui.close', { id: PANE }, async ($, e, next) => {
    const result = await next(e)
    if (!(await $.ui.panes()).some(p => p.id === PANE)) { generation++; stop() }
    return result
  })
  on('session.end', ($, e, next) => { generation++; stop(); return next(e) })
  on('session.detach', async ($, e, next) => { const result = await next(e); await sync($); return result })
  on('session.attach', async ($, e, next) => { const result = await next(e); await sync($); return result })

  on('ui.render', { component: 'Pane' }, async ($, e, next) => {
    await sync($, false)
    if (e.requestId !== PANE) return next(e)
    const { Box, Text, Button } = $.ui.resolve(e)
    const data = await read($, panel)
    return (
      <Box flexDirection="column">
        {data.message && <Text>{data.message}</Text>}
        {data.tasks.map(task => (
          <Box key={task.id} flexDirection="column">
            <Button key={`task:${task.id}`}
              label={`${task.id} · ${task.worker}${task.model ? ` · ${task.model}` : ''} · ${task.status} · ${duration(task, data.now)}`}
              onPress={() => update($, panel, current => ({ ...current,
                expanded: current.expanded.includes(task.id)
                  ? current.expanded.filter(id => id !== task.id) : [...current.expanded, task.id],
              }))} />
            {data.expanded.includes(task.id) && <Text>{task.summary || '暂无摘要'}</Text>}
          </Box>
        ))}
      </Box>
    )
  })
}
