import { timingSafeEqual } from "node:crypto";
import type { NextFunction, Request, RequestHandler, Response } from "express";
import { c } from "./console-theme.js";
import {
  HTTP_TOO_MANY_REQUESTS,
  HTTP_UNAUTHORIZED,
  sendError,
} from "./http.js";

const MS_PER_SECOND = 1000;
const MS_PER_MINUTE = 60_000;
const MAX_LOGGED_PATH_LENGTH = 120;
const UNKNOWN_IP = "unknown";

// ── Security headers ─────────────────────────────────────────────────
// The server only serves JSON to the iOS app or curl.
// HTTPS/HSTS is not possible in local Wi-Fi operation (http://<host>:18790);
// HSTS only makes sense behind a TLS proxy and is therefore only set
// when the request actually came in over TLS (req.secure).

const HSTS_VALUE = "max-age=31536000; includeSubDomains";

export function securityHeaders(): RequestHandler {
  return (req: Request, res: Response, next: NextFunction): void => {
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.setHeader("Referrer-Policy", "no-referrer");
    res.setHeader("X-Frame-Options", "DENY");
    res.setHeader("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'");
    res.setHeader("Cache-Control", "no-store");
    res.setHeader("Cross-Origin-Resource-Policy", "same-origin");
    if (req.secure) {
      res.setHeader("Strict-Transport-Security", HSTS_VALUE);
    }
    next();
  };
}

// ── Helper functions ─────────────────────────────────────────────────

/**
 * IP of the client. "trust proxy" is deliberately NOT enabled - X-Forwarded-For
 * is ignored so attackers cannot spoof their IP to evade the block.
 */
function clientIp(req: Request): string {
  return req.ip ?? req.socket.remoteAddress ?? UNKNOWN_IP;
}

/** Path for logs: truncated and as a JSON string (prevents log injection). */
function loggablePath(req: Request): string {
  return JSON.stringify(req.path.slice(0, MAX_LOGGED_PATH_LENGTH));
}

// ── Brute-force protection ──────────────────────────────────────────────
// Counts failed auth attempts per IP. After FAILURE_LIMIT failures
// within FAILURE_WINDOW, the IP is blocked for BLOCK_DURATION (429).

const FAILURE_LIMIT = 10;
const FAILURE_WINDOW_MINUTES = 15;
const BLOCK_DURATION_MINUTES = 15;
const CLEANUP_INTERVAL_MINUTES = 5;
const MAX_TRACKED_IPS = 10_000;

interface FailureEntry {
  readonly failures: readonly number[]; // timestamps of the failed attempts
  readonly blockedUntil: number;
}

export class AuthFailureTracker {
  private readonly entries = new Map<string, FailureEntry>();
  private readonly cleanupTimer: NodeJS.Timeout;
  private readonly windowMs = FAILURE_WINDOW_MINUTES * MS_PER_MINUTE;
  private readonly blockMs = BLOCK_DURATION_MINUTES * MS_PER_MINUTE;

  constructor() {
    this.cleanupTimer = setInterval(
      () => this.cleanup(Date.now()),
      CLEANUP_INTERVAL_MINUTES * MS_PER_MINUTE
    );
    // The timer must not keep the process from exiting
    this.cleanupTimer.unref();
  }

  /** Remaining block time in ms (0 = not blocked). */
  blockedRemainingMs(ip: string, now: number): number {
    const entry = this.entries.get(ip);
    return entry && entry.blockedUntil > now ? entry.blockedUntil - now : 0;
  }

  /** Records a failed attempt; true if the IP was blocked as a result. */
  recordFailure(ip: string, now: number): boolean {
    const previous = this.entries.get(ip);
    const recent = (previous?.failures ?? []).filter((t) => now - t < this.windowMs);
    const failures = [...recent, now];
    const blocked = failures.length >= FAILURE_LIMIT;
    if (!previous) {
      this.ensureCapacity(now);
    }
    this.entries.set(ip, {
      failures: blocked ? [] : failures,
      blockedUntil: blocked ? now + this.blockMs : previous?.blockedUntil ?? 0,
    });
    return blocked;
  }

