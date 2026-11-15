# Bugs found and fixed

Inventory of the original code (mrdulasolutions/visionclaude, as of `a6e9cc3`) and
what became of it in RayBan Claude. Severity: 🔴 critical · 🟠 high · 🟡 medium · ⚪ low.

## Critical – project unusable or exposed

| # | Area | Problem | Fix |
|---|---|---|---|
| 1 | 🔴 iOS | **App could no longer be built.** `from: "0.5.0"` resolves to Meta DAT 0.9.0 – `StreamSession` no longer exists there. | Port to DAT **1.0.1** (DeviceSession → Camera → Stream), officially for Ray-Ban Meta **Gen 1 and Gen 2**. Cloud build via GitHub Actions green. |
| 2 | 🔴 Repo | **The original author's real API key** in `.claude/settings.local.json` in the repo. | File not carried over, added to `.gitignore`. (The original author should revoke the key.) |
| 3 | 🔴 Channel | **Token readable from the whole Wi-Fi**: `/token` only checked the Host header – `curl -H "Host: localhost" http://PC-IP:18790/token` was enough. | Only real loopback connections + Host/Origin check (also against DNS rebinding). |
| 4 | 🔴 Gateway | **Completely open without `GATEWAY_API_KEY`** on `0.0.0.0`: anyone on the Wi-Fi could chat, run tools, change the system prompt/model. | Token always required (generated automatically). |
| 5 | 🔴 iOS | The original author's **Meta app ID, client token and Apple team ID** hard-coded. | Via `Config.xcconfig`/`Secrets.xcconfig`; not needed in developer mode. |

## Security

| # | Area | Problem | Fix |
|---|---|---|---|
| 6 | 🟠 Channel | **AppleScript injection** via the Apple ID in `/send-sms` (quotation marks → code execution). | Values as `argv`, format check; now macOS + local only. |
| 7 | 🟠 Channel | **Path traversal** when saving: the `source` field ended up unchecked in the file name. | Allowlist `iphone`/`rayban`. |
| 8 | 🟠 Channel | `/files/*` (speech output, attachments) retrievable **without a token** – the auth check came after the delivery. | Token required, file name allowlist. |
| 9 | 🟠 Channel | Arbitrary files accepted as an "image" (extension taken from the file name). | Magic byte check (JPEG/PNG/HEIC), size limit. |
| 10 | 🟠 Channel | **`.env` injection** via the ElevenLabs key (line break → further variables). | Format check, file with permissions 0600. |
| 11 | 🟠 both | No protection against **token guessing**, comparison not constant-time. | `timingSafeEqual`, lockout for 15 minutes after 10 failed attempts. |
| 12 | 🟠 Gateway | `/health` revealed MCP servers, tools and skills; **CORS `*`** allowed any web page access. | Public only "ok", CORS removed, security headers (CSP, nosniff, …). |
| 13 | 🟠 Gateway | stdio MCP servers inherited **`ANTHROPIC_API_KEY`** and the gateway token. | Only standard environment + configured `env`. |
| 14 | 🟠 iOS | Token and ElevenLabs key **in plain text in UserDefaults**. | iOS keychain. |
| 15 | 🟡 both | Internal error texts (SDK, stack traces) went to the app. | Neutral messages, details only in the log. |
| 16 | 🟡 Channel | Attachments: Claude could send any file on the PC to the app. | Only images, PDF, text, audio; max. 25 MB. |
| 17 | 🟡 Docs | `claude ... -p bypassPermissions` recommended as "hands-free" – `-p` is print mode, and bypass does not protect against prompt injection via camera images. | Pre-approve only the own reply tools; other approvals directly on the phone. |

## Functionality

