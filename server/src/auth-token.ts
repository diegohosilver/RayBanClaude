import { randomBytes } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { c } from "./console-theme.js";

// ── Gateway token ───────────────────────────────────────────────────
// The token is ALWAYS required, because the server is reachable across the whole Wi-Fi.
// Source 1: GATEWAY_API_KEY from the .env.
// Source 2: automatically generated token in ~/.raybanclaude/gateway-token
//           (32 random bytes, hex), created on first start and
//           reused afterwards.

const TOKEN_BYTES = 32;
const TOKEN_DIR_NAME = ".raybanclaude";
const TOKEN_FILE_NAME = "gateway-token";
const TOKEN_DIR_MODE = 0o700;
const TOKEN_FILE_MODE = 0o600;
const ERROR_CODE_NOT_FOUND = "ENOENT";

// Self-set token: 16-256 characters from A-Z, a-z, 0-9 and ._~+/=-
// Accepts "testtoken1234567890", rejects "kurz" and tokens containing spaces.
// https://regex101.com/?flavor=javascript&regex=%5E%5BA-Za-z0-9._~%2B%2F%3D-%5D%7B16%2C256%7D%24&flags=gm&testString=testtoken1234567890%0Akurz
const ENV_TOKEN_PATTERN = /^[A-Za-z0-9._~+/=-]{16,256}$/;

// Automatically generated token: exactly 64 lowercase hex characters.
// Accepts "aaaa…" (64× a), rejects "XYZ".
// https://regex101.com/?flavor=javascript&regex=%5E%5Ba-f0-9%5D%7B64%7D%24&flags=gm&testString=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa%0AXYZ
const FILE_TOKEN_PATTERN = /^[a-f0-9]{64}$/;

export type TokenSource = "env" | "file";

export interface GatewayToken {
  readonly value: string;
  readonly source: TokenSource;
  readonly filePath?: string;
}

/** Error in the token configuration (aborts startup). */
export class TokenConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "TokenConfigError";
  }
}

function isErrnoException(err: unknown): err is NodeJS.ErrnoException {
  return err instanceof Error && "code" in err;
}

/** Reads a stored token; null if none (valid) exists. */
function readStoredToken(filePath: string): string | null {
  try {
    const content = fs.readFileSync(filePath, "utf8").trim();
    if (FILE_TOKEN_PATTERN.test(content)) {
      return content;
    }
    console.warn(
      c.label("[Auth]") +
        c.warn(" Stored gateway token has an invalid format - a new one will be generated.")
    );
    return null;
  } catch (err) {
    if (isErrnoException(err) && err.code === ERROR_CODE_NOT_FOUND) {
      return null;
    }
    throw err;
  }
}

/** Sets the file permissions to 0600 (on Windows, the user profile's ACL protects it). */
function restrictPermissions(filePath: string): void {
  try {
    fs.chmodSync(filePath, TOKEN_FILE_MODE);
  } catch (err) {
    console.warn(
      c.label("[Auth]") + c.warn(" Could not set file permissions on the token file:"),
      err
    );
  }
}

/** Generates a new random token and saves it with permissions 0600. */
function createStoredToken(dir: string, filePath: string): string {
  const token = randomBytes(TOKEN_BYTES).toString("hex");
  fs.mkdirSync(dir, { recursive: true, mode: TOKEN_DIR_MODE });
  fs.writeFileSync(filePath, `${token}\n`, { encoding: "utf8", mode: TOKEN_FILE_MODE });
  // mode only takes effect when the file is created - set it explicitly when overwriting
  restrictPermissions(filePath);
  console.log(c.label("[Auth]") + c.success(" New gateway token generated and saved."));
  return token;
}

/** Resolves the gateway token (from .env or token file, otherwise newly generated). */
export function resolveGatewayToken(): GatewayToken {
  const fromEnv = process.env.GATEWAY_API_KEY?.trim();
  if (fromEnv) {
    if (!ENV_TOKEN_PATTERN.test(fromEnv)) {
      throw new TokenConfigError(
        "GATEWAY_API_KEY is invalid: 16-256 characters; allowed are A-Z, a-z, 0-9 and ._~+/=-"
      );
    }
    return { value: fromEnv, source: "env" };
  }

  const dir = path.join(os.homedir(), TOKEN_DIR_NAME);
  const filePath = path.join(dir, TOKEN_FILE_NAME);
  const stored = readStoredToken(filePath);
  if (stored) {
    restrictPermissions(filePath);
    return { value: stored, source: "file", filePath };
  }
  return { value: createStoredToken(dir, filePath), source: "file", filePath };
}
