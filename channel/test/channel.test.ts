/**
 * End-to-end test of the channel server: simulates Claude Code (MCP over stdio)
 * and the iPhone app (HTTP + WebSocket). Runs with `bun test`.
 */

import { afterAll, beforeAll, describe, expect, test } from 'bun:test'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import type { Subprocess } from 'bun'

const TEST_PORT = 18797
const BASE = `http://127.0.0.1:${TEST_PORT}`
const WAIT_MS = 5000
const POLL_MS = 50
const AUTH_ATTEMPTS = 10
const HTTP_OK = 200
const HTTP_ACCEPTED = 202
const HTTP_BAD_REQUEST = 400
const HTTP_UNAUTHORIZED = 401
const HTTP_FORBIDDEN = 403
const HTTP_UNSUPPORTED_MEDIA = 415
const HTTP_TOO_MANY = 429
const JSONRPC = '2.0'
const PROTOCOL = '2025-06-18'
const PERMISSION_ID = 'tbxkq'
const TEN_MINUTES_SECONDS = 600
/** A word that occurs exactly once splits the text into two parts. */
const ONE_OCCURRENCE_PARTS = 2
const NOT_A_STRING = 42
/** Smallest dummy "JPEG": magic bytes plus padding bytes (the server only checks the header). */
const FAKE_JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, ...new Array(28).fill(0)]) // eslint-disable-line ts-patterns/no-magic-numbers

interface RpcMessage {
  readonly jsonrpc: string
  readonly id?: number
  readonly method?: string
  readonly params?: Record<string, unknown>
  readonly result?: Record<string, unknown>
}

const home = mkdtempSync(join(tmpdir(), 'raybanclaude-test-'))
const testEnv = { ...process.env, HOME: home, USERPROFILE: home, RAYBANCLAUDE_PORT: String(TEST_PORT), RAYBANCLAUDE_NO_BROWSER: '1' }
const BRIDGE_INIT_ID = 1
const BRIDGE_CALL_ID = 2
const received: RpcMessage[] = []
const state = { rpcId: 0, buffer: '', token: '' }
let proc: Subprocess<'pipe', 'pipe', 'pipe'>

async function waitFor<TValue>(probe: () => TValue | undefined, label: string): Promise<TValue> {
  const deadline = Date.now() + WAIT_MS
  while (Date.now() < deadline) { // eslint-disable-line ts-patterns/no-loop-statements
    const value = probe()
    if (value !== undefined) return value
    await Bun.sleep(POLL_MS)
  }
  throw new Error(`Timeout: ${label}`)
}

function send(message: Record<string, unknown>): void {
  proc.stdin.write(JSON.stringify({ jsonrpc: JSONRPC, ...message }) + '\n')
  proc.stdin.flush()
}

async function rpc(method: string, params: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
  state.rpcId++
  const id = state.rpcId
  send({ id, method, params })
  const reply = await waitFor(() => received.find(m => m.id === id), method)
  return reply.result ?? {}
}

async function readStdout(): Promise<void> {
  const decoder = new TextDecoder()
  // Collect JSON-RPC messages line by line
  await proc.stdout.pipeTo(new WritableStream({
    write(chunk) {
      state.buffer += decoder.decode(chunk)
      const lines = state.buffer.split('\n')
      state.buffer = lines.pop() ?? ''
      lines.filter(Boolean).forEach(line => received.push(JSON.parse(line)))
    },
  }))
}

function notification(method: string, match: (p: Record<string, unknown>) => boolean): Promise<Record<string, unknown>> {
  return waitFor(() => received.find(m => m.method === method && match(m.params ?? {}))?.params, method)
}

function authed(path: string, init: RequestInit = {}): Promise<Response> {
  return fetch(BASE + path, { ...init, headers: { Authorization: `Bearer ${state.token}`, ...(init.headers ?? {}) } })
}

async function openSocket(): Promise<{ ws: WebSocket; inbox: Record<string, unknown>[] }> {
  const inbox: Record<string, unknown>[] = []
  const ws = new WebSocket(`ws://127.0.0.1:${TEST_PORT}/ws`, { headers: { Authorization: `Bearer ${state.token}` } })
  ws.onmessage = ev => inbox.push(JSON.parse(String(ev.data)))
  await waitFor(() => inbox.find(m => m.type === 'status'), 'WS-Status')
  return { ws, inbox }
}

