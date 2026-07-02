import { describe, it, expect, beforeEach, vi } from 'vitest'
import * as fs from 'fs'
import * as path from 'path'
import * as os from 'os'

// Mock child_process so session.created does not try to open the real app.
vi.mock('child_process', () => ({
  exec: vi.fn((_cmd, cb) => {
    if (cb) cb(null as any, '', '')
  }),
}))

// The plugin computes its state directory at import time from XDG_STATE_HOME,
// so we must set it before the first import.
const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'opencode-status-bar-test-'))
process.env.XDG_STATE_HOME = tmpRoot

// Import after setting the env var.
import { server as pluginFactory } from '../src/opencode-status-bar-plugin'

const stateDir = path.join(tmpRoot, 'opencode', 'statusbar', 'state.d')
const sessionId = 'ses_test_123'
const directory = '/Users/dev/my-project'

async function loadPlugin() {
  return await pluginFactory({ directory })
}

function readState(sid: string = sessionId): any {
  return JSON.parse(fs.readFileSync(path.join(stateDir, `${sid}.json`), 'utf8'))
}

function stateFiles(): string[] {
  if (!fs.existsSync(stateDir)) return []
  return fs.readdirSync(stateDir).filter((f) => f.endsWith('.json'))
}

function createdEvent(sid: string = sessionId, dir: string = directory) {
  return {
    type: 'session.created' as const,
    properties: { info: { id: sid } },
    context: { directory: dir },
  }
}

function statusEvent(sid: string, statusType: 'busy' | 'idle' | 'retry') {
  return {
    type: 'session.status' as const,
    properties: { sessionID: sid, status: { type: statusType } },
    context: { directory },
  }
}

