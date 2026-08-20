#!/bin/sh
# Deploy-time AI coding agent selection (runs as developer, idempotent).
#
# Reads the install-form choice from ~/.cf-coding-agent (written by the JPS
# manifest; file transport because su/sudo transitions drop container env).
# Values: claude (form default) | codex | copilot. A missing or invalid file
# falls back to copilot: if the choice ever fails to reach the container, the
# environment still has the built-in agent to work with.
#
# For claude/codex the built-in GitHub Copilot is removed from THIS
# environment only — the image keeps it on purpose, so a future
# "keep GitHub Copilot" option remains a one-word change.
set -eu

export HOME="${HOME:-/home/developer}"
export PATH=/opt/node-current/bin:/usr/local/bin:/usr/bin:/bin:$PATH

AGENT="$(cat "${HOME}/.cf-coding-agent" 2>/dev/null | tr -d '[:space:]' || true)"
case "$AGENT" in claude|codex|copilot) ;; *) AGENT=copilot ;; esac
echo "[coding-agent] selected agent: $AGENT"

if [ "$AGENT" = "copilot" ]; then
  echo "[coding-agent] keeping the built-in GitHub Copilot"
  exit 0
fi

case "$AGENT" in
  claude)
    CLI_PKG="@anthropic-ai/claude-code"; CLI_BIN="claude"; EXT_ID="anthropic.claude-code" ;;
  codex)
    CLI_PKG="@openai/codex"; CLI_BIN="codex"; EXT_ID="openai.chatgpt" ;;
esac

# Remove the built-in Copilot from this environment (deploy-time, not build-time).
sudo rm -rf /usr/local/lib/vscode/extensions/copilot*

# CLI: install once; first run happens as developer so the agent's home
# directory (~/.claude, ~/.codex) is created with the right owner.
if ! command -v "$CLI_BIN" >/dev/null 2>&1; then
  n=0
  until sudo env PATH="$PATH" npm install -g "$CLI_PKG" >/tmp/npm-agent.log 2>&1; do
    n=$((n + 1)); [ "$n" -ge 3 ] && { echo "[coding-agent] npm install failed"; tail -5 /tmp/npm-agent.log; exit 1; }
    sleep 3
  done
fi
"$CLI_BIN" --version >/dev/null 2>&1 || true
echo "[coding-agent] CLI ready: $("$CLI_BIN" --version 2>/dev/null | head -1)"

# IDE extension from Open VSX; skip if already installed (restart path).
if ! code-server --list-extensions 2>/dev/null | grep -qx "$EXT_ID"; then
  n=0
  until code-server --install-extension "$EXT_ID" >/tmp/ext-agent.log 2>&1; do
    n=$((n + 1)); [ "$n" -ge 3 ] && { echo "[coding-agent] extension install failed"; tail -5 /tmp/ext-agent.log; exit 1; }
    sleep 3
  done
fi
echo "[coding-agent] extension ready: $EXT_ID"

# Claude Code model/effort defaults. The Studio SDLC workflow is long and
# menu-driven; a mid-class model at medium effort follows it step by step,
# while the account default (Opus at high effort) tends to run ahead of the
# workflow and improvise. `/model` and `/effort` are session-scoped, so the
# choice has to live in the settings file to survive a reload.
#
# setdefault, not assignment: a trainee who has already picked something
# keeps it across a re-bootstrap.
# Codex model/effort defaults, same reasoning as the claude block above:
# GPT-5.6-Terra at medium reasoning follows the Studio workflow most closely.
# Codex keeps these as top-level keys in ~/.codex/config.toml, which it does
# not create until first sign-in, so the file usually does not exist yet here.
if [ "$AGENT" = "codex" ]; then
  python3 - "${HOME}/.codex/config.toml" <<'PYCODEXSET'
import os, sys

path = sys.argv[1]
os.makedirs(os.path.dirname(path), exist_ok=True)
wanted = [("model", '"gpt-5.6-terra"'), ("model_reasoning_effort", '"medium"')]

try:
    with open(path) as fh:
        lines = fh.read().splitlines()
except OSError:
    lines = []

# Top-level keys must precede the first [table] header, so split the file at it
# and only ever inspect/extend the preamble.
head = len(lines)
for i, line in enumerate(lines):
    if line.lstrip().startswith("["):
        head = i
        break
preamble, rest = lines[:head], lines[head:]

def has_key(key):
    return any(l.split("=", 1)[0].strip() == key for l in preamble if "=" in l)

added = [ "%s = %s" % (k, v) for k, v in wanted if not has_key(k) ]
if added:
    if rest and not (preamble and preamble[-1].strip() == ""):
        preamble = preamble + [""]
    preamble = added + preamble
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        fh.write("\n".join(preamble + rest).rstrip("\n") + "\n")
    os.replace(tmp, path)

report = {}
for l in preamble:
    if "=" in l:
        k, v = l.split("=", 1)
        report[k.strip()] = v.strip()
print("[coding-agent] codex settings: model=%s model_reasoning_effort=%s"
      % (report.get("model"), report.get("model_reasoning_effort")))
PYCODEXSET
fi

if [ "$AGENT" = "claude" ]; then
  python3 - "${HOME}/.claude/settings.json" <<'PYCLAUDESET'
import json, os, sys
path = sys.argv[1]
os.makedirs(os.path.dirname(path), exist_ok=True)
try:
    with open(path) as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        data = {}
except (OSError, ValueError):
    data = {}
changed = False
for key, value in (("model", "sonnet"), ("effortLevel", "medium")):
    if key not in data:
        data[key] = value
        changed = True
if changed:
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, path)
print("[coding-agent] claude settings: model=%s effortLevel=%s" % (data.get("model"), data.get("effortLevel")))
PYCLAUDESET
fi
