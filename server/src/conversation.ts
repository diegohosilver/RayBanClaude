import { randomUUID } from "node:crypto";
import type { ContentBlockParam, MessageParam } from "./types.js";

// ── Conversation store (in-memory) ───────────────────────────────
// - Camera images are NOT stored in the history; they are replaced by the
//   text block "[Camera image]". Otherwise every turn would send all old
//   images to the API again (token explosion).
// - The history is limited to the last MAX_HISTORY_MESSAGES messages and
//   always starts with a user message (valid API ordering).
// - At most MAX_CONVERSATIONS conversations; the least recently used one
//   is discarded when necessary.

const MS_PER_MINUTE = 60_000;
const CONVERSATION_TTL_MINUTES = 30;
const CLEANUP_INTERVAL_MINUTES = 5;
const DEFAULT_MAX_CONVERSATIONS = 200;
const DEFAULT_MAX_HISTORY_MESSAGES = 40;

export const IMAGE_PLACEHOLDER = "[Camera image]";

interface ConversationEntry {
  readonly messages: readonly MessageParam[];
  readonly lastAccess: number;
}

/** Replaces image blocks with a short placeholder text. */
export function withoutImages(message: MessageParam): MessageParam {
  if (typeof message.content === "string") {
    return message;
  }
  const content = message.content.map(
    (block): ContentBlockParam =>
      block.type === "image" ? { type: "text", text: IMAGE_PLACEHOLDER } : block
  );
  return { ...message, content };
}

/** true for real user input (not for tool_result messages). */
function isUserTurnStart(message: MessageParam): boolean {
  if (message.role !== "user") return false;
  return (
    typeof message.content === "string" ||
    !message.content.some((block) => block.type === "tool_result")
  );
}

/** Trims to the last maxMessages messages, starting at a user message. */
export function trimHistory(
  messages: readonly MessageParam[],
  maxMessages: number
): MessageParam[] {
  const tail = messages.slice(-maxMessages);
  const start = tail.findIndex(isUserTurnStart);
  return start === -1 ? [] : tail.slice(start);
}

export class ConversationStore {
  private readonly store = new Map<string, ConversationEntry>();
  private readonly cleanupTimer: NodeJS.Timeout;
  private readonly ttlMs = CONVERSATION_TTL_MINUTES * MS_PER_MINUTE;

  constructor(
    private readonly maxConversations: number = DEFAULT_MAX_CONVERSATIONS,
    private readonly maxHistoryMessages: number = DEFAULT_MAX_HISTORY_MESSAGES
  ) {
    this.cleanupTimer = setInterval(
      () => this.cleanup(),
      CLEANUP_INTERVAL_MINUTES * MS_PER_MINUTE
    );
    // The timer must not keep the process from exiting
    this.cleanupTimer.unref();
  }

  /** Returns the ID of an existing conversation or creates a new one. */
  resolveId(conversationId?: string): string {
    const id = conversationId ?? randomUUID();
    const existing = this.store.get(id);
    this.put(id, existing?.messages ?? []);
    return id;
  }

  /** Copy of the history (for the next API call). */
  getHistory(id: string): MessageParam[] {
    return [...(this.store.get(id)?.messages ?? [])];
  }

  /** Appends a complete turn (user + assistant). */
  appendTurn(id: string, user: MessageParam, assistant: MessageParam): void {
    const previous = this.store.get(id)?.messages ?? [];
    const next = trimHistory(
      [...previous, withoutImages(user), assistant],
      this.maxHistoryMessages
    );
    this.put(id, next);
  }

  get size(): number {
    return this.store.size;
  }

  destroy(): void {
    clearInterval(this.cleanupTimer);
    this.store.clear();
  }

  /** Stores and marks as most recently used (Map order = LRU). */
  private put(id: string, messages: readonly MessageParam[]): void {
    this.store.delete(id);
    if (this.store.size >= this.maxConversations) {
      const oldest = this.store.keys().next().value;
      if (oldest !== undefined) {
        this.store.delete(oldest);
      }
    }
    this.store.set(id, { messages, lastAccess: Date.now() });
  }

  private cleanup(): void {
    const now = Date.now();
    [...this.store]
      .filter(([, entry]) => now - entry.lastAccess > this.ttlMs)
      .forEach(([id]) => this.store.delete(id));
  }
}
