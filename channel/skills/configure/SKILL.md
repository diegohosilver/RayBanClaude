---
name: raybanclaude-configure
description: Set up the RayBan Claude channel – pairing with the iPhone, optional ElevenLabs voice and port
---

# Set up the RayBan Claude channel

The channel stores its settings in `~/.claude/channels/raybanclaude/`
(Windows: `%USERPROFILE%\.claude\channels\raybanclaude\`).

## Pairing (recommended)

1. Start Claude Code with the channel:
   `claude --dangerously-load-development-channels server:raybanclaude`
2. Open the dashboard: <http://localhost:18790>
3. Scan the QR code with the iPhone camera → “Open in RayBan Claude” → confirm.

Phone and PC must be on the same Wi-Fi. On Windows, allow the firewall prompt for
**private networks** on first start.

## Optional settings (`.env` in the folder above)

```
# More natural voice (paid; without a key the iPhone speaks for free)
ELEVENLABS_API_KEY=<your-elevenlabs-key>

# Voice (default: Charlotte)
ELEVENLABS_VOICE_ID=XB0fDUnXU5powFXDhCwa

# Different port (default 18790)
RAYBANCLAUDE_PORT=18790

# Open the dashboard on every start (1) or never open it (RAYBANCLAUDE_NO_BROWSER=1)
RAYBANCLAUDE_OPEN_DASHBOARD=0
```

The ElevenLabs key and voice can also be set directly in the dashboard.

## Reset the token

Delete the `.channel-token` file in the folder above and restart Claude – then
scan the QR code again.