beforeAll(async () => {
  proc = Bun.spawn([process.execPath, join(import.meta.dir, '..', 'server.ts')], {
    stdin: 'pipe',
    stdout: 'pipe',
    stderr: 'pipe',
    env: testEnv,
  })
  void readStdout()
  await rpc('initialize', { protocolVersion: PROTOCOL, capabilities: {}, clientInfo: { name: 'test', version: '1' } })
  send({ method: 'notifications/initialized' })
  await waitForHealth()
})

async function waitForHealth(): Promise<void> {
  const deadline = Date.now() + WAIT_MS
  while (Date.now() < deadline) { // eslint-disable-line ts-patterns/no-loop-statements
    const ok = await fetch(`${BASE}/health`).then(r => r.ok, () => false)
    if (ok) return
    await Bun.sleep(POLL_MS)
  }
  throw new Error('HTTP server does not start')
}

afterAll(() => {
  proc?.kill()
  rmSync(home, { recursive: true, force: true })
})

describe('MCP side', () => {
  test('reports channel and permission capabilities as well as six tools', async () => {
    const init = received.find(m => m.id === 1)?.result ?? {}
    const caps = (init.capabilities ?? {}) as Record<string, Record<string, unknown>>
    expect(caps.experimental?.['claude/channel']).toEqual({})
    expect(caps.experimental?.['claude/channel/permission']).toEqual({})
    const tools = (await rpc('tools/list')).tools as { name: string }[]
    expect(tools.map(t => t.name).sort()).toEqual(['edit_message', 'forget', 'phone_action', 'remember', 'reply', 'request_photo'])
  })
})

describe('HTTP security', () => {
  test('/health is public but reveals nothing', async () => {
    const res = await fetch(`${BASE}/health`)
    expect(res.status).toBe(HTTP_OK)
    expect(await res.json()).toEqual({ status: 'ok', mode: 'channel', auth: 'required' })
    expect(res.headers.get('x-content-type-options')).toBe('nosniff')
    expect(res.headers.get('access-control-allow-origin')).toBeNull()
  })

  test('/api/local returns the token only to localhost with a matching Host header', async () => {
    const ok = await fetch(`${BASE}/api/local`)
    expect(ok.status).toBe(HTTP_OK)
    const local = (await ok.json()) as { token: string } // response shape of /api/local
    state.token = local.token
    // 48 hex characters (24 random bytes). Matches: "ab12…" (48 characters); rejects: "kurz".
    // https://regex101.com/?flavor=javascript&regex=%5E%5B0-9a-f%5D%7B48%7D%24&flags=m&testString=0123456789abcdef0123456789abcdef0123456789abcdef%0Akurz
    expect(state.token).toMatch(/^[0-9a-f]{48}$/)
    const rebinding = await fetch(`${BASE}/api/local`, { headers: { Host: 'evil.example' } })
    expect(rebinding.status).toBe(HTTP_FORBIDDEN)
    const foreignOrigin = await fetch(`${BASE}/api/local`, { headers: { Origin: 'http://evil.example' } })
    expect(foreignOrigin.status).toBe(HTTP_FORBIDDEN)
  })

  test('protected routes require the token', async () => {
    expect((await fetch(`${BASE}/api/status`)).status).toBe(HTTP_UNAUTHORIZED)
    expect((await authed('/api/status')).status).toBe(HTTP_OK)
  })

  test('token in the URL is not accepted (Authorization header only)', async () => {
    const res = await fetch(`${BASE}/ws?token=${state.token}`)
    expect(res.status).toBe(HTTP_UNAUTHORIZED)
  })

  test('path traversal on /files is rejected', async () => {
    const res = await authed('/files/..%2F.channel-token')
    expect(res.status).toBe(HTTP_BAD_REQUEST)
  })

  test('upload without a real image is rejected', async () => {
    const form = new FormData()
    form.set('text', 'Test')
    form.set('image', new Blob(['<?php echo 1; ?> no image here']), 'x.jpg')
    expect((await authed('/upload', { method: 'POST', body: form })).status).toBe(HTTP_UNSUPPORTED_MEDIA)
  })
})

