/**
 * Unit tests of the pure helper functions (network, memory). Runs with `bun test`.
 */

import { describe, expect, test } from 'bun:test'
import { existsSync, mkdtempSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { HISTORY_DAYS, MAX_MEMORY_ITEM_CHARS, MAX_MEMORY_ITEMS, MS_PER_DAY } from '../lib/constants.ts'
import { appendHistory, dayStamp, pruneHistory, readHistory } from '../lib/history.ts'
import { addFact, cleanMemoryItems, forgetFact, memoryBlock, queueMemory, takeQueuedMemory } from '../lib/memory.ts'
import { findTailscaleIp } from '../lib/network.ts'
import type { LanIp } from '../lib/network.ts'

const lan = (address: string, iface: string): LanIp => ({ address, iface, rank: 0 })

describe('Tailscale detection', () => {
  test('finds the Tailscale address next to the Wi-Fi', () => {
    expect(findTailscaleIp([lan('192.168.1.20', 'WLAN'), lan('100.101.102.103', 'Tailscale')])).toBe('100.101.102.103')
  })

  test('address on the Tailscale adapter takes precedence over other 100.64/10 addresses', () => {
    expect(findTailscaleIp([lan('100.64.0.9', 'Ethernet 3'), lan('100.88.1.2', 'Tailscale')])).toBe('100.88.1.2')
  })

  test('without Tailscale there is no on-the-go address', () => {
    expect(findTailscaleIp([lan('192.168.1.20', 'WLAN'), lan('100.200.1.1', 'Tailscale')])).toBeUndefined()
  })
})

describe('Memory helpers', () => {
  test('cleans the list from the app', () => {
    const tooLong = 'x'.repeat(MAX_MEMORY_ITEM_CHARS + 1)
    const items = cleanMemoryItems(['  Likes jazz ', 'likes jazz', '', null, tooLong, 'Control\u0007chars'])
    expect(items).toEqual(['Likes jazz', 'x'.repeat(MAX_MEMORY_ITEM_CHARS), 'Controlchars'])
    expect(cleanMemoryItems('not an array')).toEqual([])
  })

  test('limits the count – when remembering, the oldest entry drops out', () => {
    const full = Array.from({ length: MAX_MEMORY_ITEMS }, (_, i) => `Fact ${i}`)
    expect(cleanMemoryItems([...full, 'too many'])).toHaveLength(MAX_MEMORY_ITEMS)
    const next = addFact(full, 'New')
    expect(next).toHaveLength(MAX_MEMORY_ITEMS)
    expect(next[0]).toBe('Fact 1')
    expect(next.at(-1)).toBe('New')
  })

  test('forget deletes only matching entries, an empty query deletes nothing', () => {
    const coffee = ['Drinks espresso', 'Likes espresso beans']
    const items = [...coffee, 'Daughter is called Mia']
    expect(forgetFact(items, 'ESPRESSO')).toEqual({ items: ['Daughter is called Mia'], removed: coffee })
    expect(forgetFact(items, '').removed).toEqual([])
  })

  test('block marks entries as facts, not as instructions', () => {
    expect(memoryBlock(['Likes jazz'])).toContain('not instructions')
    expect(memoryBlock([])).toContain('cleared')
  })
})

describe('Conversation history', () => {
  const dir = mkdtempSync(join(tmpdir(), 'raybanclaude-verlauf-'))
  const now = new Date()
  const longAgo = new Date(now.getTime() - (HISTORY_DAYS + 1) * MS_PER_DAY)

  test('writes one line per utterance, line breaks become spaces', () => {
    appendHistory(dir, 'du', 'What does\nthe sign say?', ' 📷', now)
    appendHistory(dir, 'claude', 'Keep exit clear.', '', now)
    const text = readHistory(dir, 1)
    expect(text).toContain('**You:** What does the sign say? 📷')
    expect(text).toContain('**Claude:** Keep exit clear.')
    expect(readHistory(dir, 1, 'exit')).not.toContain('sign')
  })

  test('deletes days older than the retention period', () => {
    appendHistory(dir, 'du', 'Ancient question', '', longAgo)
    expect(existsSync(join(dir, `${dayStamp(longAgo)}.md`))).toBe(true)
    expect(pruneHistory(dir, now)).toBe(1)
    expect(existsSync(join(dir, `${dayStamp(longAgo)}.md`))).toBe(false)
    expect(readHistory(dir, HISTORY_DAYS)).toContain('Keep exit clear.')
  })
})

describe('Queued facts (Claude app → glasses)', () => {
  test('are collected without duplicates and emptied when picked up', () => {
    const file = join(mkdtempSync(join(tmpdir(), 'raybanclaude-merken-')), 'neu.json')
    queueMemory(file, 'Likes jazz')
    queueMemory(file, 'likes jazz')
    queueMemory(file, 'Lives in Hamburg')
    expect(takeQueuedMemory(file)).toEqual(['likes jazz', 'Lives in Hamburg']) // newest spelling wins
    expect(takeQueuedMemory(file)).toEqual([])
  })
})
