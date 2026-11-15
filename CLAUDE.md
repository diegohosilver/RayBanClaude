Read the project status first: @STAND.md

# RayBan Claude – Notes for Claude Code

- Language: replies, code comments, UI texts and docs in **English**.
- Git texts: commit messages end with the line `Written with Claude 🤖` (before the Co-Authored-By);
  the README has the line as its footer. No update function is planned.
- Repo: public, https://github.com/MoinMornhart/RayBanClaude
- TypeScript (`channel/`, `server/`): follow the rules of the *typescript-patterns-enforcer* plugin
  (no magic numbers, no loops/`switch`, every regex with an example + regex101 link).
  The channel's regexes live in `channel/lib/patterns.ts`.
- Tests: `cd channel && bun test` · `cd server && npm run build` · iOS builds in GitHub Actions (`ios-build.yml`).
- The MCP SDK in the channel stays on `~1.32` – newer versions might negotiate protocol 2026-07-28,
  which Claude Code does not register as a channel.
- Security: no secrets in code (`.env`, `ios/Secrets.xcconfig`), validate input via allowlist,
  no internal error details to clients.
