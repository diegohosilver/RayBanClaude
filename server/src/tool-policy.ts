import type { DiscoveredTool } from "./types.js";

// ── Allowlist for MCP tools ─────────────────────────────────
// In gateway mode there is no confirmation per tool call. Text in a
// camera image could trick Claude into actions with external effects
// (prompt injection) - so Claude only gets approved tools.
//
// MCP_TOOL_ALLOWLIST (comma-separated):
//   (empty)            → only tools with MCP annotation readOnlyHint = true
//   *                 → all tools (enable deliberately)
//   readonly          → all tools marked as "read-only"
//   tool              → one tool by its name
//   server/tool       → one tool of a specific server
//   server/*          → all tools of a server

export interface ToolPolicy {
  readonly allows: (tool: DiscoveredTool) => boolean;
  readonly description: string;
}

const ENTRY_SEPARATOR = ",";
const SERVER_SEPARATOR = "/";
const ALL_TOOLS = "*";
const READ_ONLY_KEYWORD = "readonly";

const READ_ONLY_POLICY: ToolPolicy = {
  allows: (tool) => tool.readOnly,
  description: "read-only tools (default; enable more with MCP_TOOL_ALLOWLIST)",
};

const ALLOW_ALL_POLICY: ToolPolicy = {
  allows: () => true,
  description: "all tools (MCP_TOOL_ALLOWLIST=*) - warning: no confirmation before actions",
};

export function parseToolPolicy(raw: string | undefined): ToolPolicy {
  const entries = (raw ?? "")
    .split(ENTRY_SEPARATOR)
    .map((entry) => entry.trim())
    .filter(Boolean);

  if (!entries.length) return READ_ONLY_POLICY;
  if (entries.includes(ALL_TOOLS)) return ALLOW_ALL_POLICY;

  const rules: ReadonlySet<string> = new Set(entries);
  const includeReadOnly = rules.has(READ_ONLY_KEYWORD);
  return {
    allows: (tool) =>
      (includeReadOnly && tool.readOnly) ||
      rules.has(tool.name) ||
      rules.has(`${tool.serverName}${SERVER_SEPARATOR}${tool.name}`) ||
      rules.has(`${tool.serverName}${SERVER_SEPARATOR}${ALL_TOOLS}`),
    description: `Allowlist: ${entries.join(", ")}`,
  };
}
