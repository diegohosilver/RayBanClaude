import type Anthropic from "@anthropic-ai/sdk";

// ── Chat-API (contract with the iOS app - do not change) ──

export interface ChatRequest {
  text: string;
  images?: string[]; // Base64-encoded JPEG/PNG images
  conversation_id?: string;
}

export interface ToolCallResult {
  name: string;
  result: unknown;
}

export interface ChatResponse {
  text: string;
  tool_calls: ToolCallResult[];
  conversation_id: string;
}

// ── Config-API ──

export interface ConfigUpdate {
  system_prompt?: string;
  model?: string;
  max_tokens?: number;
}

/** Allowed effort levels of the Claude API (output_config.effort). */
export const EFFORT_LEVELS = ["low", "medium", "high", "xhigh", "max"] as const;
export type Effort = (typeof EFFORT_LEVELS)[number];

export interface ServerConfig {
  systemPrompt: string;
  model: string;
  maxTokens: number;
  /** null = do not send the parameter (e.g. for older models without effort support) */
  effort: Effort | null;
}

// ── MCP ──

export interface MCPServerConfig {
  // Local stdio server
  command?: string;
  args?: string[];
  env?: Record<string, string>;
  // Remote HTTP/SSE server
  url?: string;
  headers?: Record<string, string>;
}

export interface DiscoveredTool {
  serverName: string;
  name: string;
  description?: string;
  inputSchema: Record<string, unknown>;
  /** Server marks the tool as "read-only" (MCP annotation readOnlyHint) */
  readOnly: boolean;
}

// ── Conversation ──
// The SDK's beta interface is used (because of server-side
// fallbacks on refusals), hence the beta types.

export type MessageParam = Anthropic.Beta.BetaMessageParam;
export type ContentBlockParam = Anthropic.Beta.BetaContentBlockParam;
export type ContentBlock = Anthropic.Beta.BetaContentBlock;
export type ToolUseBlock = Anthropic.Beta.BetaToolUseBlock;
export type ToolResultBlockParam = Anthropic.Beta.BetaToolResultBlockParam;
export type Tool = Anthropic.Beta.BetaTool;
