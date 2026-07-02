import { exec } from 'node:child_process'
import * as fs from 'node:fs'
import * as os from 'node:os'
import * as path from 'node:path'

const APP_BUNDLE_ID = 'com.local.opencodestatusbar'

function tryOpen(cmd: string, fallback?: () => void): void {
  exec(cmd, (err) => {
    if (err && fallback) fallback()
  })
}

function launchStatusBarApp(): void {
  // Launch the status bar app if it isn't already running. Pass --auto-launch
  // so the app knows it was started by the plugin and can self-quit when no
  // sessions remain. Manual launches from Finder stay alive indefinitely.
  tryOpen(
    `pgrep -x OpenCodeStatusBar >/dev/null 2>&1 || open -b "${APP_BUNDLE_ID}" --args --auto-launch`,
    () => {
      tryOpen(`open "/Applications/OpenCodeStatusBar.app" --args --auto-launch`)
    },
  )
}

function stateDir(): string {
  return path.join(
    process.env.XDG_STATE_HOME || path.join(os.homedir(), '.local', 'state'),
    'opencode',
    'statusbar',
    'state.d',
  )
}

function debugLogDir(): string {
  return path.dirname(stateDir())
}

const PID = process.pid

// Monotonic write counter included in every state file so the macOS app can
// detect changes even when multiple writes fall inside the same filesystem
// mtime second.
let writeSeq = 0

// After a tool finishes we keep the state file in "tool" for a short beat so the
// status bar (which polls every 0.4 s) is guaranteed to show the tool label even
// for sub-millisecond tools like "read".
const TOOL_END_HOLD_MS = 2000
const pendingToolEndTimers = new Map<string, NodeJS.Timeout>()

const TOOL_LABELS: Record<string, string> = {
  bash: 'Running command',
  edit: 'Editing',
  write: 'Writing',
  read: 'Reading',
  read_file: 'Reading',
  write_file: 'Writing',
  edit_file: 'Editing',
  list_directory: 'Listing files',
  search_files: 'Searching files',
  web_search: 'Searching web',
  git: 'Running git',
  mcp: 'Using MCP tool',
  glob: 'Matching files',
  search: 'Searching',
  find: 'Searching files',
  grep: 'Searching',
  todowrite: 'Updating todos',
}

type StatusState = 'thinking' | 'tool' | 'permission' | 'done' | 'idle'

interface SessionState {
  state: StatusState
  label: string
  tool: string | null
  project: string
  sessionId: string
  entrypoint: 'cli'
  term_program: string | null
  pid: number
  started: boolean
  startedAt: number
  ts: number
  seq?: number
}

interface OpenCodeEvent {
  type: string
  properties?: unknown
  context?: {
    directory?: string
  }
}

interface PluginContext {
  directory: string
}

interface PermissionInput {
  sessionID?: string
}

interface CommandInput {
  sessionID: string
  command: string
  arguments?: string
}

interface ToolInput {
  sessionID: string
  tool: string
  callID?: string
}

function projectName(directory: string): string {
  return path.basename(directory) || 'OpenCode'
}

function ensureStateDir(): void {
  fs.mkdirSync(stateDir(), { recursive: true })
}

function stateFilePath(sessionId: string): string {
  return path.join(stateDir(), `${sessionId}.json`)
}

function readState(sessionId: string): Partial<SessionState> | undefined {
  try {
    return JSON.parse(fs.readFileSync(stateFilePath(sessionId), 'utf8')) as Partial<SessionState>
  } catch {
    return undefined
  }
}

function removeState(sessionId: string): void {
  try {
    fs.unlinkSync(stateFilePath(sessionId))
  } catch {
    // already gone
  }
}

function nowSec(): number {
  return Math.floor(Date.now() / 1000)
}

function isWorking(state?: string): boolean {
  return state === 'thinking' || state === 'tool'
}

