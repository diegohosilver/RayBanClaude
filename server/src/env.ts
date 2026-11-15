// ── Load environment ──────────────────────────────────────────────────
// This module MUST be imported first in index.ts so that the variables
// from the .env are set before other modules read them.

import path from "node:path";
import { fileURLToPath } from "node:url";
import dotenv from "dotenv";

/** Root directory of the server (one level above src/ or dist/). */
export const SERVER_ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  ".."
);

// Load .env from the server folder - independent of the working directory.
// Already-set environment variables take precedence (no override).
// If the file is missing, nothing happens (variables can also be set directly).
dotenv.config({ path: path.join(SERVER_ROOT, ".env"), quiet: true });
