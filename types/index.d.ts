export type CommanderTask = {
  id: string
  worker: string
  model?: string
  status: 'running' | 'done' | 'failed' | 'timeout'
  started: number
  ended?: number
  summary: string
}

export type CommanderPanel = {
  tasks: CommanderTask[]
  expanded: string[]
  now: number
  message: string
}

declare module 'claude-code' {
  interface PluginState {
    commander: { panel: CommanderPanel }
  }
}
