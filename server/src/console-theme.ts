// ── Console theme "RayBan Claude" ─────────────────────────────────
// Colored terminal output. Colors are disabled when NO_COLOR is set
// or the output does not go to a terminal (e.g. a log file).

const useColor = !process.env.NO_COLOR && process.stdout.isTTY === true;

function ansi(code: string): string {
  return useColor ? code : "";
}

const ORANGE = ansi("\x1b[38;2;255;149;0m");
const DARK_ORANGE = ansi("\x1b[38;2;204;119;0m");
const LIGHT_ORANGE = ansi("\x1b[38;2;255;183;77m");
const WHITE = ansi("\x1b[1;37m");
const GRAY = ansi("\x1b[90m");
const GREEN = ansi("\x1b[32m");
const RED = ansi("\x1b[31m");
const YELLOW = ansi("\x1b[33m");
const CYAN = ansi("\x1b[36m");
const DIM = ansi("\x1b[2m");
const BOLD = ansi("\x1b[1m");
const RESET = ansi("\x1b[0m");

export const c = {
  orange: (text: string) => `${ORANGE}${text}${RESET}`,
  darkOrange: (text: string) => `${DARK_ORANGE}${text}${RESET}`,
  lightOrange: (text: string) => `${LIGHT_ORANGE}${text}${RESET}`,
  white: (text: string) => `${WHITE}${text}${RESET}`,
  gray: (text: string) => `${GRAY}${text}${RESET}`,
  green: (text: string) => `${GREEN}${text}${RESET}`,
  red: (text: string) => `${RED}${text}${RESET}`,
  yellow: (text: string) => `${YELLOW}${text}${RESET}`,
  cyan: (text: string) => `${CYAN}${text}${RESET}`,
  dim: (text: string) => `${DIM}${text}${RESET}`,
  bold: (text: string) => `${BOLD}${text}${RESET}`,

  // Semantic helpers
  success: (text: string) => `${GREEN}${text}${RESET}`,
  error: (text: string) => `${RED}${text}${RESET}`,
  warn: (text: string) => `${YELLOW}${text}${RESET}`,
  info: (text: string) => `${CYAN}${text}${RESET}`,
  label: (text: string) => `${ORANGE}${text}${RESET}`,
  value: (text: string) => `${LIGHT_ORANGE}${text}${RESET}`,
  url: (text: string) => `${CYAN}${text}${RESET}`,
};

export function showBanner(): void {
  const lines = [
    "",
    `${ORANGE}   ██████╗  █████╗ ██╗   ██╗██████╗  █████╗ ███╗   ██╗${RESET}`,
    `${ORANGE}   ██╔══██╗██╔══██╗╚██╗ ██╔╝██╔══██╗██╔══██╗████╗  ██║${RESET}`,
    `${DARK_ORANGE}   ██████╔╝███████║ ╚████╔╝ ██████╔╝███████║██╔██╗ ██║${RESET}`,
    `${DARK_ORANGE}   ██╔══██╗██╔══██║  ╚██╔╝  ██╔══██╗██╔══██║██║╚██╗██║${RESET}`,
    `${LIGHT_ORANGE}   ██║  ██║██║  ██║   ██║   ██████╔╝██║  ██║██║ ╚████║${RESET}`,
    `${LIGHT_ORANGE}   ╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝   ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═══╝${RESET}`,
    "",
    `${ORANGE}    ██████╗██╗      █████╗ ██╗   ██╗██████╗ ███████╗${RESET}`,
    `${ORANGE}   ██╔════╝██║     ██╔══██╗██║   ██║██╔══██╗██╔════╝${RESET}`,
    `${DARK_ORANGE}   ██║     ██║     ███████║██║   ██║██║  ██║█████╗  ${RESET}`,
    `${DARK_ORANGE}   ██║     ██║     ██╔══██║██║   ██║██║  ██║██╔══╝  ${RESET}`,
    `${LIGHT_ORANGE}   ╚██████╗███████╗██║  ██║╚██████╔╝██████╔╝███████╗${RESET}`,
    `${LIGHT_ORANGE}    ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝${RESET}`,
    "",
    `${GRAY}   ──────────────────────────────────────────────────────${RESET}`,
    `${WHITE}    Claude sees the world through your glasses${RESET}`,
    `${GRAY}   ──────────────────────────────────────────────────────${RESET}`,
    `${DIM}    Unofficial project - not affiliated with Meta, Ray-Ban or${RESET}`,
    `${DIM}    Anthropic. Fork of visionclaude.${RESET}`,
    "",
  ];

  lines.forEach((line) => console.log(line));
}

