import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { c } from "./console-theme.js";
import { SERVER_ROOT } from "./env.js";

// ── Skill loader ────────────────────────────────────────────────────
// Looks for SKILL.md files in:
//   1. server/skills (the gateway's own skills)
//   2. ~/.claude/skills
//   3. ~/.claude/plugins (recursive)
//   4. optionally SKILL_PATHS from the .env (separator: path.delimiter,
//      i.e. ";" on Windows and ":" on macOS/Linux; relative paths
//      refer to the server folder)
// The system prompt only contains name + description; Claude loads the full
// content on demand via the local tool "skill_laden".

export interface Skill {
  readonly name: string;
  readonly description: string;
  readonly trigger: string;
  readonly content: string;
  readonly filePath: string;
}

export interface SkillSummary {
  readonly name: string;
  readonly description: string;
  readonly trigger: string;
}

const MAX_SCAN_DEPTH = 8;
const MAX_SKILL_FILES = 500;
const MAX_SKILL_FILE_BYTES = 262_144; // 256 KB
const MAX_DESCRIPTION_LENGTH = 300;
const MAX_NAME_LENGTH = 64;
const FRONTMATTER_FENCE = "---";
const HEADING_MARK = "#";
const ELLIPSIS = "…";
const SKILL_FILE_NAMES: ReadonlySet<string> = new Set(["SKILL.md", "skill.md"]);
const SKIPPED_DIRS: ReadonlySet<string> = new Set(["node_modules", ".git"]);
const BLOCK_SCALAR_MARKERS: ReadonlySet<string> = new Set([">", "|", ">-", "|-", ">+", "|+"]);
const QUOTE_CHARS: ReadonlySet<string> = new Set(['"', "'"]);
const IGNORED_FS_ERRORS: ReadonlySet<string> = new Set(["ENOENT", "ENOTDIR"]);

/** Default search paths (relative to the server folder or home directory). */
export function defaultSkillPaths(): string[] {
  const home = os.homedir();
  const extra = (process.env.SKILL_PATHS ?? "")
    .split(path.delimiter)
    .map((entry) => entry.trim())
    .filter(Boolean)
    .map((entry) => path.resolve(SERVER_ROOT, entry));
  return [
    path.join(SERVER_ROOT, "skills"),
    path.join(home, ".claude", "skills"),
    path.join(home, ".claude", "plugins"),
    ...extra,
  ];
}

function errorCode(err: unknown): string | undefined {
  return err instanceof Error && "code" in err && typeof err.code === "string"
    ? err.code
    : undefined;
}

function readDirSafe(dir: string): fs.Dirent[] {
  try {
    return fs.readdirSync(dir, { withFileTypes: true });
  } catch (err) {
    const code = errorCode(err);
    if (!code || !IGNORED_FS_ERRORS.has(code)) {
      console.warn(c.label("[Skills]") + c.warn(` Folder not readable (${code ?? "?"}): ${dir}`));
    }
    return [];
  }
}

/** Recursively finds all SKILL.md files (symlinks are not followed). */
function findSkillFiles(dir: string, depth: number): string[] {
  if (depth > MAX_SCAN_DEPTH) return [];
  return readDirSafe(dir).flatMap((entry) => {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      return SKIPPED_DIRS.has(entry.name) ? [] : findSkillFiles(fullPath, depth + 1);
    }
    return entry.isFile() && SKILL_FILE_NAMES.has(entry.name) ? [fullPath] : [];
  });
}

// ── Frontmatter parser (minimal, no YAML dependency) ──

interface ParsedSkillFile {
  readonly frontmatter: readonly string[];
  readonly body: string;
}

function splitFrontmatter(raw: string): ParsedSkillFile {
  const lines = raw.split("\n");
  if (lines[0]?.trim() !== FRONTMATTER_FENCE) {
    return { frontmatter: [], body: raw.trim() };
  }
  const end = lines.findIndex((line, index) => index > 0 && line.trim() === FRONTMATTER_FENCE);
  if (end === -1) {
    return { frontmatter: [], body: raw.trim() };
  }
  return { frontmatter: lines.slice(1, end), body: lines.slice(end + 1).join("\n").trim() };
}

function stripQuotes(value: string): string {
  const first = value.charAt(0);
  const isQuoted = QUOTE_CHARS.has(first) && value.length > 1 && value.endsWith(first);
  return isQuoted ? value.slice(1, -1) : value;
}

/** Collects indented continuation lines of a YAML block scalar (">" bzw. "|"). */
function collectIndented(lines: readonly string[]): string {
  const end = lines.findIndex(
    (line) => Boolean(line.trim()) && !line.startsWith(" ") && !line.startsWith("\t")
  );
  const block = end === -1 ? lines : lines.slice(0, end);
  return block.map((line) => line.trim()).filter(Boolean).join(" ");
}

