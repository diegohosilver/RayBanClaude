# Contributing

Thanks for helping out! Bugs and ideas are welcome as an [Issue](https://github.com/MoinMornhart/RayBanClaude/issues).

## Development environment

| Part | Tools | Commands |
|---|---|---|
| Channel (`channel/`) | Bun ≥ 1.1 | `bun install` · `bun run typecheck` · `bun test` · `bun audit` |
| Gateway (`server/`) | Node ≥ 20 | `npm ci` · `npm run build` · `npm audit` |
| iPhone app (`ios/`) | macOS, Xcode ≥ 26.4, XcodeGen | `xcodegen generate` · build in Xcode – or just push, GitHub Actions builds the IPA |

Your own signing values belong in `ios/Secrets.xcconfig` (do not commit).

## Rules

- Texts, comments and UI in English.
- TypeScript: no magic numbers, no `for`/`while` loops and no `switch` (data instead of logic),
  every regex with a description, example and regex101 link (see `channel/lib/patterns.ts`).
- Security: no secrets in code, validate input at the boundary (allowlist),
  no internal error details to clients, new routes with the appropriate access level.
- Before a pull request: tests green, `bun audit`/`npm audit` with no findings, short OWASP check in the PR description.

## Reporting bugs

Please include: Windows/macOS version, iPhone and iOS version, glasses model and firmware,
output of the channel server (in the Claude Code terminal or `claude --debug`) and steps to reproduce.
**Do not post tokens or API keys** in issues.
