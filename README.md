<p align="center">
  <img src="ios/RayBanClaude/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="112" alt="">
</p>

<h1 align="center">RayBan Claude</h1>

<p align="center">
  <b>Claude sees what you see.</b><br>
  Your Ray-Ban Meta (Gen 2) or your iPhone become Claude's eyes and ears –<br>
  through your Claude subscription on your Windows PC – at home and on the go.
</p>

<p align="center">
  <a href="https://github.com/MoinMornhart/RayBanClaude/actions/workflows/ios-build.yml"><img src="https://github.com/MoinMornhart/RayBanClaude/actions/workflows/ios-build.yml/badge.svg" alt="Build iOS app"></a>
  <a href="https://github.com/MoinMornhart/RayBanClaude/actions/workflows/server-tests.yml"><img src="https://github.com/MoinMornhart/RayBanClaude/actions/workflows/server-tests.yml/badge.svg" alt="Test server"></a>
  <img src="https://img.shields.io/badge/Windows-supported-0078D4" alt="Windows">
  <img src="https://img.shields.io/badge/License-MIT-6b7280" alt="MIT">
</p>

<p align="center">
  <a href="https://moinmornhart.github.io/RayBanClaude/"><b>🌐 Project page</b></a> ·
  <a href="https://github.com/MoinMornhart/RayBanClaude/releases/latest/download/RayBanClaude-Setup.exe"><b>⬇️ Windows installer</b></a> ·
  <a href="https://github.com/MoinMornhart/RayBanClaude/releases/latest"><b>📱 iPhone app</b></a> ·
  <a href="#-quick-start-windows">Quick start</a> ·
  <a href="#-on-the-go-with-your-claude-subscription">On the go</a> ·
  <a href="docs/IPHONE-OHNE-MAC.md">iPhone app without a Mac</a> ·
  <a href="#-faq">FAQ</a> ·
  <a href="docs/BUGFIXES.md">39 bugs fixed</a>
</p>

<p align="center">
  <img src="docs/images/app-gespraech.png" width="250" alt="Conversation: Claude reads the rating plate of a boiler, a timer is running">
  &nbsp;
  <img src="docs/images/app-anruf.png" width="250" alt="Confirmation before a call: call Mom (mobile)?">
  &nbsp;
  <img src="docs/images/app-einstellungen.png" width="250" alt="Settings: home address, on-the-go address (Tailscale) and token">
</p>

---

## 🗣 Just say "Hey Claude"

Like Meta AI – but with Claude: the app listens hands-free through the glasses' microphone, even with the iPhone locked
in your pocket. Say **"Hey Claude"** or **"Claudi"**, a short chime confirms, then ask your question. The glasses' camera
turns on **only when your question needs an image** – otherwise nothing is filmed:

| You say | What happens |
|---|---|
| "Hey Claude, what do you see?" | Claude describes the glasses' camera image |
| "Claudi, what does the sign say?" | Text is read out – translated on request |
| "Hey Claude, set a timer for ten minutes for the pasta" | Timer runs on the iPhone, with an announcement and a notification |
| "Claudi, wake me at half past six" | Alarm at 06:30 |
| "Hey Claude, call Mom" | Contact is looked up **on the iPhone**, you confirm – call |
| "Claudi, text Tom that I'll be ten minutes late" | Message is prepared, you tap Send |
| "Hey Claude, take me to the nearest train station" | Route in Apple Maps after confirmation |
| "Hey Claude, take a sharp photo and read the serial number" | Claude triggers a photo with the glasses on its own |
| "Hey Claude, take a photo" | The glasses' photo lands in your photo library |
| "Claudi, remind me about the dentist tomorrow at nine" | Entry in the Reminders app |
| "Hey Claude, remember where I parked" / "Where am I?" | Location is saved or announced – later "Take me to the car" |
| "Hey Claude, remember that my daughter's name is Mia" | Claude remembers it – tomorrow too, with or without the PC |
| "Claudi, what do you know about me?" / "Forget the espresso thing" | Answer from memory or entry deleted |
| "Hey Claude, email the photo to my team" *(with PC)* | Claude uses your MCP tools in Claude Code |

