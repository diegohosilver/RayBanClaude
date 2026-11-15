#!/usr/bin/env bun
/**
 * Links RayBan Claude to the Claude desktop app on this PC (or removes the link).
 *
 *   bun link-desktop.ts           → registers the bridge (bridge.ts) in claude_desktop_config.json
 *   bun link-desktop.ts --remove  → removes it again
 *
 * Then restart the Claude app once. Supports the regular Windows installation,
 * the Microsoft Store version, as well as macOS and Linux. Before the first change a
 * backup copy of the configuration is created.
 */

import { copyFileSync, existsSync, readdirSync, readFileSync, writeFileSync } from 'fs'
import { homedir, platform } from 'os'
import { join } from 'path'
import { JSON_INDENT } from './lib/constants.ts'

const SERVER_KEY = 'raybanclaude-brille'
const CONFIG_NAME = 'claude_desktop_config.json'
const BACKUP_SUFFIX = '.vor-raybanclaude'
const STORE_PREFIX = 'Claude_'
const remove = process.argv.includes('--remove')

type Config = Record<string, unknown> & { mcpServers?: Record<string, unknown> }

/** Claude desktop app folders per operating system (only those that actually exist) */
function configDirs(): string[] {
  const home = homedir()
  const appData = process.env.APPDATA ?? join(home, 'AppData', 'Roaming')
  const localAppData = process.env.LOCALAPPDATA ?? join(home, 'AppData', 'Local')
  const packages = join(localAppData, 'Packages')
  const storeDirs = platform() === 'win32' && existsSync(packages)
    ? readdirSync(packages).filter(name => name.startsWith(STORE_PREFIX))
      .map(name => join(packages, name, 'LocalCache', 'Roaming', 'Claude'))
    : []
  const byPlatform: Readonly<Partial<Record<NodeJS.Platform, string[]>>> = {
    win32: [join(appData, 'Claude'), ...storeDirs],
    darwin: [join(home, 'Library', 'Application Support', 'Claude')],
    linux: [join(home, '.config', 'Claude')],
  }
  return (byPlatform[platform()] ?? []).filter(dir => existsSync(dir))
}

function readConfig(file: string): Config {
  if (!existsSync(file)) return {}
  const parsed: unknown = JSON.parse(readFileSync(file, 'utf8'))
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error(`${file} is not a JSON object`)
  return parsed as Config // checked: plain object
}

function update(dir: string): string {
  const file = join(dir, CONFIG_NAME)
  const config = readConfig(file)
  const servers: Record<string, unknown> = { ...(config.mcpServers ?? {}) }
  if (remove) {
    delete servers[SERVER_KEY]
  } else {
    // Bun with full path – the Claude app does not know the command line's PATH
    servers[SERVER_KEY] = { command: process.execPath, args: [join(import.meta.dir, 'bridge.ts')] }
  }
  if (existsSync(file) && !existsSync(file + BACKUP_SUFFIX)) copyFileSync(file, file + BACKUP_SUFFIX)
  writeFileSync(file, JSON.stringify({ ...config, mcpServers: servers }, null, JSON_INDENT) + '\n')
  return file
}

const dirs = configDirs()
if (!dirs.length) {
  console.log('Claude desktop app not found – skipping the link (later: claude.ai/download, then run setup.cmd again).')
  process.exit(0)
}
try {
  const files = dirs.map(update)
  console.log(remove
    ? `Link to the Claude app removed (${files.length} configuration(s)).`
    : `Linked to the Claude app (${files.length} configuration(s)). Restart the Claude app once – then it will know the “Brille” (glasses) tool.`)
} catch (e) {
  console.error(`Linking failed: ${e instanceof Error ? e.message : String(e)}`)
  process.exit(1)
}
