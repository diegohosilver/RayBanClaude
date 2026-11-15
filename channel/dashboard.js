// RayBan Claude – dashboard (runs on http://localhost only, see server.ts)
'use strict'

const REFRESH_MS = 3000
const COPY_FEEDBACK_MS = 1800
const state = { token: '', port: 0, host: '', tailscale: '' }

const $ = id => document.getElementById(id)

function setStatus(el, text, kind) {
  el.textContent = text
  el.className = 'hint' + (kind ? ' ' + kind : '')
}

async function api(path, options = {}) {
  const res = await fetch(path, {
    ...options,
    headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + state.token, ...(options.headers || {}) },
  })
  const data = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(data.error || 'Error ' + res.status)
  return data
}

async function copyText(text, button) {
  await navigator.clipboard.writeText(text)
  const original = button.textContent
  button.textContent = 'Copied ✓'
  setTimeout(() => { button.textContent = original }, COPY_FEEDBACK_MS)
}

function renderPairing() {
  $('host').textContent = state.host
  $('port').textContent = String(state.port)
  $('token').textContent = state.token
  const img = $('qr')
  img.src = '/api/pair.svg?host=' + encodeURIComponent(state.host)
  img.onload = () => setStatus($('qr-hint'), 'Scan with the iPhone camera')
  img.onerror = () => setStatus($('qr-hint'), 'Could not generate QR code', 'bad')
  renderRemote()
}

/** Shows whether the iPhone can reach the PC on the go (via Tailscale). */
function renderRemote() {
  const hint = $('remote-hint')
  if (!state.tailscale) {
    setStatus(hint, '🌍 On the go: Tailscale not found. Install Tailscale (free) on PC and iPhone and reload this page – see README “On the go”.')
    return
  }
  if (state.tailscale === state.host) {
    setStatus(hint, '🌍 You are pairing directly via Tailscale (' + state.tailscale + ') – works at home and on the go.', 'ok')
    return
  }
  setStatus(hint, '🌍 On the go: via Tailscale (' + state.tailscale + ') – already included in the QR code. At home the app uses Wi-Fi, on the go it automatically uses Tailscale.', 'ok')
}

function renderBadges(status) {
  const clients = status.clients || 0
  $('badge-clients').innerHTML = ''
  const dot = document.createElement('span')
  dot.className = 'dot ' + (clients ? 'ok' : 'warn')
  $('badge-clients').append(dot, document.createTextNode(clients === 1 ? '1 app connected' : clients + ' apps connected'))

  $('badge-voice').innerHTML = ''
  const vdot = document.createElement('span')
  vdot.className = 'dot ok'
  $('badge-voice').append(vdot, document.createTextNode(status.tts ? 'Voice: ElevenLabs' : 'Voice: iPhone (free)'))
  if (status.voice) $('eleven-voice').value = status.voice
}

function renderActivity(entries) {
  const list = $('activity')
  list.replaceChildren()
  if (!entries.length) {
    const li = document.createElement('li')
    li.className = 'hint'
    li.textContent = 'No messages yet.'
    list.append(li)
    return
  }
  entries.forEach(e => {
    const li = document.createElement('li')
    const t = document.createElement('span')
    t.className = 't'
    t.textContent = new Date(e.ts).toLocaleTimeString('en-GB')
    const who = document.createElement('span')
    who.className = e.direction === 'in' ? 'in' : 'out'
    who.textContent = (e.direction === 'in' ? '← ' : '→ ') + e.source + (e.hasImage ? ' 📷' : '')
    const text = document.createElement('span')
    text.textContent = e.text // textContent: no HTML from messages (XSS protection)
    li.append(t, who, text)
    list.append(li)
  })
}

async function refresh() {
  try {
    renderBadges(await api('/api/status'))
    renderActivity((await api('/api/activity')).activity || [])
  } catch (e) {
    console.warn('Refresh failed', e)
  }
}

async function init() {
  const res = await fetch('/api/local')
  if (!res.ok) {
    document.body.textContent = 'The dashboard is only reachable directly on the PC at http://localhost.'
    return
  }
  const local = await res.json()
  state.token = local.token
  state.port = local.port
  state.tailscale = local.tailscale || ''
  $('version').textContent = 'v' + local.version

  const select = $('ip-select')
  const ips = local.ips.length ? local.ips : [{ address: 'localhost', iface: 'no network found' }]
  ips.forEach(ip => {
    const opt = document.createElement('option')
    opt.value = ip.address
    opt.textContent = ip.address + ' – ' + ip.iface
    select.append(opt)
  })
  state.host = ips[0].address
  select.addEventListener('change', () => { state.host = select.value; renderPairing() })
  renderPairing()

  $('card-imessage').hidden = !local.imessage

  $('btn-reveal').addEventListener('click', ev => {
    const shown = $('token').classList.toggle('shown')
    ev.target.textContent = shown ? 'Hide token' : 'Show token'
  })
  $('btn-copy').addEventListener('click', ev =>
    copyText('Host: ' + state.host + '\nPort: ' + state.port + '\nToken: ' + state.token
      + (state.tailscale && state.tailscale !== state.host ? '\nOn the go (Tailscale): ' + state.tailscale : ''), ev.target))
  document.querySelectorAll('[data-copy]').forEach(btn =>
    btn.addEventListener('click', () => copyText($(btn.dataset.copy).textContent, btn)))

  $('btn-test').addEventListener('click', async () => {
    const status = $('test-status')
    try {
      const r = await api('/api/test-message', { method: 'POST', body: JSON.stringify({ text: $('test-text').value }) })
      setStatus(status, r.delivered_to ? 'Delivered to ' + r.delivered_to + ' app(s) ✓' : 'No app connected – pair first', r.delivered_to ? 'ok' : 'bad')
    } catch (e) { setStatus(status, e.message, 'bad') }
  })

  const saveTts = async body => {
    const status = $('tts-status')
    try {
      const r = await api('/api/tts', { method: 'POST', body: JSON.stringify(body) })
      $('eleven-key').value = ''
      setStatus(status, r.tts ? 'ElevenLabs active ✓' : 'iPhone voice active (free) ✓', 'ok')
      refresh()
    } catch (e) { setStatus(status, e.message, 'bad') }
  }
  $('btn-tts').addEventListener('click', () => {
    const key = $('eleven-key').value.trim()
    saveTts(key ? { key, voice_id: $('eleven-voice').value } : { voice_id: $('eleven-voice').value })
  })
  $('btn-tts-off').addEventListener('click', () => saveTts({ key: '' }))

  $('btn-im').addEventListener('click', async () => {
    const status = $('im-status')
    try {
      const { link } = await api('/api/pair-link?host=' + encodeURIComponent(state.host))
      const message = 'Pair RayBan Claude:\n' + link
      await api('/api/send-imessage', { method: 'POST', body: JSON.stringify({ recipient: $('im-recipient').value, message }) })
      setStatus(status, 'Sent ✓ – tap the link on the iPhone', 'ok')
    } catch (e) { setStatus(status, e.message, 'bad') }
  })

  refresh()
  setInterval(refresh, REFRESH_MS)
}

init()