describe('Message flow app ↔ Claude', () => {
  test('text + image via WebSocket arrive at Claude as a channel notification', async () => {
    const { ws, inbox } = await openSocket()
    ws.send(JSON.stringify({ id: 'ios-1', text: 'Was siehst du?', source: 'rayban', mode: 'Allgemein', mode_prompt: 'Sei hilfreich.', image: Buffer.from(FAKE_JPEG).toString('base64') }))
    const params = await notification('notifications/claude/channel', p => (p.meta as Record<string, string>)?.message_id === 'ios-1')
    const meta = params.meta as Record<string, string>
    expect(meta.device).toBe('rayban')
    expect(meta.mode).toBe('Allgemein')
    expect(meta.file_path).toContain('rayban.jpg')
    expect(String(params.content)).toContain('[Mode “Allgemein”: Sei hilfreich.]')
    await waitFor(() => inbox.find(m => m.type === 'ack' && m.id === 'ios-1'), 'ack')
    ws.close()
  })

  test('reply tool reaches the app', async () => {
    const { ws, inbox } = await openSocket()
    const result = await rpc('tools/call', { name: 'reply', arguments: { text: 'Ein roter Apfel.', reply_to: 'ios-1' } })
    expect(result.isError).toBeFalsy()
    const reply = await waitFor(() => inbox.find(m => m.type === 'reply'), 'reply')
    expect(reply.text).toBe('Ein roter Apfel.')
    expect(reply.reply_to).toBe('ios-1')
    ws.close()
  })

  test('request_photo → app uploads photo → Claude receives it with request_id', async () => {
    const { ws, inbox } = await openSocket()
    await rpc('tools/call', { name: 'request_photo', arguments: { reason: 'Text lesen' } })
    const request = await waitFor(() => inbox.find(m => m.type === 'capture_request'), 'capture_request')
    const form = new FormData()
    form.set('source', 'rayban')
    form.set('in_reply_to', String(request.id))
    form.set('image', new Blob([FAKE_JPEG], { type: 'image/jpeg' }), 'foto.jpg')
    expect((await authed('/upload', { method: 'POST', body: form })).status).toBe(HTTP_ACCEPTED)
    const params = await notification('notifications/claude/channel', p => (p.meta as Record<string, string>)?.request_id === request.id)
    expect(params.content).toBe('(requested photo)')
    ws.close()
  })

  test('permission relay: approval request to the phone, answer back to Claude', async () => {
    const { ws, inbox } = await openSocket()
    send({ method: 'notifications/claude/channel/permission_request', params: { request_id: PERMISSION_ID, tool_name: 'Bash', description: 'List files', input_preview: 'ls' } })
    const ask = await waitFor(() => inbox.find(m => m.type === 'permission_request'), 'permission_request')
    expect(ask.tool_name).toBe('Bash')
    ws.send(JSON.stringify({ type: 'permission', request_id: PERMISSION_ID, behavior: 'allow' }))
    const verdict = await notification('notifications/claude/channel/permission', p => p.request_id === PERMISSION_ID)
    expect(verdict.behavior).toBe('allow')
    ws.close()
  })
})

describe('Phone actions (phone_action)', () => {
  test('timer goes to the app, its result back to Claude', async () => {
    const { ws, inbox } = await openSocket()
    const pending = rpc('tools/call', { name: 'phone_action', arguments: { action: 'timer', duration_seconds: TEN_MINUTES_SECONDS, label: 'Nudeln' } })
    const action = await waitFor(() => inbox.find(m => m.type === 'phone_action'), 'phone_action')
    expect(action.action).toBe('timer')
    expect(action.duration_seconds).toBe(TEN_MINUTES_SECONDS)
    expect(action.label).toBe('Nudeln')
    ws.send(JSON.stringify({ type: 'action_result', id: action.id, ok: true, message: 'Timer “Nudeln” running (10 min)' }))
    const result = await pending
    expect(JSON.stringify(result.content)).toContain('done')
    expect(result.isError).toBeFalsy()
    ws.close()
  })

  test('reminder, save photo and location go to the app', async () => {
    const { ws, inbox } = await openSocket()
    const answer = (action: Record<string, unknown>): void =>
      ws.send(JSON.stringify({ type: 'action_result', id: action.id, ok: true, message: `${String(action.action)} done` }))

    const reminder = rpc('tools/call', { name: 'phone_action', arguments: { action: 'reminder', text: 'Zahnarzt', date: '2026-10-20', time: '09:00' } })
    const sentReminder = await waitFor(() => inbox.find(m => m.action === 'reminder'), 'reminder')
    expect(sentReminder.text).toBe('Zahnarzt')
    expect(sentReminder.date).toBe('2026-10-20')
    answer(sentReminder)
    expect((await reminder).isError).toBeFalsy()

    const photo = rpc('tools/call', { name: 'phone_action', arguments: { action: 'save_photo' } })
    answer(await waitFor(() => inbox.find(m => m.action === 'save_photo'), 'save_photo'))
    expect((await photo).isError).toBeFalsy()

    const place = rpc('tools/call', { name: 'phone_action', arguments: { action: 'location', label: 'Auto geparkt' } })
    const sentPlace = await waitFor(() => inbox.find(m => m.action === 'location'), 'location')
    expect(sentPlace.label).toBe('Auto geparkt')
    answer(sentPlace)
    expect(JSON.stringify((await place).content)).toContain('done')
    ws.close()
  })

  test('invalid input is rejected before anything goes to the phone', async () => {
    const { ws, inbox } = await openSocket()
    const zero = await rpc('tools/call', { name: 'phone_action', arguments: { action: 'timer', duration_seconds: 0 } })
    expect(zero.isError).toBe(true)
    const badTime = await rpc('tools/call', { name: 'phone_action', arguments: { action: 'alarm', time: '25:00' } })
    expect(badTime.isError).toBe(true)
    const noTarget = await rpc('tools/call', { name: 'phone_action', arguments: { action: 'call' } })
    expect(noTarget.isError).toBe(true)
    const unknown = await rpc('tools/call', { name: 'phone_action', arguments: { action: 'format_disk' } })
    expect(unknown.isError).toBe(true)
    const badDate = await rpc('tools/call', { name: 'phone_action', arguments: { action: 'reminder', text: 'Zahnarzt', date: '20.10.2026' } })
    expect(badDate.isError).toBe(true)
    const noText = await rpc('tools/call', { name: 'phone_action', arguments: { action: 'reminder', time: '09:00' } })
    expect(noText.isError).toBe(true)
    expect(inbox.some(m => m.type === 'phone_action')).toBe(false)
    ws.close()
  })
})

