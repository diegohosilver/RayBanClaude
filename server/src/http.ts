import type { Response } from "express";

// ── HTTP status codes and neutral error responses ───────────────────
// Clients only get neutral messages - no stack traces,
// SDK error texts, paths or versions. Details belong in the log.

export const HTTP_BAD_REQUEST = 400;
export const HTTP_UNAUTHORIZED = 401;
export const HTTP_NOT_FOUND = 404;
export const HTTP_PAYLOAD_TOO_LARGE = 413;
export const HTTP_UNSUPPORTED_MEDIA_TYPE = 415;
export const HTTP_TOO_MANY_REQUESTS = 429;
export const HTTP_INTERNAL_ERROR = 500;
export const HTTP_SERVICE_UNAVAILABLE = 503;

/** Sends a JSON error response with a neutral message. */
export function sendError(res: Response, status: number, message: string): void {
  res.status(status).json({ error: message });
}
