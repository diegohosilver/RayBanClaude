import fs from "node:fs";
import { readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { SSEClientTransport } from "@modelcontextprotocol/sdk/client/sse.js";
import {
  getDefaultEnvironment,
  StdioClientTransport,
} from "@modelcontextprotocol/sdk/client/stdio.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { c } from "./console-theme.js";
import type { ToolPolicy } from "./tool-policy.js";
import type { DiscoveredTool, MCPServerConfig, Tool } from "./types.js";

// ── MCP manager ─────────────────────────────────────────────────────
// Connects to MCP servers (local via stdio or remote via
// StreamableHTTP/SSE) and makes their tools available to Claude.
//
// Configuration source:
//   - MCP_CONFIG_PATH set → only this file
//   - otherwise the operating system's Claude Desktop configuration

const CLIENT_INFO = { name: "raybanclaude-gateway", version: "1.1.0" } as const;
const DESKTOP_CONFIG_FILE = "claude_desktop_config.json";
const ALLOWED_URL_PROTOCOLS: ReadonlySet<string> = new Set(["http:", "https:"]);
const MSIX_PACKAGE_PREFIX = "Claude_";

// Valid tool names of the Claude API: 1-64 characters from a-z, A-Z, 0-9, "_" and "-".
// Accepts "read_file", rejects "server.read file".
// https://regex101.com/?flavor=javascript&regex=%5E%5Ba-zA-Z0-9_-%5D%7B1%2C64%7D%24&flags=gm&testString=read_file%0Aserver.read%20file
const TOOL_NAME_PATTERN = /^[a-zA-Z0-9_-]{1,64}$/;

type ServerType = "stdio" | "remote";

interface ConnectedServer {
  readonly name: string;
  readonly client: Client;
  readonly tools: readonly DiscoveredTool[];
  readonly type: ServerType;
}

export interface ServerStatus {
  readonly name: string;
  readonly toolCount: number;
  readonly type: ServerType;
}

// ── Configuration ──

/** Possible paths of the Claude Desktop configuration depending on the operating system. */
function desktopConfigCandidates(): string[] {
  const home = os.homedir();
  const byPlatform: Partial<Record<NodeJS.Platform, () => string[]>> = {
    darwin: () => [path.join(home, "Library", "Application Support", "Claude", DESKTOP_CONFIG_FILE)],
    win32: () => {
      const appData = process.env.APPDATA ?? path.join(home, "AppData", "Roaming");
      const localAppData = process.env.LOCALAPPDATA ?? path.join(home, "AppData", "Local");
      const packagesDir = path.join(localAppData, "Packages");
      // Claude from the Microsoft Store (MSIX) stores its data virtualized
      const msixConfigs = safeReadDir(packagesDir)
        .filter((entry) => entry.startsWith(MSIX_PACKAGE_PREFIX))
        .map((entry) =>
          path.join(packagesDir, entry, "LocalCache", "Roaming", "Claude", DESKTOP_CONFIG_FILE)
        );
      return [path.join(appData, "Claude", DESKTOP_CONFIG_FILE), ...msixConfigs];
    },
  };
  const linux = (): string[] => [
    path.join(process.env.XDG_CONFIG_HOME ?? path.join(home, ".config"), "Claude", DESKTOP_CONFIG_FILE),
  ];
  return (byPlatform[process.platform] ?? linux)();
}

function safeReadDir(dir: string): string[] {
  try {
    return fs.readdirSync(dir);
  } catch {
    // Folder does not exist (e.g. no Store installation) - not an error
    return [];
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isStringRecord(value: unknown): value is Record<string, string> {
  return isRecord(value) && Object.values(value).every((v) => typeof v === "string");
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((v) => typeof v === "string");
}

/** Returns a URL without query/fragment for the log (tokens are often found there). */
function loggableUrl(url: URL): string {
  return `${url.origin}${url.pathname}`;
}

/** Validates a server entry from the configuration file (whitelist of fields). */
function parseServerConfig(name: string, raw: unknown): MCPServerConfig | null {
  const reject = (reason: string): null => {
    console.warn(c.label("[MCP]") + c.warn(` Server "${name}" skipped: ${reason}`));
    return null;
  };
  if (!isRecord(raw)) return reject("entry is not an object");
  if (raw.env !== undefined && !isStringRecord(raw.env)) return reject("'env' must contain strings");
  if (raw.headers !== undefined && !isStringRecord(raw.headers)) return reject("'headers' must contain strings");
  if (raw.args !== undefined && !isStringArray(raw.args)) return reject("'args' must be a string array");

  if (typeof raw.url === "string" && raw.url) {
    const parsed = URL.canParse(raw.url) ? new URL(raw.url) : null;
    if (!parsed || !ALLOWED_URL_PROTOCOLS.has(parsed.protocol)) {
      return reject("'url' must be an http(s) URL");
    }
    return { url: raw.url, headers: raw.headers };
  }
  if (typeof raw.command === "string" && raw.command.trim()) {
    return { command: raw.command, args: raw.args, env: raw.env };
  }
  return reject("neither 'command' nor 'url' specified");
}

async function readConfigFile(filePath: string): Promise<Record<string, MCPServerConfig>> {
  const parsed: unknown = JSON.parse(await readFile(filePath, "utf-8"));
  const servers = isRecord(parsed) && isRecord(parsed.mcpServers) ? parsed.mcpServers : {};
  return Object.fromEntries(
    Object.entries(servers).flatMap(([name, raw]) => {
      const config = parseServerConfig(name, raw);
      return config ? [[name, config] as const] : [];
    })
  );
}

// ── Tool results ──

export class MCPToolError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "MCPToolError";
  }
}

export class MCPManager {
  private readonly servers = new Map<string, ConnectedServer>();
  private readonly toolToServer = new Map<string, string>(); // tool name → server name

  /**
   * @param policy Allowlist - only approved tools reach Claude
   * @param reservedToolNames Names that are reserved locally (e.g. "skill_laden")
   */
  constructor(
    private readonly policy: ToolPolicy,
    private readonly reservedToolNames: ReadonlySet<string> = new Set()
  ) {}

  async initialize(): Promise<void> {
    const config = await this.loadConfig();
    const entries = Object.entries(config);

    if (!entries.length) {
      console.log(c.label("[MCP]") + c.dim(" No MCP servers configured"));
      return;
    }

    console.log(c.label("[MCP]") + ` Connecting to ${entries.length} server(s)...`);

    const results = await Promise.allSettled(
      entries.map(([name, cfg]) => this.connectServer(name, cfg))
    );

    // Register in configuration order → deterministic tool list
    results.forEach((result, index) => {
      const name = entries[index][0];
      if (result.status === "fulfilled") {
        this.register(result.value);
      } else {
        console.error(
          c.label("[MCP]") + c.error(` Connection to "${name}" failed: `),
          result.reason
        );
      }
    });

    console.log(
      c.label("[MCP]") +
        c.success(
          ` ${this.servers.size}/${entries.length} server(s) connected, ${this.toolToServer.size} tool(s) available`
        )
    );
  }

  private async loadConfig(): Promise<Record<string, MCPServerConfig>> {
    const explicitPath = process.env.MCP_CONFIG_PATH?.trim();
    const candidates = explicitPath ? [path.resolve(explicitPath)] : desktopConfigCandidates();
    const found = candidates.find((candidate) => fs.existsSync(candidate));

    if (!found) {
      const hint = explicitPath
        ? ` MCP_CONFIG_PATH does not point to an existing file: ${explicitPath}`
        : " No Claude Desktop configuration found";
      console.log(c.label("[MCP]") + c.dim(hint));
      return {};
    }

    try {
      const servers = await readConfigFile(found);
      console.log(c.label("[MCP]") + ` Configuration loaded: ${found}`);
      return servers;
    } catch (err) {
      console.error(c.label("[MCP]") + c.error(` Configuration not readable: ${found}`), err);
      return {};
    }
  }

  private async connectServer(name: string, config: MCPServerConfig): Promise<ConnectedServer> {
    const isRemote = Boolean(config.url);
    const client = isRemote
      ? await this.connectRemoteServer(name, config)
      : await this.connectStdioServer(config);

    const toolsResponse = await client.listTools();
    const tools: DiscoveredTool[] = (toolsResponse.tools ?? []).map((tool) => ({
      serverName: name,
      name: tool.name,
      description: tool.description,
      inputSchema: tool.inputSchema,
      readOnly: tool.annotations?.readOnlyHint === true,
    }));

    const typeLabel = isRemote ? c.cyan("[remote]") : c.dim("[local]");
    console.log(
      c.label("[MCP]") +
        ` "${name}" ${typeLabel} connected - ${tools.length} tool(s): ${tools.map((t) => t.name).join(", ")}`
    );
    return { name, client, tools, type: isRemote ? "remote" : "stdio" };
  }

  /**
   * Registers the tools of a server. Invalid names, unapproved
   * tools (allowlist) and name collisions are reported and skipped.
   */
  private register(server: ConnectedServer): void {
    const blocked = server.tools.filter((tool) => !this.policy.allows(tool)).map((tool) => tool.name);
    if (blocked.length) {
      console.log(
        c.label("[MCP]") +
          c.dim(` "${server.name}": ${blocked.length} tool(s) blocked (${blocked.join(", ")}) - enable with MCP_TOOL_ALLOWLIST`)
      );
    }
    const accepted = server.tools.filter((tool) => {
      if (!this.policy.allows(tool)) return false;
      if (!TOOL_NAME_PATTERN.test(tool.name)) {
        console.warn(
          c.label("[MCP]") +
            c.warn(` Tool "${tool.name}" from "${server.name}" has an invalid name - ignored.`)
        );
        return false;
      }
      const owner = this.reservedToolNames.has(tool.name) ? "Gateway (local)" : this.toolToServer.get(tool.name);
      if (owner) {
        console.warn(
          c.label("[MCP]") +
            c.warn(
              ` Name collision: tool "${tool.name}" from "${server.name}" is already taken by "${owner}" - ignored.`
            )
        );
        return false;
      }
      this.toolToServer.set(tool.name, server.name);
      return true;
    });
    this.servers.set(server.name, { ...server, tools: accepted });
  }

  private async connectRemoteServer(name: string, config: MCPServerConfig): Promise<Client> {
    const url = new URL(config.url ?? "");
    const requestInit = { headers: { ...(config.headers ?? {}) } };

    // StreamableHTTP first (newer protocol), then SSE as fallback
    try {
      console.log(c.label("[MCP]") + c.dim(` "${name}" trying StreamableHTTP → ${loggableUrl(url)}`));
      const client = new Client(CLIENT_INFO, { capabilities: {} });
      await client.connect(new StreamableHTTPClientTransport(url, { requestInit }));
      console.log(c.label("[MCP]") + c.success(` "${name}" connected via StreamableHTTP`));
      return client;
    } catch (httpErr) {
      console.log(
        c.label("[MCP]") + c.dim(` "${name}" StreamableHTTP failed, trying SSE...`),
        httpErr instanceof Error ? httpErr.message : httpErr
      );
      const client = new Client(CLIENT_INFO, { capabilities: {} });
      await client.connect(new SSEClientTransport(url, { requestInit }));
      console.log(c.label("[MCP]") + c.success(` "${name}" connected via SSE`));
      return client;
    }
  }

  private async connectStdioServer(config: MCPServerConfig): Promise<Client> {
    const client = new Client(CLIENT_INFO, { capabilities: {} });
    const transport = new StdioClientTransport({
      command: config.command ?? "",
      args: config.args,
      // Only the safe default environment + explicitly configured variables -
      // ANTHROPIC_API_KEY and GATEWAY_API_KEY must not go to foreign processes.
      env: { ...getDefaultEnvironment(), ...(config.env ?? {}) },
    });
    await client.connect(transport);
    return client;
  }

  /** Calls an MCP tool. Errors are thrown as MCPToolError. */
  async invokeTool(toolName: string, args: Record<string, unknown>): Promise<unknown> {
    // Only registered (i.e. approved) tools can be called
    const serverName = this.toolToServer.get(toolName);
    const server = serverName ? this.servers.get(serverName) : undefined;
    if (!serverName || !server) {
      throw new MCPToolError(`Unknown or unapproved tool: ${toolName}`);
    }

    console.log(c.label("[MCP]") + ` Calling ${c.value(toolName)} on "${serverName}"...`);
    return server.client.callTool({ name: toolName, arguments: args });
  }

  /** Tool definitions in Claude API format (without duplicates). */
  getToolsForClaude(): Tool[] {
    return this.getAllDiscoveredTools().map((tool) => ({
      name: tool.name,
      description: tool.description ?? "",
      // MCP guarantees a JSON schema of type "object" - matches input_schema
      input_schema: tool.inputSchema as Tool["input_schema"],
    }));
  }

  getAllDiscoveredTools(): DiscoveredTool[] {
    return [...this.servers.values()].flatMap((server) => [...server.tools]);
  }

  getServerNames(): string[] {
    return [...this.servers.keys()];
  }

  getServerStatus(): ServerStatus[] {
    return [...this.servers.values()].map((server) => ({
      name: server.name,
      toolCount: server.tools.length,
      type: server.type,
    }));
  }

  async healthCheck(): Promise<{ healthy: string[]; unhealthy: string[] }> {
    const checks = await Promise.allSettled(
      [...this.servers.values()].map(async (server) => {
        await server.client.listTools();
        return server.name;
      })
    );
    const names = [...this.servers.keys()];
    return {
      healthy: names.filter((_, index) => checks[index].status === "fulfilled"),
      unhealthy: names.filter((_, index) => checks[index].status === "rejected"),
    };
  }

  async shutdown(): Promise<void> {
    console.log(c.label("[MCP]") + " Disconnecting all servers...");
    const servers = [...this.servers.values()];
    const results = await Promise.allSettled(servers.map((server) => server.client.close()));
    results.forEach((result, index) => {
      const name = servers[index].name;
      if (result.status === "fulfilled") {
        console.log(c.label("[MCP]") + c.dim(` "${name}" disconnected`));
      } else {
        console.error(c.label("[MCP]") + c.error(` Error disconnecting "${name}":`), result.reason);
      }
    });
    this.servers.clear();
    this.toolToServer.clear();
  }
}