// ── Info box after startup ──

const BOX_INNER_WIDTH = 50;

/** Visible length of a string (without ANSI color codes). */
function visibleLength(text: string): number {
  // Strips ANSI color codes: "\x1b[32mOK\x1b[0m" → "OK"; "OK" stays unchanged.
  // https://regex101.com/?flavor=javascript&regex=%5Cx1b%5C%5B%5B0-9%3B%5D*m&flags=g&testString=%1B%5B32mOK%1B%5B0m%0AOK
  // eslint-disable-next-line no-control-regex
  return text.replace(/\x1b\[[0-9;]*m/g, "").length;
}

function boxLine(content: string): string {
  const pad = Math.max(0, BOX_INNER_WIDTH - visibleLength(content));
  return `${ORANGE}   │${RESET} ${content}${" ".repeat(pad)}${ORANGE}│${RESET}`;
}

function boxRule(left: string, right: string): string {
  return `${ORANGE}   ${left}${"─".repeat(BOX_INNER_WIDTH + 1)}${right}${RESET}`;
}

export interface ServerInfo {
  port: number;
  model: string;
  mcpCount: number;
  toolCount: number;
  skillCount: number;
  lanAddresses: string[];
}

export function showServerInfo(info: ServerInfo): void {
  console.log("");
  console.log(boxRule("┌", "┐"));
  console.log(boxLine(`${GREEN}●${RESET} ${WHITE}Gateway active${RESET}`));
  console.log(boxRule("├", "┤"));
  console.log(boxLine(`${GRAY}Port${RESET}     ${WHITE}${info.port}${RESET}`));
  console.log(boxLine(`${GRAY}Model${RESET}   ${WHITE}${info.model}${RESET}`));
  console.log(
    boxLine(
      `${GRAY}MCP${RESET}      ${WHITE}${info.mcpCount} server(s)${RESET} ${GRAY}→${RESET} ${LIGHT_ORANGE}${info.toolCount} tool(s)${RESET}`
    )
  );
  console.log(boxLine(`${GRAY}Skills${RESET}   ${WHITE}${info.skillCount} loaded${RESET}`));
  info.lanAddresses.forEach((addr) =>
    console.log(boxLine(`${GRAY}Address${RESET}  ${CYAN}http://${addr}:${info.port}${RESET}`))
  );
  console.log(boxRule("├", "┤"));
  console.log(boxLine(`${CYAN}GET  /health${RESET}          ${DIM}Status (public)${RESET}`));
  console.log(boxLine(`${CYAN}GET  /health/details${RESET}  ${DIM}Details (token)${RESET}`));
  console.log(boxLine(`${CYAN}GET  /tools${RESET}           ${DIM}MCP tools${RESET}`));
  console.log(boxLine(`${CYAN}GET  /skills${RESET}          ${DIM}Loaded skills${RESET}`));
  console.log(boxLine(`${CYAN}POST /chat${RESET}            ${DIM}Message + image${RESET}`));
  console.log(boxRule("└", "┘"));
  console.log(c.dim("   All endpoints except GET /health require the gateway token."));
  console.log("");
}

/** Prints the gateway token so it can be entered in the app. */
export function showToken(token: string, source: "env" | "file", filePath?: string): void {
  if (source === "env") {
    console.log(
      c.label("[Auth]") + " Gateway token comes from GATEWAY_API_KEY (environment or .env) - value is not shown."
    );
    return;
  }
  console.log(c.label("[Auth]") + " Gateway token (enter it in the app under Settings):");
  console.log(`         ${BOLD}${LIGHT_ORANGE}${token}${RESET}`);
  if (filePath) {
    console.log(c.dim(`         saved in ${filePath}`));
  }
}
