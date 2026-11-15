/**
 * Conversation history of the glasses: one Markdown file per day in the PC's user folder.
 *
 * This lets Claude remember later what you talked about through the glasses – in the
 * Claude desktop app via the `brille_verlauf` tool. Days older than
 * HISTORY_DAYS are deleted automatically. The history never leaves the PC.
 */

import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync, unlinkSync } from 'fs'
import { join } from 'path'
import {
  HISTORY_DAYS, MAX_HISTORY_ENTRY_CHARS, MAX_HISTORY_READ_CHARS, MS_PER_DAY, PRIVATE_FILE_MODE,
} from './constants.ts'
import { ISO_DATE, LINE_BREAK } from './patterns.ts'
import { cleanText } from './validate.ts'

export type Speaker = 'du' | 'claude'

const SPEAKER_LABEL: Readonly<Record<Speaker, string>> = { du: 'You', claude: 'Claude' }
const FILE_SUFFIX = '.md'
/** Swedish date format = YYYY-MM-DD in local time */
const DAY_LOCALE = 'sv-SE'

export function dayStamp(date: Date): string {
  return date.toLocaleDateString(DAY_LOCALE)
}

function timeStamp(date: Date): string {
  return date.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })
}

/** Append a line to the day's history (line breaks become spaces). */
export function appendHistory(dir: string, speaker: Speaker, raw: string, note = '', now: Date = new Date()): void {
  const text = cleanText(raw, MAX_HISTORY_ENTRY_CHARS).split(LINE_BREAK).join(' ')
  if (!text) return
  mkdirSync(dir, { recursive: true })
  const day = dayStamp(now)
  const file = join(dir, `${day}${FILE_SUFFIX}`)
  const header = existsSync(file) ? '' : `# Conversations via the glasses – ${day}\n\n`
  appendFileSync(file, `${header}- ${timeStamp(now)} **${SPEAKER_LABEL[speaker]}:** ${text}${note}\n`, { mode: PRIVATE_FILE_MODE })
}

/** Days with history, oldest first */
function historyDays(dir: string): string[] {
  if (!existsSync(dir)) return []
  return readdirSync(dir)
    .filter(name => name.endsWith(FILE_SUFFIX) && ISO_DATE.test(name.slice(0, -FILE_SUFFIX.length)))
    .map(name => name.slice(0, -FILE_SUFFIX.length))
    .sort()
}

/** Delete days older than HISTORY_DAYS. */
export function pruneHistory(dir: string, now: Date = new Date()): number {
  const oldest = dayStamp(new Date(now.getTime() - HISTORY_DAYS * MS_PER_DAY))
  const expired = historyDays(dir).filter(day => day < oldest)
  expired.forEach(day => unlinkSync(join(dir, `${day}${FILE_SUFFIX}`)))
  return expired.length
}

/**
 * History of the last `days` days, optionally only lines containing the search term.
 * If it gets too long, the newest entries are kept.
 */
export function readHistory(dir: string, days: number, query = ''): string {
  const needle = query.trim().toLocaleLowerCase('de-DE')
  const text = historyDays(dir)
    .slice(-days)
    .map(day => readFileSync(join(dir, `${day}${FILE_SUFFIX}`), 'utf8'))
    .map(content => needle ? filterLines(content, needle) : content)
    .filter(Boolean)
    .join('\n')
  return text.length > MAX_HISTORY_READ_CHARS ? `…\n${text.slice(-MAX_HISTORY_READ_CHARS)}` : text
}

function filterLines(content: string, needle: string): string {
  const lines = content.split(LINE_BREAK)
  const heading = lines.find(line => line.startsWith('# ')) ?? ''
  const hits = lines.filter(line => line.toLocaleLowerCase('de-DE').includes(needle))
  return hits.length ? [heading, ...hits].join('\n') : ''
}