describe('Memory', () => {
  const channelMessage = (id: string): Promise<Record<string, unknown>> =>
    notification('notifications/claude/channel', p => (p.meta as Record<string, string>)?.message_id === id)

  test('the app memory list reaches Claude with the first message – not again afterwards', async () => {
    const { ws } = await openSocket()
    ws.send(JSON.stringify({ type: 'memory_sync', items: ['Daughter is called Mia', 'daughter is called mia', NOT_A_STRING, 'Drinks espresso'] }))
    ws.send(JSON.stringify({ id: 'mem-1', text: 'Hallo' }))
    const first = String((await channelMessage('mem-1')).content)
    expect(first).toContain('- Daughter is called Mia')
    expect(first).toContain('- Drinks espresso')
    expect(first.split('Mia').length).toBe(ONE_OCCURRENCE_PARTS) // duplicate entry was removed
    expect(first.endsWith('Hallo')).toBe(true)
    ws.send(JSON.stringify({ id: 'mem-2', text: 'Und jetzt?' }))
    expect((await channelMessage('mem-2')).content).toBe('Und jetzt?')
    ws.close()
  })

  test('remember and forget change the list in the app', async () => {
    const { ws, inbox } = await openSocket()
    const saved = await rpc('tools/call', { name: 'remember', arguments: { fact: 'Drives a blue Golf' } })
    expect(saved.isError).toBeFalsy()
    const add = await waitFor(() => inbox.find(m => m.type === 'memory' && m.op === 'add'), 'memory add')
    expect(add.items).toEqual(['Drives a blue Golf'])
    const removed = await rpc('tools/call', { name: 'forget', arguments: { fact: 'espresso' } })
    expect(JSON.stringify(removed.content)).toContain('Drinks espresso')
    const remove = await waitFor(() => inbox.find(m => m.type === 'memory' && m.op === 'remove'), 'memory remove')
    expect(remove.items).toEqual(['Drinks espresso'])
    const nothing = await rpc('tools/call', { name: 'forget', arguments: { fact: 'Parachute' } })
    expect(JSON.stringify(nothing.content)).toContain('Nothing is stored')
    ws.close()
  })

  test('an emptied list is communicated to Claude', async () => {
    const { ws } = await openSocket()
    ws.send(JSON.stringify({ type: 'memory_sync', items: [] }))
    ws.send(JSON.stringify({ id: 'mem-3', text: 'What do you know about me?' }))
    expect(String((await channelMessage('mem-3')).content)).toContain('cleared their memory list')
    ws.close()
  })

  test('memory switched off: nothing is sent or remembered', async () => {
    const { ws, inbox } = await openSocket()
    ws.send(JSON.stringify({ type: 'memory_sync', items: ['Secret fact'], enabled: false }))
    ws.send(JSON.stringify({ id: 'mem-4', text: 'Hallo' }))
    expect((await channelMessage('mem-4')).content).toBe('Hallo')
    const refused = await rpc('tools/call', { name: 'remember', arguments: { fact: 'Likes tea' } })
    expect(refused.isError).toBe(true)
    expect(inbox.some(m => m.type === 'memory')).toBe(false)
    ws.close()
  })
})

