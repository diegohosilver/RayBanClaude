#!/usr/bin/env bash
# chat-sichern.sh - saves the chat transcript of the Claude Code session into the project repo.
# Runs as a PreToolUse hook on Bash (.claude/settings.json): as soon as Claude
# runs "git push", chats/<date>_<session>.md is written and
# committed first. That way the chat is on GitHub even if the cloud session is wiped.
#
# Disable per project: create the file .claude/hooks/chat-sichern-aus (e.g. for public repos).
# Trigger manually:      bash .claude/hooks/chat-sichern.sh --jetzt
# Never aborts, never blocks the push.

EINGABE="$(cat 2>/dev/null || true)"
export EINGABE
export JETZT="${1:-}"

python3 - <<'PY' 2>>"${HOME}/.claude/chat-sichern.log" || true
import json, os, re, subprocess, glob, datetime

roh = os.environ.get("EINGABE", "")
try:
    daten = json.loads(roh) if roh.strip() else {}
except Exception:
    daten = {}

von_hand = os.environ.get("JETZT") == "--jetzt"
befehl = (daten.get("tool_input") or {}).get("command", "")
if not von_hand and not re.search(r"\bgit\b[^\n;&|]*\bpush\b", befehl):
    raise SystemExit(0)

projekt = os.environ.get("CLAUDE_PROJECT_DIR") or daten.get("cwd") or os.getcwd()
try:
    projekt = subprocess.run(["git", "-C", projekt, "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, check=True).stdout.strip()
except Exception:
    raise SystemExit(0)
if os.path.exists(os.path.join(projekt, ".claude", "hooks", "chat-sichern-aus")):
    raise SystemExit(0)

verlauf = daten.get("transcript_path")
if not verlauf or not os.path.exists(verlauf):
    kandidaten = sorted(glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")),
                        key=os.path.getmtime, reverse=True)
    verlauf = kandidaten[0] if kandidaten else None
if not verlauf:
    raise SystemExit(0)
sitzung = (daten.get("session_id") or os.path.splitext(os.path.basename(verlauf))[0])[:8]

GEHEIM = [
    (re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}"), "[TOKEN REMOVED]"),
    (re.compile(r"github_pat_[A-Za-z0-9_]{20,}"), "[TOKEN REMOVED]"),
    (re.compile(r"sk-[A-Za-z0-9_-]{20,}"), "[KEY REMOVED]"),
    (re.compile(r"xox[abpr]-[A-Za-z0-9-]{10,}"), "[TOKEN REMOVED]"),
    (re.compile(r"[MN][A-Za-z\d]{23,25}\.[\w-]{6}\.[\w-]{27,}"), "[DISCORD TOKEN REMOVED]"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.S), "[PRIVATE KEY REMOVED]"),
    (re.compile(r"(?i)((?:password|passwort|token|secret|api[_-]?key)\s*[=:]\s*)\S+"), r"\1[REMOVED]"),
]
def sauber(t):
    t = re.sub(r"<system-reminder>.*?</system-reminder>", "", t, flags=re.S)
    for muster, ersatz in GEHEIM:
        t = muster.sub(ersatz, t)
    return t.strip()

teile, start = [], None
for zeile in open(verlauf, encoding="utf-8"):
    try:
        e = json.loads(zeile)
    except Exception:
        continue
    if e.get("isSidechain") or e.get("type") not in ("user", "assistant"):
        continue
    zeit = (e.get("timestamp") or "")[:16].replace("T", " ")
    start = start or zeit
    inhalt = (e.get("message") or {}).get("content")
    if isinstance(inhalt, str):
        inhalt = [{"type": "text", "text": inhalt}]
    if not isinstance(inhalt, list):
        continue
    texte, werkzeuge = [], []
    for b in inhalt:
        if b.get("type") == "text":
            t = sauber(b.get("text", ""))
            if t:
                texte.append(t)
        elif b.get("type") == "tool_use":
            ein = b.get("input") or {}
            info = ein.get("description") or ein.get("file_path") or ein.get("query") or ein.get("pattern") or ""
            werkzeuge.append(f"- 🔧 {b.get('name')}" + (f": {sauber(str(info))[:120]}" if info else ""))
    if e["type"] == "user" and texte:
        teile.append(f"### 🧑 Philip · {zeit}\n\n" + "\n\n".join(texte))
    elif e["type"] == "assistant" and (texte or werkzeuge):
        teile.append(f"### 🤖 Claude · {zeit}\n\n" + "\n\n".join(texte + (["\n".join(werkzeuge)] if werkzeuge else [])))

if not teile:
    raise SystemExit(0)

datum = (start or datetime.date.today().isoformat())[:10]
ordner = os.path.join(projekt, "chats")
os.makedirs(ordner, exist_ok=True)
datei = os.path.join(ordner, f"{datum}_{sitzung}.md")
name = os.path.basename(projekt)
kopf = (f"# 💬 Chat history {name}\n\n"
        f"Session `{sitzung}` · started {start} · last saved "
        f"{datetime.datetime.now().strftime('%Y-%m-%d %H:%M')}\n\n"
        "Saved automatically on push (hook `chat-sichern.sh`). Tool outputs are omitted, "
        "detected tokens and passwords removed.\n\n---\n\n")
with open(datei, "w", encoding="utf-8", newline="\n") as f:
    f.write(kopf + "\n\n---\n\n".join(teile) + "\n")

g = lambda *a: subprocess.run(["git", "-C", projekt, *a], capture_output=True, text=True)
g("add", "--", os.path.relpath(datei, projekt))
if g("diff", "--cached", "--quiet", "--", os.path.relpath(datei, projekt)).returncode == 0:
    raise SystemExit(0)
nachricht = "Chat history saved"
try:
    if "Written with Claude" in open(os.path.join(projekt, "CLAUDE.md"), encoding="utf-8").read():
        nachricht += "\n\nWritten with Claude 🤖"
except Exception:
    pass
g("commit", "-m", nachricht, "--", os.path.relpath(datei, projekt))
PY
exit 0
