# Architecture

## Overview

```
┌──────────────────┐  Bluetooth   ┌──────────────────────────┐   Wi-Fi (token)  ┌──────────────────────────────┐
│ Ray-Ban Meta Gen2│ ───────────▶ │ iPhone app (SwiftUI)      │ ───────────────▶ │ PC: channel server (Bun)      │
│ Camera · mic ·   │ ◀─────────── │ • Meta DAT SDK 1.0.1      │ ◀─────────────── │ • HTTP + WebSocket :18790     │
│ speakers         │   HFP audio  │ • Apple speech recognition│  Reply, audio,   │ • Dashboard + QR pairing      │
└──────────────────┘              │ • iPhone voice/ElevenLabs │  approvals       │ • MCP channel (stdio) ───────┐│
                                  └──────────────────────────┘                  └──────────────────────────────┘│
                                                                                  Claude Code ◀──────────────────┘
                                                                                  (all MCP tools & skills)
```

## Message flow (channel mode)

1. The app recognizes speech on the iPhone, grabs the current camera image (glasses or iPhone)
   and sends both over WebSocket (`type: message`) – large images via `POST /upload`.
2. The channel server checks token, text and image (magic bytes), stores the image in
   `~/.claude/channels/raybanclaude/inbox/` and sends `notifications/claude/channel` to Claude Code.
   It sends the mode prompt only when the mode changes (saves tokens).
3. Claude reads the image (`file_path`) and answers via the `reply` tool.
4. The server optionally generates ElevenLabs audio and sends `type: reply` to the app, which reads it aloud
   (otherwise with the free iPhone voice) and then listens again.

Other message types: `ack` (delivered), `edit` (correction), `capture_request`
(Claude requests a photo), `permission_request`/`permission_resolved` (tool approval
on the phone), `phone_action`/`action_result` (timer, call … on the iPhone),
`memory_sync`/`memory` (memory), `error`.

## On the go: two addresses, one PC

Besides the home address, the pairing link optionally contains `remote` – the PC's Tailscale address
(100.64.0.0/10, detected from the "Tailscale" adapter). The app (`ClaudeBridge`) tries the addresses in order:

| iPhone network | Order |
|---|---|
| Wi-Fi | home address → Tailscale |
| mobile data only | Tailscale |

A network change (`NWPathMonitor`) or a failed ping restarts the connection immediately.
If the PC cannot be reached at any address and an API key is stored, the app asks Claude directly.
On the go, everything therefore still runs through Claude Code and the user's Claude subscription.

## Camera only on request (like Meta AI)

- `VisionIntent` decides from the question whether an image is needed ("What is this?", "Read it out", "Take a photo").
  Otherwise the question goes to Claude without an image; if Claude needs one after all, it calls `request_photo`/`take_photo`.