describe('opencode-status-bar plugin', () => {
  beforeEach(() => {
    if (fs.existsSync(stateDir)) {
      fs.rmSync(stateDir, { recursive: true, force: true })
    }
  })

  it('creates an idle state file on session.created', async () => {
    const plugin = await loadPlugin()
    await plugin.event({ event: createdEvent() })

    expect(stateFiles()).toEqual([`${sessionId}.json`])
    const state = readState()
    expect(state.state).toBe('done')
    expect(state.project).toBe('my-project')
    expect(state.entrypoint).toBe('cli')
    expect(state.sessionId).toBe(sessionId)
  })

  it('switches to thinking on session.status busy', async () => {
    const plugin = await loadPlugin()
    await plugin.event({ event: createdEvent() })
    await plugin.event({ event: statusEvent(sessionId, 'busy') })

    const state = readState()
    expect(state.state).toBe('thinking')
    expect(state.label).toBe('Thinking…')
    expect(state.started).toBe(true)
    expect(state.startedAt).toBeGreaterThan(0)
  })

  it('maps command.executed to tool labels', async () => {
    const plugin = await loadPlugin()
    await plugin.event({ event: createdEvent() })
    await plugin.event({
      event: {
        type: 'command.executed' as const,
        properties: { sessionID: sessionId, name: 'edit', arguments: '', messageID: 'msg_1' },
        context: { directory },
      },
    })

    const state = readState()
    expect(state.state).toBe('tool')
    expect(state.tool).toBe('edit')
    expect(state.label).toBe('Editing')
  })

  it('falls back to a readable label for unknown tools', async () => {
    const plugin = await loadPlugin()
    await plugin.event({ event: createdEvent() })
    await plugin.event({
      event: {
        type: 'command.executed' as const,
        properties: {
          sessionID: sessionId,
          name: 'custom_tool',
          arguments: '',
          messageID: 'msg_1',
        },
        context: { directory },
      },
    })

    const state = readState()
    expect(state.state).toBe('tool')
    expect(state.label).toBe('Custom Tool')
  })

  it('is case-insensitive when mapping tool labels', async () => {
    const plugin = await loadPlugin()
    await plugin.event({ event: createdEvent() })
    await (plugin as any)['command.execute.before']({
      sessionID: sessionId,
      command: 'Edit',
      arguments: '',
    })

    const state = readState()
    expect(state.state).toBe('tool')
    expect(state.tool).toBe('edit')
    expect(state.label).toBe('Editing')
  })

  it('sets permission state on permission.updated', async () => {
    const plugin = await loadPlugin()
    await plugin.event({ event: createdEvent() })
    await plugin.event({
      event: {
        type: 'permission.updated' as const,
        properties: {
          id: 'perm_1',
          sessionID: sessionId,
          type: 'bash',
          title: 'Run command',
          metadata: {},
          time: { created: Date.now() },
        },
        context: { directory },
      },
    })

    const state = readState()
    expect(state.state).toBe('permission')
    expect(state.label).toBe('Awaiting permission')
    expect(state.started).toBe(false)
  })

  it('sets permission state on SDK-v2 permission.asked', async () => {
    const plugin = await loadPlugin()
    await plugin.event({ event: createdEvent() })
    await plugin.event({
      event: {
        type: 'permission.asked' as const,
        properties: {
          id: 'req_1',
          sessionID: sessionId,
          permission: 'bash',
          patterns: ['/Users/dev/my-project/*'],
          metadata: {},
          always: [],
        },
        context: { directory },
      },
    })

    const state = readState()
    expect(state.state).toBe('permission')
    expect(state.label).toBe('Awaiting permission')
  })

  it('sets permission state via permission.ask hook', async () => {
    const plugin = await loadPlugin()
    await plugin.event({ event: createdEvent() })
    await (plugin as any)['permission.ask']({
      sessionID: sessionId,
      type: 'bash',
      pattern: '/Users/dev/my-project/*',
      metadata: {},
    })

    const state = readState()
    expect(state.state).toBe('permission')
    expect(state.label).toBe('Awaiting permission')
  })

  it('sets tool state via command.execute.before hook', async () => {
    const plugin = await loadPlugin()
    await plugin.event({ event: createdEvent() })
    await (plugin as any)['command.execute.before']({
      sessionID: sessionId,
      command: 'edit',
      arguments: '',
    })

    const state = readState()
    expect(state.state).toBe('tool')
    expect(state.tool).toBe('edit')
    expect(state.label).toBe('Editing')
  })

  it('sets tool state via tool.execute.before hook', async () => {
    const plugin = await loadPlugin()
    await plugin.event({ event: createdEvent() })
    await (plugin as any)['tool.execute.before']({
      sessionID: sessionId,
      tool: 'write',
      callID: 'call_1',
    })

    const state = readState()
    expect(state.state).toBe('tool')
    expect(state.tool).toBe('write')
    expect(state.label).toBe('Writing')
  })

  it('returns to thinking via tool.execute.after hook after a 2-second hold', async () => {
    vi.useFakeTimers()
    const plugin = await loadPlugin()
    await plugin.event({ event: createdEvent() })
    await (plugin as any)['tool.execute.before']({
      sessionID: sessionId,
      tool: 'read',
      callID: 'call_1',
    })
    expect(readState().state).toBe('tool')
    expect(readState().label).toBe('Reading')

    await (plugin as any)['tool.execute.after']({
      sessionID: sessionId,
      tool: 'read',
      callID: 'call_1',
    })
    expect(readState().state).toBe('tool')
    expect(readState().label).toBe('Reading')

    vi.advanceTimersByTime(2000)
    const state = readState()
    expect(state.state).toBe('thinking')
    expect(state.label).toBe('Thinking…')
    vi.useRealTimers()
  })

  it('cancels pending tool-end when a new tool starts', async () => {
    vi.useFakeTimers()
    const plugin = await loadPlugin()
    await plugin.event({ event: createdEvent() })
    await (plugin as any)['tool.execute.before']({
      sessionID: sessionId,
      tool: 'read',
      callID: 'call_1',
    })
    await (plugin as any)['tool.execute.after']({
      sessionID: sessionId,
      tool: 'read',
      callID: 'call_1',
    })

    await (plugin as any)['tool.execute.before']({
      sessionID: sessionId,
      tool: 'bash',
      callID: 'call_2',
    })
    vi.advanceTimersByTime(2000)

    const state = readState()
    expect(state.state).toBe('tool')
    expect(state.tool).toBe('bash')
    expect(state.label).toBe('Running command')
    vi.useRealTimers()
  })

  it('returns to thinking on permission.replied', async () => {
    const plugin = await loadPlugin()
    await plugin.event({ event: createdEvent() })
    await plugin.event({
      event: {
        type: 'permission.updated' as const,
        properties: {
          id: 'perm_1',
          sessionID: sessionId,
          type: 'bash',
          title: 'Run command',
          metadata: {},
          time: { created: Date.now() },
        },
        context: { directory },
      },
    })
    await plugin.event({
      event: {
        type: 'permission.replied' as const,
        properties: { sessionID: sessionId, permissionID: 'perm_1', response: 'allow' },
        context: { directory },
      },
    })

    const state = readState()
    expect(state.state).toBe('thinking')
  })

  it('preserves startedAt across repeated busy events', async () => {
    const plugin = await loadPlugin()
    await plugin.event({ event: createdEvent() })
    await plugin.event({ event: statusEvent(sessionId, 'busy') })
    const firstStartedAt = readState().startedAt

    await plugin.event({ event: statusEvent(sessionId, 'busy') })
    const state = readState()
    expect(state.state).toBe('thinking')
    expect(state.startedAt).toBe(firstStartedAt)
  })

  it('preserves startedAt through tool and permission round trips', async () => {
    const plugin = await loadPlugin()
    await plugin.event({ event: createdEvent() })
    await plugin.event({ event: statusEvent(sessionId, 'busy') })
    const turnStart = readState().startedAt

    await (plugin as any)['tool.execute.before']({
      sessionID: sessionId,
      tool: 'read',
      callID: 'call_1',
    })
    expect(readState().startedAt).toBe(turnStart)

    await (plugin as any)['tool.execute.after']({
      sessionID: sessionId,
      tool: 'read',
      callID: 'call_1',
    })
    expect(readState().startedAt).toBe(turnStart)

    await plugin.event({
      event: {
        type: 'permission.updated' as const,
        properties: {
          id: 'perm_1',
          sessionID: sessionId,
          type: 'bash',
          title: 'Run command',
          metadata: {},
          time: { created: Date.now() },
        },
        context: { directory },
      },
    })
    expect(readState().startedAt).toBe(turnStart)

    await plugin.event({
      event: {
        type: 'permission.replied' as const,
        properties: { sessionID: sessionId, permissionID: 'perm_1', response: 'allow' },
        context: { directory },
      },
    })
    const state = readState()
    expect(state.state).toBe('thinking')
    expect(state.startedAt).toBe(turnStart)
  })

  it('marks done on session.status idle', async () => {
    const plugin = await loadPlugin()
    await plugin.event({ event: createdEvent() })
    await plugin.event({ event: statusEvent(sessionId, 'busy') })
    await plugin.event({ event: statusEvent(sessionId, 'idle') })

    const state = readState()
    expect(state.state).toBe('done')
    expect(state.label).toBe('Done')
    expect(state.started).toBe(false)
  })

  it('removes the state file on session.deleted', async () => {
    const plugin = await loadPlugin()
    await plugin.event({ event: createdEvent() })
    expect(stateFiles()).toHaveLength(1)

    await plugin.event({
      event: {
        type: 'session.deleted' as const,
        properties: { sessionID: sessionId },
        context: { directory },
      },
    })

    expect(stateFiles()).toHaveLength(0)
  })

  it('keeps multi-session state isolated', async () => {
    const plugin = await loadPlugin()
    const ids = ['ses_a', 'ses_b']
    await Promise.all(ids.map((id) => plugin.event({ event: createdEvent(id) })))
    await plugin.event({
      event: {
        type: 'command.executed' as const,
        properties: { sessionID: 'ses_a', name: 'bash', arguments: '', messageID: 'msg_1' },
        context: { directory },
      },
    })

    expect(stateFiles()).toHaveLength(2)
    expect(readState('ses_a').state).toBe('tool')
    expect(readState('ses_b').state).toBe('done')
  })
})
