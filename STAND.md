# Status: RayBan Claude (handover 2026-10-24)

## What it is
Turns Philip's Ray-Ban Meta (Gen 2) or the iPhone into Claude's eyes and ears – "like Meta AI, but with Claude". The iPhone app (wake word "Hey Claude"/"Claudi") talks over Wi-Fi or Tailscale to Claude Code (Claude subscription) on the Windows PC; without a PC, as a fallback, directly via the Claude API. A copy of `mrdulasolutions/visionclaude`, renamed to RayBan Claude and tailored to Ray-Ban Meta Gen 2.

## Goal
- The glasses should feel like Meta AI, but with Claude.
- Camera only on request – no continuous filming; a photo only when the question needs one.
- The glasses take priority for camera, microphone and speakers; the iPhone only steps in.

## Current state
On `main` (version **2.1.0**, 24.10.; v2.0.0 from 19.10. is the latest published release):
- **iOS app** (SwiftUI, Meta DAT SDK 1.0.1, English UI): hands-free wake word even with the iPhone locked, camera only on request, glasses take priority over iPhone/other headsets, phone actions (timer, alarm, reminders, photos, location; call/message/navigation always with confirmation), memory, 11 expert modes, QR pairing, direct mode with API key only as a fallback. Builds in GitHub Actions; `.ipa` without a Mac via Sideloadly (`docs/IPHONE-OHNE-MAC.md`).
- **On the go via the Claude subscription:** the app reaches the PC via Tailscale over mobile data too.
- **Channel server** (`channel/`, Bun, MCP channel for Claude Code) with dashboard at `http://localhost:18790` (local only), conversation history and memory copy on the PC, bridge to the Claude desktop app (tool "glasses").
- **Gateway server** (`server/`, Node/TS) for operation without confirmations; by default only read-only MCP tools.
- **Windows installer** `RayBanClaude-Setup.exe` (Inno Setup, release with checksum): installs Bun + Claude Code, firewall only for home Wi-Fi and Tailscale, link with the Claude app; plus `setup.cmd`/`start.cmd`.
- **Project page** (GitHub Pages, `docs/index.html`, strict CSP) and dashboard in Jarvis look; 39 bugs fixed in `docs/BUGFIXES.md`.

New in 2.1.0 (from the branches of 20.10., merged into `main` on 24.10.):
- **iPhone app in Jarvis look** (from `claude/zealous-pascal-dfcf80`): HUD colors (midnight blue, cyan, gold) centrally in `HUDStyle.swift`, reactor rings around the microphone button (still with "Reduce Motion"). Visuals only, controls unchanged.
- **Glasses gestures** (from `claude/reverent-moore-d93bfa`, Meta's experimental module `MWDATInputs`): double-tap on the touchpad = Claude listens right away, Capture button short press = photo + "What do you see?", Back = cancel. With gestures the glasses session stays open, the camera is added per photo and turns off again 15 s later. Switch *Settings → Ray-Ban Meta → Gestures (experimental)*, **off by default** – then as before: session only for the photo.
- Both branches merged (conflict in `SettingsView.swift` resolved), iOS build green without warnings, simulator smoke test green.

## Done recently
- 2026-10-24: Version 2.1.0 on `main`: iPhone app in Jarvis look + glasses gestures (off by default); handover from the local chats (18.–20.10.) incorporated.
- 2026-10-24: Cloud start hook (Philip's skills in cloud sessions).
- 2026-10-20: Gestures (double-tap, Capture button) and iPhone app in Jarvis look built on separate branches, builds green.
- 2026-10-19: Release v2.0.0. Project page + dashboard in Jarvis look; installer fix; "like Meta AI" (camera on request, pocket mode); glasses take priority; link with the Claude app; on the go via the subscription (Tailscale) + memory; wake word, phone actions, direct mode; security check.
- 2026-10-18: Import as RayBan Claude, security holes fixed, Windows support, Meta DAT 1.0.1, German.

## Open / next steps
- **None of this has been tested on real hardware (glasses + iPhone)** – the most important open point; background listening is also untested.
- Test gestures on real glasses (Settings → Ray-Ban Meta → Gestures): Does the Capture button arrive while the camera is running? Do the glasses additionally take a photo of their own? Does the open session block Meta AI? Then decide whether they should be on by default.
- Publish release v2.1.0 on GitHub (not possible from the cloud session – `gh` has no login there); the workflows then attach Setup.exe and .ipa themselves.
- Add new screenshots in Jarvis look to the README (`docs/images/app-*.png`, 600 px wide) and the project page (embedded, 520 px): they are available as the artifact `ios-screenshots` in the workflow "iOS screenshots"; the download from the cloud failed because of the network allowlist (`*.blob.core.windows.net`).
- Delete the old branches `claude/reverent-moore-d93bfa` and `claude/zealous-pascal-dfcf80` (after Philip's OK).
- Issue #1 (VibeWorks): update dependencies, among others `@anthropic-ai/sdk` 0.135 → 1.3 (major).
- Idea: token protection on foreign Wi-Fi networks – mutual verification without a plain-text token (on Wi-Fi the app only sends the token to the stored home address).
- Known limits: memory leak in the Meta DAT SDK on Gen 2 (~4 MB/min, Meta issue #324) → restart the app in long sessions; Wi-Fi connection HTTP only (with token); prompt injection via camera images cannot be fully avoided.
- Not possible / not yet: tap and hold on the temple (Meta does not release the gesture), live translation, music, reading out notifications; Android app missing.
- The installer is not signed with a paid certificate (SmartScreen warning).

## Important info
- Tests/build: `cd channel && bun test` · `cd server && npm run build` · iOS via `ios-build.yml` (XcodeGen from `ios/project.yml`).
- Other workflows: `server-tests.yml`, `windows-installer.yml`, `ios-screenshots.yml`, `vibeworks-check.yml`.
- Start: `start.cmd` (Claude Code with `--dangerously-load-development-channels`, NOT with `--dangerously-skip-permissions`).
- Port channel/dashboard: 18790. Data on the PC: `%USERPROFILE%\.claude\channels\raybanclaude` (history 30 days, `.env`).
- Keep the MCP SDK in the channel on `~1.32` (newer ones may negotiate protocol 2026-07-28 → no channel).
- TypeScript rules from the plugin *typescript-patterns-enforcer*; regexes in `channel/lib/patterns.ts`.
- Secrets only in `.env` / `ios/Secrets.xcconfig` (both ignored).
- Sideloadly: sign in with the Apple ID (= email address); a team ID is not needed.

## Philip's requirements
- Repo **public** (github.com/MoinMornhart/RayBanClaude), MIT license.
- **No update function** planned.
- Everything in English (replies, comments, app interface, docs).

This file is kept up to date while working: after every larger step adjust "Current state" and "Open".
