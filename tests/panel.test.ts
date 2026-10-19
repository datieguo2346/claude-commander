import { test, expect, mock } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On, RenderSurface } from 'claude-code'

const ID = 'commander-tasks'
const NOW = Date.parse('2026-10-19T00:01:00Z')

function fixture(on: On, surface: RenderSurface) {
  const clock = mock.clock(on, { now: NOW })
  let shown = true
  let opened = false
  let reads = 0
  let git = true
  let missing = false
  let status: string | undefined
  const toasts: string[] = []
  const files: Record<string, string> = {}
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('command.register', () => ({ value: { command: ID } }))
  on('process.run', ($, e) => {
    expect(e.argv).toEqual(['git', 'rev-parse', '--show-toplevel'])
    return { value: { exitCode: git ? 0 : 1, stdout: git ? '/target\n' : '', stderr: '',
      isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('ui.open', ($, e) => {
    expect(e.id).toBe(ID)
    expect(e.title).toBe('Commander 任务')
    opened = true
    return { value: shown ? { isPlaced: true } : { isPlaced: false, reason: 'hidden' } }
  })
  on('ui.panes', () => ({ value: opened ? [{ id: ID, title: 'Commander 任务', isPlaced: shown, isShown: shown, isFocused: true }] : [] }))
  on('ui.close', () => { opened = false; return { value: undefined } })
  on('ui.status', ($, e) => { status = e.text; return { value: undefined } })
  on('ui.toast', ($, e) => { toasts.push(e.text); return { value: undefined } })
  on('fs.list', ($, e) => {
    reads++
    expect(e.path).toBe('/target/.tasks')
    if (missing) return { deny: 'ENOENT' }
    return { value: [...new Set(Object.keys(files).map(p => p.split('/')[0]!))].map(name => ({
      name, kind: 'dir' as const, size: 0, mtimeMs: 0, isLink: false,
    })) }
  })
  on('fs.read', ($, e) => {
    const content = files[e.path.replace('/target/.tasks/', '')]
    if (content === undefined) return { value: '' }
    return { value: content }
  })
  on('fs.stat', () => ({ value: { kind: 'file', size: 4, mtimeMs: NOW, isLink: false } }))
  on('fs.exists', () => ({ value: false }))
  return { clock, files, toasts, get status() { return status }, get reads() { return reads },
    get opened() { return opened }, hide() { shown = false }, show() { shown = true },
    close() { opened = false }, noGit() { git = false }, missingTasks() { missing = true }, surface }
}

async function mount($: Engine, surface: 'terminal' | 'desktop') {
  return $.ui.mount({ plugin: 'commander', surface, component: 'Pane', requestId: ID,
    props: { title: 'Commander 任务', isFocused: true, bodyColumns: 100,
      placement: 'inline', scroll: { offset: 0, bodyRows: 20 }, view: {} } })
}

async function open($: Engine, surface: RenderSurface) {
  await $.session.start({ cwd: '/target/subdirectory', surface, isInteractive: true })
  await $.command.run({ command: ID, args: '', origin: { kind: 'composer' },
    presentation: { isFullscreen: false, columns: 100 } })
}

for (const surface of ['terminal', 'desktop'] as const) {
  test(`${surface}: command opens pane, session start does not`, async ($, on) => {
    const f = fixture(on, surface)
    await $.session.start({ cwd: '/target', surface, isInteractive: true })
    expect(f.opened).toBe(false)
    f.missingTasks()
    await open($, surface)
    expect(f.opened).toBe(true)
    const ui = await mount($, surface)
    expect(await ui.find({ type: 'Text', text: '暂无任务' })).toBeDefined()
    f.hide()
    await ui.unmount()
  })

  test(`${surface}: running first, status, summary, polling and completion`, async ($, on) => {
    const f = fixture(on, surface)
    const add = (id: string, status: string, started: string, model?: string) => {
      f.files[`${id}/status`] = status
      f.files[`${id}/meta.json`] = JSON.stringify({ worker: 'codex', model, started })
    }
    add('new-done', 'done', '2026-10-19T00:00:50Z')
    add('old-running', 'running', '2026-10-19T00:00:00Z', 'gpt-test')
    add('old-done', 'done', '2026-10-18T00:00:00Z')
    f.files['old-running/summary.md'] = Array.from({ length: 35 }, (_, n) => `line ${n + 1}`).join('\n')
    await open($, surface)
    const ui = await mount($, surface)
    expect((await ui.findAll({ type: 'Button' })).map(b => b.key)).toEqual([
      'task:old-running', 'task:new-done', 'task:old-done',
    ])
    expect(f.status).toBe('commander: 1 运行中')
    expect((await ui.find({ key: 'task:old-running' }))?.text).toContain('gpt-test · running · 已运行 60s')
    await ui.press({ key: 'task:old-running' })
    expect((await ui.find({ type: 'Text', text: 'line 1' }))?.text).toContain('line 30')
    expect((await ui.find({ type: 'Text', text: 'line 1' }))?.text).not.toContain('line 31')
    await ui.press({ key: 'task:old-running' })
    expect(await ui.find({ type: 'Text', text: 'line 1' })).toBeUndefined()
    await f.clock.advance(3000)
    expect((await ui.find({ key: 'task:old-running' }))?.text).toContain('已运行 63s')
    f.hide()
    const reads = f.reads
    await f.clock.advance(9000)
    expect(f.reads).toBe(reads)
    f.show()
    await ui.unmount()
    const resumed = await mount($, surface)
    f.files['old-running/status'] = 'failed'
    await f.clock.advance(3000)
    expect(f.status).toBeUndefined()
    expect(f.toasts).toEqual(['old-running: failed'])
    await f.clock.advance(6000)
    expect(f.toasts).toEqual(['old-running: failed'])
    expect((await resumed.find({ key: 'task:old-running' }))?.text).toContain('总耗时 60s')
    f.close()
    const closedReads = f.reads
    await f.clock.advance(9000)
    expect(f.reads).toBe(closedReads)
    await resumed.unmount()
  })

  for (const completed of ['done', 'timeout'] as const) {
    test(`${surface}: ${completed} notification is emitted once`, async ($, on) => {
      const f = fixture(on, surface)
      f.files['task/status'] = 'running'
      f.files['task/meta.json'] = JSON.stringify({ worker: 'codex', started: '2026-10-19T00:00:00Z' })
      await open($, surface)
      f.files['task/status'] = completed
      await f.clock.advance(6000)
      expect(f.toasts).toEqual([`task: ${completed}`])
      expect(f.status).toBeUndefined()
      f.hide()
    })
  }

  test(`${surface}: non git directory`, async ($, on) => {
    const f = fixture(on, surface)
    f.noGit()
    await open($, surface)
    const ui = await mount($, surface)
    expect(await ui.find({ text: '当前目录不是 git 仓库' })).toBeDefined()
    expect(f.reads).toBe(0)
    f.hide()
    await ui.unmount()
  })
}
