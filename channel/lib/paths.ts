/**
 * Storage locations in the PC's user folder (shared by the channel and the Claude app bridge).
 */

import { homedir } from 'os'
import { join } from 'path'
import { SERVER_NAME } from './constants.ts'

export const STATE_DIR = join(homedir(), '.claude', 'channels', SERVER_NAME)
/** Conversation history of the glasses – one Markdown file per day */
export const HISTORY_DIR = join(STATE_DIR, 'verlauf')
/** Copy of the memory list (the iPhone app remains the source of truth) */
export const MEMORY_FILE = join(STATE_DIR, 'gedaechtnis.json')
/** Facts queued by the Claude app – the glasses pick them up the next time they connect */
export const PENDING_MEMORY_FILE = join(STATE_DIR, 'gedaechtnis-neu.json')
