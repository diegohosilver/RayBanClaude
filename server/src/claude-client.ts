import Anthropic from "@anthropic-ai/sdk";
import { c } from "./console-theme.js";
import type { MCPManager } from "./mcp-manager.js";
import { QueueFullError } from "./middleware.js";
import type { SkillLoader } from "./skill-loader.js";
import {
  HTTP_INTERNAL_ERROR,
  HTTP_SERVICE_UNAVAILABLE,
} from "./http.js";
import type {
  ContentBlock,
  ContentBlockParam,
  MessageParam,
  ServerConfig,
  Tool,
  ToolCallResult,
  ToolResultBlockParam,
  ToolUseBlock,
} from "./types.js";
import type { ValidatedImage } from "./validation.js";

// ── Claude client ───────────────────────────────────────────────────
// - Uses the beta Messages API to enable server-side fallbacks on
//   refusals by safety classifiers
//   (fallbacks: "default" - models without fallback support simply
//   run without them).
// - Thinking is not set: current models think adaptively; the
//   thinking depth (and thus the voice latency) is controlled by output_config.effort.
// - System prompt and tools stay unchanged within a turn,
//   messages are only appended (prompt cache, valid thinking blocks).

const MAX_TOOL_ITERATIONS = 10;
const API_TIMEOUT_MS = 120_000;
const MAX_TOOL_RESULT_CHARS = 50_000;
const FALLBACK_BETA = "server-side-fallback-2026-07-01";
export const SKILL_TOOL_NAME = "skill_laden";

const REFUSAL_TEXT = "Sorry, I can't help with that.";
const EMPTY_RESPONSE_TEXT = "I couldn't come up with an answer to that right now.";
const MAX_ITERATIONS_TEXT =
  "I used several tools but didn't reach a result. Please try a simpler request.";
const TRUNCATION_NOTE = "\n[… output truncated]";

/** What the app sees when a tool fails (without internal details). */
const TOOL_ERROR_FOR_CLIENT = { error: "Tool call failed." } as const;

export interface ChatTurnResult {
  readonly responseText: string;
  readonly toolCalls: readonly ToolCallResult[];
  /** true if the request was refused - do not store such turns */
  readonly refused: boolean;
}

interface ToolOutcome {
  readonly clientCall: ToolCallResult;
  readonly resultBlock: ToolResultBlockParam;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function truncate(text: string): string {
  return text.length > MAX_TOOL_RESULT_CHARS
    ? `${text.slice(0, MAX_TOOL_RESULT_CHARS)}${TRUNCATION_NOTE}`
    : text;
}

/** Converts an MCP CallToolResult into text for the tool_result block. */
function toolResultText(result: unknown): string {
  if (isRecord(result) && Array.isArray(result.content)) {
    const parts = result.content.map((item: unknown) => {
      if (isRecord(item) && item.type === "text" && typeof item.text === "string") {
        return item.text;
      }
      const type = isRecord(item) && typeof item.type === "string" ? item.type : "unknown";
      return `[Content of type ${type} - cannot be displayed as text]`;
    });
    return truncate(parts.join("\n"));
  }
  return truncate(JSON.stringify(result) ?? "");
}

function extractText(content: readonly ContentBlock[]): string {
  return content
    .flatMap((block) => (block.type === "text" ? [block.text] : []))
    .join("\n")
    .trim();
}

/** Builds the user message: images first, then text. */
export function buildUserMessage(text: string, images: readonly ValidatedImage[]): MessageParam {
  const imageBlocks: ContentBlockParam[] = images.map((image) => ({
    type: "image",
    source: { type: "base64", media_type: image.mediaType, data: image.data },
  }));
  const textBlocks: ContentBlockParam[] = text ? [{ type: "text", text }] : [];
  return { role: "user", content: [...imageBlocks, ...textBlocks] };
}

// ── Error mapping for the app client ──

export interface ClientFacingError {
  readonly status: number;
  readonly message: string;
}

const BUSY_ERROR: ClientFacingError = {
  status: HTTP_SERVICE_UNAVAILABLE,
  message: "The service is currently busy - please try again shortly.",
};
const UNREACHABLE_ERROR: ClientFacingError = {
  status: HTTP_SERVICE_UNAVAILABLE,
  message: "The AI is currently unreachable - please try again later.",
};
const GENERIC_ERROR: ClientFacingError = {
  status: HTTP_INTERNAL_ERROR,
  message: "The request could not be processed.",
};

/** Order: most specific class first (APIConnectionError inherits from APIError). */
const ERROR_RULES: readonly (readonly [(err: unknown) => boolean, ClientFacingError])[] = [
  [(err) => err instanceof QueueFullError, BUSY_ERROR],
  [(err) => err instanceof Anthropic.APIConnectionError, UNREACHABLE_ERROR],
  [(err) => err instanceof Anthropic.RateLimitError, BUSY_ERROR],
  [(err) => err instanceof Anthropic.InternalServerError, UNREACHABLE_ERROR],
];

/** Neutral message + status for the client; details only go to the log. */
export function describeChatError(err: unknown): ClientFacingError {
  if (err instanceof Anthropic.AuthenticationError || err instanceof Anthropic.PermissionDeniedError) {
    console.error(
      c.label("[Claude]") +
        c.error(" The Claude API rejects the API key - check ANTHROPIC_API_KEY in the .env.")
    );
  }
  return ERROR_RULES.find(([test]) => test(err))?.[1] ?? GENERIC_ERROR;
}

// ── Client ──

export class ClaudeClient {
  private readonly anthropic: Anthropic;
  private config: ServerConfig;