function debugLog(payload: Record<string, unknown>): void {
  try {
    const dir = debugLogDir()
    fs.mkdirSync(dir, { recursive: true })
    const line = JSON.stringify({ ts: new Date().toISOString(), ...payload }) + '\n'
    fs.appendFileSync(path.join(dir, 'debug.log'), line)
  } catch {
    // Debug logging must never break the plugin.
  }
}

function formatToolLabel(name: string): string {
  const spaced = name
    .replace(/([a-z])([A-Z])/g, '$1 $2')
    .replace(/[_-]+/g, ' ')
    .trim()
  if (!spaced) return 'Using tool'
  return spaced.replace(/\b\w/g, (c) => c.toUpperCase())
}

function clearToolEndTimer(sessionId: string): void {
  const t = pendingToolEndTimers.get(sessionId)
  if (t) {
    clearTimeout(t)
    pendingToolEndTimers.delete(sessionId)
  }
}

function scheduleToolEnd(sessionId: string, project: string): void {
  clearToolEndTimer(sessionId)
  pendingToolEndTimers.set(
    sessionId,
    setTimeout(() => {
      pendingToolEndTimers.delete(sessionId)
      const existing = readState(sessionId)
      // Only switch back to thinking if no newer state has overwritten the tool.
      if (existing?.state === 'tool') {
        writeState(sessionId, project, {
          state: 'thinking',
          label: 'Thinking…',
          tool: null,
          started: true,
        })
      }
    }, TOOL_END_HOLD_MS),
  )
}

function writeState(sessionId: string, project: string, updates: Partial<SessionState>): void {
  // Any explicit state update cancels a pending "return to thinking" timer,
  // because newer information (new tool, permission, idle) must win.
  clearToolEndTimer(sessionId)
  ensureStateDir()
  const now = nowSec()
  const existing = readState(sessionId) || {}

  // Preserve the turn start time across working-state transitions. A single user
  // request may cycle thinking -> tool -> thinking -> permission -> thinking, but
  // the elapsed timer should count from the start of the turn, not reset on every
  // internal state change.
  let startedAt = updates.startedAt ?? existing.startedAt ?? 0
  let started = updates.started ?? existing.started ?? false

  if (isWorking(updates.state)) {
    started = true
    if (isWorking(existing.state) && (existing.startedAt ?? 0) > 0) {
      startedAt = existing.startedAt as number
    } else if (startedAt === 0) {
      startedAt = now
    }
  }

  const seq = ++writeSeq
  const state: SessionState = {
    state: 'done',
    label: 'Done',
    tool: null,
    project,
    sessionId,
    entrypoint: 'cli',
    term_program: process.env.TERM_PROGRAM || null,
    pid: PID,
    ...existing,
    ...updates,
    started,
    startedAt,
    ts: now,
    seq,
  }
  const tmp = stateFilePath(sessionId) + '.tmp'
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2))
  fs.renameSync(tmp, stateFilePath(sessionId))
}

function getProperties(event: OpenCodeEvent): Record<string, unknown> {
  return (event.properties as Record<string, unknown>) || {}
}

function writeToolState(sessionId: string, project: string, name: string): void {
  const key = name.toLowerCase().trim()
  if (!key) return
  writeState(sessionId, project, {
    state: 'tool',
    tool: key,
    label: TOOL_LABELS[key] || formatToolLabel(key),
    started: true,
  })
}

export const id = 'opencode-status-bar'