  /** A successful login resets the counter. */
  recordSuccess(ip: string): void {
    this.entries.delete(ip);
  }

  destroy(): void {
    clearInterval(this.cleanupTimer);
    this.entries.clear();
  }

  private cleanup(now: number): void {
    [...this.entries]
      .filter(
        ([, entry]) =>
          entry.blockedUntil <= now &&
          entry.failures.every((t) => now - t >= this.windowMs)
      )
      .forEach(([ip]) => this.entries.delete(ip));
  }

  /** Limits memory usage: discard the oldest entry if necessary. */
  private ensureCapacity(now: number): void {
    if (this.entries.size < MAX_TRACKED_IPS) return;
    this.cleanup(now);
    if (this.entries.size < MAX_TRACKED_IPS) return;
    const oldest = this.entries.keys().next().value;
    if (oldest !== undefined) {
      this.entries.delete(oldest);
    }
  }
}

// ── Gateway auth ────────────────────────────────────────────────────
// A token is required for all endpoints except GET/HEAD /health.
// Accepted: "Authorization: Bearer <token>" and "X-Gateway-Key: <token>".

const PUBLIC_PATHS: ReadonlySet<string> = new Set(["/health", "/health/"]);
const PUBLIC_METHODS: ReadonlySet<string> = new Set(["GET", "HEAD"]);
const BEARER_PREFIX = "bearer ";
const MAX_TOKEN_LENGTH = 512;

function isPublicRequest(req: Request): boolean {
  return PUBLIC_METHODS.has(req.method) && PUBLIC_PATHS.has(req.path);
}

function singleHeader(req: Request, name: string): string | undefined {
  const value = req.headers[name];
  return typeof value === "string" ? value : undefined;
}

/** Reads all token candidates sent by the client from the headers. */
function extractTokens(req: Request): string[] {
  const authorization = singleHeader(req, "authorization");
  const hasBearer =
    authorization !== undefined &&
    authorization.slice(0, BEARER_PREFIX.length).toLowerCase() === BEARER_PREFIX;
  const bearer = hasBearer ? authorization.slice(BEARER_PREFIX.length).trim() : undefined;
  const gatewayKey = singleHeader(req, "x-gateway-key")?.trim();
  return [bearer, gatewayKey].filter(
    (token): token is string => Boolean(token) && (token?.length ?? 0) <= MAX_TOKEN_LENGTH
  );
}

/** Constant-time comparison (lengths are checked beforehand). */
function tokenMatches(candidate: string, expected: Buffer): boolean {
  const given = Buffer.from(candidate, "utf8");
  if (given.length !== expected.length) {
    // Run a comparison anyway so the runtime reveals nothing
    timingSafeEqual(expected, expected);
    return false;
  }
  return timingSafeEqual(given, expected);
}

export function gatewayAuth(token: string, tracker: AuthFailureTracker): RequestHandler {
  const expected = Buffer.from(token, "utf8");

  return (req: Request, res: Response, next: NextFunction): void => {
    if (isPublicRequest(req)) {
      next();
      return;
    }

    const ip = clientIp(req);
    const now = Date.now();
    const blockedMs = tracker.blockedRemainingMs(ip, now);
    if (blockedMs) {
      res.setHeader("Retry-After", String(Math.ceil(blockedMs / MS_PER_SECOND)));
      sendError(
        res,
        HTTP_TOO_MANY_REQUESTS,
        "Too many failed login attempts - please try again later."
      );
      return;
    }

    if (extractTokens(req).some((candidate) => tokenMatches(candidate, expected))) {
      tracker.recordSuccess(ip);
      next();
      return;
    }

    const nowBlocked = tracker.recordFailure(ip, now);
    const blockNote = nowBlocked ? ` - IP blocked for ${BLOCK_DURATION_MINUTES} minutes` : "";
    console.warn(
      c.label("[Auth]") +
        c.warn(` Rejected: ${req.method} ${loggablePath(req)} from ${ip}${blockNote}`)
    );
    sendError(res, HTTP_UNAUTHORIZED, "Unauthorized - valid gateway token required.");
  };
}