  constructor(
    private readonly mcpManager: MCPManager,
    private readonly skillLoader: SkillLoader,
    config: ServerConfig
  ) {
    // The key comes from ANTHROPIC_API_KEY (environment/.env), never from the code
    this.anthropic = new Anthropic({ timeout: API_TIMEOUT_MS });
    this.config = { ...config };
  }

  updateConfig(updates: Partial<ServerConfig>): void {
    this.config = { ...this.config, ...updates };
  }

  getConfig(): ServerConfig {
    return { ...this.config };
  }

  /** Runs a chat turn (including the tool loop). */
  async chat(
    history: readonly MessageParam[],
    text: string,
    images: readonly ValidatedImage[]
  ): Promise<ChatTurnResult> {
    // Snapshot: changes via /config take effect from the next turn
    const config = this.getConfig();
    const tools = this.collectTools();
    const messages = [...history, buildUserMessage(text, images)];
    return this.runLoop(messages, config, tools, [], 0);
  }

  private collectTools(): Tool[] {
    const skillTool: Tool[] = this.skillLoader.count
      ? [
          {
            name: SKILL_TOOL_NAME,
            description:
              "Loads the full instructions of an available skill (see the list in the system prompt). Call before applying a skill.",
            input_schema: {
              type: "object",
              properties: {
                name: { type: "string", description: "Name of the skill, exactly as in the list" },
              },
              required: ["name"],
              additionalProperties: false,
            },
          },
        ]
      : [];
    return [...skillTool, ...this.mcpManager.getToolsForClaude()];
  }

  private async runLoop(
    messages: readonly MessageParam[],
    config: ServerConfig,
    tools: readonly Tool[],
    toolCalls: readonly ToolCallResult[],
    iteration: number
  ): Promise<ChatTurnResult> {
    if (iteration >= MAX_TOOL_ITERATIONS) {
      console.warn(c.label("[Claude]") + c.warn(" Maximum number of tool rounds reached."));
      return { responseText: MAX_ITERATIONS_TEXT, toolCalls, refused: false };
    }

    const response = await this.anthropic.beta.messages.create({
      model: config.model,
      max_tokens: config.maxTokens,
      // Stable prefix (tools + system prompt) is cached
      system: [{ type: "text", text: config.systemPrompt, cache_control: { type: "ephemeral" } }],
      messages: [...messages],
      ...(tools.length ? { tools: [...tools] } : {}),
      ...(config.effort ? { output_config: { effort: config.effort } } : {}),
      fallbacks: "default",
      betas: [FALLBACK_BETA],
    });

    // Always check for refusal BEFORE reading the content
    if (response.stop_reason === "refusal") {
      console.warn(
        c.label("[Claude]") +
          c.warn(` Request refused (category: ${response.stop_details?.category ?? "unknown"})`)
      );
      return { responseText: REFUSAL_TEXT, toolCalls, refused: true };
    }

    const toolUses = response.content.filter(
      (block): block is ToolUseBlock => block.type === "tool_use"
    );

    if (response.stop_reason !== "tool_use" || !toolUses.length) {
      if (response.stop_reason === "max_tokens") {
        console.warn(c.label("[Claude]") + c.warn(" Response truncated due to max_tokens."));
      }
      const responseText = extractText(response.content) || EMPTY_RESPONSE_TEXT;
      return { responseText, toolCalls, refused: false };
    }

    // Run parallel tool calls concurrently; all results in ONE message
    const outcomes = await Promise.all(toolUses.map((toolUse) => this.executeTool(toolUse)));
    const nextMessages: MessageParam[] = [
      ...messages,
      { role: "assistant", content: response.content },
      { role: "user", content: outcomes.map((outcome) => outcome.resultBlock) },
    ];
    return this.runLoop(
      nextMessages,
      config,
      tools,
      [...toolCalls, ...outcomes.map((outcome) => outcome.clientCall)],
      iteration + 1
    );
  }

  private async executeTool(toolUse: ToolUseBlock): Promise<ToolOutcome> {
    console.log(c.label("[Claude]") + ` Tool call: ${toolUse.name}`);
    const input = isRecord(toolUse.input) ? toolUse.input : {};

    if (toolUse.name === SKILL_TOOL_NAME) {
      return this.loadSkill(toolUse, input);
    }

    try {
      const result = await this.mcpManager.invokeTool(toolUse.name, input);
      const isError = isRecord(result) && result.isError === true;
      return {
        clientCall: { name: toolUse.name, result: isError ? TOOL_ERROR_FOR_CLIENT : result },
        resultBlock: {
          type: "tool_result",
          tool_use_id: toolUse.id,
          content: toolResultText(result),
          ...(isError ? { is_error: true } : {}),
        },
      };
    } catch (err) {
      // Claude may see the error text (for self-correction), the app may not
      const message = err instanceof Error ? err.message : String(err);
      console.error(c.label("[Claude]") + c.error(` Tool error (${toolUse.name}):`), message);
      return {
        clientCall: { name: toolUse.name, result: TOOL_ERROR_FOR_CLIENT },
        resultBlock: {
          type: "tool_result",
          tool_use_id: toolUse.id,
          content: `Error during tool call: ${message}`,
          is_error: true,
        },
      };
    }
  }

  private loadSkill(toolUse: ToolUseBlock, input: Record<string, unknown>): ToolOutcome {
    const name = typeof input.name === "string" ? input.name : "";
    const prompt = this.skillLoader.getSkillPrompt(name);
    return {
      clientCall: { name: toolUse.name, result: { skill: name, gefunden: prompt !== null } },
      resultBlock: {
        type: "tool_result",
        tool_use_id: toolUse.id,
        content: prompt ? truncate(prompt) : `Skill "${name}" does not exist.`,
        ...(prompt ? {} : { is_error: true }),
      },
    };
  }
}