export const server = async (ctx: PluginContext) => {
  const sessions = new Map<string, string>()

  // Make sure the status-bar app is running whenever OpenCode starts. If no
  // session exists yet the app will self-quit after a short grace period.
  launchStatusBarApp()

  return {
    event: async ({ event }: { event: OpenCodeEvent }) => {
      const properties = getProperties(event)
      const contextDir = event.context?.directory || ctx.directory

      // Resolve session ID from the various event shapes (SDK v1/v2).
      const info = properties.info as Record<string, unknown> | undefined
      const sessionId =
        (properties.sessionID as string | undefined) || (info?.id as string | undefined)

      if (!sessionId) return

      const project = sessions.get(sessionId) || projectName(contextDir)

      debugLog({
        source: 'event',
        type: event.type,
        sessionId,
        name: properties.name,
        command: properties.command,
        status: (properties.status as Record<string, unknown>)?.type,
      })

      switch (event.type) {
        case 'session.created': {
          sessions.set(sessionId, project)
          writeState(sessionId, project, {
            state: 'done',
            label: project,
            started: false,
            startedAt: 0,
          })
          break
        }

        case 'session.deleted': {
          sessions.delete(sessionId)
          clearToolEndTimer(sessionId)
          removeState(sessionId)
          break
        }

        case 'session.status': {
          const status = properties.status as Record<string, unknown> | undefined
          const statusType = status?.type as string | undefined
          if (statusType === 'busy' || statusType === 'retry') {
            writeState(sessionId, project, {
              state: 'thinking',
              label: 'Thinking…',
              tool: null,
              started: true,
            })
          } else if (statusType === 'idle') {
            writeState(sessionId, project, {
              state: 'done',
              label: 'Done',
              tool: null,
              started: false,
              startedAt: 0,
            })
          }
          break
        }

        case 'session.idle': {
          writeState(sessionId, project, {
            state: 'done',
            label: 'Done',
            tool: null,
            started: false,
            startedAt: 0,
          })
          break
        }

        case 'permission.updated':
        case 'permission.asked': {
          writeState(sessionId, project, {
            state: 'permission',
            label: 'Awaiting permission',
          })
          break
        }

        case 'permission.replied': {
          writeState(sessionId, project, {
            state: 'thinking',
            label: 'Thinking…',
            started: true,
          })
          break
        }

        case 'command.executed': {
          const command = (properties.name as string) || (properties.command as string) || ''
          writeToolState(sessionId, project, command)
          break
        }

        default: {
          // Unknown event — ignore.
        }
      }
    },

    // SDK also exposes permission requests as a dedicated hook; keep it as a fallback
    // in case the runtime emits the hook but not the event.
    'permission.ask': async (input: PermissionInput) => {
      const sessionId = input.sessionID
      if (!sessionId) return
      sessions.set(sessionId, sessions.get(sessionId) || projectName(ctx.directory))
      const project = sessions.get(sessionId)!
      debugLog({ source: 'hook', name: 'permission.ask', sessionId })
      writeState(sessionId, project, {
        state: 'permission',
        label: 'Awaiting permission',
      })
      launchStatusBarApp()
    },

    // Hooks are often more reliable than events for tool execution.
    'command.execute.before': async (input: CommandInput) => {
      const sessionId = input.sessionID
      sessions.set(sessionId, sessions.get(sessionId) || projectName(ctx.directory))
      const project = sessions.get(sessionId)!
      debugLog({
        source: 'hook',
        name: 'command.execute.before',
        sessionId,
        command: input.command,
        arguments: input.arguments,
      })
      writeToolState(sessionId, project, input.command)
      launchStatusBarApp()
    },

    'tool.execute.before': async (input: ToolInput) => {
      const sessionId = input.sessionID
      sessions.set(sessionId, sessions.get(sessionId) || projectName(ctx.directory))
      const project = sessions.get(sessionId)!
      debugLog({
        source: 'hook',
        name: 'tool.execute.before',
        sessionId,
        tool: input.tool,
        callID: input.callID,
      })
      writeToolState(sessionId, project, input.tool)
      launchStatusBarApp()
    },

    'tool.execute.after': async (input: ToolInput) => {
      const sessionId = input.sessionID
      const project = sessions.get(sessionId) || projectName(ctx.directory)
      debugLog({
        source: 'hook',
        name: 'tool.execute.after',
        sessionId,
        tool: input.tool,
        callID: input.callID,
      })
      // Keep the tool label visible for at least 1 second after the tool finishes,
      // so the status bar can't miss sub-millisecond tools like "read".
      scheduleToolEnd(sessionId, project)
    },
  }
}