// ── Rate limiter ────────────────────────────────────────────────────
// Limits requests per IP and time window (applies after successful auth).

const DEFAULT_RATE_LIMIT = 30;

interface RateLimitEntry {
  readonly count: number;
  readonly resetAt: number;
}

export interface RateLimiter {
  readonly middleware: RequestHandler;
  readonly destroy: () => void;
}

export function rateLimiter(
  maxRequests: number = DEFAULT_RATE_LIMIT,
  windowMs: number = MS_PER_MINUTE
): RateLimiter {
  const clients = new Map<string, RateLimitEntry>();

  // Remove expired entries regularly
  const cleanupTimer = setInterval(() => {
    const now = Date.now();
    [...clients]
      .filter(([, entry]) => now > entry.resetAt)
      .forEach(([ip]) => clients.delete(ip));
  }, windowMs);
  cleanupTimer.unref();

  const middleware = (req: Request, res: Response, next: NextFunction): void => {
    if (isPublicRequest(req)) {
      next();
      return;
    }

    const ip = clientIp(req);
    const now = Date.now();
    const current = clients.get(ip);
    const entry: RateLimitEntry =
      !current || now > current.resetAt
        ? { count: 1, resetAt: now + windowMs }
        : { count: current.count + 1, resetAt: current.resetAt };
    clients.set(ip, entry);

    res.setHeader("X-RateLimit-Limit", maxRequests);
    res.setHeader("X-RateLimit-Remaining", Math.max(0, maxRequests - entry.count));
    res.setHeader("X-RateLimit-Reset", Math.ceil(entry.resetAt / MS_PER_SECOND));

    if (entry.count > maxRequests) {
      console.warn(c.label("[RateLimit]") + c.warn(` ${ip} exceeded the limit`));
      res.setHeader("Retry-After", String(Math.ceil((entry.resetAt - now) / MS_PER_SECOND)));
      sendError(res, HTTP_TOO_MANY_REQUESTS, "Too many requests - please wait a moment.");
      return;
    }

    next();
  };

  return {
    middleware,
    destroy: () => {
      clearInterval(cleanupTimer);
      clients.clear();
    },
  };
}

// ── Request queue ───────────────────────────────────────────
// Limits concurrent Claude API calls and the queue length so that
// under overload the server quickly answers with 503 instead of piling up.

const DEFAULT_MAX_CONCURRENT = 2;
const DEFAULT_MAX_QUEUED = 10;

/** The queue is full - request is rejected. */
export class QueueFullError extends Error {
  constructor() {
    super("Request queue is full");
    this.name = "QueueFullError";
  }
}

export class RequestQueue {
  private readonly queue: Array<() => Promise<void>> = [];
  private activeCount = 0;

  constructor(
    private readonly maxConcurrent: number = DEFAULT_MAX_CONCURRENT,
    private readonly maxQueued: number = DEFAULT_MAX_QUEUED
  ) {}

  async enqueue<TResult>(task: () => Promise<TResult>): Promise<TResult> {
    if (this.queue.length >= this.maxQueued) {
      throw new QueueFullError();
    }
    return new Promise<TResult>((resolve, reject) => {
      this.queue.push(async () => {
        try {
          resolve(await task());
        } catch (err) {
          reject(err);
        }
      });
      this.drain();
    });
  }

  get pending(): number {
    return this.queue.length;
  }

  get active(): number {
    return this.activeCount;
  }

  private drain(): void {
    if (this.activeCount >= this.maxConcurrent) return;
    const next = this.queue.shift();
    if (!next) return;
    this.activeCount++;
    void this.run(next);
  }

  private async run(job: () => Promise<void>): Promise<void> {
    try {
      await job();
    } finally {
      this.activeCount--;
      this.drain();
    }
  }
}