function frontmatterValue(lines: readonly string[], key: string): string {
  const prefix = `${key}:`;
  const index = lines.findIndex((line) => line.toLowerCase().startsWith(prefix));
  if (index === -1) return "";
  const inline = lines[index].slice(prefix.length).trim();
  const value = BLOCK_SCALAR_MARKERS.has(inline) ? collectIndented(lines.slice(index + 1)) : inline;
  // Convert escaped line breaks ("\n" as text) into spaces
  return stripQuotes(value).split("\\n").join(" ").trim();
}

function truncate(text: string, maxLength: number): string {
  return text.length > maxLength ? `${text.slice(0, maxLength - 1)}${ELLIPSIS}` : text;
}

/** First non-empty line of the content, without leading "#". */
function firstLineDescription(body: string): string {
  const firstLine = body.split("\n").find((line) => line.trim()) ?? "";
  const textStart = [...firstLine].findIndex((ch) => ch !== HEADING_MARK);
  return (textStart === -1 ? "" : firstLine.slice(textStart)).trim();
}

function parseSkillFile(filePath: string): Skill | null {
  try {
    if (fs.statSync(filePath).size > MAX_SKILL_FILE_BYTES) {
      console.warn(c.label("[Skills]") + c.warn(` File too large, skipped: ${filePath}`));
      return null;
    }
    // Normalize Windows line endings so the frontmatter parser works
    const raw = fs.readFileSync(filePath, "utf-8").split("\r\n").join("\n");
    const { frontmatter, body } = splitFrontmatter(raw);
    const dirName = path.basename(path.dirname(filePath));
    const name = truncate(frontmatterValue(frontmatter, "name") || dirName, MAX_NAME_LENGTH);
    const description = truncate(
      frontmatterValue(frontmatter, "description") || firstLineDescription(body),
      MAX_DESCRIPTION_LENGTH
    );
    const trigger = frontmatterValue(frontmatter, "trigger") || name;
    return { name, description, trigger, content: body, filePath };
  } catch (err) {
    console.warn(c.label("[Skills]") + c.warn(` Skill not readable: ${filePath}`), err);
    return null;
  }
}

export class SkillLoader {
  private skills = new Map<string, Skill>();
  private readonly searchPaths: readonly string[];

  constructor(searchPaths: readonly string[] = defaultSkillPaths()) {
    this.searchPaths = searchPaths;
  }

  /** Scans all search paths and loads the skills (the first match for a name wins). */
  load(): void {
    console.log(c.label("[Skills]") + " Searching for skills...");

    const allFiles = this.searchPaths.flatMap((searchPath) => findSkillFiles(searchPath, 0));
    if (allFiles.length > MAX_SKILL_FILES) {
      console.warn(
        c.label("[Skills]") +
          c.warn(` ${allFiles.length} skill files found - only the first ${MAX_SKILL_FILES} are loaded.`)
      );
    }

    this.skills = allFiles
      .slice(0, MAX_SKILL_FILES)
      .map(parseSkillFile)
      .filter((skill): skill is Skill => skill !== null)
      .reduce((map, skill) => (map.has(skill.name) ? map : map.set(skill.name, skill)), new Map<string, Skill>());

    if (this.skills.size) {
      const names = [...this.skills.keys()].join(", ");
      console.log(
        c.label("[Skills]") + c.success(` ${this.skills.size} skill(s) loaded: `) + c.dim(names)
      );
    } else {
      console.log(
        c.label("[Skills]") +
          c.dim(" No skills found (place SKILL.md files in server/skills)")
      );
    }
  }

  /** Reloads the skills (e.g. after changes to the files). */
  reload(): void {
    const previousCount = this.skills.size;
    this.load();
    const diff = this.skills.size - previousCount;
    if (diff) {
      console.log(
        c.label("[Skills]") + ` Reloaded: ${diff > 0 ? "+" : ""}${diff} skill(s)`
      );
    }
  }

  getAll(): Skill[] {
    return [...this.skills.values()];
  }

  get(name: string): Skill | undefined {
    return this.skills.get(name);
  }

  /** Section for the system prompt: list of available skills. */
  buildSystemPromptSection(toolName: string): string {
    if (!this.skills.size) return "";
    const lines = [
      "",
      "",
      "AVAILABLE SKILLS:",
      `Detailed instructions exist for the following tasks. If a request matches a skill, load the instructions with the tool "${toolName}" and follow them.`,
      "",
      ...this.getAll().map((skill) => `- ${skill.name}: ${skill.description}`),
    ];
    return lines.join("\n");
  }

  /** Full skill content for the tool "skill_laden". */
  getSkillPrompt(name: string): string | null {
    const skill = this.skills.get(name);
    return skill ? `[SKILL: ${skill.name}]\n${skill.content}\n[/SKILL]` : null;
  }

  get count(): number {
    return this.skills.size;
  }

  /** Overview for the /skills and /health/details endpoints. */
  getSkillList(): SkillSummary[] {
    return this.getAll().map((skill) => ({
      name: skill.name,
      description: skill.description,
      trigger: skill.trigger,
    }));
  }
}
