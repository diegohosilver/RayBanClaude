import type { ServerConfig } from "./types.js";

// ── Input validation ──────────────────────────────────────────────
// Whitelist check of all fields (type, length, format). Error messages are
// neutral; they reveal nothing about internal workings.

export type ValidationResult<TValue> =
  | { readonly ok: true; readonly value: TValue }
  | { readonly ok: false; readonly error: string };

function valid<TValue>(value: TValue): ValidationResult<TValue> {
  return { ok: true, value };
}

function invalid<TValue>(error: string): ValidationResult<TValue> {
  return { ok: false, error };
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** undefined and null count as "field not provided". */
function isAbsent(value: unknown): value is undefined | null {
  return value === undefined || value === null;
}

const NOT_AN_OBJECT = "Invalid request body - a JSON object is expected.";

// ── POST /chat ──

export const MAX_TEXT_LENGTH = 4000;
export const MAX_IMAGES = 4;
/** Base64 length of a 5 MB image (Claude API image limit: 5 × 1024 × 1024 bytes × 4/3) */
export const MAX_IMAGE_BASE64_LENGTH = 6_990_508;
const BASE64_BLOCK_SIZE = 4;
const MAX_CONVERSATION_ID_LENGTH = 64;

// Plain Base64 (standard alphabet, optional 1-2 "=" at the end, no line breaks).
// Accepts "/9j/4AAQSkZJRg==", rejects "abc$def".
// https://regex101.com/?flavor=javascript&regex=%5E%5BA-Za-z0-9%2B%2F%5D%2B%3D%7B0%2C2%7D%24&flags=gm&testString=%2F9j%2F4AAQSkZJRg%3D%3D%0Aabc%24def
const BASE64_PATTERN = /^[A-Za-z0-9+/]+={0,2}$/;

// Conversation ID: 1-64 characters from A-Z, a-z, 0-9, "_" and "-".
// Accepts "a1b2-c3_d4", rejects "abc/def".
// https://regex101.com/?flavor=javascript&regex=%5E%5BA-Za-z0-9_-%5D%7B1%2C64%7D%24&flags=gm&testString=a1b2-c3_d4%0Aabc%2Fdef
const CONVERSATION_ID_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;

export type ImageMediaType = "image/jpeg" | "image/png";

/** Image formats based on the Base64-encoded magic bytes (JPEG: FF D8 FF, PNG: 89 50 4E 47). */
const IMAGE_SIGNATURES: readonly { readonly prefix: string; readonly mediaType: ImageMediaType }[] = [
  { prefix: "/9j/", mediaType: "image/jpeg" },
  { prefix: "iVBOR", mediaType: "image/png" },
];

export interface ValidatedImage {
  readonly mediaType: ImageMediaType;
  readonly data: string;
}

export interface ValidatedChatRequest {
  readonly text: string;
  readonly images: readonly ValidatedImage[];
  readonly conversationId?: string;
}

function validateImage(raw: unknown, index: number): ValidationResult<ValidatedImage> {
  const label = `Image ${index + 1}`;
  if (typeof raw !== "string" || !raw) {
    return invalid(`${label}: Base64 string expected.`);
  }
  if (raw.length > MAX_IMAGE_BASE64_LENGTH) {
    return invalid(`${label} is too large (max. 5 MB).`);
  }
  if (raw.length % BASE64_BLOCK_SIZE || !BASE64_PATTERN.test(raw)) {
    return invalid(`${label}: invalid Base64 encoding.`);
  }
  const signature = IMAGE_SIGNATURES.find((sig) => raw.startsWith(sig.prefix));
  if (!signature) {
    return invalid(`${label}: only JPEG or PNG images are supported.`);
  }
  return valid({ mediaType: signature.mediaType, data: raw });
}

function validateImages(raw: unknown): ValidationResult<readonly ValidatedImage[]> {
  if (isAbsent(raw)) {
    return valid([]);
  }
  if (!Array.isArray(raw)) {
    return invalid("Field 'images' must be an array.");
  }
  if (raw.length > MAX_IMAGES) {
    return invalid(`Too many images (max. ${MAX_IMAGES}).`);
  }
  const results = raw.map((item: unknown, index) => validateImage(item, index));
  const failure = results.find((result) => !result.ok);
  if (failure && !failure.ok) {
    return invalid(failure.error);
  }
  return valid(results.flatMap((result) => (result.ok ? [result.value] : [])));
}

function validateConversationId(raw: unknown): ValidationResult<string | undefined> {
  if (isAbsent(raw)) {
    return valid(undefined);
  }
  if (typeof raw !== "string" || !CONVERSATION_ID_PATTERN.test(raw)) {
    return invalid(
      `Field 'conversation_id' is invalid (max. ${MAX_CONVERSATION_ID_LENGTH} characters, only A-Z, a-z, 0-9, _ and -).`
    );
  }
  return valid(raw);
}

function validateText(raw: unknown): ValidationResult<string> {
  if (isAbsent(raw)) {
    return valid("");
  }
  if (typeof raw !== "string") {
    return invalid("Field 'text' must be a string.");
  }
  if (raw.length > MAX_TEXT_LENGTH) {
    return invalid(`Field 'text' is too long (max. ${MAX_TEXT_LENGTH} characters).`);
  }
  return valid(raw.trim());
}

/** Validates the body of POST /chat. Unknown fields are ignored. */
export function validateChatRequest(body: unknown): ValidationResult<ValidatedChatRequest> {
  if (!isPlainObject(body)) {
    return invalid(NOT_AN_OBJECT);
  }
  const text = validateText(body.text);
  if (!text.ok) return invalid(text.error);

  const images = validateImages(body.images);
  if (!images.ok) return invalid(images.error);

  const conversationId = validateConversationId(body.conversation_id);
  if (!conversationId.ok) return invalid(conversationId.error);

  if (!text.value && !images.value.length) {
    return invalid("Text or image required.");
  }

  return valid({
    text: text.value,
    images: images.value,
    ...(conversationId.value ? { conversationId: conversationId.value } : {}),
  });
}

// ── POST /config ──

export const MAX_SYSTEM_PROMPT_LENGTH = 20_000;
export const MAX_TOKENS_LIMIT = 32_000;

// Model ID: "claude-" followed by 1-60 characters from a-z, 0-9, "." and "-".
// Accepts "claude-opus-5-5", rejects "gpt-4o" and "claude-Opus".
// https://regex101.com/?flavor=javascript&regex=%5Eclaude-%5Ba-z0-9.-%5D%7B1%2C60%7D%24&flags=gm&testString=claude-opus-5-5%0Agpt-4o
export const MODEL_PATTERN = /^claude-[a-z0-9.-]{1,60}$/;

export type ConfigChanges = Partial<Pick<ServerConfig, "systemPrompt" | "model" | "maxTokens">>;

function validateSystemPrompt(raw: unknown): ValidationResult<string | undefined> {
  if (raw === undefined) return valid(undefined);
  if (typeof raw !== "string" || !raw.trim() || raw.length > MAX_SYSTEM_PROMPT_LENGTH) {
    return invalid(
      `Field 'system_prompt' must be a non-empty string with at most ${MAX_SYSTEM_PROMPT_LENGTH} characters.`
    );
  }
  return valid(raw);
}

function validateModel(raw: unknown): ValidationResult<string | undefined> {
  if (raw === undefined) return valid(undefined);
  if (typeof raw !== "string" || !MODEL_PATTERN.test(raw)) {
    return invalid("Field 'model' is invalid (format: claude-…).");
  }
  return valid(raw);
}

function validateMaxTokens(raw: unknown): ValidationResult<number | undefined> {
  if (raw === undefined) return valid(undefined);
  if (typeof raw !== "number" || !Number.isInteger(raw) || raw < 1 || raw > MAX_TOKENS_LIMIT) {
    return invalid(`Field 'max_tokens' must be an integer between 1 and ${MAX_TOKENS_LIMIT}.`);
  }
  return valid(raw);
}

/** Validates the body of POST /config. Unknown fields are ignored. */
export function validateConfigUpdate(body: unknown): ValidationResult<ConfigChanges> {
  if (!isPlainObject(body)) {
    return invalid(NOT_AN_OBJECT);
  }
  const systemPrompt = validateSystemPrompt(body.system_prompt);
  if (!systemPrompt.ok) return invalid(systemPrompt.error);

  const model = validateModel(body.model);
  if (!model.ok) return invalid(model.error);

  const maxTokens = validateMaxTokens(body.max_tokens);
  if (!maxTokens.ok) return invalid(maxTokens.error);

  return valid({
    ...(systemPrompt.value !== undefined ? { systemPrompt: systemPrompt.value } : {}),
    ...(model.value !== undefined ? { model: model.value } : {}),
    ...(maxTokens.value !== undefined ? { maxTokens: maxTokens.value } : {}),
  });
}