- `RayBanManager` is only "ready": with gestures the device session stays open, and the camera is only added
  for a photo: `addCamera` → stream (`hvc1`, according to Meta also runs in the background) → `capturePhoto`; after 15 s without
  another photo `camera.stop()`. A stopped camera is invalid – every photo gets a fresh `addCamera`.
  If the camera does not restart on the running session (Meta issue #260), the app rebuilds the whole session once
  (at least 2 s between sessions). Gestures off (default) → session only for the photo, then everything is released.
  Even while the user is still speaking, a recognized image question wakes the camera.
- Glasses first: `AudioSessionManager` selects the Ray-Ban Meta's Bluetooth microphone ahead of any other headset;
  if the glasses cannot take a photo, the iPhone camera steps in while the app is open.

## Glasses gestures (experimental, not yet tested on real glasses)

Via Meta's `MWDATInputs` module (DAT 1.0, developer mode/beta channel only, no runtime permission):

| Gesture | Event | App |
|---|---|---|
| Double-tap on the touchpad | `.select` | `SessionViewModel.startListening` – listen right away, 7 s for the question |
| Capture button, short press | `.capture(.shortPress)` | Wake the camera, `sendText("What do you see?")` → `VisionIntent` → photo |
| Action button (Oakley Vanguard) | `.button(.action)` | same as double-tap |
| Back | `.back` | Cancel answer/listening (real glasses do not deliver it yet, according to Meta) |
| Swipe | `.nav` | no action (only logged) |
| Single tap / tap and hold | – | stays with the system: pause or end the session |

- `addInputs(configuration:)` only on a **started** session; sources `captouch`, `captureButton`, `actionButton`
  (the Capture button alone delivered nothing in Meta's BirdSpotter example), `consumeBack: true`.
- `sources` is not a filter: the glasses redirect these surfaces to the app – swiping then arrives as `.nav` instead of
  volume.
- Attached only once `session.device.linkState == .connected`, plus 0.75 s – too early and inputs fail
  silently once (`deviceDisconnected`).
- If the capability falls back from `.active` to `.inactive` (e.g. because a photo arrives over Bluetooth), the
  event stream ends or it reports an error: `removeInputs()` → `addInputs()`, at most 5 times in a row.
  `permissionDenied`/`capabilityUnavailable` → hint in Settings, no new attempt.
- Session ended from outside (tap and hold, glasses off) → rebuild after 5 s, at most 3 times in a row;
  temples folded → wait until they are unfolded again. In the background without pocket mode everything is
  released, back in the foreground the session returns.
- Off by default until tested on real glasses; turn on under *Settings → Ray-Ban Meta →
  Gestures (experimental)* (`ClaudeConfig.glassesGestures`).

## Pocket mode

Recording (`AVAudioEngine`) keeps running, only speech recognition switches (`RecognitionSink`) – that way iOS lets the
app keep running with background audio, even with the iPhone locked. Without a wake word the microphone is released
entirely.

## Link with the Claude desktop app

- The channel writes the conversation history (`~/.claude/channels/raybanclaude/verlauf/JJJJ-MM-TT.md`, 30 days) and
  a copy of the memory list (`gedaechtnis.json`).
- `channel/bridge.ts` is a separate MCP server (stdio) for the Claude desktop app with `brille_verlauf`,
  `brille_gedaechtnis` and `brille_merken`. Pending facts (`gedaechtnis-neu.json`) are picked up by the channel as soon as
  the iPhone is connected, and sent to the app as `memory`/`add`.
- `channel/link-desktop.ts` registers the bridge in `claude_desktop_config.json` (regular and Store version, with a
  backup copy); `--remove` unregisters it again.
- `start.ps1` starts Claude Code with `--continue` if there is already a session in this folder.

## Memory

- **The app is the source of truth** (`MemoryStore`, JSON file with data protection class
  *complete until first user authentication*). Max. 200 entries of 300 characters each.
- **Channel:** On connecting and after every change the app sends `memory_sync`. The server keeps a
  copy (RAM + `gedaechtnis.json` for the Claude app) and prepends it to the *first* message to Claude –
  again only if it has changed. The `remember`/`forget` tools change the copy and send `memory` (add/remove) to the app.
- **Direct:** The list is in the first user message of a history (the system prompt stays the same →
  prompt caching), `remember`/`forget` run locally.
- **Gateway:** The list is sent once per conversation; remembering there only works via the app.
- Entries are expressly **facts, not instructions** for Claude; Claude should not store text from images or
  web pages.

## Components

| Component | File(s) | Purpose |
|---|---|---|
| Channel server | `channel/server.ts` | MCP channel, route table with access levels (public/local/token/admin), WebSocket |
| Helper modules | `channel/lib/*.ts` | Constants, regexes with examples, validation, LAN/Tailscale detection, phone actions, memory |
| Dashboard | `channel/dashboard.*` | QR pairing, activity, voice; `localhost` only, strict CSP |
| Gateway | `server/src/*.ts` | Alternative without Claude Code: Claude API + MCP client + skills |
| `RayBanManager` | `ios/…/Services/RayBanManager.swift` | DAT 1.0.1: registration, persistent session, gestures (inputs), camera per photo, device state |
| `CameraManager` | `ios/…/Services/CameraManager.swift` | iPhone camera, JPEG throttling, QR/barcodes |
| `SpeechManager` | `ios/…/Services/SpeechManager.swift` | Speech recognition (on-device), speech output |
| `ClaudeBridge` | `ios/…/Services/ClaudeBridge.swift` | WebSocket/REST, Wi-Fi → Tailscale, reconnect with backoff, token header |
| `DirectClaudeClient` | `ios/…/Services/DirectClaudeClient.swift` | Without PC: Claude API directly, tool loop, prompt caching |
| `MemoryStore` | `ios/…/Services/MemoryStore.swift` | Memory: store, sync, import from the Claude app |
| `SessionViewModel` | `ios/…/ViewModels/SessionViewModel.swift` | Flow control, timeouts, pairing, approvals, glasses gestures |

## Access levels in the channel server

| Level | Condition | Routes |
|---|---|---|
| public | none | `GET /health` ("ok" only) |
| local | loopback IP + Host/Origin = localhost | Dashboard, `/api/local` (token, IPs), `/api/pair.svg`, `/api/pair-link` |
| token | valid bearer token | `/ws`, `/upload`, `/message`, `/files/*`, `/api/status`, `/api/activity` |
| admin | local **and** token | `/api/tts`, `/api/test-message`, `/api/send-imessage` |

## Ray-Ban Meta Gen 2 – specifics

- Stream at 720p and 15 fps (cleaner still frames over Bluetooth than 30 fps).
- The audio session is set **once** to `.playAndRecord` + HFP and "settled" for about 2 s before `stream.start()` –
  frequent switching leads to "Device unavailable" on Gen 2, according to Meta.
- Closed temples end the session; when unfolded the app rebuilds it (device state `hingeState`).
- A tap on the touchpad pauses the session (`DeviceSessionState.paused`), another one resumes it.
- Photos via `stream.capturePhoto(format: .jpeg)` – video pauses briefly.