After an answer the app keeps listening for a few seconds – follow-up questions work without the wake word.

Or without words at all, like with Meta AI: **double-tap the touchpad** – Claude listens right away, **press the Capture
button briefly** – Claude tells you what you see *(experimental and off by default, see [Like Meta AI](#-like-meta-ai--but-with-claude))*.

## ✨ What RayBan Claude can do

| | |
|---|---|
| 👓 **Glasses first** | Camera, microphone and speakers of the Ray-Ban Meta take priority – the iPhone only steps in |
| 📷 **Camera only on request** | Like Meta AI: a photo only when the question needs one ("What is this?") – saves battery and privacy |
| 🗣 **Hands-free** | Wake word, even with the iPhone locked in your pocket; speech recognition on the iPhone, answer by voice |
| 👆 **Glasses gestures** | Double-tap = listen, Capture button = "What do you see?" – like Meta AI (experimental, opt-in) |
| 📱 **Phone actions** | Timers, alarms, reminders, calls, messages, navigation, photos, location – calls & co. always with confirmation |
| 🧰 **All your tools** | With a PC, Claude uses your entire Claude Code session incl. MCP servers |
| 🌍 **On the go via your subscription** | With Tailscale (free) the app reaches your PC over mobile data too |
| 🧠 **Memory** | "Remember …" – Claude knows you next time and continues the last glasses conversation |
| 🔗 **Linked to your Claude app** | In your Claude chats on the PC: "What did I ask through the glasses today?" – and transfer your knowledge to the glasses |
| 📶 **Without a PC if needed** | Direct mode with your own API key, switches over automatically |
| 🔐 **Approvals on the phone** | If Claude wants to use a tool, the app asks – "Yes" is enough |
| 🎯 **11 expert modes** | Translator, surroundings (visual impairment), vehicles, heating, plumbing, electrician (VDE), occupational safety (DGUV) … |
| 🔳 **QR pairing** | Scan the QR code in the dashboard – done |
| 🌐 **English** | English interface; the speech recognition language is selectable (German is still supported) |

## 🔀 Three ways to Claude – the app chooses on its own

| | **At home** | **On the go with Tailscale** | **Without a PC** (fallback) |
|---|---|---|---|
| How | iPhone → Wi-Fi → Claude Code on your PC | iPhone → mobile data → Tailscale → your PC at home | iPhone → internet → Claude API |
| Cost | **included in your Claude subscription** (Pro/Max) | **included in your Claude subscription** – Tailscale is free for personal use | your own API key, approx. **1–3 cents per question** |
| Tools | all MCP servers and skills of your session | all MCP servers and skills of your session | timers, calls, navigation, photos, web search |
| Requirement | PC on, `start.cmd` running | plus Tailscale on PC and iPhone | API key in the app |

At home the app tries Wi-Fi first, on the go it automatically uses Tailscale – and only if the PC cannot be reached at all
(and an API key is stored) does it ask Claude directly. The top of the app shows which way is currently in use:
**PC**, **PC · on the go** or **Direct**.

```
 Ray-Ban Meta Gen 2 ──Bluetooth──▶ iPhone app ──Wi-Fi / Tailscale──▶ your PC: channel server ──▶ Claude Code (subscription)
   Camera · microphone ·            Wake word ·    ╲                    Dashboard + QR            all MCP tools
   speakers                         Memory          ╲──Internet──▶ Claude API (no PC, API key)
```

## 🚀 Quick start (Windows)

1. **[Download RayBanClaude-Setup.exe](https://github.com/MoinMornhart/RayBanClaude/releases/latest/download/RayBanClaude-Setup.exe)** and double-click → *Next* → done.
   The installer sets up Bun and Claude Code (official installers), opens the firewall only for your home Wi-Fi
   and Tailscale, links the Claude desktop app and puts **"RayBan Claude"** on your desktop.
   <sub>Windows may warn "Windows protected your PC" – the file is (not yet) signed with a paid certificate:
   *More info → Run anyway*. Checksum: `RayBanClaude-Setup.exe.sha256` in the release.</sub>
2. **Start "RayBan Claude"** – the first time, sign in to Claude and confirm *"Use this MCP server"* as well as
   *"I am using this for local development"* ([why?](#-faq)). The dashboard opens.
3. **App on the iPhone** – without a Mac, for free: [guide](docs/IPHONE-OHNE-MAC.md)
4. **Scan the QR code** and off you go: *"Hey Claude, what do you see?"*
5. *Optional for on the go:* [set up Tailscale](#-on-the-go-with-your-claude-subscription) – then it works over mobile data too.

Without the installer: [download the ZIP](https://github.com/MoinMornhart/RayBanClaude/archive/refs/heads/main.zip), double-click `setup.cmd` and
`start.cmd`. macOS/Linux: `./setup.sh` and `./start.sh`. The setup prompts accept `y` (or `j`) for yes; to start a fresh
conversation instead of resuming the last one, use `start.cmd -Neu` (`./start.sh --neu` on macOS/Linux).

<p align="center">
  <img src="docs/images/dashboard.png" width="640" alt="Dashboard on the PC with QR code for pairing">
  <br><sub>The dashboard at <code>http://localhost:18790</code> – reachable only from the PC itself.</sub>
</p>

## 🌍 On the go with your Claude subscription

So that Claude also runs through **your subscription** while shopping or on a building site, the app connects to your PC at home via
[Tailscale](https://tailscale.com) – encrypted, no port forwarding on your router, free for personal use.

1. **Install Tailscale on the PC** ([download](https://tailscale.com/download)) and sign in.
2. **Get Tailscale on the iPhone** from the App Store, sign in with the **same account**, turn the VPN on.
3. **Run `setup.cmd` again** – it finds Tailscale and opens the port only for your Tailscale devices.
4. **Start `start.cmd`**. The dashboard now shows *"🌍 On the go: via Tailscale (100.…)"* – **scan the
   QR code once more**. Done.

From now on the app uses Wi-Fi at home and Tailscale on the go automatically. The PC has to stay switched on
and `start.cmd` running (tip: *Windows Settings → System → Power → Sleep: Never* while it is plugged in).

## 🧠 Memory and history

Say *"Hey Claude, remember …"* – or Claude notes down on its own what is important long-term (names, preferences,
appointments). Next conversation Claude still knows it, whether via the PC or directly. In addition, **Claude Code
continues the last glasses conversation** (new conversation: Start menu → *RayBan Claude → New conversation*).

- **View and delete:** *Settings → Memory* (swipe left) or *"Forget the thing about …"*.
- **Where is it stored?** The memory list belongs to the iPhone (encrypted). The PC keeps a copy and the
  conversation history of the last 30 days in your user folder (`%USERPROFILE%\.claude\channels\raybanclaude`) –
  for the link with the Claude app. Turn memory off: switch in the app; turn history off:
  `RAYBANCLAUDE_VERLAUF=0` in `%USERPROFILE%\.claude\channels\raybanclaude\.env`.

## 🔗 Linked to your Claude app

A third-party app may not read or write your chats on claude.ai – Anthropic offers no interface for that. The route via
**the Claude desktop app on your PC** does work, though: the installer registers the "glasses" tool there
(restart the Claude app once afterwards). In your regular Claude chats you can then say:

| You say in the Claude app | What happens |
|---|---|
| "What did I ask through the glasses today?" | Claude reads the glasses history |
| "Transfer what you know about me to the glasses" | Claude knows you from your chats and passes the essentials to the glasses' memory |
| "Remember for the glasses that I'm in Hamburg next week" | Arrives on the iPhone on the next connection |
| "Summarize what I talked about with the glasses this week" | Summary – and the chat for it sits in your Claude account like any other |

It also works without a PC: *Settings → Memory → Import from the Claude app* gives you a ready-made question for
the Claude app, and you paste its answer back in.

## 👓 Like Meta AI – but with Claude

| Meta AI on the glasses | RayBan Claude | |
|---|---|---|
| "Hey Meta" | "Hey Claude" / "Claudi" – recognized by the iPhone through the glasses' microphone, even when locked | ✅ |
| "Look, what is this?" | Photo only when needed, Claude describes, reads, translates | ✅ |
| Double-tap on the touchpad | Claude listens right away – without a wake word, even in the middle of an answer | 🧪 |
| Press the Capture button briefly | Photo with the glasses, Claude tells you what you see | 🧪 |
| Reminders, timers, "Remember where I parked" | Reminders app, timers, alarms, location in memory | ✅ |
| Photo by voice | "Take a photo" → photo library | ✅ |
| Calls, messages | With one tap on the iPhone (Apple does not allow apps to send/call silently) | 🟡 |
| Single tap / tap and hold | Stays with the system – with gestures it pauses or ends the connection to the app (it reconnects after a few seconds) | 🟡 |
| Live translation, music control, reading out notifications | Not yet / not possible for third-party apps (notifications) | ❌ |
| Knowledge | **Claude** with your tools, your memory and your Claude chats | ⭐ |

🧪 **Gestures = experimental and not yet tested on real glasses.** They run through Meta's `MWDATInputs` module
(since DAT 1.0, developer mode or beta channel only). For this the connection to the glasses stays open, but the camera
still only turns on for a photo. Whether the Capture button arrives while the camera is running is still open at Meta;
likewise whether the glasses additionally take a photo of their own in that case. While gestures are on, swiping on the
temple may not change the volume. That is why they are **off by default**. To turn them on: *Settings →
Ray-Ban Meta → Gestures (experimental)*. When off, the app only connects to the glasses for the photo.

## 💶 What does it cost?

| Part | Cost |
|---|---|
| With PC: Claude Code with a Claude subscription (Pro/Max) | included in the subscription |
| On the go via the subscription: Tailscale | **free** (personal plan) |
| Without PC: Claude API with your own key | Opus 5.5 approx. 1–3 ct/question · Sonnet 5.5 about half · Haiku 5.5 a fraction · web search approx. 1 ct |
| Speech output | **free iPhone voice** (ElevenLabs optional) |
| Building the iPhone app | **free** via GitHub Actions |
| App on the iPhone | **free** with Sideloadly + a regular Apple ID (refresh every 7 days) |

## 👓 Setting up Ray-Ban Meta Gen 2

1. Meta AI app (version 290 or later) → Settings → Glasses → **Developer mode on** → restart the glasses
2. RayBan Claude → Settings → **Connect glasses via Meta AI** → allow in the Meta AI app
3. Tap **Glasses** at the bottom right and confirm the camera permission

Developer mode needs **no** Meta app ID of your own. Temples folded = stream off; when you unfold them the app reconnects.

## 🔐 Security & privacy

- **Token** (48 characters) for every connection, header only; after 10 failed attempts a 15-minute lockout.
- **Dashboard reachable only from the PC** itself (protection against DNS rebinding), strict Content Security Policy.
- **Speech recognition on the iPhone**, contacts are only searched locally – phone numbers never go to Claude.
- **Keys in the iPhone's keychain** (channel token, Anthropic and ElevenLabs keys).
- **On the go only via Tailscale** (encrypted, only your own devices) – never via port forwarding on the router.
  The firewall rule applies only to the Tailscale adapter.
- **Memory only on the iPhone**, encrypted; entries count as facts for Claude, not as instructions.
- **Approvals stay on:** only RayBan Claude's own tools are pre-approved (replies, photos, phone actions,
  memory). Calls, messages and navigation you always confirm yourself on the iPhone.
- **Camera only on request:** the glasses do not film continuously; the glasses' camera LED shows every capture.
  Please **do not** start with `--dangerously-skip-permissions` – text in camera images can contain instructions (prompt injection).
- Gateway mode without confirmations: by default only read-only MCP tools (`MCP_TOOL_ALLOWLIST`).

## ❓ FAQ

<details>
<summary><b>Why does the start need <code>--dangerously-load-development-channels</code>?</b></summary>

Channels are a research preview in Claude Code. Without this flag Claude Code only loads channel plugins
that Anthropic has reviewed and approved (`--channels plugin:…`). RayBan Claude is not (yet) on that list –
for your own, locally stored channels the flag is the official way.

What the flag does **not** do: it does not turn off confirmations or permissions, it only skips the
approval list for this one session. Only load code you trust with it – RayBan Claude is open source and runs
entirely on your PC. Every sender has to identify itself with a token, and tool approvals stay active.
</details>

<details>
<summary><b>Does it also work when the iPhone is not connected to the PC?</b></summary>

Yes, in two ways:

- **Without a PC (direct mode):** In the app under *Settings → Without PC* enter an Anthropic API key
  ([create one here](https://console.anthropic.com/settings/keys)). If the PC cannot be reached, the app automatically
  asks Claude directly – over mobile data too. Costs a few cents per question; no PC tools then.
- **PC from on the go (via your subscription):** with [Tailscale](#-on-the-go-with-your-claude-subscription) – the app switches
  automatically from Wi-Fi to Tailscale. The PC has to be switched on for that.
</details>

<details>
<summary><b>Does this run through my Claude subscription on the go?</b></summary>

Yes – with Tailscale. The app then talks to Claude Code on your PC at home over mobile data too, and Claude Code
runs through your subscription. Only direct mode (entirely without a PC) needs an API key: Anthropic allows the subscription for the
Claude apps and Claude Code, not for third-party apps that talk to Claude directly.
</details>

<details>
<summary><b>Does Claude know my chats from the Claude app – and do the glasses conversations end up there?</b></summary>

Not directly – Anthropic offers no interface through which third-party apps could read or create your chats
(fortunately). Via the [link with the Claude desktop app](#-linked-to-your-claude-app) it works anyway:
there you say "Transfer what you know about me to the glasses", and Claude can read and summarize the glasses history –
that chat then sits in your Claude account like any other.
</details>

<details>
<summary><b>Does "Hey Claude" also work with the iPhone locked?</b></summary>

Yes – with pocket mode (*Settings → Speech & voice → Keep listening while iPhone is locked*, on by default)
the app keeps listening through the glasses, and iOS shows the orange microphone dot at the top right. The app has to have been opened
once; if you swipe it away, it stops listening. Not yet tested on real hardware.
</details>

<details>
<summary><b>Do I need a Mac or an Apple developer account?</b></summary>

No. The app is built for free in the cloud and installed on Windows with Sideloadly and your regular Apple ID:
[guide](docs/IPHONE-OHNE-MAC.md).
</details>

<details>
<summary><b>Is there an Android version?</b></summary>

Not yet. Meta also offers the glasses SDK for Android – contributions are welcome.
</details>

## 🛠 For developers

```bash
cd channel && bun install && bun test      # 33 tests (end-to-end, Claude app bridge, helpers)
cd server && npm ci && npm run build       # Gateway
cd ios && xcodegen generate                # Xcode project (macOS only)
```

| Folder | Contents |
|---|---|
| `channel/` | Channel server (Bun): MCP channel, WebSocket for the app, dashboard, tools `reply`, `request_photo`, `phone_action`, `remember`, `forget`; `bridge.ts` = "glasses" tool for the Claude desktop app |
| `installer/` | Windows installer (Inno Setup), built via GitHub Actions |
| `server/` | Gateway (Node, optional): own server with API key and MCP client |
| `ios/` | iPhone app (SwiftUI, Meta DAT SDK 1.0.1); project via XcodeGen, cloud build via GitHub Actions |
| `docs/` | Guides, [bug list](docs/BUGFIXES.md), project page |

More: [ARCHITECTURE.md](ARCHITECTURE.md) · [CONTRIBUTING.md](CONTRIBUTING.md)

## 📄 License

MIT – see [LICENSE](LICENSE). Fork of [mrdulasolutions/visionclaude](https://github.com/mrdulasolutions/visionclaude),
original code © 2026 MR Dula Solutions. Use of the Meta Wearables Device Access Toolkit is subject to the
[Meta Wearables Developer Terms](https://wearables.developer.meta.com/terms).

<sub>Unofficial project – not affiliated with Meta Platforms, Ray-Ban/EssilorLuxottica or Anthropic.
Ray-Ban and Meta are trademarks of their owners, Claude is a trademark of Anthropic.</sub>

---

<p align="center">Written with Claude 🤖</p>