/** Calls a tool of the Claude app bridge (bridge.ts) – the way the Claude desktop app does. */
async function bridgeCall(name: string, args: Record<string, unknown>): Promise<string> {
  const child = Bun.spawn([process.execPath, join(import.meta.dir, '..', 'bridge.ts')], { stdin: 'pipe', stdout: 'pipe', stderr: 'pipe', env: testEnv })
  const messages: RpcMessage[] = []
  const decoder = new TextDecoder()
  const pending = { buffer: '' }
  void child.stdout.pipeTo(new WritableStream({
    write(chunk) {
      pending.buffer += decoder.decode(chunk)
      const lines = pending.buffer.split('\n')
      pending.buffer = lines.pop() ?? ''
      lines.filter(Boolean).forEach(line => messages.push(JSON.parse(line)))
    },
  }))
  const write = (message: Record<string, unknown>): void => {
    child.stdin.write(JSON.stringify({ jsonrpc: JSONRPC, ...message }) + '\n')
    child.stdin.flush()
  }
  write({ id: BRIDGE_INIT_ID, method: 'initialize', params: { protocolVersion: PROTOCOL, capabilities: {}, clientInfo: { name: 'claude-app', version: '1' } } })
  await waitFor(() => messages.find(m => m.id === BRIDGE_INIT_ID), 'bridge starts')
  write({ method: 'notifications/initialized' })
  write({ id: BRIDGE_CALL_ID, method: 'tools/call', params: { name, arguments: args } })
  const reply = await waitFor(() => messages.find(m => m.id === BRIDGE_CALL_ID), name)
  child.kill()
  return JSON.stringify(reply.result ?? {})
}

describe('Claude app bridge (history and memory)', () => {
  test('brille_verlauf returns what was discussed through the glasses', async () => {
    const history = await bridgeCall('brille_verlauf', { tage: 1 })
    expect(history).toContain('Was siehst du?')
    expect(history).toContain('Ein roter Apfel.')
    const search = await bridgeCall('brille_verlauf', { suche: 'apfel' })
    expect(search).toContain('Ein roter Apfel.')
    expect(search).not.toContain('Was siehst du?')
  })

  test('brille_merken from the Claude app ends up on the iPhone the next time it connects', async () => {
    expect(await bridgeCall('brille_merken', { fakt: 'Likes green tea' })).toContain('Queued')
    expect(await bridgeCall('brille_gedaechtnis', {})).toContain('Likes green tea')
    const { ws, inbox } = await openSocket()
    ws.send(JSON.stringify({ type: 'memory_sync', items: ['Daughter is called Mia'] }))
    const added = await waitFor(() => inbox.find(m => m.type === 'memory' && m.op === 'add'), 'memory add from the Claude app')
    expect(added.items).toEqual(['Likes green tea'])
    const memoryNow = await bridgeCall('brille_gedaechtnis', {})
    expect(memoryNow).toContain('Daughter is called Mia')
    expect(memoryNow).not.toContain('Queued')
    ws.close()
  })

  test('empty fact is rejected', async () => {
    expect(await bridgeCall('brille_merken', { fakt: '   ' })).toContain('isError')
  })
})

describe('Brute-force protection', () => {
  test(`locked after ${AUTH_ATTEMPTS} wrong tokens`, async () => {
    const attempts = Array.from({ length: AUTH_ATTEMPTS }, () =>
      fetch(`${BASE}/api/status`, { headers: { Authorization: 'Bearer wrong' } }))
    await Promise.all(attempts)
    const locked = await fetch(`${BASE}/api/status`, { headers: { Authorization: `Bearer ${state.token}` } })
    expect(locked.status).toBe(HTTP_TOO_MANY)
  })
})

describe('Lifecycle', () => {
  test('process ends when Claude Code closes the connection (no orphaned port)', async () => {
    proc.stdin.end()
    const code = await Promise.race([proc.exited, Bun.sleep(WAIT_MS).then(() => 'timeout')])
    expect(code).toBe(0)
  })
})