| # | Area | Problem | Fix |
|---|---|---|---|
| 18 | 🟠 iOS | **Glasses kept streaming after "Stop"** (task read `streamSession` only after it was `nil`). | Clean teardown camera → session. |
| 19 | 🟠 iOS | **Images arrived rotated by 90°** at Claude (sensor orientation). | `videoRotationAngle = 90`. |
| 20 | 🟠 iOS | Without an answer the app **hung on "Thinking" forever** – every further question was ignored. | Delivery acknowledgement (10 s) and answer timeout. |
| 21 | 🟠 iOS | Speech recognition and voice **hard-coded to English** – German was not understood. | Language selectable, default = device language. |
| 22 | 🟠 Channel | **Orphaned process** after quitting Claude blocked the port ("port in use"). | Process ends with the MCP connection. |
| 23 | 🟠 Channel | **Crash on Windows/Linux** (macOS command `open`). | Platform-dependent, hardened. |
| 24 | 🟠 Gateway | Every camera image stayed in the history → **costs exploded** per round. | Images only in the current message, history capped. |
| 25 | 🟡 Channel | Attachments from `reply` were copied but **never sent to the app**. | URLs in the reply, shown in the history. |
| 26 | 🟡 Channel | `edit_message` created a **new message** instead of changing the old one. | Dedicated message type `edit`. |
| 27 | 🟡 iOS | Gateway mode **never selectable**, sent no token; upload expected 204. | Selection in Settings, token header, 2xx. |
| 28 | 🟡 iOS | Reconnect: counter never incremented, duplicate reconnects, **URLSession leak**, endless loop with a wrong token. | Backoff, one connection, stop on 401/429. |
| 29 | 🟡 iOS | Mode selection and glasses status **did not update** (nested ObservableObjects). | Forwarding or `@ObservedObject`. |
| 30 | 🟡 iOS | Listening aborted silently, display stayed on "Listening"; sentences were sometimes sent **twice**. | Feedback on abort, pause processed only once. |
| 31 | 🟡 iOS | Audio session was switched constantly – on **Gen 2** this leads to "Device unavailable". | `.playAndRecord` + HFP once, no switch to `.playback`. |
| 32 | 🟡 iOS | **Crash** on invalid host input (`URL(...)!`); port field jumped to 18790 when deleting. | Optional URLs, own text state. |
| 33 | 🟡 Channel | **Wrong IP** in the dashboard on Windows (WSL/Hyper-V adapter first). | Ranking: Wi-Fi/192.168.x first, virtual adapters last. |
| 34 | 🟡 Channel | `.env` with Windows line endings (CRLF) read incorrectly. | CRLF-tolerant. |
| 35 | 🟡 Gateway | `HOME` undefined on Windows; the original author's **private paths** hard-coded; Claude desktop config only on macOS. | `os.homedir()`, `SKILL_PATHS`, paths for Windows/Linux/Store app. |
| 36 | 🟡 Gateway | Duplicate tool names made **every request fail with 400**; skill contents never reached Claude. | Collisions filtered, tool `skill_laden`. |
| 37 | ⚪ Channel | Inbox/outbox grew without limit. | Cleanup after 24 h. |
| 38 | ⚪ iOS | Camera stop missed during a running start; new `CIContext` per image; display link created a task per frame; pulse animation invisible. | Session queue, one context, direct update. |
| 39 | ⚪ Setup | `.mcp.json` with the original author's absolute paths; setup for macOS only. | Relative path, `setup.cmd`/`start.cmd` for Windows. |

## Newly added

- **QR pairing**: the dashboard shows a QR code, scan it with the iPhone camera, done (with a security prompt).
- **Approvals on the phone** (permission relay): tool approvals by button or "Yes"/"No".
- **Photo on request**: Claude can trigger a sharp photo with the glasses using `request_photo`.
- **Gen 2 details**: battery, model, temple status, automatic restart on unfolding.
- **Free cloud build** of the iPhone app + guide for Windows (Sideloadly).
- **Tests**: 12 end-to-end tests for the channel, CI on Windows/macOS/Linux.
- German interface, German modes (VDE, DGUV/ASR instead of NEC/OSHA), new modes "Translator" and "Surroundings".

## Open / known limits

- On Wi-Fi the connection runs over **HTTP** (no certificate possible for LAN IPs) – protected by a token.
  For on the go: Tailscale or similar instead of port forwarding on the router.
- **Prompt injection via camera images** (text in the image) cannot be fully prevented –
  that is why tool approvals stay active and Claude is supposed to ask before actions with external effect.
  In gateway mode (without confirmations) only read-only tools are approved by default (`MCP_TOOL_ALLOWLIST`).

## Follow-up after the security check (2026-10-19)

- Gateway: allowlist for MCP tools, default = read-only tools only (`server/src/tool-policy.ts`).
- Channel: token only in the `Authorization` header, no longer as a URL parameter (+ test).
- `.gitignore`: `.env.*`, key and certificate files, local databases, Python caches.
- gitleaks false positive (public voice ID) defused: placeholder + `.gitleaksignore` with justification.
- Meta DAT 1.0.x has a known **memory leak** in the Bluetooth buffer on Gen 2 (~4 MB/min, Meta issue #324) –
  restart the app now and then in very long sessions.
- The iPhone app is built in the cloud, but **not yet tested on real hardware** (glasses + iPhone).

## Like Meta AI: camera on request, pocket mode (2026-10-19)

- The glasses filmed continuously (battery, heat, memory leak in the Meta SDK #324) – now only photos on request.
- Recording was stopped after every sentence; in the background iOS then may not restart it – now it keeps running.
- `request_photo` made Claude wait forever if no photo was possible – now "Photo not possible" comes back.
- Another Bluetooth headset (e.g. in the car) could "take away" the microphone from the glasses – now the glasses have priority.

## Follow-up with "On the go via the subscription" and memory (2026-10-19)

- **Own mistake from the first version of direct mode:** voice commands still checked whether the PC was connected –
  without a PC that always produced "Not connected". The follow-up question after an answer and the camera start when
  switching the image source also depended on the PC connection. Now what counts is whether *any* path to Claude is open.
- Dead connections (e.g. Wi-Fi gone, tunnel interrupted) stayed "connected" for up to two minutes – now the
  app detects them via ping and network change and reconnects immediately (on the go via Tailscale).
- Open: the app sends its token on Wi-Fi to the stored home address – also on foreign Wi-Fi networks, as before.
  On mobile data it only uses the Tailscale address. Mutual verification without a plain-text token is planned.
